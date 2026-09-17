// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TokenVestingVault
/// @notice Linear vesting with an optional cliff, for employee/investor/grant token allocations.
///         Owner creates schedules; only the beneficiary can claim their own vested tokens.
contract TokenVestingVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        address beneficiary;
        IERC20 token;
        uint256 totalAmount;
        uint256 released;
        uint64 start;
        uint64 cliff; // absolute timestamp, cliff >= start
        uint64 duration; // seconds, vesting completes at start + duration
        bool revocable;
        bool revoked;
    }

    uint256 public nextScheduleId;
    mapping(uint256 => VestingSchedule) public schedules;

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 totalAmount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    );
    event Claimed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event Revoked(uint256 indexed scheduleId, uint256 vestedKept, uint256 unvestedReturned);

    error InvalidSchedule();
    error NotBeneficiary();
    error NothingToClaim();
    error NotRevocable();
    error AlreadyRevoked();
    error ZeroAddress();

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Creates a schedule and pulls `totalAmount` tokens from the owner into the vault.
    function createSchedule(
        address beneficiary,
        IERC20 token,
        uint256 totalAmount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    ) external onlyOwner nonReentrant returns (uint256 scheduleId) {
        if (beneficiary == address(0) || address(token) == address(0)) revert ZeroAddress();
        if (totalAmount == 0 || duration == 0) revert InvalidSchedule();
        if (cliff < start) revert InvalidSchedule();
        if (cliff > start + duration) revert InvalidSchedule();

        scheduleId = nextScheduleId++;
        schedules[scheduleId] = VestingSchedule({
            beneficiary: beneficiary,
            token: token,
            totalAmount: totalAmount,
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revocable: revocable,
            revoked: false
        });

        token.safeTransferFrom(msg.sender, address(this), totalAmount);

        emit ScheduleCreated(scheduleId, beneficiary, address(token), totalAmount, start, cliff, duration, revocable);
    }

    /// @notice Amount vested so far under linear release, capped at totalAmount and frozen at revocation time.
    function vestedAmount(uint256 scheduleId) public view returns (uint256) {
        VestingSchedule storage s = schedules[scheduleId];
        if (s.totalAmount == 0) return 0;
        if (s.revoked) return s.totalAmount; // frozen at the vested figure captured at revoke()

        if (block.timestamp < s.cliff) {
            return 0;
        }
        if (block.timestamp >= s.start + s.duration) {
            return s.totalAmount;
        }
        return (s.totalAmount * (block.timestamp - s.start)) / s.duration;
    }

    function claimable(uint256 scheduleId) public view returns (uint256) {
        VestingSchedule storage s = schedules[scheduleId];
        uint256 vested = vestedAmount(scheduleId);
        if (vested <= s.released) return 0;
        return vested - s.released;
    }

    /// @notice Beneficiary claims all currently vested, unclaimed tokens.
    function claim(uint256 scheduleId) external nonReentrant {
        VestingSchedule storage s = schedules[scheduleId];
        if (msg.sender != s.beneficiary) revert NotBeneficiary();

        uint256 amount = claimable(scheduleId);
        if (amount == 0) revert NothingToClaim();

        s.released += amount;
        s.token.safeTransfer(s.beneficiary, amount);

        emit Claimed(scheduleId, s.beneficiary, amount);
    }

    /// @notice Owner revokes a revocable schedule: already-vested tokens remain claimable by the
    ///         beneficiary, unvested tokens return to the owner immediately.
    function revoke(uint256 scheduleId) external onlyOwner nonReentrant {
        VestingSchedule storage s = schedules[scheduleId];
        if (!s.revocable) revert NotRevocable();
        if (s.revoked) revert AlreadyRevoked();

        uint256 vested = vestedAmount(scheduleId);
        uint256 unvested = s.totalAmount - vested;

        s.revoked = true;
        s.totalAmount = vested; // freezes future vestedAmount() at the already-vested figure

        if (unvested > 0) {
            s.token.safeTransfer(owner(), unvested);
        }

        emit Revoked(scheduleId, vested, unvested);
    }
}
