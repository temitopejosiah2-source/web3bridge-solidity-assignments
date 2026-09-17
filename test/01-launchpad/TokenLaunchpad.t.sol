// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenLaunchpad} from "../../src/01-launchpad/TokenLaunchpad.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenLaunchpadTest is Test {
    TokenLaunchpad launchpad;
    MockERC20 token;

    address creator = makeAddr("creator");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant PRICE = 0.001 ether; // per 1e18 tokens
    uint256 constant ALLOCATION = 1_000_000e18;
    uint256 constant HARD_CAP = 10 ether;
    uint256 constant WALLET_LIMIT = 2_000e18;
    uint256 startTime;
    uint256 endTime;
    uint256 saleId;

    function setUp() public {
        launchpad = new TokenLaunchpad(500, feeRecipient); // 5% fee
        token = new MockERC20("Sale Token", "SALE", 18);

        token.mint(creator, ALLOCATION);
        vm.prank(creator);
        token.approve(address(launchpad), ALLOCATION);

        startTime = block.timestamp + 1 days;
        endTime = startTime + 7 days;

        vm.prank(creator);
        saleId = launchpad.createSale(IERC20(address(token)), PRICE, ALLOCATION, startTime, endTime, HARD_CAP, WALLET_LIMIT);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _cost(uint256 amount) internal pure returns (uint256) {
        return (amount * PRICE) / 1e18;
    }

    // ---------- Time window enforcement ----------

    function test_RevertWhen_BuyBeforeStart() public {
        vm.prank(alice);
        vm.expectRevert(TokenLaunchpad.SaleNotActive.selector);
        launchpad.buy{value: _cost(100e18)}(saleId, 100e18);
    }

    function test_RevertWhen_BuyAfterEnd() public {
        vm.warp(endTime + 1);
        vm.prank(alice);
        vm.expectRevert(TokenLaunchpad.SaleNotActive.selector);
        launchpad.buy{value: _cost(100e18)}(saleId, 100e18);
    }

    function test_BuySucceeds_DuringWindow() public {
        vm.warp(startTime);
        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);
        assertEq(launchpad.purchased(saleId, alice), 500e18);
    }

    // ---------- Multiple buyers ----------

    function test_MultipleBuyers_TrackSeparately() public {
        vm.warp(startTime);

        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);

        vm.prank(bob);
        launchpad.buy{value: _cost(1_000e18)}(saleId, 1_000e18);

        assertEq(launchpad.purchased(saleId, alice), 500e18);
        assertEq(launchpad.purchased(saleId, bob), 1_000e18);

        (,,,,,,,, uint256 totalRaised, uint256 totalSold,,) = launchpad.sales(saleId);
        assertEq(totalSold, 1_500e18);
        assertEq(totalRaised, _cost(500e18) + _cost(1_000e18));
    }

    // ---------- Incorrect payment ----------

    function test_RevertWhen_IncorrectPayment() public {
        vm.warp(startTime);
        vm.prank(alice);
        vm.expectRevert(TokenLaunchpad.IncorrectPayment.selector);
        launchpad.buy{value: _cost(500e18) - 1}(saleId, 500e18);
    }

    // ---------- Wallet limit ----------

    function test_RevertWhen_WalletLimitExceeded() public {
        vm.warp(startTime);
        vm.startPrank(alice);
        launchpad.buy{value: _cost(WALLET_LIMIT)}(saleId, WALLET_LIMIT);
        vm.expectRevert(TokenLaunchpad.WalletLimitExceeded.selector);
        launchpad.buy{value: _cost(1e15)}(saleId, 1e15);
        vm.stopPrank();
    }

    // ---------- Hard cap ----------

    function test_RevertWhen_HardCapExceeded() public {
        vm.warp(startTime);
        // Buy enough from many wallets to approach the hard cap, then push one over.
        uint256 nearCapTokens = (HARD_CAP * 1e18) / PRICE; // tokens worth exactly hard cap
        // Split across two purchases from different wallets due to wallet limit constraints
        // Use a wallet-limit-free scenario by raising limit for this test via a fresh sale.
        vm.stopPrank();

        token.mint(creator, ALLOCATION);
        vm.prank(creator);
        token.approve(address(launchpad), ALLOCATION);
        vm.prank(creator);
        uint256 bigSaleId =
            launchpad.createSale(IERC20(address(token)), PRICE, ALLOCATION, startTime, endTime, HARD_CAP, ALLOCATION);

        vm.prank(alice);
        launchpad.buy{value: HARD_CAP}(bigSaleId, nearCapTokens);

        vm.prank(bob);
        vm.expectRevert(TokenLaunchpad.HardCapExceeded.selector);
        launchpad.buy{value: _cost(1e18)}(bigSaleId, 1e18);
    }

    // ---------- Claims ----------

    function test_RevertWhen_ClaimBeforeSaleEnds() public {
        vm.warp(startTime);
        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);

        vm.prank(alice);
        vm.expectRevert(TokenLaunchpad.SaleStillActive.selector);
        launchpad.claim(saleId);
    }

    function test_ClaimSucceeds_AfterSaleEnds() public {
        vm.warp(startTime);
        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);

        vm.warp(endTime + 1);
        vm.prank(alice);
        launchpad.claim(saleId);

        assertEq(token.balanceOf(alice), 500e18);
        assertTrue(launchpad.claimed(saleId, alice));
    }

    function test_RevertWhen_DoubleClaim() public {
        vm.warp(startTime);
        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);

        vm.warp(endTime + 1);
        vm.prank(alice);
        launchpad.claim(saleId);

        vm.prank(alice);
        vm.expectRevert(TokenLaunchpad.AlreadyClaimed.selector);
        launchpad.claim(saleId);
    }

    function test_RevertWhen_NothingToClaim() public {
        vm.warp(endTime + 1);
        vm.prank(bob);
        vm.expectRevert(TokenLaunchpad.NothingToClaim.selector);
        launchpad.claim(saleId);
    }

    // ---------- Withdrawals ----------

    function test_RevertWhen_UnauthorizedWithdraw() public {
        vm.warp(startTime);
        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);

        vm.warp(endTime + 1);
        vm.prank(bob); // not the creator
        vm.expectRevert(TokenLaunchpad.NotCreator.selector);
        launchpad.withdrawProceeds(saleId);
    }

    function test_RevertWhen_WithdrawBeforeSaleEnds() public {
        vm.warp(startTime);
        vm.prank(creator);
        vm.expectRevert(TokenLaunchpad.SaleStillActive.selector);
        launchpad.withdrawProceeds(saleId);
    }

    function test_WithdrawProceeds_SplitsFeeCorrectly() public {
        vm.warp(startTime);
        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);

        uint256 raised = _cost(500e18);
        uint256 expectedFee = (raised * 500) / 10_000;
        uint256 expectedCreator = raised - expectedFee;

        vm.warp(endTime + 1);
        vm.prank(creator);
        launchpad.withdrawProceeds(saleId);

        assertEq(feeRecipient.balance, expectedFee);
        assertEq(creator.balance, expectedCreator);
    }

    function test_RevertWhen_DoubleWithdraw() public {
        vm.warp(startTime);
        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);

        vm.warp(endTime + 1);
        vm.prank(creator);
        launchpad.withdrawProceeds(saleId);

        vm.prank(creator);
        vm.expectRevert(TokenLaunchpad.AlreadyWithdrawn.selector);
        launchpad.withdrawProceeds(saleId);
    }

    // ---------- Unsold recovery ----------

    function test_RecoverUnsold_ReturnsCorrectAmount() public {
        vm.warp(startTime);
        vm.prank(alice);
        launchpad.buy{value: _cost(500e18)}(saleId, 500e18);

        vm.warp(endTime + 1);
        vm.prank(creator);
        launchpad.recoverUnsold(saleId);

        assertEq(token.balanceOf(creator), ALLOCATION - 500e18);
    }

    function test_RevertWhen_UnauthorizedRecovery() public {
        vm.warp(endTime + 1);
        vm.prank(alice);
        vm.expectRevert(TokenLaunchpad.NotCreator.selector);
        launchpad.recoverUnsold(saleId);
    }

    function test_RevertWhen_DoubleRecovery() public {
        vm.warp(endTime + 1);
        vm.prank(creator);
        launchpad.recoverUnsold(saleId);

        vm.prank(creator);
        vm.expectRevert(TokenLaunchpad.AlreadyRecovered.selector);
        launchpad.recoverUnsold(saleId);
    }

    // ---------- Fuzz: exact payment boundary ----------

    function testFuzz_BuyRevertsOnAnyIncorrectPayment(uint256 amount, uint256 delta) public {
        amount = bound(amount, 1e18, WALLET_LIMIT);
        delta = bound(delta, 1, 1 ether);

        vm.warp(startTime);
        uint256 correctCost = _cost(amount);

        vm.prank(alice);
        vm.expectRevert(TokenLaunchpad.IncorrectPayment.selector);
        launchpad.buy{value: correctCost + delta}(saleId, amount);
    }
}
