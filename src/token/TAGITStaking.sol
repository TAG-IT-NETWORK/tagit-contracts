// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITAGITStaking} from "../interfaces/ITAGITStaking.sol";
import {TAGITToken} from "./TAGITToken.sol";
import {RateLimiter} from "../libraries/RateLimiter.sol";
import {MIN_STAKE_FOR_REP, VERSION, BASIS_POINTS} from "../libraries/Constants.sol";

/**
 * @title TAGITStaking
 * @author TAG IT Network <dev@tagit.network>
 * @notice Staking contract for TAGIT tokens with time-weighted rewards and locked staking
 * @dev Implements Synthetix-style reward distribution with tier-based lock multipliers
 *
 * NIST CSF 2.0 Compliance:
 * - AC-7: Unsuccessful Authentication Attempts - RateLimiter prevents spam
 * - SC-5: Denial of Service Protection - rate limiting prevents resource exhaustion
 * - SI-4: System Monitoring - indexed events for Forta monitoring
 *
 * Key Features:
 * - Stake TAGIT tokens to earn rewards (flex and locked)
 * - Time-weighted reward distribution with tier multipliers
 * - Locked staking: TIER_30 (1.2x), TIER_90 (1.5x), TIER_180 (2.0x)
 * - Rewards added from Emissions allocation (30%)
 * - Minimum stake for reputation boost (100 TAGIT)
 * - Rate limiting to prevent spam attacks (NIST AC-7)
 * - Pausable for emergencies
 * - UUPS upgradeable
 *
 * Reward Math (Synthetix-style with multipliers):
 * - rewardPerToken = stored + (rate * elapsed * 1e18 / totalEffectiveStaked)
 * - earned = effectiveBalance * (rewardPerToken - userPaid) / 1e18
 * - effectiveBalance = flexStake + sum(lockedAmount * tierMultiplier / 10000)
 *
 * @custom:security-contact security@tagit.network
 */
