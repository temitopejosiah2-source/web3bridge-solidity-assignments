// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title YieldVault
/// @notice ERC-4626 tokenized vault. Depositors receive shares priced against the vault's total
///         asset balance, so yield added directly to the vault (e.g. by a strategy or airdrop)
///         raises the value of every existing share pro-rata.
/// @dev Inflation-attack protection: inherits OpenZeppelin's virtual-shares/virtual-assets offset
///      (see ERC4626._decimalsOffset, set to 3 here) rather than reinventing rounding logic.
///      Exit fee: charged as a basis-point cut of the assets leaving the vault on withdraw/redeem,
///      taken from the withdrawn amount itself (never minted as extra shares), so it can never
///      corrupt the share/asset exchange rate for remaining depositors.
contract YieldVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 2_000; // 20% hard ceiling, so owner can never set an abusive fee
    uint256 public exitFeeBps;
    address public feeRecipient;

    event ExitFeeCharged(address indexed receiver, address indexed owner, uint256 feeAssets);
    event ExitFeeUpdated(uint256 newFeeBps);
    event FeeRecipientUpdated(address newFeeRecipient);

    error ZeroShares();
    error ZeroAssets();
    error FeeTooHigh();
    error ZeroAddress();

    constructor(IERC20 asset_, string memory name_, string memory symbol_, uint256 exitFeeBps_, address feeRecipient_, address initialOwner)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(initialOwner)
    {
        if (exitFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        exitFeeBps = exitFeeBps_;
        feeRecipient = feeRecipient_;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    // ---------- Owner controls ----------

    function setExitFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        exitFeeBps = newFeeBps;
        emit ExitFeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    // ---------- Guarded entry points ----------
    // Re-declared with nonReentrant since ERC4626's public deposit/mint/withdraw/redeem are not
    // virtual-overridable at the modifier level; wrapping here protects the external asset-token
    // call (and any future strategy hook) from reentrancy.

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        shares = super.deposit(assets, receiver);
        if (shares == 0) revert ZeroShares();
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        assets = super.mint(shares, receiver);
        if (assets == 0) revert ZeroAssets();
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        if (assets == 0) revert ZeroAssets();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        if (shares == 0) revert ZeroShares();
        return super.redeem(shares, receiver, owner);
    }

    /// @dev Splits the gross `assets` leaving the vault into a fee cut (sent to feeRecipient) and
    ///      a net amount (sent to receiver). Shares burned and total assets leaving the vault are
    ///      unchanged by the fee, so the share/asset exchange rate for remaining holders is untouched.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        uint256 feeAssets = (assets * exitFeeBps) / BPS_DENOMINATOR;
        uint256 netAssets = assets - feeAssets;

        if (feeAssets > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, feeAssets);
            emit ExitFeeCharged(receiver, owner, feeAssets);
        }
        IERC20(asset()).safeTransfer(receiver, netAssets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }
}
