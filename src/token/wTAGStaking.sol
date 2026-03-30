// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {wTAG} from "./wTAG.sol";
import {TAGITStaking} from "./TAGITStaking.sol";

/**
 * @title wTAGStaking
 * @author TAG IT Network <dev@tagit.network>
 * @notice Staking wrapper that accepts wTAG tokens and delegates to TAGITStaking
 * @dev Users deposit wTAG → contract unwraps to TAGIT → stakes in TAGITStaking.
 *      On withdrawal, the reverse occurs: unstake TAGIT → wrap to wTAG → return.
 *      Rewards accrue in TAGIT and are passed through to the user on claim.
 *
 * Architecture:
 *   wTAGStaking holds wTAG deposits and manages the TAGIT↔wTAG conversion.
 *   It maintains its own accounting of per-user wTAG deposits separate from
 *   the underlying TAGITStaking balances.
 *
 * Security:
 *   - ReentrancyGuard on all state-changing functions
 *   - Checks-Effects-Interactions pattern throughout
 *   - SafeERC20 for all external token interactions
 *   - Pausable for emergencies
 *   - Custom errors only (no string reverts)
 *
 * @custom:security-contact security@tagit.network
 */
contract wTAGStaking is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using SafeERC20 for wTAG;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The wTAG token contract
    wTAG public immutable wtagToken;

    /// @notice The underlying TAGIT ERC-20 token
    IERC20 public immutable tagToken;

    /// @notice The TAGITStaking contract we delegate to
    TAGITStaking public immutable stakingContract;

    /// @notice Total wTAG deposited across all users
    uint256 private _totalDeposited;

    /// @notice Per-user wTAG deposit tracking
    mapping(address => uint256) private _deposits;

    /// @notice Per-user reward debt (rewards already accounted for)
    mapping(address => uint256) private _rewardDebt;

    /// @notice Per-user accumulated rewards snapshot
    mapping(address => uint256) private _accumulatedRewards;

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @dev Thrown when a zero address is provided
    error ZeroAddress();

    /// @dev Thrown when a zero amount is provided
    error ZeroAmount();

    /// @dev Thrown when withdrawal exceeds deposit
    error InsufficientDeposit(uint256 requested, uint256 available);

    /// @dev Thrown when there are no rewards to claim
    error NoRewardsToClaim();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when wTAG tokens are deposited for staking
    event Deposited(address indexed user, uint256 wtagAmount);

    /// @notice Emitted when wTAG tokens are withdrawn from staking
    event Withdrawn(address indexed user, uint256 wtagAmount);

    /// @notice Emitted when TAGIT rewards are claimed
    event RewardsClaimed(address indexed user, uint256 tagitAmount);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the wTAGStaking wrapper
     * @param _wtagToken Address of the wTAG token contract
     * @param _stakingContract Address of the TAGITStaking contract
     * @param _owner Admin address for pause/unpause
     */
    constructor(address _wtagToken, address _stakingContract, address _owner) Ownable(_owner) {
        if (_wtagToken == address(0)) revert ZeroAddress();
        if (_stakingContract == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        wtagToken = wTAG(_wtagToken);
        stakingContract = TAGITStaking(_stakingContract);
        tagToken = IERC20(address(stakingContract.token()));

        // Pre-approve staking contract to spend TAGIT on our behalf
        tagToken.approve(address(stakingContract), type(uint256).max);
    }

    // ============================================
    // USER FUNCTIONS
    // ============================================

    /**
     * @notice Deposit wTAG tokens for staking
     * @dev wTAG is unwrapped to TAGIT, then staked in TAGITStaking.
     *      Caller must have approved this contract to spend wTAG.
     * @param amount Amount of wTAG to deposit
     * @custom:security Uses nonReentrant, whenNotPaused, CEI pattern
     * @custom:emits Deposited
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Snapshot pending rewards before state change
        _updateRewards(msg.sender);

        // Effects: update internal accounting
        _deposits[msg.sender] += amount;
        _totalDeposited += amount;

        // Interactions: pull wTAG from user
        wtagToken.safeTransferFrom(msg.sender, address(this), amount);

        // Interactions: unwrap wTAG → TAGIT
        wtagToken.unwrap(amount);

        // Interactions: stake TAGIT in the staking contract
        stakingContract.stake(amount);

        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw wTAG tokens from staking
     * @dev TAGIT is unstaked from TAGITStaking, then wrapped back to wTAG.
     * @param amount Amount of wTAG to withdraw
     * @custom:security Uses nonReentrant, CEI pattern
     * @custom:emits Withdrawn
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > _deposits[msg.sender]) {
            revert InsufficientDeposit(amount, _deposits[msg.sender]);
        }

        // Snapshot pending rewards before state change
        _updateRewards(msg.sender);

        // Effects: update internal accounting
        _deposits[msg.sender] -= amount;
        _totalDeposited -= amount;

        // Interactions: unstake TAGIT from staking contract
        stakingContract.unstake(amount);

        // Interactions: approve wTAG to pull TAGIT for wrapping
        tagToken.approve(address(wtagToken), amount);

        // Interactions: wrap TAGIT → wTAG
        wtagToken.wrap(amount);

        // Interactions: return wTAG to user
        wtagToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim accumulated TAGIT rewards
     * @dev Rewards are claimed from TAGITStaking and transferred as TAGIT to user
     * @return claimed Amount of TAGIT rewards claimed
     * @custom:security Uses nonReentrant
     * @custom:emits RewardsClaimed
     */
    function claimRewards() external nonReentrant returns (uint256 claimed) {
        _updateRewards(msg.sender);

        claimed = _accumulatedRewards[msg.sender];
        if (claimed == 0) revert NoRewardsToClaim();

        // Effects: reset accumulated rewards
        _accumulatedRewards[msg.sender] = 0;

        // Interactions: claim from staking contract
        uint256 actualClaimed = stakingContract.claimRewards();

        // Use the minimum to prevent over-distribution
        if (actualClaimed < claimed) {
            claimed = actualClaimed;
        }

        // Interactions: transfer TAGIT rewards to user
        tagToken.safeTransfer(msg.sender, claimed);

        emit RewardsClaimed(msg.sender, claimed);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Pause deposits (withdrawals always allowed)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause deposits
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the wTAG deposit balance for a user
     * @param user Address to query
     * @return The amount of wTAG deposited
     */
    function depositBalance(address user) external view returns (uint256) {
        return _deposits[user];
    }

    /**
     * @notice Get total wTAG deposited across all users
     * @return Total deposited amount
     */
    function totalDeposited() external view returns (uint256) {
        return _totalDeposited;
    }

    /**
     * @notice Get pending TAGIT rewards for a user
     * @dev Queries the underlying staking contract for accrued rewards
     * @param user Address to query
     * @return Pending reward amount in TAGIT
     */
    function pendingRewards(address user) external view returns (uint256) {
        if (_deposits[user] == 0) return _accumulatedRewards[user];
        // Approximate: user's share of total pending on the staking contract
        uint256 totalPending = stakingContract.pendingRewards(address(this));
        if (_totalDeposited == 0) return _accumulatedRewards[user];
        uint256 userShare = (totalPending * _deposits[user]) / _totalDeposited;
        return _accumulatedRewards[user] + userShare - _rewardDebt[user];
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Update reward accounting for a user before state changes
     * @param user The user whose rewards to update
     */
    function _updateRewards(address user) internal {
        if (_totalDeposited == 0 || _deposits[user] == 0) return;

        uint256 totalPending = stakingContract.pendingRewards(address(this));
        uint256 userShare = (totalPending * _deposits[user]) / _totalDeposited;

        if (userShare > _rewardDebt[user]) {
            _accumulatedRewards[user] += userShare - _rewardDebt[user];
        }
        _rewardDebt[user] = userShare;
    }
}
