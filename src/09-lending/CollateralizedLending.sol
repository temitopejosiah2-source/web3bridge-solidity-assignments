// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";

/// @title CollateralizedLending
/// @notice A single-borrow-asset lending market backed by one or more supported ERC-20
///         collateral assets, priced through a MockPriceOracle.
/// @dev Simplifying assumptions, documented rather than hidden: (1) all tokens (collateral and
///      the borrow asset) use 18 decimals, matching oracle prices scaled 1e18 USD per whole
///      token; (2) interest accrues linearly (simple interest) per second, not compounded, which
///      satisfies "block/time-based interest" without the added complexity of a compounding
///      index; (3) borrowable liquidity is pre-funded via `supplyLiquidity` rather than modeled
///      as a separate interest-earning supplier market, since the assignment scope is borrowing,
///      collateral, and liquidation, not a two-sided money market.
contract CollateralizedLending is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct CollateralConfig {
        bool supported;
        uint256 collateralFactorBps; // max LTV usable at borrow time
    }

    IERC20 public immutable borrowToken;
    MockPriceOracle public immutable oracle;
    uint256 public immutable ratePerSecond; // 1e18-scaled fraction of principal, per second
    uint256 public immutable maxPriceAge; // seconds after which a price is considered stale
    uint256 public immutable liquidationThresholdBps; // health-factor boundary, e.g. 8000 = 80%
    uint256 public immutable liquidationBonusBps; // extra collateral seized, e.g. 500 = 5%
    uint256 public immutable closeFactorBps; // max fraction of debt repayable per liquidation call

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant RATE_SCALE = 1e18;

    mapping(address => CollateralConfig) public collateralConfigs;
    mapping(address => mapping(address => uint256)) public collateralBalance; // token => user => amount
    address[] private _collateralAssetList;

    mapping(address => uint256) public borrowPrincipal;
    mapping(address => uint256) public borrowLastAccrual;
    uint256 public totalBorrows;
    uint256 public totalSupplied;

    event CollateralAssetAdded(address indexed token, uint256 collateralFactorBps);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event LiquiditySupplied(address indexed supplier, uint256 amount);
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateralToken,
        uint256 repaidAmount,
        uint256 collateralSeized,
        bool badDebt
    );

    error AssetNotSupported();
    error ZeroAmount();
    error InsufficientCollateralBalance();
    error UnhealthyPosition();
    error InsufficientLiquidity();
    error NoDebt();
    error StalePrice();
    error NotLiquidatable();
    error ExceedsCloseFactor();
    error InvalidConfig();

    constructor(
        IERC20 _borrowToken,
        MockPriceOracle _oracle,
        uint256 _ratePerSecond,
        uint256 _maxPriceAge,
        uint256 _liquidationThresholdBps,
        uint256 _liquidationBonusBps,
        uint256 _closeFactorBps,
        address initialOwner
    ) Ownable(initialOwner) {
        if (_liquidationThresholdBps == 0 || _liquidationThresholdBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (_closeFactorBps == 0 || _closeFactorBps > BPS_DENOMINATOR) revert InvalidConfig();

        borrowToken = _borrowToken;
        oracle = _oracle;
        ratePerSecond = _ratePerSecond;
        maxPriceAge = _maxPriceAge;
        liquidationThresholdBps = _liquidationThresholdBps;
        liquidationBonusBps = _liquidationBonusBps;
        closeFactorBps = _closeFactorBps;
    }

    // ---------- Admin ----------

    function addCollateralAsset(address token, uint256 collateralFactorBps) external onlyOwner {
        if (collateralFactorBps == 0 || collateralFactorBps > liquidationThresholdBps) revert InvalidConfig();
        if (!collateralConfigs[token].supported) {
            _collateralAssetList.push(token);
        }
        collateralConfigs[token] = CollateralConfig({supported: true, collateralFactorBps: collateralFactorBps});
        emit CollateralAssetAdded(token, collateralFactorBps);
    }

    /// @notice Anyone may seed borrowable liquidity (no shares/interest modeled -- see contract NatSpec).
    function supplyLiquidity(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        borrowToken.safeTransferFrom(msg.sender, address(this), amount);
        totalSupplied += amount;
        emit LiquiditySupplied(msg.sender, amount);
    }

    // ---------- Interest accrual ----------

    /// @notice Current debt including linearly accrued interest, without mutating state.
    function currentDebt(address user) public view returns (uint256) {
        uint256 principal = borrowPrincipal[user];
        if (principal == 0) return 0;
        uint256 elapsed = block.timestamp - borrowLastAccrual[user];
        uint256 interest = (principal * ratePerSecond * elapsed) / RATE_SCALE;
        return principal + interest;
    }

    function _accrue(address user) internal {
        if (borrowPrincipal[user] > 0) {
            borrowPrincipal[user] = currentDebt(user);
        }
        borrowLastAccrual[user] = block.timestamp;
    }

    // ---------- Pricing ----------

    function _priceOf(address token) internal view returns (uint256) {
        (uint256 price, uint256 updatedAt) = oracle.getPrice(token); // reverts if never set (missing)
        if (block.timestamp - updatedAt > maxPriceAge) revert StalePrice();
        return price;
    }

    /// @dev USD value (1e18-scaled) of `amount` (1e18-scaled token units) at the current price.
    function _valueUSD(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return (amount * _priceOf(token)) / RATE_SCALE;
    }

    // ---------- Collateral ----------

    function depositCollateral(address token, uint256 amount) external nonReentrant {
        if (!collateralConfigs[token].supported) revert AssetNotSupported();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        collateralBalance[token][msg.sender] += amount;

        emit CollateralDeposited(msg.sender, token, amount);
    }

    function withdrawCollateral(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (collateralBalance[token][msg.sender] < amount) revert InsufficientCollateralBalance();

        _accrue(msg.sender);

        collateralBalance[token][msg.sender] -= amount;
        if (_debtValueUSD(msg.sender) > _sumCollateralUSD(msg.sender, false)) revert UnhealthyPosition();

        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    // ---------- Borrow / repay ----------

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrue(msg.sender);
        borrowPrincipal[msg.sender] += amount;

        if (_debtValueUSD(msg.sender) > _sumCollateralUSD(msg.sender, false)) revert UnhealthyPosition();
        if (borrowToken.balanceOf(address(this)) < amount) revert InsufficientLiquidity();

        totalBorrows += amount;
        borrowToken.safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _accrue(msg.sender);
        uint256 debt = borrowPrincipal[msg.sender];
        if (debt == 0) revert NoDebt();

        uint256 payment = amount > debt ? debt : amount;
        borrowPrincipal[msg.sender] = debt - payment;
        totalBorrows = totalBorrows > payment ? totalBorrows - payment : 0;

        borrowToken.safeTransferFrom(msg.sender, address(this), payment);

        emit Repaid(msg.sender, payment);
    }

    // ---------- Liquidation ----------

    function healthFactor(address user) public view returns (uint256) {
        uint256 debtValue = _valueUSD(address(borrowToken), currentDebt(user));
        if (debtValue == 0) return type(uint256).max;
        uint256 adjustedCollateral = _sumCollateralUSD(user, true);
        return (adjustedCollateral * RATE_SCALE) / debtValue;
    }

    /// @notice Liquidate an unhealthy position by repaying up to `closeFactorBps` of its debt in
    ///         exchange for a bonus-adjusted amount of the specified collateral asset.
    function liquidate(address borrower, address collateralToken, uint256 repayAmount) external nonReentrant {
        if (repayAmount == 0) revert ZeroAmount();
        _accrue(borrower);

        if (healthFactor(borrower) >= RATE_SCALE) revert NotLiquidatable();

        uint256 debt = borrowPrincipal[borrower];
        uint256 maxRepay = (debt * closeFactorBps) / BPS_DENOMINATOR;
        if (repayAmount > maxRepay) revert ExceedsCloseFactor();

        borrowToken.safeTransferFrom(msg.sender, address(this), repayAmount);
        borrowPrincipal[borrower] = debt - repayAmount;
        totalBorrows = totalBorrows > repayAmount ? totalBorrows - repayAmount : 0;

        uint256 repayValueUSD = _valueUSD(address(borrowToken), repayAmount);
        uint256 seizeValueUSD = (repayValueUSD * (BPS_DENOMINATOR + liquidationBonusBps)) / BPS_DENOMINATOR;
        uint256 collateralPrice = _priceOf(collateralToken);
        uint256 seizeAmount = (seizeValueUSD * RATE_SCALE) / collateralPrice;

        uint256 available = collateralBalance[collateralToken][borrower];
        bool badDebt = false;
        uint256 actualSeize = seizeAmount;
        if (actualSeize >= available) {
            actualSeize = available; // bad debt: collateral doesn't fully cover the bonus-adjusted seize
            badDebt = true;
        }

        collateralBalance[collateralToken][borrower] -= actualSeize;
        IERC20(collateralToken).safeTransfer(msg.sender, actualSeize);

        emit Liquidated(msg.sender, borrower, collateralToken, repayAmount, actualSeize, badDebt);
    }

    // ---------- Internal value helpers ----------

    function _debtValueUSD(address user) internal view returns (uint256) {
        return _valueUSD(address(borrowToken), borrowPrincipal[user]);
    }

    /// @param useLiquidationThreshold true => value using liquidationThresholdBps (health factor);
    ///        false => value using each asset's own collateralFactorBps (borrow limit).
    function _sumCollateralUSD(address user, bool useLiquidationThreshold) internal view returns (uint256 total) {
        uint256 len = _collateralAssetList.length;
        for (uint256 i = 0; i < len; i++) {
            address token = _collateralAssetList[i];
            uint256 bal = collateralBalance[token][user];
            if (bal == 0) continue;
            uint256 factorBps = useLiquidationThreshold ? liquidationThresholdBps : collateralConfigs[token].collateralFactorBps;
            total += (_valueUSD(token, bal) * factorBps) / BPS_DENOMINATOR;
        }
    }
}
