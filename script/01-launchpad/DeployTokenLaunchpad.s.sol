// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TokenLaunchpad} from "../../src/01-launchpad/TokenLaunchpad.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys TokenLaunchpad plus a demo sale token so you can immediately try createSale/buy.
/// @dev Run with:
///   forge script script/01-launchpad/DeployTokenLaunchpad.s.sol --rpc-url <RPC_URL> --broadcast
/// Reads the deployer key from the PRIVATE_KEY environment variable -- never hardcode a key here
/// and never commit a .env file containing one.
contract DeployTokenLaunchpad is Script {
    uint256 public constant PLATFORM_FEE_BPS = 250; // 2.5%

    function run() external returns (TokenLaunchpad launchpad, MockERC20 saleToken) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        launchpad = new TokenLaunchpad(PLATFORM_FEE_BPS, deployer);
        saleToken = new MockERC20("Demo Sale Token", "DEMO", 18);
        saleToken.mint(deployer, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("TokenLaunchpad deployed at:", address(launchpad));
        console2.log("Demo sale token deployed at:", address(saleToken));
        console2.log("Deployer (fee-eligible owner) address:", deployer);
    }
}
