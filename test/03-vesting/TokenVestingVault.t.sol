// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenVestingVault} from "../../src/03-vesting/TokenVestingVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenVestingVaultTest is Test {
    TokenVestingVault vault;
    MockERC20 token;

    address owner = makeAddr("owner");
    address beneficiary = makeAddr("beneficiary");
    address stranger = makeAddr("stranger");

    uint256 constant TOTAL = 120_000e18;
    uint64 start;
    uint64 cliff;
    uint64 duration = 360 days;
    uint256 scheduleId;

    function setUp() public {
        vault = new TokenVestingVault(owner);
        token = new MockERC20("Grant Token", "GRT", 18);

        token.mint(owner, TOTAL);
        vm.prank(owner);
        token.approve(address(vault), TOTAL);

        start = uint64(block.timestamp);
        cliff = start + 90 days;

        vm.prank(owner);
        scheduleId = vault.createSchedule(beneficiary, IERC20(address(token)), TOTAL, start, cliff, duration, true);
    }

    // ---------- Pre-cliff ----------

    function test_RevertWhen_ClaimBeforeCliff() public {
        vm.warp(start + 30 days);
        vm.prank(beneficiary);
        vm.expectRevert(TokenVestingVault.NothingToClaim.selector);
        vault.claim(scheduleId);
    }

    function test_VestedAmountZero_BeforeCliff() public {
        vm.warp(start + 1 days);
        assertEq(vault.vestedAmount(scheduleId), 0);
    }

    // ---------- Partial vesting ----------

    function test_PartialVesting_AtCliff() public {
        vm.warp(cliff);
        uint256 expected = (TOTAL * (cliff - start)) / duration;
        assertEq(vault.vestedAmount(scheduleId), expected);
    }

    function test_PartialClaim_Halfway() public {
        vm.warp(start + duration / 2);
        uint256 expected = TOTAL / 2;

        vm.prank(beneficiary);
        vault.claim(scheduleId);

        assertEq(token.balanceOf(beneficiary), expected);
    }

    // ---------- Full vesting ----------

    function test_FullVesting_AfterDuration() public {
        vm.warp(start + duration + 1 days);
        assertEq(vault.vestedAmount(scheduleId), TOTAL);

        vm.prank(beneficiary);
        vault.claim(scheduleId);
        assertEq(token.balanceOf(beneficiary), TOTAL);
    }

    // ---------- Repeated claims ----------

    function test_RevertWhen_DoubleClaimSameMoment() public {
        vm.warp(start + duration / 2);
        vm.prank(beneficiary);
        vault.claim(scheduleId);

        vm.prank(beneficiary);
        vm.expectRevert(TokenVestingVault.NothingToClaim.selector);
        vault.claim(scheduleId);
    }

    function test_SequentialClaims_AccumulateCorrectly() public {
        vm.warp(start + duration / 4);
        vm.prank(beneficiary);
        vault.claim(scheduleId);
        uint256 firstBalance = token.balanceOf(beneficiary);

        vm.warp(start + duration / 2);
        vm.prank(beneficiary);
        vault.claim(scheduleId);

        assertEq(token.balanceOf(beneficiary), TOTAL / 2);
        assertGt(token.balanceOf(beneficiary), firstBalance);
    }

    function test_RevertWhen_NonBeneficiaryClaims() public {
        vm.warp(start + duration / 2);
        vm.prank(stranger);
        vm.expectRevert(TokenVestingVault.NotBeneficiary.selector);
        vault.claim(scheduleId);
    }

    // ---------- Revocation ----------

    function test_Revoke_PreservesVestedKeepsClaimable() public {
        vm.warp(start + duration / 2); // 50% vested
        uint256 vestedAtRevoke = vault.vestedAmount(scheduleId);

        vm.prank(owner);
        vault.revoke(scheduleId);

        // Beneficiary can still claim what had already vested.
        vm.prank(beneficiary);
        vault.claim(scheduleId);
        assertEq(token.balanceOf(beneficiary), vestedAtRevoke);

        // Owner got the unvested remainder back immediately.
        assertEq(token.balanceOf(owner), TOTAL - vestedAtRevoke);
    }

    function test_Revoke_FreezesFurtherVesting() public {
        vm.warp(start + duration / 4); // 25% vested
        vm.prank(owner);
        vault.revoke(scheduleId);

        uint256 frozen = vault.vestedAmount(scheduleId);

        // Time passes well past what would have been full vesting.
        vm.warp(start + duration + 10 days);
        assertEq(vault.vestedAmount(scheduleId), frozen, "vested amount must not grow after revocation");
    }

    function test_RevertWhen_RevokeNonRevocableSchedule() public {
        vm.prank(owner);
        token.mint(owner, TOTAL);
        vm.prank(owner);
        token.approve(address(vault), TOTAL);

        vm.prank(owner);
        uint256 nonRevocableId =
            vault.createSchedule(beneficiary, IERC20(address(token)), TOTAL, start, cliff, duration, false);

        vm.prank(owner);
        vm.expectRevert(TokenVestingVault.NotRevocable.selector);
        vault.revoke(nonRevocableId);
    }

    function test_RevertWhen_DoubleRevoke() public {
        vm.warp(start + duration / 2);
        vm.prank(owner);
        vault.revoke(scheduleId);

        vm.prank(owner);
        vm.expectRevert(TokenVestingVault.AlreadyRevoked.selector);
        vault.revoke(scheduleId);
    }

    function test_RevertWhen_UnauthorizedRevoke() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.revoke(scheduleId);
    }

    // ---------- Invalid schedules ----------

    function test_RevertWhen_CliffBeforeStart() public {
        token.mint(owner, TOTAL);
        vm.prank(owner);
        token.approve(address(vault), TOTAL);

        vm.prank(owner);
        vm.expectRevert(TokenVestingVault.InvalidSchedule.selector);
        vault.createSchedule(beneficiary, IERC20(address(token)), TOTAL, start + 100, start, duration, true);
    }

    function test_RevertWhen_ZeroAmountSchedule() public {
        vm.prank(owner);
        vm.expectRevert(TokenVestingVault.InvalidSchedule.selector);
        vault.createSchedule(beneficiary, IERC20(address(token)), 0, start, cliff, duration, true);
    }

    // ---------- Fuzz: linear vesting bounds ----------

    function testFuzz_VestedAmountNeverExceedsTotal(uint256 warpSeconds) public {
        warpSeconds = bound(warpSeconds, 0, uint256(duration) * 3);
        vm.warp(start + warpSeconds);
        assertLe(vault.vestedAmount(scheduleId), TOTAL);
    }
}
