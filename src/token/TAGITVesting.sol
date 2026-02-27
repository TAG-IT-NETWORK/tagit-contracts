// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITAGITVesting} from "../interfaces/ITAGITVesting.sol";
import {VERSION} from "../libraries/Constants.sol";

/**
 * @title TAGITVesting
 * @author TAG IT Network <dev@tagit.network>
 * @notice Manages token lockups with cliff and linear vesting
 * @dev Implements cliff + linear vesting for team/development allocations
 *
 * Key Features:
 * - Cliff period before any tokens unlock
 * - Linear vesting after cliff
 * - Immutable schedules (no admin override)
 * - Beneficiary-initiated claims
 * - ReentrancyGuard protection
 *
 * Vesting Math:
 * - Before cliff: vestedAmount = 0
 * - After cliff: vestedAmount = totalAmount * (currentTime - startTime) / vestingDuration
 * - claimable = vestedAmount - claimed
 *
 * Security:
 * - No admin function to accelerate vesting
 * - No admin function to revoke vesting
 * - Schedules are immutable once created
 * - ReentrancyGuard on claim()
 *
 * @custom:security-contact security@tagit.network
 */
contract TAGITVesting is ITAGITVesting, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The TAGIT token contract
    IERC20 public immutable token;

    /// @notice Vesting schedules by beneficiary
    mapping(address => VestingSchedule) private _schedules;

    /// @notice Total tokens allocated to vesting schedules
    uint256 public totalAllocated;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the vesting contract
     * @param _token Address of the TAGIT token
     * @param _owner Owner who can create vesting schedules
     */
    constructor(address _token, address _owner) Ownable(_owner) {
        if (_token == address(0)) revert ZeroAddress();
        token = IERC20(_token);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Create a vesting schedule for a beneficiary
     * @dev Only owner can call. Schedule is immutable once created.
     *      Tokens must be transferred to this contract before or after calling.
     * @param beneficiary Address receiving the vested tokens
     * @param amount Total tokens to vest
     * @param cliffDuration Seconds before any tokens unlock
     * @param vestingDuration Total vesting period in seconds
     * @custom:security Schedule cannot be modified after creation
     * @custom:emits VestingCreated
     */
    function createVest(address beneficiary, uint256 amount, uint256 cliffDuration, uint256 vestingDuration)
        external
        onlyOwner
    {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (vestingDuration == 0) revert ZeroDuration();
        if (cliffDuration > vestingDuration) revert CliffExceedsVesting(cliffDuration, vestingDuration);
        if (_schedules[beneficiary].totalAmount != 0) revert ScheduleAlreadyExists(beneficiary);

        _schedules[beneficiary] = VestingSchedule({
            totalAmount: amount,
            startTime: block.timestamp,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            claimed: 0
        });

        totalAllocated += amount;

        emit VestingCreated(beneficiary, amount, block.timestamp, cliffDuration, vestingDuration);
    }

    // ============================================
    // BENEFICIARY FUNCTIONS
    // ============================================

    /**
     * @notice Claim vested tokens
     * @dev Beneficiary calls this to withdraw available tokens
     * @custom:security Uses nonReentrant and Checks-Effects-Interactions
     * @custom:emits TokensClaimed
     */
    function claim() external nonReentrant {
        VestingSchedule storage schedule = _schedules[msg.sender];

        if (schedule.totalAmount == 0) revert NoScheduleExists(msg.sender);

        uint256 cliffEnd = schedule.startTime + schedule.cliffDuration;
        if (block.timestamp < cliffEnd) revert CliffNotReached(block.timestamp, cliffEnd);

        uint256 vested = _calculateVestedAmount(schedule);
        uint256 claimable = vested - schedule.claimed;

        if (claimable == 0) revert NothingToClaim();

        // Effects before interactions (CEI pattern)
        schedule.claimed += claimable;

        // Interaction
        token.safeTransfer(msg.sender, claimable);

        emit TokensClaimed(msg.sender, claimable);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get total vested amount for a beneficiary
     * @param beneficiary Address to query
     * @return Total tokens that have vested (may be partially claimed)
     */
    function vestedAmount(address beneficiary) external view returns (uint256) {
        VestingSchedule storage schedule = _schedules[beneficiary];
        if (schedule.totalAmount == 0) return 0;
        return _calculateVestedAmount(schedule);
    }

    /**
     * @notice Get claimable amount for a beneficiary
     * @param beneficiary Address to query
     * @return Tokens available to claim right now
     */
    function claimableAmount(address beneficiary) external view returns (uint256) {
        VestingSchedule storage schedule = _schedules[beneficiary];
        if (schedule.totalAmount == 0) return 0;

        uint256 cliffEnd = schedule.startTime + schedule.cliffDuration;
        if (block.timestamp < cliffEnd) return 0;

        uint256 vested = _calculateVestedAmount(schedule);
        return vested - schedule.claimed;
    }

    /**
     * @notice Get total claimed amount for a beneficiary
     * @param beneficiary Address to query
     * @return Total tokens already claimed
     */
    function totalClaimed(address beneficiary) external view returns (uint256) {
        return _schedules[beneficiary].claimed;
    }

    /**
     * @notice Get grant amount for a beneficiary
     * @param beneficiary Address to query
     * @return Total tokens in the vesting schedule
     */
    function grantAmount(address beneficiary) external view returns (uint256) {
        return _schedules[beneficiary].totalAmount;
    }

    /**
     * @notice Get full vesting schedule for a beneficiary
     * @param beneficiary Address to query
     * @return schedule The complete vesting schedule
     */
    function vestingSchedule(address beneficiary) external view returns (VestingSchedule memory schedule) {
        return _schedules[beneficiary];
    }

    /**
     * @notice Get cliff end timestamp for a beneficiary
     * @param beneficiary Address to query
     * @return The timestamp when cliff period ends
     */
    function cliffEndTime(address beneficiary) external view returns (uint256) {
        VestingSchedule storage schedule = _schedules[beneficiary];
        if (schedule.totalAmount == 0) return 0;
        return schedule.startTime + schedule.cliffDuration;
    }

    /**
     * @notice Get vesting end timestamp for a beneficiary
     * @param beneficiary Address to query
     * @return The timestamp when vesting completes
     */
    function vestingEndTime(address beneficiary) external view returns (uint256) {
        VestingSchedule storage schedule = _schedules[beneficiary];
        if (schedule.totalAmount == 0) return 0;
        return schedule.startTime + schedule.vestingDuration;
    }

    /**
     * @notice Check if beneficiary has a vesting schedule
     * @param beneficiary Address to query
     * @return True if schedule exists
     */
    function hasSchedule(address beneficiary) external view returns (bool) {
        return _schedules[beneficiary].totalAmount > 0;
    }

    /**
     * @notice Get the contract version
     * @return Current version string
     */
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Calculate vested amount based on linear schedule
     * @dev Returns totalAmount if vesting is complete
     * @param schedule The vesting schedule to calculate
     * @return The total vested amount
     */
    function _calculateVestedAmount(VestingSchedule storage schedule) internal view returns (uint256) {
        uint256 cliffEnd = schedule.startTime + schedule.cliffDuration;

        // Before cliff: nothing vested
        if (block.timestamp < cliffEnd) {
            return 0;
        }

        uint256 vestingEnd = schedule.startTime + schedule.vestingDuration;

        // After vesting complete: everything vested
        if (block.timestamp >= vestingEnd) {
            return schedule.totalAmount;
        }

        // During vesting: linear calculation
        uint256 elapsed = block.timestamp - schedule.startTime;
        return (schedule.totalAmount * elapsed) / schedule.vestingDuration;
    }
}
