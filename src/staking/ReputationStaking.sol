// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ReputationStaking
 * @author TAG IT Network <dev@tagit.network>
 * @notice Minimal standalone stake-for-reputation contract. Stakers lock TAGIT tokens
 *         to earn time-weighted reputation points used by off-chain services
 *         (tagit-services ReputationService) for trust scoring.
 * @dev Non-upgradeable, single-asset (TAGIT). Reputation is computed off-chain
 *      from on-chain events + view methods. This contract is intentionally
 *      simple: no rewards token, no slashing — that lives in TAGITStaking.
 *
 * NIST CSF 2.0 Compliance:
 * - PR.AC-4: Access permissions enforced (Ownable, capability-less)
 * - PR.IP-1: Reentrancy guards on all mutating functions
 * - DE.CM-1: Indexed events for monitoring
 *
 * Security:
 * - CEI pattern enforced on stake/unstake
 * - SafeERC20 for non-standard ERC20 compatibility
 * - Pausable to halt new stakes in emergencies
 * - MIN_LOCK enforces time-based reputation (anti-gaming)
 *
 * @custom:security-contact security@tagit.network
 */
contract ReputationStaking is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    error ZeroAddress();
    error ZeroAmount();
    error BelowMinimumStake(uint256 amount, uint256 minimum);
    error NothingStaked(address staker);
    error LockNotExpired(uint64 unlockAt, uint64 nowAt);
    error InsufficientStake(uint256 requested, uint256 available);

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Minimum stake required to receive reputation (anti-spam)
    uint256 public constant MIN_STAKE = 100 * 1e18;

    /// @notice Minimum lock duration before unstake is allowed
    uint64 public constant MIN_LOCK = 7 days;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice TAGIT token used for staking
    IERC20 public immutable stakingToken;

    /// @notice Per-staker position
    struct Position {
        uint256 amount;
        uint64 stakedAt;
        uint64 lastUpdateAt;
    }

    /// @notice Staker => Position
    mapping(address => Position) private _positions;

    /// @notice Total tokens currently staked
    uint256 public totalStaked;

    // ============================================
    // EVENTS
    // ============================================

    event Staked(address indexed staker, uint256 amount, uint256 newTotal, uint64 stakedAt);
    event Unstaked(address indexed staker, uint256 amount, uint256 remaining, uint64 unstakedAt);
    event EmergencyWithdraw(address indexed staker, uint256 amount);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @param _stakingToken Address of the TAGIT (ERC20) token
     * @param _initialOwner Address that will own admin functions (pause/unpause)
     */
    constructor(address _stakingToken, address _initialOwner) Ownable(_initialOwner) {
        if (_stakingToken == address(0)) revert ZeroAddress();
        if (_initialOwner == address(0)) revert ZeroAddress();
        stakingToken = IERC20(_stakingToken);
    }

    // ============================================
    // STAKE / UNSTAKE
    // ============================================

    /**
     * @notice Stake TAGIT tokens to start earning reputation
     * @dev CEI: validate → effects → external transfer
     * @param amount Tokens to stake (must be >= MIN_STAKE on first deposit)
     */
    function stake(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();

        Position memory pos = _positions[msg.sender];
        uint256 newAmount = pos.amount + amount;
        if (newAmount < MIN_STAKE) revert BelowMinimumStake(newAmount, MIN_STAKE);

        // EFFECTS
        _positions[msg.sender] = Position({
            amount: newAmount,
            stakedAt: pos.stakedAt == 0 ? uint64(block.timestamp) : pos.stakedAt,
            lastUpdateAt: uint64(block.timestamp)
        });
        totalStaked += amount;

        // INTERACTIONS
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, newAmount, uint64(block.timestamp));
    }

    /**
     * @notice Unstake tokens after lock period
     * @dev CEI: validate → effects → external transfer
     * @param amount Tokens to withdraw
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        Position memory pos = _positions[msg.sender];
        if (pos.amount == 0) revert NothingStaked(msg.sender);
        if (amount > pos.amount) revert InsufficientStake(amount, pos.amount);

        uint64 unlockAt = pos.stakedAt + MIN_LOCK;
        if (block.timestamp < unlockAt) revert LockNotExpired(unlockAt, uint64(block.timestamp));

        // EFFECTS
        uint256 remaining = pos.amount - amount;
        if (remaining == 0) {
            delete _positions[msg.sender];
        } else {
            _positions[msg.sender] =
                Position({amount: remaining, stakedAt: pos.stakedAt, lastUpdateAt: uint64(block.timestamp)});
        }
        totalStaked -= amount;

        // INTERACTIONS
        stakingToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount, remaining, uint64(block.timestamp));
    }

    // ============================================
    // ADMIN
    // ============================================

    /// @notice Pause new stakes (existing stakers can still unstake)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume normal staking
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Get a staker's current position
    function positionOf(address staker) external view returns (uint256 amount, uint64 stakedAt, uint64 lastUpdateAt) {
        Position memory pos = _positions[staker];
        return (pos.amount, pos.stakedAt, pos.lastUpdateAt);
    }

    /// @notice Compute time-weighted reputation: amount * seconds-staked / 1 day
    /// @dev Off-chain services may apply additional curves; this is the raw weight
    function reputationOf(address staker) external view returns (uint256) {
        Position memory pos = _positions[staker];
        if (pos.amount < MIN_STAKE) return 0;
        uint256 elapsed = block.timestamp - pos.stakedAt;
        return (pos.amount * elapsed) / 1 days;
    }

    /// @notice True once the staker's lock period has elapsed
    function isUnlocked(address staker) external view returns (bool) {
        Position memory pos = _positions[staker];
        if (pos.amount == 0) return false;
        return block.timestamp >= pos.stakedAt + MIN_LOCK;
    }
}
