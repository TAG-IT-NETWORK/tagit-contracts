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
import {
    MIN_STAKE_FOR_REP,
    VERSION
} from "../libraries/Constants.sol";

/**
 * @title TAGITStaking
 * @author TAG IT Network <dev@tagit.network>
 * @notice Staking contract for TAGIT tokens with time-weighted rewards
 * @dev Implements Synthetix-style reward distribution
 *
 * NIST CSF 2.0 Compliance:
 * - AC-7: Unsuccessful Authentication Attempts - RateLimiter prevents spam
 * - SC-5: Denial of Service Protection - rate limiting prevents resource exhaustion
 * - SI-4: System Monitoring - indexed events for Forta monitoring
 *
 * Key Features:
 * - Stake TAGIT tokens to earn rewards
 * - Time-weighted reward distribution
 * - Rewards added from Emissions allocation (30%)
 * - Minimum stake for reputation boost (100 TAGIT)
 * - Rate limiting to prevent spam attacks (NIST AC-7)
 * - Pausable for emergencies
 * - UUPS upgradeable
 *
 * Reward Math (Synthetix-style):
 * - rewardPerToken = stored + (rate * elapsed * 1e18 / totalStaked)
 * - earned = staked * (rewardPerToken - userPaid) / 1e18
 *
 * @custom:security-contact security@tagit.network
 */
contract TAGITStaking is
    ITAGITStaking,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
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

    /// @dev Storage gap for future upgrades (reduced to account for new storage)
    uint256[38] private __gap;

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
    function initialize(
        address _token,
        address _governor,
        address initialOwner
    ) public initializer {
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
            DEFAULT_MAX_PER_WINDOW,
            DEFAULT_WINDOW_DURATION,
            DEFAULT_COOLDOWN,
            DEFAULT_GLOBAL_LIMIT
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
     * @notice Stake tokens to earn rewards
     * @param amount Amount of tokens to stake
     * @custom:security Uses nonReentrant, whenNotPaused, and rate limiting
     * @custom:emits Staked
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused rateLimited updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        _totalStaked += amount;
        _stakes[msg.sender].amount += amount;

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake tokens
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

        IERC20(address(token)).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
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
    function setRateLimitConfig(
        uint64 maxPerWindow,
        uint64 windowDuration,
        uint64 cooldownDuration,
        uint64 globalMax
    ) external onlyGovernor {
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
    function getRateLimitState(address user) external view returns (
        uint64 count,
        uint64 windowStart,
        uint64 lockedUntil
    ) {
        return RateLimiter.getUserState(_rateLimitStates, user);
    }

    /**
     * @notice Check remaining actions before rate limit
     * @param user User address to query
     * @return canAct_ Whether user can perform action
     * @return remaining Actions remaining in current window
     * @return lockedUntil Lockout end timestamp (0 = not locked)
     */
    function getRemainingActions(address user) external view returns (
        bool canAct_,
        uint256 remaining,
        uint256 lockedUntil
    ) {
        return _rateLimitConfig.canAct(_rateLimitStates, user);
    }

    /**
     * @notice Get global rate limit state
     * @return globalCount Current global action count
     * @return globalWindowStart Global window start timestamp
     * @return globalRemaining Remaining global capacity
     */
    function getGlobalRateLimitState() external view returns (
        uint64 globalCount,
        uint64 globalWindowStart,
        uint256 globalRemaining
    ) {
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
     * @return The accumulated reward per token
     */
    function rewardPerToken() public view returns (uint256) {
        if (_totalStaked == 0) {
            return _rewardPerTokenStored;
        }

        return _rewardPerTokenStored + (
            (lastTimeRewardApplicable() - _lastUpdateTime) * _rewardRate * 1e18 / _totalStaked
        );
    }

    /**
     * @notice Calculate earned rewards for an account
     * @param account The user address
     * @return The total earned rewards
     */
    function earned(address account) public view returns (uint256) {
        return (
            _stakes[account].amount * (rewardPerToken() - _stakes[account].rewardPerTokenPaid) / 1e18
        ) + _stakes[account].rewards;
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