contract TAGITStaking is ITAGITStaking, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using RateLimiter for RateLimiter.Config;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Default rate limit per window (10 actions)
    uint64 public constant DEFAULT_MAX_PER_WINDOW = 10;

    /// @notice Default window duration (1 hour)
    uint64 public constant DEFAULT_WINDOW_DURATION = 1 hours;

    /// @notice Default cooldown after hitting limit (15 minutes)
    uint64 public constant DEFAULT_COOLDOWN = 15 minutes;

    /// @notice Default global limit per window (1000 actions)
    uint64 public constant DEFAULT_GLOBAL_LIMIT = 1000;

    // ============================================
    // LOCKED STAKING TIER CONSTANTS
    // ============================================

    /// @notice TIER_30 lock duration: 30 days
    uint256 public constant TIER_30_DURATION = 30 days;

    /// @notice TIER_90 lock duration: 90 days
    uint256 public constant TIER_90_DURATION = 90 days;

    /// @notice TIER_180 lock duration: 180 days
    uint256 public constant TIER_180_DURATION = 180 days;

    /// @notice TIER_30 reward multiplier: 1.2x (12000 basis points)
    uint256 public constant TIER_30_MULTIPLIER = 12000;

    /// @notice TIER_90 reward multiplier: 1.5x (15000 basis points)
    uint256 public constant TIER_90_MULTIPLIER = 15000;

    /// @notice TIER_180 reward multiplier: 2.0x (20000 basis points)
    uint256 public constant TIER_180_MULTIPLIER = 20000;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The TAGIT token contract
    TAGITToken public token;

    /// @notice Governor address for access control
    address public governor;

    /// @notice Emissions contract address (can notify rewards)
    address public emissions;

    /// @notice Total staked tokens
    uint256 private _totalStaked;

    /// @notice Reward rate per second
    uint256 private _rewardRate;

    /// @notice Accumulated reward per token stored
    uint256 private _rewardPerTokenStored;

    /// @notice Last time rewards were updated
    uint256 private _lastUpdateTime;

    /// @notice Period end timestamp for current rewards
    uint256 private _periodFinish;

    /// @notice Staking info per user
    mapping(address => StakeInfo) private _stakes;

    // ============================================
    // RATE LIMITER (NIST AC-7)
    // ============================================

    /// @notice Rate limiter configuration
    RateLimiter.Config private _rateLimitConfig;

    /// @notice Per-user rate limit state
    mapping(address => RateLimiter.UserState) private _rateLimitStates;

    // ============================================
    // LOCKED STAKING STATE
    // ============================================

    /// @notice Per-user locked stake entries
    mapping(address => LockedStake[]) private _lockedStakes;

    /// @notice Total effective staked (flex + boosted locked) for reward calculations
    uint256 private _totalEffectiveStaked;

    /// @notice Per-user effective balance for reward calculations
    mapping(address => uint256) private _effectiveBalances;

    /// @dev Storage gap for future upgrades (reduced to account for new storage)
    uint256[35] private __gap;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when rate limit blocks an action
    event RateLimitBlocked(address indexed user, string action);

    // ============================================
    // CONSTRUCTOR (disabled for upgradeable)
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================
    // INITIALIZER
    // ============================================

    /**
     * @notice Initialize the staking contract
     * @param _token Address of the TAGIT token
     * @param _governor Governor address for admin functions
     * @param initialOwner Owner of the contract (for upgrades)
     */
    function initialize(address _token, address _governor, address initialOwner) public initializer {
        if (_token == address(0)) revert ZeroAddress();
        if (_governor == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __Pausable_init();

        token = TAGITToken(_token);
        governor = _governor;

        // Initialize rate limiter (NIST AC-7)
        // - 10 stake/unstake operations per hour per user
        // - 15 minute cooldown after hitting limit
        // - 1000 operations per hour globally
        _rateLimitConfig.initialize(
            DEFAULT_MAX_PER_WINDOW, DEFAULT_WINDOW_DURATION, DEFAULT_COOLDOWN, DEFAULT_GLOBAL_LIMIT
        );
    }

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Restricts access to governor only
     */
    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorized();
        _;
    }

    /**
     * @notice Restricts access to emissions contract only
     */
    modifier onlyEmissions() {
        if (msg.sender != emissions) revert Unauthorized();
        _;
    }

    /**
     * @notice Updates reward calculations before state changes
     */
    modifier updateReward(address account) {
        _rewardPerTokenStored = rewardPerToken();
        _lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            _stakes[account].rewards = earned(account);
            _stakes[account].rewardPerTokenPaid = _rewardPerTokenStored;
        }
        _;
    }

    /**
     * @notice Rate limit check for spam prevention (NIST AC-7)
     */
    modifier rateLimited() {
        if (!_rateLimitConfig.check(_rateLimitStates, msg.sender)) {
            emit RateLimitBlocked(msg.sender, "stake/unstake");
            revert RateLimiter.RateLimitExceeded(msg.sender, _rateLimitStates[msg.sender].lockedUntil);
        }
        _;
    }

    // ============================================
    // USER FUNCTIONS
    // ============================================

    /**
     * @notice Stake tokens to earn rewards (flex stake, 1x multiplier)
     * @param amount Amount of tokens to stake
     * @custom:security Uses nonReentrant, whenNotPaused, and rate limiting
     * @custom:emits Staked
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused rateLimited updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        _totalStaked += amount;
        _stakes[msg.sender].amount += amount;

        // Flex stake: 1x effective balance (amount == effective contribution)
        _effectiveBalances[msg.sender] += amount;
        _totalEffectiveStaked += amount;

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake flex-staked tokens
     * @param amount Amount of tokens to unstake
     * @custom:security Uses nonReentrant and rate limiting
     * @custom:emits Unstaked
     */
    function unstake(uint256 amount) external nonReentrant rateLimited updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (amount > _stakes[msg.sender].amount) {
            revert InsufficientStake(amount, _stakes[msg.sender].amount);
        }

        _totalStaked -= amount;
        _stakes[msg.sender].amount -= amount;

        // Flex stake: 1x effective balance reduction
        _effectiveBalances[msg.sender] -= amount;
        _totalEffectiveStaked -= amount;

        IERC20(address(token)).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // ============================================
    // LOCKED STAKING FUNCTIONS
    // ============================================

    /**
     * @notice Stake tokens with a time lock for boosted rewards
     * @dev Creates a LockedStake entry. Tokens cannot be withdrawn until lockEnd.
     *      Reward multiplier is applied as effective balance for Synthetix math.
     * @param amount Amount of tokens to lock
     * @param tier Lock tier (TIER_30, TIER_90, TIER_180)
     * @custom:security Uses nonReentrant, whenNotPaused, rateLimited. CEI pattern followed.
     * @custom:emits LockedStakeCreated
     */
    function stakeLocked(uint256 amount, LockTier tier)
        external
        nonReentrant
        whenNotPaused
        rateLimited
        updateReward(msg.sender)
    {
        if (amount == 0) revert ZeroAmount();

        uint256 duration = _tierDuration(tier);
        uint256 multiplier = _tierMultiplier(tier);
        uint256 lockEnd = block.timestamp + duration;
        uint256 effectiveContribution = (amount * multiplier) / BASIS_POINTS;

        // Effects
        _totalStaked += amount;
        _effectiveBalances[msg.sender] += effectiveContribution;
        _totalEffectiveStaked += effectiveContribution;

        uint256 stakeId = _lockedStakes[msg.sender].length;
        _lockedStakes[msg.sender].push(LockedStake({amount: amount, tier: tier, lockEnd: lockEnd, released: false}));

        // Interactions
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);

        emit LockedStakeCreated(msg.sender, stakeId, amount, tier, lockEnd);
    }

    /**
     * @notice Unlock a locked stake after the lock period has expired
     * @dev Returns locked tokens and settles boosted rewards. CEI pattern followed.
     * @param stakeId Index of the locked stake in the user's array
     * @custom:security Uses nonReentrant. Validates lock expiry and stake existence.
     * @custom:emits LockedStakeReleased
     */
    function unlockStake(uint256 stakeId) external nonReentrant updateReward(msg.sender) {
        LockedStake[] storage stakes = _lockedStakes[msg.sender];
        if (stakeId >= stakes.length) revert StakeNotFound(stakeId);

        LockedStake storage lockedStake = stakes[stakeId];
        if (lockedStake.released) revert StakeNotFound(stakeId);
        if (block.timestamp < lockedStake.lockEnd) {
            revert LockNotExpired(stakeId, lockedStake.lockEnd, block.timestamp);
        }

        uint256 amount = lockedStake.amount;
        uint256 multiplier = _tierMultiplier(lockedStake.tier);
        uint256 effectiveContribution = (amount * multiplier) / BASIS_POINTS;

        // Effects: mark released before external calls
        lockedStake.released = true;
        _totalStaked -= amount;
        _effectiveBalances[msg.sender] -= effectiveContribution;
        _totalEffectiveStaked -= effectiveContribution;

        // Calculate reward bonus (difference between boosted and base rewards)
        uint256 bonusMultiplier = multiplier - BASIS_POINTS;
        uint256 rewardBonus = (amount * bonusMultiplier) / BASIS_POINTS;

        // Interactions
        IERC20(address(token)).safeTransfer(msg.sender, amount);

        emit LockedStakeReleased(msg.sender, stakeId, amount, rewardBonus);
    }

    /**
     * @notice Claim accumulated rewards
     * @return claimed Amount of rewards claimed
     * @custom:security Uses nonReentrant (no rate limit on claims)
     * @custom:emits RewardsClaimed
     */
    function claimRewards() external nonReentrant updateReward(msg.sender) returns (uint256 claimed) {
        claimed = _stakes[msg.sender].rewards;

        if (claimed == 0) revert NoRewardsToClaim();

        _stakes[msg.sender].rewards = 0;

        IERC20(address(token)).safeTransfer(msg.sender, claimed);

        emit RewardsClaimed(msg.sender, claimed);
    }

    // ============================================
    // EMISSIONS FUNCTIONS
    // ============================================

    /**
     * @notice Set the emissions address (one-time)
     * @param _emissions Address of the emissions contract
     */
    function setEmissions(address _emissions) external onlyOwner {
        if (_emissions == address(0)) revert ZeroAddress();
        if (emissions != address(0)) revert EmissionsAlreadySet();

        emissions = _emissions;
        emit EmissionsSet(_emissions);
    }

    /**
     * @notice Add rewards to the pool
     * @dev Called by Emissions contract during distribution
     * @param amount Amount of reward tokens to add
     * @custom:emits RewardAdded
     */
    function notifyRewardAmount(uint256 amount) external onlyEmissions updateReward(address(0)) {
        if (amount == 0) revert ZeroAmount();

        // Transfer rewards from emissions
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate new reward rate
        if (block.timestamp >= _periodFinish) {
            // New period: set rate based on reward duration (7 days)
            _rewardRate = amount / 7 days;
        } else {
            // Extend current period
            uint256 remaining = _periodFinish - block.timestamp;
            uint256 leftover = remaining * _rewardRate;
            _rewardRate = (amount + leftover) / 7 days;
        }

        _lastUpdateTime = block.timestamp;
        _periodFinish = block.timestamp + 7 days;

        emit RewardAdded(amount);
    }

    // ============================================
    // GOVERNOR FUNCTIONS
    // ============================================

    /**
     * @notice Update the reward rate
     * @param rate New reward rate per second
     * @custom:emits RewardRateUpdated
     */
    function setRewardRate(uint256 rate) external onlyGovernor updateReward(address(0)) {
        uint256 oldRate = _rewardRate;
        _rewardRate = rate;
        _lastUpdateTime = block.timestamp;

        emit RewardRateUpdated(oldRate, rate);
    }

    /**
     * @notice Pause staking operations
     */
    function pause() external onlyGovernor {
        _pause();
    }

    /**
     * @notice Unpause staking operations
     */
    function unpause() external onlyGovernor {
        _unpause();
    }

    /**
     * @notice Update the governor address
     * @param newGovernor The new governor address
     * @custom:emits GovernorUpdated
     */
    function setGovernor(address newGovernor) external onlyOwner {
        if (newGovernor == address(0)) revert ZeroAddress();

        address oldGovernor = governor;
        governor = newGovernor;

        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    // ============================================
    // RATE LIMITER ADMIN (NIST AC-7)
    // ============================================

    /**
     * @notice Update rate limiter configuration
     * @param maxPerWindow Max actions per window per user
     * @param windowDuration Window duration in seconds
     * @param cooldownDuration Cooldown duration after hitting limit
     * @param globalMax Global limit (0 = disabled)
     */
    function setRateLimitConfig(uint64 maxPerWindow, uint64 windowDuration, uint64 cooldownDuration, uint64 globalMax)
        external
        onlyGovernor
    {
        _rateLimitConfig.initialize(maxPerWindow, windowDuration, cooldownDuration, globalMax);
    }

    /**
     * @notice Enable or disable rate limiting
     * @param enabled Whether to enable rate limiting
     */
    function setRateLimitEnabled(bool enabled) external onlyGovernor {
        _rateLimitConfig.setEnabled(enabled);
    }

    /**
     * @notice Reset rate limit for a specific user
     * @param user User address to reset
     */
    function resetUserRateLimit(address user) external onlyGovernor {
        RateLimiter.forceUnlock(_rateLimitStates, user);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get staked balance for a user
     * @param user Address to query
     * @return Staked token amount
     */
    function stakedBalance(address user) external view returns (uint256) {
        return _stakes[user].amount;
    }

    /**
     * @notice Get pending rewards for a user
     * @param user Address to query
     * @return Pending reward amount
     */
    function pendingRewards(address user) external view returns (uint256) {
        return earned(user);
    }

    /**
     * @notice Get total staked tokens
     * @return Total staked amount
     */
    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    /**
     * @notice Get current reward rate
     * @return Reward rate per second
     */
    function rewardRate() external view returns (uint256) {
        return _rewardRate;
    }

    /**
     * @notice Check if user qualifies for reputation boost
     * @param user Address to query
     * @return True if stake >= MIN_STAKE_FOR_REP
     */
    function qualifiesForRepBoost(address user) external view returns (bool) {
        return _stakes[user].amount >= MIN_STAKE_FOR_REP;
    }

    /**
     * @notice Get stake info for a user
     * @param user Address to query
     * @return Stake information
     */
    function getStakeInfo(address user) external view returns (StakeInfo memory) {
        return _stakes[user];
    }

    /**
     * @notice Get period finish timestamp
     * @return When current reward period ends
     */
    function periodFinish() external view returns (uint256) {
        return _periodFinish;
    }

    /**
     * @notice Get the contract version
     * @return Current version string
     */
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // ============================================
    // RATE LIMITER VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if rate limiting is enabled
     * @return Whether rate limiting is enabled
     */
    function isRateLimitEnabled() external view returns (bool) {
        return _rateLimitConfig.isEnabled();
    }

    /**
     * @notice Get rate limit state for a user
     * @param user User address to query
     * @return count Actions in current window
     * @return windowStart Start of current window
     * @return lockedUntil Lockout end timestamp (0 = not locked)
     */
    function getRateLimitState(address user)
        external
        view
        returns (uint64 count, uint64 windowStart, uint64 lockedUntil)
    {
        return RateLimiter.getUserState(_rateLimitStates, user);
    }

    /**
     * @notice Check remaining actions before rate limit
     * @param user User address to query
     * @return canAct_ Whether user can perform action
     * @return remaining Actions remaining in current window
     * @return lockedUntil Lockout end timestamp (0 = not locked)
     */
    function getRemainingActions(address user)
        external
        view
        returns (bool canAct_, uint256 remaining, uint256 lockedUntil)
    {
        return _rateLimitConfig.canAct(_rateLimitStates, user);
    }

    /**
     * @notice Get global rate limit state
     * @return globalCount Current global action count
     * @return globalWindowStart Global window start timestamp
     * @return globalRemaining Remaining global capacity
     */
    function getGlobalRateLimitState()
        external
        view
        returns (uint64 globalCount, uint64 globalWindowStart, uint256 globalRemaining)
    {
        return _rateLimitConfig.getGlobalState();
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Get the last time rewards are applicable
     * @return The min of current time and period finish
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < _periodFinish ? block.timestamp : _periodFinish;
    }

    /**
     * @notice Calculate current reward per token
     * @dev Uses _totalEffectiveStaked (includes lock multipliers) for fair distribution
     * @return The accumulated reward per token
     */
    function rewardPerToken() public view returns (uint256) {
        if (_totalEffectiveStaked == 0) {
            return _rewardPerTokenStored;
        }

        return _rewardPerTokenStored
            + ((lastTimeRewardApplicable() - _lastUpdateTime) * _rewardRate * 1e18 / _totalEffectiveStaked);
    }

    /**
     * @notice Calculate earned rewards for an account
     * @dev Uses effective balance (flex + boosted locked) for accurate reward calculation
     * @param account The user address
     * @return The total earned rewards
     */
    function earned(address account) public view returns (uint256) {
        return (_effectiveBalances[account] * (rewardPerToken() - _stakes[account].rewardPerTokenPaid) / 1e18)
            + _stakes[account].rewards;
    }

    // ============================================
    // LOCKED STAKING VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get all locked stakes for a user
     * @param user Address to query
     * @return Array of locked stake entries
     */
    function getLockedStakes(address user) external view returns (LockedStake[] memory) {
        return _lockedStakes[user];
    }

    /**
     * @notice Get locked stake count for a user
     * @param user Address to query
     * @return Number of locked stakes (including released)
     */
    function lockedStakeCount(address user) external view returns (uint256) {
        return _lockedStakes[user].length;
    }

    /**
     * @notice Get effective staked balance for reward calculations
     * @param user Address to query
     * @return Effective staked balance (flex + boosted locked)
     */
    function effectiveBalance(address user) external view returns (uint256) {
        return _effectiveBalances[user];
    }

    /**
     * @notice Get total effective staked across all users
     * @return Total effective staked amount
     */
    function totalEffectiveStaked() external view returns (uint256) {
        return _totalEffectiveStaked;
    }

    // ============================================
    // LOCKED STAKING INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Get lock duration for a tier
     * @param tier The lock tier
     * @return Duration in seconds
     */
    function _tierDuration(LockTier tier) internal pure returns (uint256) {
        if (tier == LockTier.TIER_30) return TIER_30_DURATION;
        if (tier == LockTier.TIER_90) return TIER_90_DURATION;
        if (tier == LockTier.TIER_180) return TIER_180_DURATION;
        revert InvalidTier(uint8(tier));
    }

    /**
     * @notice Get reward multiplier for a tier in basis points
     * @param tier The lock tier
     * @return Multiplier in basis points (e.g. 12000 = 1.2x)
     */
    function _tierMultiplier(LockTier tier) internal pure returns (uint256) {
        if (tier == LockTier.TIER_30) return TIER_30_MULTIPLIER;
        if (tier == LockTier.TIER_90) return TIER_90_MULTIPLIER;
        if (tier == LockTier.TIER_180) return TIER_180_MULTIPLIER;
        revert InvalidTier(uint8(tier));
    }

    // ============================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================

    /**
     * @notice Authorize contract upgrades
     * @dev Only owner can authorize upgrades
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
