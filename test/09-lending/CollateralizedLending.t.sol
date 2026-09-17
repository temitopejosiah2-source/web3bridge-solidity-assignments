// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralizedLending} from "../../src/09-lending/CollateralizedLending.sol";
import {MockPriceOracle} from "../../src/09-lending/MockPriceOracle.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CollateralizedLendingTest is Test {
    CollateralizedLending lending;
    MockPriceOracle oracle;
    MockERC20 usdc; // borrow asset
    MockERC20 weth; // collateral asset

    address platformOwner = makeAddr("platformOwner");
    address liquidityProvider = makeAddr("liquidityProvider");
    address alice = makeAddr("alice"); // borrower
    address liquidator = makeAddr("liquidator");

    uint256 constant RATE_PER_SECOND = 317; // ~1% APR scaled 1e18 (317 / 1e18 * 31.5M sec/yr ~= 1%)
    uint256 constant MAX_PRICE_AGE = 1 hours;
    uint256 constant LIQ_THRESHOLD_BPS = 8_000; // 80%
    uint256 constant LIQ_BONUS_BPS = 500; // 5%
    uint256 constant CLOSE_FACTOR_BPS = 5_000; // 50%
    uint256 constant COLLATERAL_FACTOR_BPS = 7_500; // 75%

    uint256 constant WETH_PRICE = 2_000e18; // $2000
    uint256 constant USDC_PRICE = 1e18; // $1

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 18);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        oracle = new MockPriceOracle(platformOwner);

        lending = new CollateralizedLending(
            IERC20(address(usdc)),
            oracle,
            RATE_PER_SECOND,
            MAX_PRICE_AGE,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            CLOSE_FACTOR_BPS,
            platformOwner
        );

        vm.startPrank(platformOwner);
        lending.addCollateralAsset(address(weth), COLLATERAL_FACTOR_BPS);
        oracle.setPrice(address(weth), WETH_PRICE);
        oracle.setPrice(address(usdc), USDC_PRICE);
        vm.stopPrank();

        usdc.mint(liquidityProvider, 1_000_000e18);
        vm.prank(liquidityProvider);
        usdc.approve(address(lending), type(uint256).max);
        vm.prank(liquidityProvider);
        lending.supplyLiquidity(500_000e18);

        weth.mint(alice, 100e18);
        vm.prank(alice);
        weth.approve(address(lending), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(lending), type(uint256).max);

        usdc.mint(liquidator, 1_000_000e18);
        vm.prank(liquidator);
        usdc.approve(address(lending), type(uint256).max);
    }

    // ---------- Healthy borrowing ----------

    function test_DepositAndBorrow_WithinLimit() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18); // $20,000 collateral
        lending.borrow(10_000e18); // well within 75% of $20,000 = $15,000
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 10_000e18);
        assertEq(lending.currentDebt(alice), 10_000e18);
    }

    function test_RevertWhen_DepositUnsupportedAsset() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(alice, 100e18);
        vm.prank(alice);
        randomToken.approve(address(lending), 100e18);

        vm.prank(alice);
        vm.expectRevert(CollateralizedLending.AssetNotSupported.selector);
        lending.depositCollateral(address(randomToken), 10e18);
    }

    // ---------- Interest accrual over time ----------

    function test_InterestAccrues_OverTime() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(10_000e18);
        vm.stopPrank();

        uint256 debtBefore = lending.currentDebt(alice);

        vm.warp(block.timestamp + 365 days);

        uint256 debtAfter = lending.currentDebt(alice);
        assertGt(debtAfter, debtBefore, "debt must grow with elapsed time");
    }

    function test_InterestAccrual_MatchesLinearFormula() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(10_000e18);
        vm.stopPrank();

        uint256 elapsed = 180 days;
        vm.warp(block.timestamp + elapsed);

        uint256 expectedInterest = (10_000e18 * RATE_PER_SECOND * elapsed) / 1e18;
        assertEq(lending.currentDebt(alice), 10_000e18 + expectedInterest);
    }

    // ---------- Price drops ----------

    function test_PriceDrop_ReducesHealthFactor() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(12_000e18); // 80% liq threshold of $20,000 = $16,000 headroom
        vm.stopPrank();

        uint256 healthyBefore = lending.healthFactor(alice);
        assertGe(healthyBefore, 1e18);

        vm.prank(platformOwner);
        oracle.setPrice(address(weth), 1_000e18); // WETH crashes 50%

        uint256 healthAfter = lending.healthFactor(alice);
        assertLt(healthAfter, healthyBefore);
        assertLt(healthAfter, 1e18, "position should now be liquidatable");
    }

    // ---------- Over-borrow prevention ----------

    function test_RevertWhen_BorrowExceedsCollateralFactor() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18); // $20,000, 75% = $15,000 limit

        vm.expectRevert(CollateralizedLending.UnhealthyPosition.selector);
        lending.borrow(15_001e18);
        vm.stopPrank();
    }

    function test_RevertWhen_BorrowExceedsAvailableLiquidity() public {
        // Deposit huge collateral but try to borrow more than the pool has supplied.
        weth.mint(alice, 1_000e18);
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1_000e18); // $2,000,000 collateral, way under LTV limit

        vm.expectRevert(CollateralizedLending.InsufficientLiquidity.selector);
        lending.borrow(600_000e18); // pool only has 500,000e18 supplied
        vm.stopPrank();
    }

    // ---------- Repayment ----------

    function test_PartialRepay_ReducesDebt() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(10_000e18);
        lending.repay(4_000e18);
        vm.stopPrank();

        assertEq(lending.currentDebt(alice), 6_000e18);
    }

    function test_FullRepay_ZeroesDebtAndAllowsFullWithdrawal() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(10_000e18);

        vm.warp(block.timestamp + 30 days);
        uint256 debt = lending.currentDebt(alice);
        usdc.mint(alice, debt); // top up in case interest exceeds original borrow for repay
        lending.repay(debt);
        vm.stopPrank();

        assertEq(lending.currentDebt(alice), 0);

        vm.prank(alice);
        lending.withdrawCollateral(address(weth), 10e18); // no debt left, fully healthy
        assertEq(weth.balanceOf(alice), 100e18);
    }

    function test_RevertWhen_RepayWithNoDebt() public {
        vm.prank(alice);
        vm.expectRevert(CollateralizedLending.NoDebt.selector);
        lending.repay(1e18);
    }

    function test_RevertWhen_WithdrawWouldBreakHealth() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(14_000e18); // near the 75% limit of $20,000 = $15,000

        vm.expectRevert(CollateralizedLending.UnhealthyPosition.selector);
        lending.withdrawCollateral(address(weth), 9e18); // would leave far too little collateral
        vm.stopPrank();
    }

    // ---------- Liquidation ----------

    function _setUpLiquidatablePosition() internal {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18); // $20,000
        lending.borrow(12_000e18); // within 80% threshold ($16,000) at $2000/WETH
        vm.stopPrank();

        vm.prank(platformOwner);
        oracle.setPrice(address(weth), 1_300e18); // now $13,000 collateral vs $12,000 debt -> under 80% threshold ($10,400 adjusted)
    }

    function test_RevertWhen_LiquidatingHealthyPosition() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(5_000e18); // very healthy
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert(CollateralizedLending.NotLiquidatable.selector);
        lending.liquidate(alice, address(weth), 1_000e18);
    }

    function test_Liquidate_SeizesCollateralWithBonus() public {
        _setUpLiquidatablePosition();

        uint256 repayAmount = 6_000e18; // 50% close factor of 12,000 debt
        uint256 expectedSeizeValueUSD = (repayAmount * (10_000 + LIQ_BONUS_BPS)) / 10_000; // USDC price = $1
        uint256 expectedSeizeAmount = (expectedSeizeValueUSD * 1e18) / 1_300e18;

        vm.prank(liquidator);
        lending.liquidate(alice, address(weth), repayAmount);

        assertEq(weth.balanceOf(liquidator), expectedSeizeAmount);
        assertEq(lending.currentDebt(alice), 12_000e18 - repayAmount);
    }

    function test_RevertWhen_LiquidationExceedsCloseFactor() public {
        _setUpLiquidatablePosition();

        vm.prank(liquidator);
        vm.expectRevert(CollateralizedLending.ExceedsCloseFactor.selector);
        lending.liquidate(alice, address(weth), 6_001e18); // > 50% of 12,000
    }

    // ---------- Bad debt ----------

    function test_Liquidate_CapsSeizeAtAvailableCollateral_BadDebt() public {
        // Crash the price so hard that even the close-factor-bounded repay's bonus-adjusted
        // seize value exceeds what collateral remains -- classic bad debt scenario.
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(12_000e18);
        vm.stopPrank();

        vm.prank(platformOwner);
        oracle.setPrice(address(weth), 500e18); // collateral now worth only $5,000 total

        assertLt(lending.healthFactor(alice), 1e18);

        uint256 aliceCollateralBefore = lending.collateralBalance(address(weth), alice);

        vm.prank(liquidator);
        lending.liquidate(alice, address(weth), 6_000e18); // 50% close factor of 12,000

        // All remaining WETH collateral was seized (capped), not the full bonus-adjusted amount.
        assertEq(lending.collateralBalance(address(weth), alice), 0);
        assertEq(weth.balanceOf(liquidator), aliceCollateralBefore);
    }

    // ---------- Stale / missing prices ----------

    function test_RevertWhen_PriceIsStale() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(5_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + MAX_PRICE_AGE + 1); // WETH price now stale

        vm.prank(alice);
        vm.expectRevert(CollateralizedLending.StalePrice.selector);
        lending.borrow(1e18);
    }

    function test_RevertWhen_PriceNeverSet_UnsupportedInOracle() public {
        MockERC20 unpriced = new MockERC20("Unpriced", "UNP", 18);
        vm.prank(platformOwner);
        lending.addCollateralAsset(address(unpriced), 5_000);

        unpriced.mint(alice, 10e18);
        vm.prank(alice);
        unpriced.approve(address(lending), 10e18);
        vm.prank(alice);
        lending.depositCollateral(address(unpriced), 10e18);

        vm.prank(alice);
        vm.expectRevert(MockPriceOracle.AssetNotSupported.selector);
        lending.borrow(1e18);
    }

    // ---------- Fuzz: health factor never lets borrow exceed collateral factor ----------

    function testFuzz_BorrowNeverExceedsCollateralFactorLimit(uint256 collateralAmt, uint256 borrowAmt) public {
        collateralAmt = bound(collateralAmt, 1e18, 50e18);
        borrowAmt = bound(borrowAmt, 1e18, 200_000e18);

        weth.mint(alice, collateralAmt);
        vm.prank(alice);
        weth.approve(address(lending), collateralAmt);
        vm.prank(alice);
        lending.depositCollateral(address(weth), collateralAmt);

        uint256 limit = (collateralAmt * WETH_PRICE / 1e18) * COLLATERAL_FACTOR_BPS / 10_000;

        vm.prank(alice);
        if (borrowAmt > limit || borrowAmt > 500_000e18) {
            vm.expectRevert();
            lending.borrow(borrowAmt);
        } else {
            lending.borrow(borrowAmt);
            assertLe(lending.currentDebt(alice), limit);
        }
    }
}
