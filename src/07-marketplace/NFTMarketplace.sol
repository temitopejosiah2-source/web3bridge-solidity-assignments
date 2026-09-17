// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NFTMarketplace
/// @notice Fixed-price ERC-721 listings, paid in an ERC-20 of the seller's choosing, with
///         ERC-2981 royalty distribution and a marketplace fee on every sale.
contract NFTMarketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ERC165Checker for address;

    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;

    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 price;
        IERC20 paymentToken;
        uint256 expiry;
        bool active;
    }

    uint256 public marketplaceFeeBps;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000; // 10% ceiling

    uint256 public nextListingId;
    mapping(uint256 => Listing) public listings;

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 price,
        address paymentToken,
        uint256 expiry
    );
    event ListingCancelled(uint256 indexed listingId);
    event Purchased(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        uint256 royaltyAmount,
        address royaltyReceiver,
        uint256 marketplaceFee,
        uint256 sellerProceeds
    );
    event MarketplaceFeeUpdated(uint256 newFeeBps);

    error NotOwnerOfToken();
    error NotApprovedForMarketplace();
    error InvalidPrice();
    error InvalidExpiry();
    error NotSeller();
    error ListingNotActive();
    error ListingExpiredError();
    error StaleOwnership();
    error StaleApproval();
    error FeeTooHigh();
    error PriceTooLowForFees();

    constructor(uint256 _marketplaceFeeBps, address initialOwner) Ownable(initialOwner) {
        if (_marketplaceFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        marketplaceFeeBps = _marketplaceFeeBps;
    }

    function setMarketplaceFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        marketplaceFeeBps = newFeeBps;
        emit MarketplaceFeeUpdated(newFeeBps);
    }

    // ---------- Listing lifecycle ----------

    function createListing(address nftContract, uint256 tokenId, uint256 price, IERC20 paymentToken, uint256 expiry)
        external
        returns (uint256 listingId)
    {
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();

        IERC721 nft = IERC721(nftContract);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotOwnerOfToken();
        if (!_isApprovedForMarketplace(nft, msg.sender, tokenId)) revert NotApprovedForMarketplace();

        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            price: price,
            paymentToken: paymentToken,
            expiry: expiry,
            active: true
        });

        emit ListingCreated(listingId, msg.sender, nftContract, tokenId, price, address(paymentToken), expiry);
    }

    function cancelListing(uint256 listingId) external {
        Listing storage l = listings[listingId];
        if (msg.sender != l.seller) revert NotSeller();
        if (!l.active) revert ListingNotActive();

        l.active = false;
        emit ListingCancelled(listingId);
    }

    /// @notice Purchase a listing at its exact listed price.
    function purchase(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingNotActive();
        if (block.timestamp > l.expiry) revert ListingExpiredError();

        IERC721 nft = IERC721(l.nftContract);
        if (nft.ownerOf(l.tokenId) != l.seller) revert StaleOwnership();
        if (!_isApprovedForMarketplace(nft, l.seller, l.tokenId)) revert StaleApproval();

        // Effects before interactions: close the listing before any external call.
        l.active = false;

        (address royaltyReceiver, uint256 royaltyAmount) = _royaltyInfo(l.nftContract, l.tokenId, l.price);
        uint256 fee = (l.price * marketplaceFeeBps) / BPS_DENOMINATOR;
        if (royaltyAmount + fee > l.price) revert PriceTooLowForFees();
        uint256 sellerProceeds = l.price - royaltyAmount - fee;

        // Pull the full price from the buyer once, then push out each share.
        l.paymentToken.safeTransferFrom(msg.sender, address(this), l.price);

        if (royaltyAmount > 0) {
            l.paymentToken.safeTransfer(royaltyReceiver, royaltyAmount);
        }
        if (fee > 0) {
            l.paymentToken.safeTransfer(owner(), fee);
        }
        l.paymentToken.safeTransfer(l.seller, sellerProceeds);

        // NFT moves last; safeTransferFrom may call back into an ERC721Receiver hook on the
        // buyer, but nonReentrant already blocks any reentrant call into this contract.
        nft.safeTransferFrom(l.seller, msg.sender, l.tokenId);

        emit Purchased(listingId, msg.sender, l.seller, l.price, royaltyAmount, royaltyReceiver, fee, sellerProceeds);
    }

    // ---------- Internal helpers ----------

    function _isApprovedForMarketplace(IERC721 nft, address seller, uint256 tokenId) internal view returns (bool) {
        return nft.isApprovedForAll(seller, address(this)) || nft.getApproved(tokenId) == address(this);
    }

    function _royaltyInfo(address nftContract, uint256 tokenId, uint256 price)
        internal
        view
        returns (address receiver, uint256 amount)
    {
        if (nftContract.supportsInterface(_INTERFACE_ID_ERC2981)) {
            (receiver, amount) = IERC2981(nftContract).royaltyInfo(tokenId, price);
        }
    }
}
