// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITAGITOperationalTreasury} from "../interfaces/ITAGITOperationalTreasury.sol";

/**
 * @title TAGITOperationalTreasury
 * @author TAG IT Network <dev@tagit.network>
 * @notice Operational treasury for day-to-day fund management with per-category budget caps
 * @dev Complements TAGITTreasury (governance-level) with lower-latency operational spending.
 *      Enforces budget caps per spending category within configurable time periods.
 *
 * NIST CSF 2.0 Compliance:
 * - AC-6: Least Privilege — role-based access (OPERATOR, TREASURER, ADMIN)
 * - AU-6: Audit Record Review — indexed events for all fund movements
 * - CM-3: Configuration Change Control — admin-only cap/period changes
 *
 * Role hierarchy:
 * - OPERATOR_ROLE:   deposit funds, withdraw within caps
 * - TREASURER_ROLE:  manage budget caps, reset periods
 * - ADMIN_ROLE:      pause/unpause, emergency sweep, set period duration
 * - DEFAULT_ADMIN_ROLE: grant/revoke roles (deployer initially)
 *
 * Fund flows:
 * - Operators deposit ETH/ERC-20 via depositETH()/depositERC20()
 * - Operators withdraw within budget caps via withdrawETH()/withdrawERC20()
 * - Budget caps auto-reset when the period elapses
 * - Admin can emergency sweep to a safe address
 */
