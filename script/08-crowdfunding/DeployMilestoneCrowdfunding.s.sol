// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MilestoneCrowdfunding} from "../../src/08-crowdfunding/MilestoneCrowdfunding.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Deploys MilestoneCrowdfunding plus a demo funding token.
/// @dev Run with:
///   forge script script/08-crowdfunding/DeployMilestoneCrowdfunding.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployMilestoneCrowdfunding is Script {
    function run() external returns (MilestoneCrowdfunding crowd, MockERC20 fundToken) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        crowd = new MilestoneCrowdfunding(deployer);
        fundToken = new MockERC20("Demo Fund Token", "DFUND", 18);
        fundToken.mint(deployer, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("MilestoneCrowdfunding deployed at:", address(crowd));
        console2.log("Demo fund token deployed at:", address(fundToken));
        console2.log("Deployer is the platform owner who approves milestones:", deployer);
    }
}
