// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITVesting
 * @notice Interface for the TAGIT token vesting contract
 * @dev Manages cliff + linear vesting for team and development allocations
 */
interface ITAGITVesting {
    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Vesting schedule for a beneficiary
    struct VestingSchedule {
        uint256 totalAmount; // Total tokens granted
        uint256 startTime; // When vesting started
        uint256 cliffDuration; // Time before any unlock
        uint256 vestingDuration; // Total vesting period
        uint256 claimed; // Already withdrawn
    }

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a vesting schedule is created
    event VestingCreated(
        address indexed beneficiary, uint256 amount, uint256 startTime, uint256 cliffDuration, uint256 vestingDuration
    );

    /// @notice Emitted when tokens are claimed
    event TokensClaimed(address indexed beneficiary, uint256 amount);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when duration is zero
    error ZeroDuration();

    /// @notice Thrown when beneficiary already has a vesting schedule
    error ScheduleAlreadyExists(address beneficiary);

    /// @notice Thrown when beneficiary has no vesting schedule
    error NoScheduleExists(address beneficiary);

    /// @notice Thrown when claiming before cliff period ends
    error CliffNotReached(uint256 currentTime, uint256 cliffEnd);

    /// @notice Thrown when no tokens are available to claim
    error NothingToClaim();

    /// @notice Thrown when cliff duration exceeds vesting duration
    error CliffExceedsVesting(uint256 cliff, uint256 vesting);

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Create a vesting schedule for a beneficiary
     * @dev Only owner can call. Schedule is immutable once created.
     * @param beneficiary Address receiving the vested tokens
     * @param amount Total tokens to vest
     * @param cliffDuration Seconds before any tokens unlock
     * @param vestingDuration Total vesting period in seconds
     */
    function createVest(address beneficiary, uint256 amount, uint256 cliffDuration, uint256 vestingDuration) external;

    // ============================================
    // BENEFICIARY FUNCTIONS
    // ============================================

    /**
     * @notice Claim vested tokens
     * @dev Beneficiary calls this to withdraw available tokens
     */
    function claim() external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get total vested amount for a beneficiary
     * @param beneficiary Address to query
     * @return Total tokens that have vested (may be partially claimed)
     */
    function vestedAmount(address beneficiary) external view returns (uint256);

    /**
     * @notice Get claimable amount for a beneficiary
     * @param beneficiary Address to query
     * @return Tokens available to claim right now
     */
    function claimableAmount(address beneficiary) external view returns (uint256);

    /**
     * @notice Get total claimed amount for a beneficiary
     * @param beneficiary Address to query
     * @return Total tokens already claimed
     */
    function totalClaimed(address beneficiary) external view returns (uint256);

    /**
     * @notice Get grant amount for a beneficiary
     * @param beneficiary Address to query
     * @return Total tokens in the vesting schedule
     */
    function grantAmount(address beneficiary) external view returns (uint256);

    /**
     * @notice Get full vesting schedule for a beneficiary
     * @param beneficiary Address to query
     * @return schedule The complete vesting schedule
     */
    function vestingSchedule(address beneficiary) external view returns (VestingSchedule memory schedule);
}
