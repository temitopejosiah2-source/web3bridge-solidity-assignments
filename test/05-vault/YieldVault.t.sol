// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../../src/05-vault/YieldVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract YieldVaultTest is Test {
    YieldVault vault;
    MockERC20 asset;

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant FEE_BPS = 200; // 2%

    function setUp() public {
        asset = new MockERC20("Yield Asset", "YLD", 18);
        vault = new YieldVault(IERC20(address(asset)), "Yield Vault", "vYLD", FEE_BPS, feeRecipient, owner);

        asset.mint(alice, 1_000_000e18);
        asset.mint(bob, 1_000_000e18);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }

    // ---------- First deposit ----------

    function test_FirstDeposit_MintsShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e18, alice);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), 1_000e18);
    }

    function test_RevertWhen_ZeroAssetDeposit() public {
        vm.prank(alice);
        vm.expectRevert(YieldVault.ZeroAssets.selector);
        vault.deposit(0, alice);
    }

    function test_RevertWhen_ZeroShareMint() public {
        vm.prank(alice);
        vm.expectRevert(YieldVault.ZeroShares.selector);
        vault.mint(0, alice);
    }

    // ---------- Multiple depositors ----------

    function test_MultipleDepositors_ShareSupplyProportional() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000e18, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(2_000e18, bob);

        // Bob deposited exactly 2x Alice's amount at the same share price -> ~2x shares.
        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18);
        assertEq(vault.totalAssets(), 3_000e18);
    }

    // ---------- Yield gains raise share price ----------

    function test_YieldAccrual_RaisesRedeemableAssets() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000e18, alice);

        // Simulate yield: assets appear in the vault without new shares minted (e.g. a strategy return).
        asset.mint(address(vault), 500e18);

        uint256 redeemable = vault.previewRedeem(aliceShares);
        assertGt(redeemable, 1_000e18);
    }

    function test_YieldAccrual_BenefitsAllHoldersProRata() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);
        vm.prank(bob);
        vault.deposit(1_000e18, bob);

        asset.mint(address(vault), 400e18); // yield split 50/50 by share proportion

        uint256 aliceRedeemable = vault.previewRedeem(vault.balanceOf(alice));
        uint256 bobRedeemable = vault.previewRedeem(vault.balanceOf(bob));

        assertApproxEqRel(aliceRedeemable, bobRedeemable, 0.001e18);
    }

    // ---------- Withdrawals & fees ----------

    function test_Withdraw_ChargesExitFeeToFeeRecipient() public {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);

        uint256 withdrawAmount = 5_000e18;
        uint256 expectedFee = (withdrawAmount * FEE_BPS) / vault.BPS_DENOMINATOR();
        uint256 expectedNet = withdrawAmount - expectedFee;

        uint256 aliceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(asset.balanceOf(alice) - aliceBefore, expectedNet);
        assertEq(asset.balanceOf(feeRecipient), expectedFee);
    }

    function test_Redeem_ChargesExitFeeToFeeRecipient() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(10_000e18, alice);

        uint256 grossAssets = vault.previewRedeem(shares);
        uint256 expectedFee = (grossAssets * FEE_BPS) / vault.BPS_DENOMINATOR();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(asset.balanceOf(feeRecipient), expectedFee);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_ExitFee_DoesNotCorruptExchangeRateForRemainingHolders() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);
        vm.prank(bob);
        vault.deposit(1_000e18, bob);

        uint256 bobRedeemableBefore = vault.previewRedeem(vault.balanceOf(bob));

        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);

        uint256 bobRedeemableAfter = vault.previewRedeem(vault.balanceOf(bob));

        // Bob's own redeemable value is unaffected by Alice's exit fee -- the fee comes out of
        // Alice's withdrawal, not out of the shared pool.
        assertApproxEqRel(bobRedeemableAfter, bobRedeemableBefore, 0.001e18);
    }

    function test_RevertWhen_ZeroAssetWithdraw() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        vm.prank(alice);
        vm.expectRevert(YieldVault.ZeroAssets.selector);
        vault.withdraw(0, alice, alice);
    }

    // ---------- Over-withdrawal / excessive redemption ----------

    function test_RevertWhen_WithdrawMoreThanOwned() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(2_000e18, alice, alice);
    }

    function test_RevertWhen_RedeemMoreSharesThanOwned() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e18, alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares + 1, alice, alice);
    }

    function test_RevertWhen_WithdrawWithoutAllowance() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        // Bob has no allowance over Alice's shares.
        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(500e18, bob, alice);
    }

    // ---------- Rounding boundaries ----------

    function test_RoundingNeverMintsFreeShares_ForDustDeposit() public {
        // Prime the vault with a large pre-existing balance to create a steep share price,
        // then attempt a dust deposit.
        vm.prank(alice);
        vault.deposit(1_000_000e18, alice);
        asset.mint(address(vault), 9_000_000e18); // pushes share price very high

        vm.prank(bob);
        uint256 shares = vault.deposit(1, bob); // 1 wei of asset

        // Either zero shares are minted (deposit reverts) or a strictly fair, non-exploitable
        // rounding-down amount is minted -- never more value in shares than was deposited.
        uint256 valueBack = vault.previewRedeem(shares);
        assertLe(valueBack, 1);
    }

    function testFuzz_ConvertToSharesNeverExceedsConvertToAssetsRoundTrip(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e18);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);
        uint256 assetsBack = vault.previewRedeem(shares);

        // Rounding must only ever cost the depositor dust, never hand them a profit.
        assertLe(assetsBack, depositAmount);
    }
}
