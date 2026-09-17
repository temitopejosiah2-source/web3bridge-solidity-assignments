// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTMarketplace} from "../../src/07-marketplace/NFTMarketplace.sol";
import {MockERC721Royalty} from "../../src/mocks/MockERC721Royalty.sol";
import {MockERC721Plain} from "../../src/mocks/MockERC721Plain.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {ReentrantBuyer} from "../../src/mocks/ReentrantBuyer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NFTMarketplaceTest is Test {
    NFTMarketplace market;
    MockERC721Royalty royaltyNft;
    MockERC721Plain plainNft;
    MockERC20 payToken;

    address feeOwner = makeAddr("feeOwner");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address royaltyReceiver = makeAddr("royaltyReceiver");

    uint256 constant PRICE = 1_000e18;
    uint256 constant FEE_BPS = 250; // 2.5%
    uint96 constant ROYALTY_BPS = 500; // 5%

    function setUp() public {
        market = new NFTMarketplace(FEE_BPS, feeOwner);
        royaltyNft = new MockERC721Royalty("Royalty NFT", "RNFT");
        plainNft = new MockERC721Plain("Plain NFT", "PNFT");
        payToken = new MockERC20("Pay Token", "PAY", 18);

        payToken.mint(buyer, 100_000e18);
        vm.prank(buyer);
        payToken.approve(address(market), type(uint256).max);
    }

    function _listRoyaltyNft() internal returns (uint256 listingId, uint256 tokenId) {
        tokenId = royaltyNft.mint(seller, royaltyReceiver, ROYALTY_BPS);
        vm.prank(seller);
        royaltyNft.approve(address(market), tokenId);

        vm.prank(seller);
        listingId =
            market.createListing(address(royaltyNft), tokenId, PRICE, IERC20(address(payToken)), block.timestamp + 7 days);
    }

    // ---------- Listing creation ----------

    function test_RevertWhen_ListingByNonOwner() public {
        uint256 tokenId = royaltyNft.mint(seller, royaltyReceiver, ROYALTY_BPS);
        vm.prank(seller);
        royaltyNft.approve(address(market), tokenId);

        vm.prank(buyer); // not the owner
        vm.expectRevert(NFTMarketplace.NotOwnerOfToken.selector);
        market.createListing(address(royaltyNft), tokenId, PRICE, IERC20(address(payToken)), block.timestamp + 7 days);
    }

    function test_RevertWhen_ListingWithoutApproval() public {
        uint256 tokenId = royaltyNft.mint(seller, royaltyReceiver, ROYALTY_BPS);
        // No approval granted to the marketplace.
        vm.prank(seller);
        vm.expectRevert(NFTMarketplace.NotApprovedForMarketplace.selector);
        market.createListing(address(royaltyNft), tokenId, PRICE, IERC20(address(payToken)), block.timestamp + 7 days);
    }

    // ---------- Successful purchase ----------

    function test_Purchase_TransfersNftAndSplitsPaymentCorrectly() public {
        (uint256 listingId,) = _listRoyaltyNft();

        vm.prank(buyer);
        market.purchase(listingId);

        assertEq(royaltyNft.ownerOf(1), buyer);

        uint256 expectedRoyalty = (PRICE * ROYALTY_BPS) / 10_000;
        uint256 expectedFee = (PRICE * FEE_BPS) / 10_000;
        uint256 expectedSeller = PRICE - expectedRoyalty - expectedFee;

        assertEq(payToken.balanceOf(royaltyReceiver), expectedRoyalty);
        assertEq(payToken.balanceOf(feeOwner), expectedFee);
        assertEq(payToken.balanceOf(seller), expectedSeller);
    }

    function test_Purchase_WorksWithoutRoyaltySupport() public {
        uint256 tokenId = plainNft.mint(seller);
        vm.prank(seller);
        plainNft.approve(address(market), tokenId);
        vm.prank(seller);
        uint256 listingId =
            market.createListing(address(plainNft), tokenId, PRICE, IERC20(address(payToken)), block.timestamp + 7 days);

        vm.prank(buyer);
        market.purchase(listingId);

        uint256 expectedFee = (PRICE * FEE_BPS) / 10_000;
        assertEq(payToken.balanceOf(feeOwner), expectedFee);
        assertEq(payToken.balanceOf(seller), PRICE - expectedFee);
        assertEq(plainNft.ownerOf(tokenId), buyer);
    }

    // ---------- Stale ownership / approval ----------

    function test_RevertWhen_StaleOwnership_SellerAlreadyTransferredNft() public {
        (uint256 listingId, uint256 tokenId) = _listRoyaltyNft();

        // Seller sells the NFT elsewhere before the marketplace purchase happens.
        address elsewhere = makeAddr("elsewhere");
        vm.prank(seller);
        royaltyNft.transferFrom(seller, elsewhere, tokenId);

        vm.prank(buyer);
        vm.expectRevert(NFTMarketplace.StaleOwnership.selector);
        market.purchase(listingId);
    }

    function test_RevertWhen_StaleApproval_SellerRevokedApproval() public {
        (uint256 listingId, uint256 tokenId) = _listRoyaltyNft();

        vm.prank(seller);
        royaltyNft.approve(address(0), tokenId); // revoke

        vm.prank(buyer);
        vm.expectRevert(NFTMarketplace.StaleApproval.selector);
        market.purchase(listingId);
    }

    function test_ApprovalForAll_SatisfiesApprovalCheckEvenAfterSingleApprovalRevoked() public {
        uint256 tokenId = royaltyNft.mint(seller, royaltyReceiver, ROYALTY_BPS);
        vm.startPrank(seller);
        royaltyNft.setApprovalForAll(address(market), true);
        vm.stopPrank();

        vm.prank(seller);
        uint256 listingId =
            market.createListing(address(royaltyNft), tokenId, PRICE, IERC20(address(payToken)), block.timestamp + 7 days);

        vm.prank(buyer);
        market.purchase(listingId);
        assertEq(royaltyNft.ownerOf(tokenId), buyer);
    }

    // ---------- Expiry ----------

    function test_RevertWhen_ListingExpired() public {
        (uint256 listingId,) = _listRoyaltyNft();
        vm.warp(block.timestamp + 8 days);

        vm.prank(buyer);
        vm.expectRevert(NFTMarketplace.ListingExpiredError.selector);
        market.purchase(listingId);
    }

    function test_RevertWhen_CreateListingWithPastExpiry() public {
        uint256 tokenId = royaltyNft.mint(seller, royaltyReceiver, ROYALTY_BPS);
        vm.prank(seller);
        royaltyNft.approve(address(market), tokenId);

        vm.prank(seller);
        vm.expectRevert(NFTMarketplace.InvalidExpiry.selector);
        market.createListing(address(royaltyNft), tokenId, PRICE, IERC20(address(payToken)), block.timestamp);
    }

    // ---------- Cancellation ----------

    function test_Cancel_BySeller() public {
        (uint256 listingId,) = _listRoyaltyNft();

        vm.prank(seller);
        market.cancelListing(listingId);

        vm.prank(buyer);
        vm.expectRevert(NFTMarketplace.ListingNotActive.selector);
        market.purchase(listingId);
    }

    function test_RevertWhen_CancelByNonSeller() public {
        (uint256 listingId,) = _listRoyaltyNft();

        vm.prank(buyer);
        vm.expectRevert(NFTMarketplace.NotSeller.selector);
        market.cancelListing(listingId);
    }

    function test_RevertWhen_DoubleCancel() public {
        (uint256 listingId,) = _listRoyaltyNft();
        vm.prank(seller);
        market.cancelListing(listingId);

        vm.prank(seller);
        vm.expectRevert(NFTMarketplace.ListingNotActive.selector);
        market.cancelListing(listingId);
    }

    function test_RevertWhen_PurchaseAlreadyPurchasedListing() public {
        (uint256 listingId,) = _listRoyaltyNft();
        vm.prank(buyer);
        market.purchase(listingId);

        address buyer2 = makeAddr("buyer2");
        payToken.mint(buyer2, PRICE);
        vm.prank(buyer2);
        payToken.approve(address(market), PRICE);

        vm.prank(buyer2);
        vm.expectRevert(NFTMarketplace.ListingNotActive.selector);
        market.purchase(listingId);
    }

    // ---------- Fee governance ----------

    function test_RevertWhen_FeeTooHigh() public {
        vm.prank(feeOwner);
        vm.expectRevert(NFTMarketplace.FeeTooHigh.selector);
        market.setMarketplaceFeeBps(1_001);
    }

    function test_RevertWhen_UnauthorizedFeeChange() public {
        vm.prank(buyer);
        vm.expectRevert();
        market.setMarketplaceFeeBps(500);
    }

    // ---------- Reentrancy ----------

    function test_RevertWhen_ReentrantPurchaseAttempted() public {
        ReentrantBuyer attacker = new ReentrantBuyer(market);
        payToken.mint(address(attacker), 10_000e18);
        vm.prank(address(attacker));
        payToken.approve(address(market), type(uint256).max);

        uint256 tokenId1 = royaltyNft.mint(seller, royaltyReceiver, ROYALTY_BPS);
        vm.prank(seller);
        royaltyNft.approve(address(market), tokenId1);
        vm.prank(seller);
        uint256 listingId1 = market.createListing(
            address(royaltyNft), tokenId1, PRICE, IERC20(address(payToken)), block.timestamp + 7 days
        );

        uint256 tokenId2 = royaltyNft.mint(seller, royaltyReceiver, ROYALTY_BPS);
        vm.prank(seller);
        royaltyNft.approve(address(market), tokenId2);
        vm.prank(seller);
        uint256 listingId2 = market.createListing(
            address(royaltyNft), tokenId2, PRICE, IERC20(address(payToken)), block.timestamp + 7 days
        );

        attacker.arm(listingId2);

        // Buying listing 1 triggers onERC721Received, which tries to reenter and buy listing 2.
        // The nonReentrant guard must block the inner call, reverting the whole transaction.
        vm.expectRevert();
        attacker.buy(listingId1);

        // Neither listing should have moved, since the outer transaction reverted entirely.
        assertEq(royaltyNft.ownerOf(tokenId1), seller);
        assertEq(royaltyNft.ownerOf(tokenId2), seller);
    }

    // ---------- Fuzz: seller proceeds + fee + royalty always reconstruct the price ----------

    function testFuzz_PayoutsAlwaysSumToPrice(uint256 price, uint96 royaltyBps) public {
        price = bound(price, 1e18, 1_000_000e18);
        royaltyBps = uint96(bound(royaltyBps, 0, 9_000)); // keep royalty+fee under 100%

        uint256 tokenId = royaltyNft.mint(seller, royaltyReceiver, royaltyBps);
        vm.prank(seller);
        royaltyNft.approve(address(market), tokenId);
        vm.prank(seller);
        uint256 listingId =
            market.createListing(address(royaltyNft), tokenId, price, IERC20(address(payToken)), block.timestamp + 7 days);

        payToken.mint(buyer, price);
        vm.prank(buyer);
        payToken.approve(address(market), price);

        vm.prank(buyer);
        market.purchase(listingId);

        uint256 royaltyPaid = payToken.balanceOf(royaltyReceiver);
        uint256 feePaid = payToken.balanceOf(feeOwner);
        uint256 sellerPaid = payToken.balanceOf(seller);

        assertEq(royaltyPaid + feePaid + sellerPaid, price);
    }
}
