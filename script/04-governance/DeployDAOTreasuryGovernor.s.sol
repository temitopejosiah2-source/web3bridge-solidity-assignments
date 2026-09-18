// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {GovToken} from "../../src/04-governance/GovToken.sol";
import {DAOTreasuryGovernor} from "../../src/04-governance/DAOTreasuryGovernor.sol";

/// @notice Deploys GovToken and DAOTreasuryGovernor wired together.
/// @dev Run with:
///   forge script script/04-governance/DeployDAOTreasuryGovernor.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployDAOTreasuryGovernor is Script {
    uint256 public constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 public constant VOTING_DELAY = 1 hours;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public constant QUORUM_BPS = 2_000; // 20%
    uint256 public constant PROPOSAL_THRESHOLD = 10_000e18;

    function run() external returns (GovToken token, DAOTreasuryGovernor governor) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        token = new GovToken("Demo Gov Token", "DGOV", INITIAL_SUPPLY, deployer);
        governor = new DAOTreasuryGovernor(
            token, VOTING_DELAY, VOTING_PERIOD, TIMELOCK_DELAY, QUORUM_BPS, PROPOSAL_THRESHOLD
        );

        vm.stopBroadcast();

        console2.log("GovToken deployed at:", address(token));
        console2.log("DAOTreasuryGovernor deployed at:", address(governor));
        console2.log("Remember: token.delegate(yourself) is required before your votes count.");
        console2.log("Fund the governor's treasury by sending it ETH or ERC-20s directly.");
    }
}
