// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigPayroll} from "../../src/06-multisig/MultisigPayroll.sol";

/// @notice Deploys a 2-of-3 MultisigPayroll. Owner #1 is the deployer; owners #2 and #3 are read
///         from OWNER2 / OWNER3 env vars if set, otherwise default to anvil's well-known demo
///         accounts #1 and #2 (public addresses, not secrets -- fine for local testing only).
/// @dev Run with:
///   forge script script/06-multisig/DeployMultisigPayroll.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployMultisigPayroll is Script {
    uint256 public constant THRESHOLD = 2;
    address public constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant ANVIL_ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function run() external returns (MultisigPayroll payroll) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address owner2 = vm.envOr("OWNER2", ANVIL_ACCOUNT_1);
        address owner3 = vm.envOr("OWNER3", ANVIL_ACCOUNT_2);

        address[] memory owners = new address[](3);
        owners[0] = deployer;
        owners[1] = owner2;
        owners[2] = owner3;

        vm.startBroadcast(deployerKey);

        payroll = new MultisigPayroll(owners, THRESHOLD, "MultisigPayroll");

        vm.stopBroadcast();

        console2.log("MultisigPayroll deployed at:", address(payroll));
        console2.log("Owner 1 (deployer):", deployer);
        console2.log("Owner 2:", owner2);
        console2.log("Owner 3:", owner3);
        console2.log("Threshold:", THRESHOLD);
        console2.log("Fund it by sending ETH directly to the deployed address.");
    }
}
