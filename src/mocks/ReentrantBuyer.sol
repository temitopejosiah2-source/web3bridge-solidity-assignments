// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NFTMarketplace} from "../07-marketplace/NFTMarketplace.sol";

/// @dev Attempts to call back into the marketplace mid-purchase, from within the
///      onERC721Received hook, to prove the reentrancy guard holds.
contract ReentrantBuyer is IERC721Receiver {
    NFTMarketplace public marketplace;
    uint256 public listingIdToRetry;
    bool public attack;

    constructor(NFTMarketplace _marketplace) {
        marketplace = _marketplace;
    }

    function arm(uint256 _listingId) external {
        listingIdToRetry = _listingId;
        attack = true;
    }

    function buy(uint256 listingId) external {
        marketplace.purchase(listingId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (attack) {
            attack = false; // avoid infinite loop if the guard somehow failed
            marketplace.purchase(listingIdToRetry);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
