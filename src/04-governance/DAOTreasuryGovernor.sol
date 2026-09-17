// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovToken} from "./GovToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DAOTreasuryGovernor
/// @notice Governs an ETH/ERC-20 treasury held by this contract itself. The only way funds leave
///         is through a fully executed, approved proposal — there is no separate withdraw function.
contract DAOTreasuryGovernor is ReentrancyGuard {
    enum VoteType {
        Against,
        For,
        Abstain
    }

    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed,
        Cancelled
    }

    struct Proposal {
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 snapshotTime;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 eta;
        bool executed;
        bool cancelled;
    }

    GovToken public immutable token;
    uint256 public immutable votingDelay; // seconds between proposal creation and voting start
    uint256 public immutable votingPeriod; // seconds voting stays open
    uint256 public immutable timelockDelay; // seconds a succeeded proposal must wait before execution
    uint256 public immutable quorumBps; // basis points of snapshot total supply required to vote
    uint256 public immutable proposalThreshold; // minimum current voting power required to propose
    uint256 public constant GRACE_PERIOD = 14 days;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 public nextProposalId;
    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        uint256 voteStart,
        uint256 voteEnd,
        string description
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteType support, uint256 weight);
    event ProposalQueued(uint256 indexed proposalId, uint256 eta);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event TreasuryReceived(address indexed from, uint256 amount);

    error InvalidProposalLength();
    error EmptyProposal();
    error BelowProposalThreshold();
    error ProposalNotActive();
    error AlreadyVoted();
    error ProposalNotSucceeded();
    error ProposalNotQueued();
    error TimelockNotElapsed();
    error ProposalExpiredError();
    error NotProposer();
    error AlreadyFinalized();
    error ExecutionFailed(uint256 index);
    error ProposalDoesNotExist();

    constructor(
        GovToken _token,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _timelockDelay,
        uint256 _quorumBps,
        uint256 _proposalThreshold
    ) {
        token = _token;
        votingDelay = _votingDelay;
        votingPeriod = _votingPeriod;
        timelockDelay = _timelockDelay;
        quorumBps = _quorumBps;
        proposalThreshold = _proposalThreshold;
    }

    receive() external payable {
        emit TreasuryReceived(msg.sender, msg.value);
    }

    // ---------- Proposal lifecycle ----------

    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId) {
        if (targets.length == 0) revert EmptyProposal();
        if (targets.length != values.length || targets.length != calldatas.length) revert InvalidProposalLength();
        if (token.getVotes(msg.sender) < proposalThreshold) revert BelowProposalThreshold();

        proposalId = nextProposalId++;
        Proposal storage p = _proposals[proposalId];
        p.proposer = msg.sender;
        for (uint256 i = 0; i < targets.length; i++) {
            p.targets.push(targets[i]);
            p.values.push(values[i]);
            p.calldatas.push(calldatas[i]);
        }
        p.snapshotTime = block.timestamp;
        p.voteStart = block.timestamp + votingDelay;
        p.voteEnd = p.voteStart + votingPeriod;

        emit ProposalCreated(proposalId, msg.sender, targets, values, calldatas, p.voteStart, p.voteEnd, description);
    }

    function castVote(uint256 proposalId, VoteType support) external {
        Proposal storage p = _requireExists(proposalId);
        if (state(proposalId) != ProposalState.Active) revert ProposalNotActive();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        hasVoted[proposalId][msg.sender] = true;
        uint256 weight = token.getPastVotes(msg.sender, p.snapshotTime);

        if (support == VoteType.For) {
            p.forVotes += weight;
        } else if (support == VoteType.Against) {
            p.againstVotes += weight;
        } else {
            p.abstainVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    function queue(uint256 proposalId) external {
        if (state(proposalId) != ProposalState.Succeeded) revert ProposalNotSucceeded();
        Proposal storage p = _proposals[proposalId];
        p.eta = block.timestamp + timelockDelay;
        emit ProposalQueued(proposalId, p.eta);
    }

    function execute(uint256 proposalId) external payable nonReentrant {
        if (state(proposalId) != ProposalState.Queued) revert ProposalNotQueued();
        Proposal storage p = _proposals[proposalId];
        if (block.timestamp < p.eta) revert TimelockNotElapsed();

        p.executed = true;

        for (uint256 i = 0; i < p.targets.length; i++) {
            (bool ok,) = p.targets[i].call{value: p.values[i]}(p.calldatas[i]);
            if (!ok) revert ExecutionFailed(i);
        }

        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        Proposal storage p = _requireExists(proposalId);
        if (msg.sender != p.proposer) revert NotProposer();
        if (p.executed || p.cancelled) revert AlreadyFinalized();

        p.cancelled = true;
        emit ProposalCancelled(proposalId);
    }

    // ---------- Views ----------

    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = _requireExists(proposalId);

        if (p.cancelled) return ProposalState.Cancelled;
        if (p.executed) return ProposalState.Executed;
        if (block.timestamp < p.voteStart) return ProposalState.Pending;
        if (block.timestamp <= p.voteEnd) return ProposalState.Active;

        if (!_quorumReached(p) || p.forVotes <= p.againstVotes) return ProposalState.Defeated;
        if (p.eta == 0) return ProposalState.Succeeded;
        if (block.timestamp >= p.eta + GRACE_PERIOD) return ProposalState.Expired;
        return ProposalState.Queued;
    }

    function _quorumReached(Proposal storage p) internal view returns (bool) {
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        uint256 quorumVotes = (token.getPastTotalSupply(p.snapshotTime) * quorumBps) / BPS_DENOMINATOR;
        return totalVotes >= quorumVotes;
    }

    function _requireExists(uint256 proposalId) internal view returns (Proposal storage p) {
        p = _proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalDoesNotExist();
    }

    function getProposal(uint256 proposalId)
        external
        view
        returns (
            address proposer,
            uint256 snapshotTime,
            uint256 voteStart,
            uint256 voteEnd,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            uint256 eta,
            bool executed,
            bool cancelled
        )
    {
        Proposal storage p = _requireExists(proposalId);
        return (
            p.proposer,
            p.snapshotTime,
            p.voteStart,
            p.voteEnd,
            p.forVotes,
            p.againstVotes,
            p.abstainVotes,
            p.eta,
            p.executed,
            p.cancelled
        );
    }
}