contract TAGITOperationalTreasury is AccessControl, ReentrancyGuard, Pausable, ITAGITOperationalTreasury {
    using SafeERC20 for IERC20;

    // ============================================
    // ROLES
    // ============================================

    /// @notice Role for operational deposits and withdrawals
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role for managing budget caps and periods
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");

    /// @notice Role for emergency and admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Default period duration (30 days)
    uint48 public constant DEFAULT_PERIOD_DURATION = 30 days;

    /// @notice Minimum period duration (1 day)
    uint48 public constant MIN_PERIOD_DURATION = 1 days;

    /// @notice Maximum period duration (365 days)
    uint48 public constant MAX_PERIOD_DURATION = 365 days;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice Global period duration in seconds
    uint48 private _periodDuration;

    /// @notice Budget caps by category key
    mapping(bytes32 => BudgetCap) private _budgetCaps;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the operational treasury
     * @param admin Address that receives DEFAULT_ADMIN_ROLE and ADMIN_ROLE
     * @param treasurer Address that receives TREASURER_ROLE
     * @param operator Address that receives OPERATOR_ROLE
     */
    constructor(address admin, address treasurer, address operator) {
        if (admin == address(0)) revert ZeroAddress();
        if (treasurer == address(0)) revert ZeroAddress();
        if (operator == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(TREASURER_ROLE, treasurer);
        _grantRole(OPERATOR_ROLE, operator);

        _periodDuration = DEFAULT_PERIOD_DURATION;
    }

    // ============================================
    // DEPOSIT FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function depositETH() external payable override nonReentrant onlyRole(OPERATOR_ROLE) {
        if (msg.value == 0) revert ZeroAmount();
        emit ETHDeposited(msg.sender, msg.value);
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function depositERC20(address token, uint256 amount) external override nonReentrant onlyRole(OPERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit ERC20Deposited(token, msg.sender, amount);
    }

    /// @notice Receive ETH directly (no role check — allows protocol transfers)
    receive() external payable {
        emit ETHDeposited(msg.sender, msg.value);
    }

    // ============================================
    // WITHDRAWAL FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function withdrawETH(bytes32 category, address to, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // CHECKS: enforce budget cap
        _enforceAndRecordSpend(category, amount);

        // INTERACTIONS: transfer ETH
        (bool success,) = to.call{value: amount}("");
        if (!success) revert ETHTransferFailed(to, amount);

        emit ETHWithdrawn(category, to, amount);
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function withdrawERC20(bytes32 category, address token, address to, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // CHECKS: enforce budget cap
        _enforceAndRecordSpend(category, amount);

        // INTERACTIONS: transfer tokens
        IERC20(token).safeTransfer(to, amount);

        emit ERC20Withdrawn(category, token, to, amount);
    }

    // ============================================
    // BUDGET CAP MANAGEMENT
    // ============================================

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function setBudgetCap(bytes32 category, uint256 cap) external override onlyRole(TREASURER_ROLE) {
        if (category == bytes32(0)) revert CategoryNotFound(category);
        if (cap == 0) revert ZeroCap();

        BudgetCap storage bc = _budgetCaps[category];
        uint256 oldCap = bc.cap;

        bc.cap = cap;

        // Initialize period if this is a new category
        if (bc.periodStart == 0) {
            bc.periodStart = uint48(block.timestamp);
            bc.active = true;
        }

        emit BudgetCapUpdated(category, oldCap, cap);
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function deactivateCategory(bytes32 category) external override onlyRole(TREASURER_ROLE) {
        BudgetCap storage bc = _budgetCaps[category];
        if (bc.cap == 0) revert CategoryNotFound(category);
        if (!bc.active) revert CategoryNotActive(category);

        bc.active = false;

        emit CategoryDeactivated(category);
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function reactivateCategory(bytes32 category) external override onlyRole(TREASURER_ROLE) {
        BudgetCap storage bc = _budgetCaps[category];
        if (bc.cap == 0) revert CategoryNotFound(category);
        if (bc.active) revert CategoryAlreadyExists(category);

        bc.active = true;

        emit CategoryReactivated(category);
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function resetPeriod(bytes32 category) external override onlyRole(TREASURER_ROLE) {
        BudgetCap storage bc = _budgetCaps[category];
        if (bc.cap == 0) revert CategoryNotFound(category);

        bc.spent = 0;
        bc.periodStart = uint48(block.timestamp);

        emit PeriodReset(category, uint48(block.timestamp));
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function setPeriodDuration(uint48 newDuration) external override onlyRole(ADMIN_ROLE) {
        if (newDuration < MIN_PERIOD_DURATION || newDuration > MAX_PERIOD_DURATION) {
            revert InvalidPeriodDuration(newDuration);
        }

        uint48 oldDuration = _periodDuration;
        _periodDuration = newDuration;

        emit PeriodDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Pause all withdrawals
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause withdrawals
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function emergencySweep(address token, address to) external override nonReentrant onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();

        uint256 amount;

        if (token == address(0)) {
            amount = address(this).balance;
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed(to, amount);
        } else {
            amount = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencySweep(token, to, amount);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function getBudgetCap(bytes32 category) external view override returns (BudgetCap memory) {
        BudgetCap memory bc = _budgetCaps[category];

        // If period has elapsed, report spent as 0 (will be reset on next write)
        if (bc.periodStart > 0 && block.timestamp >= bc.periodStart + _periodDuration) {
            bc.spent = 0;
            bc.periodStart = uint48(block.timestamp);
        }

        return bc;
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function remainingBudget(bytes32 category) external view override returns (uint256) {
        BudgetCap memory bc = _budgetCaps[category];
        if (!bc.active || bc.cap == 0) return 0;

        // If period has elapsed, full cap is available
        if (block.timestamp >= bc.periodStart + _periodDuration) {
            return bc.cap;
        }

        return bc.cap > bc.spent ? bc.cap - bc.spent : 0;
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function periodDuration() external view override returns (uint48) {
        return _periodDuration;
    }

    /**
     * @inheritdoc ITAGITOperationalTreasury
     */
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Enforce budget cap and record the spend
     * @dev Auto-resets the period if it has elapsed. Reverts if spend exceeds cap.
     * @param category Budget category key
     * @param amount Amount being spent
     */
    function _enforceAndRecordSpend(bytes32 category, uint256 amount) internal {
        BudgetCap storage bc = _budgetCaps[category];

        // Category must exist and be active
        if (bc.cap == 0) revert CategoryNotFound(category);
        if (!bc.active) revert CategoryNotActive(category);

        // Auto-reset period if elapsed
        if (block.timestamp >= bc.periodStart + _periodDuration) {
            bc.spent = 0;
            bc.periodStart = uint48(block.timestamp);
            emit PeriodReset(category, uint48(block.timestamp));
        }

        // Check cap enforcement
        uint256 remaining = bc.cap - bc.spent;
        if (amount > remaining) {
            revert WithdrawalExceedsCap(category, amount, remaining);
        }

        // Record spend (EFFECTS before INTERACTIONS in caller)
        bc.spent += amount;
    }
}
