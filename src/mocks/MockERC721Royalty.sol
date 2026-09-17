// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

contract MockERC721Royalty is ERC721, ERC2981 {
    uint256 public nextTokenId = 1;

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address to, address royaltyReceiver, uint96 royaltyFeeBps) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _mint(to, tokenId);
        _setTokenRoyalty(tokenId, royaltyReceiver, royaltyFeeBps);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
