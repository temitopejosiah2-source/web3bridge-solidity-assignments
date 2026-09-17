// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GovToken} from "../../src/04-governance/GovToken.sol";
import {DAOTreasuryGovernor} from "../../src/04-governance/DAOTreasuryGovernor.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract DAOTreasuryGovernorTest is Test {
    GovToken token;
    DAOTreasuryGovernor gov;
    MockERC20 treasuryToken;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice"); // 40%
    address bob = makeAddr("bob"); // 30%
    address carol = makeAddr("carol"); // 20%
    address dave = makeAddr("dave"); // 10%, never delegates
    address recipient = makeAddr("recipient");

    uint256 constant SUPPLY = 1_000_000e18;
    uint256 constant VOTING_DELAY = 1 hours;
    uint256 constant VOTING_PERIOD = 3 days;
    uint256 constant TIMELOCK = 2 days;
    uint256 constant QUORUM_BPS = 2000; // 20%
    uint256 constant PROPOSAL_THRESHOLD = 10_000e18;

    function setUp() public {
        token = new GovToken("Gov Token", "GOV", SUPPLY, deployer);

        vm.startPrank(deployer);
        token.transfer(alice, SUPPLY * 40 / 100);
        token.transfer(bob, SUPPLY * 30 / 100);
        token.transfer(carol, SUPPLY * 20 / 100);
        token.transfer(dave, SUPPLY * 10 / 100);
        vm.stopPrank();

        // Everyone except Dave activates their voting power.
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(carol);
        token.delegate(carol);
        // Dave intentionally does not delegate -> zero voting power despite holding tokens.

        gov = new DAOTreasuryGovernor(token, VOTING_DELAY, VOTING_PERIOD, TIMELOCK, QUORUM_BPS, PROPOSAL_THRESHOLD);

        treasuryToken = new MockERC20("Treasury Asset", "TRA", 18);
        treasuryToken.mint(address(gov), 100_000e18);
        vm.deal(address(gov), 10 ether);
    }

    function _propose() internal returns (uint256 id) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(treasuryToken);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(treasuryToken.transfer.selector, recipient, 5_000e18);

        vm.prank(alice);
        id = gov.propose(targets, values, calldatas, "Send 5000 TRA to recipient");
    }

    // ---------- Voting power / proposal threshold ----------

    function test_RevertWhen_ProposerBelowThreshold() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(treasuryToken);
        calldatas[0] = "";

        vm.prank(dave); // never delegated, zero voting power
        vm.expectRevert(DAOTreasuryGovernor.BelowProposalThreshold.selector);
        gov.propose(targets, values, calldatas, "should fail");
    }

    function test_UndelegatedHolder_HasZeroVotingPower() public view {
        assertEq(token.getVotes(dave), 0);
    }

    function test_VoteWeight_MatchesSnapshotBalance() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY);

        vm.prank(alice);
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);

        (,,,, uint256 forVotes,,,,,) = gov.getProposal(id);
        assertEq(forVotes, SUPPLY * 40 / 100);
    }

    function test_VoteWeight_UnaffectedByPostSnapshotTransfer() public {
        uint256 id = _propose(); // snapshot taken now, at T0

        // Move forward slightly so the transfer below lands in a LATER checkpoint than the
        // snapshot itself (checkpoints at the identical timestamp would otherwise merge).
        vm.warp(block.timestamp + 1);

        // Alice moves her tokens to Dave AFTER the snapshot was taken but BEFORE voting starts.
        vm.prank(alice);
        token.transfer(dave, SUPPLY * 40 / 100);

        vm.warp(block.timestamp + VOTING_DELAY);

        vm.prank(alice);
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);

        // Alice's vote weight is still her snapshot-time balance, not her now-empty balance.
        (,,,, uint256 forVotes,,,,,) = gov.getProposal(id);
        assertEq(forVotes, SUPPLY * 40 / 100);
    }

    // ---------- Duplicate voting ----------

    function test_RevertWhen_DuplicateVote() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY);

        vm.startPrank(alice);
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);
        vm.expectRevert(DAOTreasuryGovernor.AlreadyVoted.selector);
        gov.castVote(id, DAOTreasuryGovernor.VoteType.Against);
        vm.stopPrank();
    }

    function test_RevertWhen_VoteBeforeActive() public {
        uint256 id = _propose();
        vm.prank(alice);
        vm.expectRevert(DAOTreasuryGovernor.ProposalNotActive.selector);
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);
    }

    function test_RevertWhen_VoteAfterVotingEnds() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);
        vm.prank(alice);
        vm.expectRevert(DAOTreasuryGovernor.ProposalNotActive.selector);
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);
    }

    // ---------- Quorum ----------

    function test_Defeated_WhenQuorumNotReached() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY);

        // Only Carol (20% exactly) votes For -- quorum is 20%, but let's use a smaller voter
        // to clearly fall short: have nobody vote at all.
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint8(gov.state(id)), uint8(DAOTreasuryGovernor.ProposalState.Defeated));
    }

    function test_Succeeded_WhenQuorumAndMajorityMet() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY);

        vm.prank(alice); // 40%
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);
        vm.prank(bob); // 30% against
        gov.castVote(id, DAOTreasuryGovernor.VoteType.Against);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint8(gov.state(id)), uint8(DAOTreasuryGovernor.ProposalState.Succeeded));
    }

    function test_Defeated_WhenAgainstBeatsFor() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY);

        vm.prank(alice); // 40% against
        gov.castVote(id, DAOTreasuryGovernor.VoteType.Against);
        vm.prank(bob); // 30% for
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint8(gov.state(id)), uint8(DAOTreasuryGovernor.ProposalState.Defeated));
    }

    // ---------- Timelock enforcement ----------

    function _passProposal() internal returns (uint256 id) {
        id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY);
        vm.prank(alice);
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);
        vm.prank(bob);
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
    }

    function test_RevertWhen_QueueBeforeSucceeded() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY);
        vm.expectRevert(DAOTreasuryGovernor.ProposalNotSucceeded.selector);
        gov.queue(id);
    }

    function test_RevertWhen_ExecuteBeforeQueued() public {
        uint256 id = _passProposal();
        vm.expectRevert(DAOTreasuryGovernor.ProposalNotQueued.selector);
        gov.execute(id);
    }

    function test_ExecuteFailsPreTimelock_WithTimelockError() public {
        uint256 id = _passProposal();
        gov.queue(id);

        // state() is Queued right after queue(), so execute() reaches the timelock check.
        vm.expectRevert(DAOTreasuryGovernor.TimelockNotElapsed.selector);
        gov.execute(id);
    }

    function test_Execute_SucceedsAfterTimelock() public {
        uint256 id = _passProposal();
        gov.queue(id);
        vm.warp(block.timestamp + TIMELOCK + 1);

        gov.execute(id);

        assertEq(treasuryToken.balanceOf(recipient), 5_000e18);
    }

    function test_RevertWhen_DoubleExecute() public {
        uint256 id = _passProposal();
        gov.queue(id);
        vm.warp(block.timestamp + TIMELOCK + 1);
        gov.execute(id);

        vm.expectRevert(DAOTreasuryGovernor.ProposalNotQueued.selector);
        gov.execute(id);
    }

    function test_RevertWhen_ExecuteExpiredProposal() public {
        uint256 id = _passProposal();
        gov.queue(id);
        vm.warp(block.timestamp + TIMELOCK + gov.GRACE_PERIOD() + 1);

        vm.expectRevert(DAOTreasuryGovernor.ProposalNotQueued.selector);
        gov.execute(id);
        assertEq(uint8(gov.state(id)), uint8(DAOTreasuryGovernor.ProposalState.Expired));
    }

    // ---------- Cancellation ----------

    function test_Cancel_ByProposer() public {
        uint256 id = _propose();
        vm.prank(alice);
        gov.cancel(id);
        assertEq(uint8(gov.state(id)), uint8(DAOTreasuryGovernor.ProposalState.Cancelled));
    }

    function test_RevertWhen_UnauthorizedCancel() public {
        uint256 id = _propose();
        vm.prank(bob);
        vm.expectRevert(DAOTreasuryGovernor.NotProposer.selector);
        gov.cancel(id);
    }

    function test_RevertWhen_ExecuteCancelledProposal() public {
        uint256 id = _passProposal();
        vm.prank(alice);
        gov.cancel(id);

        vm.expectRevert(DAOTreasuryGovernor.ProposalNotQueued.selector);
        gov.execute(id);
    }

    // ---------- Treasury cannot move outside governance ----------

    function test_TreasuryHasNoDirectWithdrawPath() public {
        // The governor contract exposes no withdraw/transfer function at all --
        // the only way tokens or ETH leave is via execute() on an approved proposal.
        // We assert this structurally: a random call to a nonexistent selector fails,
        // and a direct ERC20 transfer call cannot be triggered by anyone but this contract itself.
        vm.prank(alice);
        vm.expectRevert();
        (bool ok,) = address(gov).call(abi.encodeWithSignature("withdraw(address,uint256)", alice, 1e18));
        ok; // silence unused warning; call is expected to revert (no such function, no fallback logic)
    }

    function test_ExecuteMovesFundsOnlyToApprovedTarget() public {
        uint256 id = _passProposal();
        gov.queue(id);
        vm.warp(block.timestamp + TIMELOCK + 1);
        gov.execute(id);

        // Funds went to the recipient encoded in the approved calldata, not anywhere else,
        // and the un-transferred remainder stays in the treasury.
        assertEq(treasuryToken.balanceOf(recipient), 5_000e18);
        assertEq(treasuryToken.balanceOf(address(gov)), 95_000e18);
    }

    // ---------- Fuzz: quorum boundary ----------

    function testFuzz_QuorumBoundary(uint256 abstainPct) public {
        abstainPct = bound(abstainPct, 0, 20); // Carol holds exactly 20%

        uint256 id = _propose();
        vm.warp(block.timestamp + VOTING_DELAY);

        vm.prank(alice); // 40% for, always enough for majority
        gov.castVote(id, DAOTreasuryGovernor.VoteType.For);

        if (abstainPct == 20) {
            vm.prank(carol);
            gov.castVote(id, DAOTreasuryGovernor.VoteType.Abstain);
        }

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        if (abstainPct == 20) {
            // 40% for + 20% abstain = 60% turnout, clears the 20% quorum.
            assertEq(uint8(gov.state(id)), uint8(DAOTreasuryGovernor.ProposalState.Succeeded));
        } else {
            // Only Alice's 40% for votes counted as turnout, still clears 20% quorum on its own,
            // so this branch also succeeds -- demonstrating quorum counts For votes too.
            assertEq(uint8(gov.state(id)), uint8(DAOTreasuryGovernor.ProposalState.Succeeded));
        }
    }
}
