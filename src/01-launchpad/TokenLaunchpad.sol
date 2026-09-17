// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TokenLaunchpad
/// @notice Lets any creator open an ERC-20 token sale paid for in native ETH.
/// @dev Assumes the sale token uses 18 decimals for price-per-token math (documented assumption,
///      consistent with the vast majority of ERC-20 launchpad tokens).
contract TokenLaunchpad is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Sale {
        address creator;
        IERC20 token;
        uint256 pricePerToken; // wei per 1e18 units of token
        uint256 totalAllocation; // tokens deposited for sale (token's smallest unit)
        uint256 startTime;
        uint256 endTime;
        uint256 hardCap; // max wei raiseable
        uint256 perWalletLimit; // max tokens (smallest unit) a single wallet may buy
        uint256 totalRaised; // wei raised so far
        uint256 totalSold; // tokens sold so far
        bool proceedsWithdrawn;
        bool unsoldRecovered;
    }

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public immutable platformFeeBps;
    address public immutable feeRecipient;

    uint256 public nextSaleId;
    mapping(uint256 => Sale) public sales;
    mapping(uint256 => mapping(address => uint256)) public purchased;
    mapping(uint256 => mapping(address => bool)) public claimed;

    event SaleCreated(
        uint256 indexed saleId,
        address indexed creator,
        address indexed token,
        uint256 pricePerToken,
        uint256 totalAllocation,
        uint256 startTime,
        uint256 endTime,
        uint256 hardCap,
        uint256 perWalletLimit
    );
    event Purchased(uint256 indexed saleId, address indexed buyer, uint256 tokenAmount, uint256 paid);
    event Claimed(uint256 indexed saleId, address indexed buyer, uint256 tokenAmount);
    event ProceedsWithdrawn(uint256 indexed saleId, address indexed creator, uint256 creatorAmount, uint256 feeAmount);
    event UnsoldRecovered(uint256 indexed saleId, address indexed creator, uint256 amount);

    error InvalidTimeWindow();
    error ZeroAmount();
    error ZeroAddress();
    error SaleNotActive();
    error SaleStillActive();
    error IncorrectPayment();
    error HardCapExceeded();
    error WalletLimitExceeded();
    error AllocationExceeded();
    error NotCreator();
    error AlreadyClaimed();
    error NothingToClaim();
    error AlreadyWithdrawn();
    error AlreadyRecovered();
    error TransferFailed();

    constructor(uint256 _platformFeeBps, address _feeRecipient) {
        if (_platformFeeBps > BPS_DENOMINATOR) revert IncorrectPayment();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        platformFeeBps = _platformFeeBps;
        feeRecipient = _feeRecipient;
    }

    modifier onlyCreator(uint256 saleId) {
        if (msg.sender != sales[saleId].creator) revert NotCreator();
        _;
    }

    /// @notice Opens a new sale. Creator must have approved this contract for `totalAllocation` tokens.
    function createSale(
        IERC20 token,
        uint256 pricePerToken,
        uint256 totalAllocation,
        uint256 startTime,
        uint256 endTime,
        uint256 hardCap,
        uint256 perWalletLimit
    ) external nonReentrant returns (uint256 saleId) {
        if (address(token) == address(0)) revert ZeroAddress();
        if (startTime >= endTime || endTime <= block.timestamp) revert InvalidTimeWindow();
        if (pricePerToken == 0 || totalAllocation == 0 || hardCap == 0 || perWalletLimit == 0) revert ZeroAmount();

        saleId = nextSaleId++;
        sales[saleId] = Sale({
            creator: msg.sender,
            token: token,
            pricePerToken: pricePerToken,
            totalAllocation: totalAllocation,
            startTime: startTime,
            endTime: endTime,
            hardCap: hardCap,
            perWalletLimit: perWalletLimit,
            totalRaised: 0,
            totalSold: 0,
            proceedsWithdrawn: false,
            unsoldRecovered: false
        });

        token.safeTransferFrom(msg.sender, address(this), totalAllocation);

        emit SaleCreated(
            saleId, msg.sender, address(token), pricePerToken, totalAllocation, startTime, endTime, hardCap, perWalletLimit
        );
    }

    /// @notice Buy `tokenAmount` (smallest unit) of the sale token, paying exact ETH.
    function buy(uint256 saleId, uint256 tokenAmount) external payable nonReentrant {
        Sale storage sale = sales[saleId];
        if (block.timestamp < sale.startTime || block.timestamp > sale.endTime) revert SaleNotActive();
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 cost = (tokenAmount * sale.pricePerToken) / 1e18;
        if (cost == 0 || msg.value != cost) revert IncorrectPayment();

        if (sale.totalSold + tokenAmount > sale.totalAllocation) revert AllocationExceeded();
        if (sale.totalRaised + msg.value > sale.hardCap) revert HardCapExceeded();

        uint256 newPurchased = purchased[saleId][msg.sender] + tokenAmount;
        if (newPurchased > sale.perWalletLimit) revert WalletLimitExceeded();

        purchased[saleId][msg.sender] = newPurchased;
        sale.totalSold += tokenAmount;
        sale.totalRaised += msg.value;

        emit Purchased(saleId, msg.sender, tokenAmount, msg.value);
    }

    /// @notice Claim purchased tokens once the sale has ended.
    function claim(uint256 saleId) external nonReentrant {
        Sale storage sale = sales[saleId];
        if (block.timestamp <= sale.endTime) revert SaleStillActive();
        if (claimed[saleId][msg.sender]) revert AlreadyClaimed();

        uint256 amount = purchased[saleId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimed[saleId][msg.sender] = true;
        sale.token.safeTransfer(msg.sender, amount);

        emit Claimed(saleId, msg.sender, amount);
    }

    /// @notice Creator withdraws ETH proceeds (minus platform fee) once the sale has ended.
    function withdrawProceeds(uint256 saleId) external nonReentrant onlyCreator(saleId) {
        Sale storage sale = sales[saleId];
        if (block.timestamp <= sale.endTime) revert SaleStillActive();
        if (sale.proceedsWithdrawn) revert AlreadyWithdrawn();

        sale.proceedsWithdrawn = true;

        uint256 feeAmount = (sale.totalRaised * platformFeeBps) / BPS_DENOMINATOR;
        uint256 creatorAmount = sale.totalRaised - feeAmount;

        if (feeAmount > 0) {
            (bool feeOk,) = feeRecipient.call{value: feeAmount}("");
            if (!feeOk) revert TransferFailed();
        }
        if (creatorAmount > 0) {
            (bool ok,) = sale.creator.call{value: creatorAmount}("");
            if (!ok) revert TransferFailed();
        }

        emit ProceedsWithdrawn(saleId, sale.creator, creatorAmount, feeAmount);
    }

    /// @notice Creator recovers unsold tokens once the sale has ended.
    function recoverUnsold(uint256 saleId) external nonReentrant onlyCreator(saleId) {
        Sale storage sale = sales[saleId];
        if (block.timestamp <= sale.endTime) revert SaleStillActive();
        if (sale.unsoldRecovered) revert AlreadyRecovered();

        sale.unsoldRecovered = true;
        uint256 unsold = sale.totalAllocation - sale.totalSold;

        if (unsold > 0) {
            sale.token.safeTransfer(sale.creator, unsold);
        }

        emit UnsoldRecovered(saleId, sale.creator, unsold);
    }
}
