// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITStaking
 * @notice Interface for the TAGIT staking contract
 * @dev Allows users to stake tokens for rewards with time-weighted distribution
 */
interface ITAGITStaking {
    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Staking information for a user
    struct StakeInfo {
        uint256 amount; // Tokens staked
        uint256 rewardPerTokenPaid; // Rewards already accounted
        uint256 rewards; // Accumulated unclaimed rewards
    }

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when tokens are staked
    event Staked(address indexed user, uint256 amount);

    /// @notice Emitted when tokens are unstaked
    event Unstaked(address indexed user, uint256 amount);

    /// @notice Emitted when rewards are claimed
    event RewardsClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when rewards are added to the pool
    event RewardAdded(uint256 amount);

    /// @notice Emitted when reward rate is updated
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when governor is updated
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    /// @notice Emitted when emissions address is set
    event EmissionsSet(address indexed emissions);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when trying to unstake more than staked
    error InsufficientStake(uint256 requested, uint256 available);

    /// @notice Thrown when contract is paused
    error ContractPaused();

    /// @notice Thrown when there are no rewards to claim
    error NoRewardsToClaim();

    /// @notice Thrown when emissions address is already set
    error EmissionsAlreadySet();

    // ============================================
    // USER FUNCTIONS
    // ============================================

    /**
     * @notice Stake tokens to earn rewards
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 amount) external;

    /**
     * @notice Unstake tokens
     * @param amount Amount of tokens to unstake
     */
    function unstake(uint256 amount) external;

    /**
     * @notice Claim accumulated rewards
     * @return claimed Amount of rewards claimed
     */
    function claimRewards() external returns (uint256 claimed);

    // ============================================
    // EMISSIONS FUNCTIONS
    // ============================================

    /**
     * @notice Add rewards to the pool (called by Emissions)
     * @param amount Amount of reward tokens to add
     */
    function notifyRewardAmount(uint256 amount) external;

    // ============================================
    // GOVERNOR FUNCTIONS
    // ============================================

    /**
     * @notice Update the reward rate
     * @param rate New reward rate per second
     */
    function setRewardRate(uint256 rate) external;

    /**
     * @notice Pause staking operations
     */
    function pause() external;

    /**
     * @notice Unpause staking operations
     */
    function unpause() external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get staked balance for a user
     * @param user Address to query
     * @return Staked token amount
     */
    function stakedBalance(address user) external view returns (uint256);

    /**
     * @notice Get pending rewards for a user
     * @param user Address to query
     * @return Pending reward amount
     */
    function pendingRewards(address user) external view returns (uint256);

    /**
     * @notice Get total staked tokens
     * @return Total staked amount
     */
    function totalStaked() external view returns (uint256);

    /**
     * @notice Get current reward rate
     * @return Reward rate per second
     */
    function rewardRate() external view returns (uint256);

    /**
     * @notice Check if user qualifies for reputation boost
     * @param user Address to query
     * @return True if stake >= MIN_STAKE_FOR_REP
     */
    function qualifiesForRepBoost(address user) external view returns (bool);
}
