// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TokenVestingVault} from "../../src/03-vesting/TokenVestingVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Deploys TokenVestingVault plus a demo grant token you can create schedules with.
/// @dev Run with:
///   forge script script/03-vesting/DeployTokenVestingVault.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployTokenVestingVault is Script {
    function run() external returns (TokenVestingVault vault, MockERC20 grantToken) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        vault = new TokenVestingVault(deployer);
        grantToken = new MockERC20("Demo Grant Token", "GRANT", 18);
        grantToken.mint(deployer, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("TokenVestingVault deployed at:", address(vault));
        console2.log("Demo grant token deployed at:", address(grantToken));
        console2.log("Owner address:", deployer);
        console2.log("Approve the vault for the grant token before calling createSchedule.");
    }
}
