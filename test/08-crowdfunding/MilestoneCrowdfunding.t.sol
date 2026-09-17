// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MilestoneCrowdfunding} from "../../src/08-crowdfunding/MilestoneCrowdfunding.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MilestoneCrowdfundingTest is Test {
    MilestoneCrowdfunding crowd;
    MockERC20 token;

    address platformOwner = makeAddr("platformOwner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant TARGET = 30_000e18;
    uint256 deadline;
    uint256[] milestones;

    function setUp() public {
        crowd = new MilestoneCrowdfunding(platformOwner);
        token = new MockERC20("Fund Token", "FUND", 18);

        token.mint(alice, 100_000e18);
        token.mint(bob, 100_000e18);
        vm.prank(alice);
        token.approve(address(crowd), type(uint256).max);
        vm.prank(bob);
        token.approve(address(crowd), type(uint256).max);

        deadline = block.timestamp + 30 days;
        milestones = new uint256[](3);
        milestones[0] = 10_000e18;
        milestones[1] = 10_000e18;
        milestones[2] = 10_000e18;
    }

    function _createCampaign() internal returns (uint256 id) {
        vm.prank(creator);
        id = crowd.createCampaign(IERC20(address(token)), TARGET, deadline, milestones);
    }

    // ---------- Creation validation ----------

    function test_RevertWhen_MilestonesDontSumToTarget() public {
        uint256[] memory bad = new uint256[](2);
        bad[0] = 10_000e18;
        bad[1] = 5_000e18; // sums to 15k, target is 30k

        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdfunding.MilestoneSumMismatch.selector);
        crowd.createCampaign(IERC20(address(token)), TARGET, deadline, bad);
    }

    // ---------- Contribution / deadline ----------

    function test_RevertWhen_ContributeAfterDeadline() public {
        uint256 id = _createCampaign();
        vm.warp(deadline + 1);

        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdfunding.DeadlinePassed.selector);
        crowd.contribute(id, 1_000e18);
    }

    function test_Contribute_TracksPerContributor() public {
        uint256 id = _createCampaign();

        vm.prank(alice);
        crowd.contribute(id, 12_000e18);
        vm.prank(bob);
        crowd.contribute(id, 8_000e18);

        assertEq(crowd.contributions(id, alice), 12_000e18);
        assertEq(crowd.contributions(id, bob), 8_000e18);
        (,,,, uint256 totalContributed,,,) = crowd.getCampaign(id);
        assertEq(totalContributed, 20_000e18);
    }

    // ---------- Target success path ----------

    function test_TargetReached_AllowsMilestoneApprovalAndWithdrawal() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET);

        vm.prank(platformOwner);
        crowd.approveMilestone(id);

        uint256 creatorBefore = token.balanceOf(creator);
        vm.prank(creator);
        crowd.withdrawMilestone(id);

        assertEq(token.balanceOf(creator) - creatorBefore, milestones[0]);
    }

    function test_RevertWhen_WithdrawBeforeTargetReached() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET - 1); // just short

        vm.prank(platformOwner);
        vm.expectRevert(MilestoneCrowdfunding.TargetNotReached.selector);
        crowd.approveMilestone(id);
    }

    // ---------- Target failure -> refunds ----------

    function test_TargetFailed_AllowsRefundAfterDeadline() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, 5_000e18); // well short of target

        vm.warp(deadline + 1);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        crowd.refund(id);

        assertEq(token.balanceOf(alice) - before, 5_000e18);
    }

    function test_RevertWhen_RefundBeforeDeadlineAndTargetStillReachable() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, 5_000e18);

        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdfunding.RefundNotAvailable.selector);
        crowd.refund(id);
    }

    // ---------- Duplicate refunds ----------

    function test_RevertWhen_DuplicateRefund() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, 5_000e18);
        vm.warp(deadline + 1);

        vm.prank(alice);
        crowd.refund(id);

        vm.prank(alice);
        vm.expectRevert(MilestoneCrowdfunding.AlreadyRefunded.selector);
        crowd.refund(id);
    }

    function test_RevertWhen_RefundWithNoContribution() public {
        uint256 id = _createCampaign();
        vm.warp(deadline + 1);

        vm.prank(bob); // never contributed
        vm.expectRevert(MilestoneCrowdfunding.NothingToRefund.selector);
        crowd.refund(id);
    }

    // ---------- Milestone ordering ----------

    function test_RevertWhen_WithdrawingUnapprovedMilestone() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET);

        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdfunding.NoApprovedMilestonePending.selector);
        crowd.withdrawMilestone(id);
    }

    function test_MilestonesRelease_StrictlyInOrder() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET);

        vm.startPrank(platformOwner);
        crowd.approveMilestone(id); // approves index 0
        vm.stopPrank();

        vm.prank(creator);
        crowd.withdrawMilestone(id); // releases index 0

        // Trying to withdraw again before milestone 1 is approved must fail.
        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdfunding.NoApprovedMilestonePending.selector);
        crowd.withdrawMilestone(id);

        vm.prank(platformOwner);
        crowd.approveMilestone(id); // approves index 1

        uint256 before = token.balanceOf(creator);
        vm.prank(creator);
        crowd.withdrawMilestone(id); // releases index 1
        assertEq(token.balanceOf(creator) - before, milestones[1]);
    }

    function test_RevertWhen_ApprovingBeyondMilestoneCount() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET);

        vm.startPrank(platformOwner);
        crowd.approveMilestone(id);
        crowd.approveMilestone(id);
        crowd.approveMilestone(id);
        vm.expectRevert(MilestoneCrowdfunding.AllMilestonesApproved.selector);
        crowd.approveMilestone(id);
        vm.stopPrank();
    }

    // ---------- Partial releases ----------

    function test_PartialRelease_LeavesRemainderInContractUntilApproved() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET);

        vm.prank(platformOwner);
        crowd.approveMilestone(id);
        vm.prank(creator);
        crowd.withdrawMilestone(id);

        // Only 1 of 3 milestones released; 2/3 of target should remain in the contract.
        assertEq(token.balanceOf(address(crowd)), TARGET - milestones[0]);
    }

    // ---------- Unauthorized approvals ----------

    function test_RevertWhen_NonOwnerApprovesMilestone() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET);

        vm.prank(creator); // creator is not the platform owner/approver
        vm.expectRevert();
        crowd.approveMilestone(id);
    }

    function test_RevertWhen_NonCreatorWithdraws() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET);
        vm.prank(platformOwner);
        crowd.approveMilestone(id);

        vm.prank(bob);
        vm.expectRevert(MilestoneCrowdfunding.NotCreator.selector);
        crowd.withdrawMilestone(id);
    }

    // ---------- Cancellation ----------

    function test_Cancel_EnablesImmediateRefundRegardlessOfDeadline() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, 5_000e18);

        vm.prank(creator);
        crowd.cancelCampaign(id);

        // Deadline hasn't passed and target wasn't even close, but cancellation alone unlocks refunds.
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        crowd.refund(id);
        assertEq(token.balanceOf(alice) - before, 5_000e18);
    }

    function test_RevertWhen_CancelAfterMilestoneReleased() public {
        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, TARGET);
        vm.prank(platformOwner);
        crowd.approveMilestone(id);
        vm.prank(creator);
        crowd.withdrawMilestone(id);

        vm.prank(creator);
        vm.expectRevert(MilestoneCrowdfunding.CannotCancelAfterRelease.selector);
        crowd.cancelCampaign(id);
    }

    // ---------- Conservation: funds in = funds out + funds remaining ----------

    function testFuzz_FundsConservation(uint256 aliceAmt, uint256 bobAmt) public {
        aliceAmt = bound(aliceAmt, 1e18, 50_000e18);
        bobAmt = bound(bobAmt, 1e18, 50_000e18);

        uint256 id = _createCampaign();
        vm.prank(alice);
        crowd.contribute(id, aliceAmt);
        vm.prank(bob);
        crowd.contribute(id, bobAmt);

        uint256 totalIn = aliceAmt + bobAmt;

        if (totalIn >= TARGET) {
            vm.prank(platformOwner);
            crowd.approveMilestone(id);
            vm.prank(creator);
            crowd.withdrawMilestone(id);

            assertEq(token.balanceOf(address(crowd)), totalIn - milestones[0]);
        } else {
            vm.warp(deadline + 1);
            vm.prank(alice);
            crowd.refund(id);
            vm.prank(bob);
            crowd.refund(id);

            assertEq(token.balanceOf(address(crowd)), 0);
            assertEq(token.balanceOf(alice) + token.balanceOf(bob), 200_000e18); // fully restored
        }
    }
}
