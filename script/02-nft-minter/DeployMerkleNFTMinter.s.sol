// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MerkleNFTMinter} from "../../src/02-nft-minter/MerkleNFTMinter.sol";

/// @notice Deploys MerkleNFTMinter with demo parameters.
/// @dev Run with:
///   forge script script/02-nft-minter/DeployMerkleNFTMinter.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployMerkleNFTMinter is Script {
    uint256 public constant MAX_SUPPLY = 1_000;
    uint256 public constant ALLOWLIST_PRICE = 0.03 ether;
    uint256 public constant PUBLIC_PRICE = 0.05 ether;
    uint256 public constant PUBLIC_PER_WALLET_LIMIT = 5;

    function run() external returns (MerkleNFTMinter nft) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        nft = new MerkleNFTMinter(
            "Demo Merkle NFT", "DMNFT", MAX_SUPPLY, ALLOWLIST_PRICE, PUBLIC_PRICE, PUBLIC_PER_WALLET_LIMIT, deployer
        );

        vm.stopBroadcast();

        console2.log("MerkleNFTMinter deployed at:", address(nft));
        console2.log("Owner address:", deployer);
        console2.log("Set the Merkle root with setMerkleRoot(bytes32) before allowlist minting.");
    }
}
