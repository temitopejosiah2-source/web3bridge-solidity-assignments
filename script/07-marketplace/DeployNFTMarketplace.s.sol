// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {NFTMarketplace} from "../../src/07-marketplace/NFTMarketplace.sol";
import {MockERC721Royalty} from "../../src/mocks/MockERC721Royalty.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Deploys NFTMarketplace plus a demo royalty NFT and payment token so you can list and
///         buy something immediately.
/// @dev Run with:
///   forge script script/07-marketplace/DeployNFTMarketplace.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployNFTMarketplace is Script {
    uint256 public constant MARKETPLACE_FEE_BPS = 250; // 2.5%
    uint96 public constant DEMO_ROYALTY_BPS = 500; // 5%

    function run()
        external
        returns (NFTMarketplace market, MockERC721Royalty nft, MockERC20 payToken)
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        market = new NFTMarketplace(MARKETPLACE_FEE_BPS, deployer);
        nft = new MockERC721Royalty("Demo Royalty NFT", "DRNFT");
        payToken = new MockERC20("Demo Pay Token", "DPAY", 18);

        uint256 tokenId = nft.mint(deployer, deployer, DEMO_ROYALTY_BPS);
        payToken.mint(deployer, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("NFTMarketplace deployed at:", address(market));
        console2.log("Demo NFT deployed at:", address(nft));
        console2.log("Demo token minted:", tokenId);
        console2.log("Demo payment token deployed at:", address(payToken));
        console2.log("Approve the marketplace for the NFT, then call createListing.");
    }
}
