// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {YieldVault} from "../../src/05-vault/YieldVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys YieldVault plus a demo underlying asset token.
/// @dev Run with:
///   forge script script/05-vault/DeployYieldVault.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployYieldVault is Script {
    uint256 public constant EXIT_FEE_BPS = 200; // 2%

    function run() external returns (YieldVault vault, MockERC20 asset) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        asset = new MockERC20("Demo Vault Asset", "DVA", 18);
        vault = new YieldVault(IERC20(address(asset)), "Demo Yield Vault", "vDVA", EXIT_FEE_BPS, deployer, deployer);
        asset.mint(deployer, 1_000_000e18);

        vm.stopBroadcast();

        console2.log("YieldVault deployed at:", address(vault));
        console2.log("Demo asset token deployed at:", address(asset));
        console2.log("Approve the vault for the asset token before calling deposit/mint.");
    }
}
