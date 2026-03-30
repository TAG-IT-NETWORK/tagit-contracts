// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITStaking
 * @notice Interface for the TAGIT staking contract
 * @dev Allows users to stake tokens for rewards with time-weighted distribution
 */
interface ITAGITStaking {
    // ============================================
    // ENUMS
    // ============================================

    /// @notice Lock tier for time-locked staking with reward multipliers
    /// @dev Multipliers in basis points: TIER_30=12000 (1.2x), TIER_90=15000 (1.5x), TIER_180=20000 (2.0x)
    enum LockTier {
        TIER_30, // 30-day lock, 1.2x reward multiplier
        TIER_90, // 90-day lock, 1.5x reward multiplier
        TIER_180 // 180-day lock, 2.0x reward multiplier
    }

    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Staking information for a user
    struct StakeInfo {
        uint256 amount; // Tokens staked
        uint256 rewardPerTokenPaid; // Rewards already accounted
        uint256 rewards; // Accumulated unclaimed rewards
    }

    /// @notice Locked stake entry for time-locked staking
    struct LockedStake {
        uint256 amount; // Tokens locked
        LockTier tier; // Lock tier (determines duration + multiplier)
        uint256 lockEnd; // Timestamp when lock expires
        bool released; // Whether stake has been released
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

    /// @notice Emitted when a locked stake is created
    event LockedStakeCreated(
        address indexed user, uint256 indexed stakeId, uint256 amount, LockTier tier, uint256 lockEnd
    );

    /// @notice Emitted when a locked stake is released
    event LockedStakeReleased(address indexed user, uint256 indexed stakeId, uint256 amount, uint256 rewardBonus);

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

    /// @notice Thrown when lock period has not expired
    error LockNotExpired(uint256 stakeId, uint256 lockEnd, uint256 currentTime);

    /// @notice Thrown when lock tier is invalid
    error InvalidTier(uint8 tier);

    /// @notice Thrown when locked stake ID is invalid or already released
    error StakeNotFound(uint256 stakeId);

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

    // ============================================
    // LOCKED STAKING FUNCTIONS
    // ============================================

    /**
     * @notice Stake tokens with a time lock for boosted rewards
     * @param amount Amount of tokens to lock
     * @param tier Lock tier (determines duration and multiplier)
     */
    function stakeLocked(uint256 amount, LockTier tier) external;

    /**
     * @notice Unlock a locked stake after the lock period expires
     * @param stakeId Index of the locked stake to release
     */
    function unlockStake(uint256 stakeId) external;

    /**
     * @notice Get all locked stakes for a user
     * @param user Address to query
     * @return Array of locked stake entries
     */
    function getLockedStakes(address user) external view returns (LockedStake[] memory);

    /**
     * @notice Get locked stake count for a user
     * @param user Address to query
     * @return Number of locked stakes (including released)
     */
    function lockedStakeCount(address user) external view returns (uint256);

    /**
     * @notice Get effective staked balance (flex + boosted locked) for reward calculations
     * @param user Address to query
     * @return Effective staked balance
     */
    function effectiveBalance(address user) external view returns (uint256);
}
