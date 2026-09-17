// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MilestoneCrowdfunding
/// @notice Campaigns raise a fixed ERC-20 target, released to the creator in ordered milestone
///         stages. Each milestone must be approved by the platform owner before the creator can
///         withdraw it, and only after the campaign has hit its funding target.
contract MilestoneCrowdfunding is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Campaign {
        address creator;
        IERC20 token;
        uint256 target;
        uint256 deadline;
        uint256 totalContributed;
        uint256[] milestoneAmounts;
        uint256 approvedCount;
        uint256 releasedCount;
        bool cancelled;
    }

    uint256 public nextCampaignId;
    mapping(uint256 => Campaign) private _campaigns;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(uint256 => mapping(address => bool)) public refunded;

    event CampaignCreated(
        uint256 indexed campaignId, address indexed creator, address token, uint256 target, uint256 deadline, uint256[] milestoneAmounts
    );
    event Contributed(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event MilestoneApproved(uint256 indexed campaignId, uint256 indexed milestoneIndex);
    event MilestoneReleased(uint256 indexed campaignId, uint256 indexed milestoneIndex, uint256 amount);
    event CampaignCancelled(uint256 indexed campaignId);
    event Refunded(uint256 indexed campaignId, address indexed contributor, uint256 amount);

    error InvalidTarget();
    error InvalidDeadline();
    error MilestoneSumMismatch();
    error ZeroAmount();
    error CampaignIsCancelled();
    error DeadlinePassed();
    error TargetNotReached();
    error AllMilestonesApproved();
    error NoApprovedMilestonePending();
    error NotCreator();
    error NothingToRefund();
    error AlreadyRefunded();
    error RefundNotAvailable();
    error CannotCancelAfterRelease();

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyCreator(uint256 campaignId) {
        if (msg.sender != _campaigns[campaignId].creator) revert NotCreator();
        _;
    }

    // ---------- Campaign creation ----------

    function createCampaign(IERC20 token, uint256 target, uint256 deadline, uint256[] calldata milestoneAmounts)
        external
        returns (uint256 campaignId)
    {
        if (target == 0) revert InvalidTarget();
        if (deadline <= block.timestamp) revert InvalidDeadline();
        if (milestoneAmounts.length == 0) revert MilestoneSumMismatch();

        uint256 sum;
        for (uint256 i = 0; i < milestoneAmounts.length; i++) {
            sum += milestoneAmounts[i];
        }
        if (sum != target) revert MilestoneSumMismatch();

        campaignId = nextCampaignId++;
        Campaign storage c = _campaigns[campaignId];
        c.creator = msg.sender;
        c.token = token;
        c.target = target;
        c.deadline = deadline;
        for (uint256 i = 0; i < milestoneAmounts.length; i++) {
            c.milestoneAmounts.push(milestoneAmounts[i]);
        }

        emit CampaignCreated(campaignId, msg.sender, address(token), target, deadline, milestoneAmounts);
    }

    // ---------- Contribution ----------

    function contribute(uint256 campaignId, uint256 amount) external nonReentrant {
        Campaign storage c = _campaigns[campaignId];
        if (c.cancelled) revert CampaignIsCancelled();
        if (block.timestamp > c.deadline) revert DeadlinePassed();
        if (amount == 0) revert ZeroAmount();

        c.token.safeTransferFrom(msg.sender, address(this), amount);
        contributions[campaignId][msg.sender] += amount;
        c.totalContributed += amount;

        emit Contributed(campaignId, msg.sender, amount);
    }

    // ---------- Milestone approval & release ----------

    function approveMilestone(uint256 campaignId) external onlyOwner {
        Campaign storage c = _campaigns[campaignId];
        if (c.cancelled) revert CampaignIsCancelled();
        if (c.totalContributed < c.target) revert TargetNotReached();
        if (c.approvedCount >= c.milestoneAmounts.length) revert AllMilestonesApproved();

        emit MilestoneApproved(campaignId, c.approvedCount);
        c.approvedCount++;
    }

    /// @notice Creator withdraws the next approved-but-unreleased milestone, strictly in order.
    function withdrawMilestone(uint256 campaignId) external nonReentrant onlyCreator(campaignId) {
        Campaign storage c = _campaigns[campaignId];
        if (c.cancelled) revert CampaignIsCancelled();
        if (c.totalContributed < c.target) revert TargetNotReached();
        if (c.releasedCount >= c.approvedCount) revert NoApprovedMilestonePending();

        uint256 idx = c.releasedCount;
        c.releasedCount++;
        uint256 amount = c.milestoneAmounts[idx];

        c.token.safeTransfer(c.creator, amount);

        emit MilestoneReleased(campaignId, idx, amount);
    }

    // ---------- Cancellation ----------

    /// @dev Cancellation is only allowed before any milestone has been released, so every
    ///      contributor's funds are still fully present in the contract for refunding.
    function cancelCampaign(uint256 campaignId) external {
        Campaign storage c = _campaigns[campaignId];
        if (msg.sender != c.creator && msg.sender != owner()) revert NotCreator();
        if (c.cancelled) revert CampaignIsCancelled();
        if (c.releasedCount > 0) revert CannotCancelAfterRelease();

        c.cancelled = true;
        emit CampaignCancelled(campaignId);
    }

    // ---------- Refunds ----------

    function refund(uint256 campaignId) external nonReentrant {
        Campaign storage c = _campaigns[campaignId];
        uint256 amount = contributions[campaignId][msg.sender];
        if (amount == 0) revert NothingToRefund();
        if (refunded[campaignId][msg.sender]) revert AlreadyRefunded();

        bool eligible = c.cancelled || (block.timestamp > c.deadline && c.totalContributed < c.target);
        if (!eligible) revert RefundNotAvailable();

        refunded[campaignId][msg.sender] = true;
        c.token.safeTransfer(msg.sender, amount);

        emit Refunded(campaignId, msg.sender, amount);
    }

    // ---------- Views ----------

    function getCampaign(uint256 campaignId)
        external
        view
        returns (
            address creator,
            address token,
            uint256 target,
            uint256 deadline,
            uint256 totalContributed,
            uint256 approvedCount,
            uint256 releasedCount,
            bool cancelled
        )
    {
        Campaign storage c = _campaigns[campaignId];
        return (c.creator, address(c.token), c.target, c.deadline, c.totalContributed, c.approvedCount, c.releasedCount, c.cancelled);
    }

    function getMilestoneAmounts(uint256 campaignId) external view returns (uint256[] memory) {
        return _campaigns[campaignId].milestoneAmounts;
    }
}
