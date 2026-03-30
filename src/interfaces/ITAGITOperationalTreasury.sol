// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITOperationalTreasury
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for operational treasury with per-category budget caps
 * @dev Manages day-to-day fund disbursements subject to periodic budget limits.
 *      Designed to work alongside the protocol TAGITTreasury which handles
 *      governance-level allocations and timelocked withdrawals.
 *
 * Budget cap model:
 *   - Each spending category (bytes32 key) has a maximum cap per period
 *   - Periods reset on a configurable cadence (default 30 days)
 *   - Spent amounts are tracked cumulatively within a period
 *   - On period reset, cumulative spend resets to zero
 */
interface ITAGITOperationalTreasury {
    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Budget cap configuration for a spending category
     * @dev Packed for storage efficiency
     */
    struct BudgetCap {
        uint256 cap; // Maximum spend per period (wei / token units)
        uint256 spent; // Amount spent in current period
        uint48 periodStart; // Timestamp when current period started
        bool active; // Whether this category is active
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Caller lacks required role
    error Unauthorized(address caller, bytes32 role);

    /// @notice Withdrawal would exceed budget cap for category
    error WithdrawalExceedsCap(bytes32 category, uint256 requested, uint256 remaining);

    /// @notice Budget category is not active
    error CategoryNotActive(bytes32 category);

    /// @notice Budget category already exists
    error CategoryAlreadyExists(bytes32 category);

    /// @notice Budget category does not exist
    error CategoryNotFound(bytes32 category);

    /// @notice ETH transfer failed
    error ETHTransferFailed(address to, uint256 amount);

    /// @notice Invalid period duration (zero or too long)
    error InvalidPeriodDuration(uint48 duration);

    /// @notice Cap amount cannot be zero when activating
    error ZeroCap();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when ETH is deposited
    event ETHDeposited(address indexed from, uint256 amount);

    /// @notice Emitted when ERC-20 tokens are deposited
    event ERC20Deposited(address indexed token, address indexed from, uint256 amount);

    /// @notice Emitted when ETH is withdrawn
    event ETHWithdrawn(bytes32 indexed category, address indexed to, uint256 amount);

    /// @notice Emitted when ERC-20 tokens are withdrawn
    event ERC20Withdrawn(bytes32 indexed category, address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a budget cap is created or updated
    event BudgetCapUpdated(bytes32 indexed category, uint256 oldCap, uint256 newCap);

    /// @notice Emitted when a budget category is deactivated
    event CategoryDeactivated(bytes32 indexed category);

    /// @notice Emitted when a budget category is reactivated
    event CategoryReactivated(bytes32 indexed category);

    /// @notice Emitted when a budget period is reset
    event PeriodReset(bytes32 indexed category, uint48 newPeriodStart);

    /// @notice Emitted when the global period duration is changed
    event PeriodDurationUpdated(uint48 oldDuration, uint48 newDuration);

    /// @notice Emitted when an emergency sweep is executed
    event EmergencySweep(address indexed token, address indexed to, uint256 amount);

    // ============================================
    // DEPOSIT FUNCTIONS
    // ============================================

    /**
     * @notice Deposit ETH into the operational treasury
     * @dev Callable by anyone. Emits ETHDeposited.
     */
    function depositETH() external payable;

    /**
     * @notice Deposit ERC-20 tokens into the operational treasury
     * @param token ERC-20 token address
     * @param amount Amount to deposit
     */
    function depositERC20(address token, uint256 amount) external;

    // ============================================
    // WITHDRAWAL FUNCTIONS
    // ============================================

    /**
     * @notice Withdraw ETH subject to budget cap enforcement
     * @param category Budget category key
     * @param to Recipient address
     * @param amount Amount of ETH to withdraw
     */
    function withdrawETH(bytes32 category, address to, uint256 amount) external;

    /**
     * @notice Withdraw ERC-20 tokens subject to budget cap enforcement
     * @param category Budget category key
     * @param token ERC-20 token address
     * @param to Recipient address
     * @param amount Amount of tokens to withdraw
     */
    function withdrawERC20(bytes32 category, address token, address to, uint256 amount) external;

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Create or update a budget cap for a category
     * @param category Budget category key (e.g. keccak256("OPERATIONS"))
     * @param cap Maximum spend per period in wei/token units
     */
    function setBudgetCap(bytes32 category, uint256 cap) external;

    /**
     * @notice Deactivate a budget category (blocks withdrawals)
     * @param category Budget category key
     */
    function deactivateCategory(bytes32 category) external;

    /**
     * @notice Reactivate a budget category
     * @param category Budget category key
     */
    function reactivateCategory(bytes32 category) external;

    /**
     * @notice Reset the period for a specific category (zeroes spent)
     * @param category Budget category key
     */
    function resetPeriod(bytes32 category) external;

    /**
     * @notice Update the global period duration
     * @param newDuration New period duration in seconds
     */
    function setPeriodDuration(uint48 newDuration) external;

    /**
     * @notice Emergency sweep all funds of a token to a safe address
     * @param token Token to sweep (address(0) for ETH)
     * @param to Recipient address
     */
    function emergencySweep(address token, address to) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get budget cap details for a category
     * @param category Budget category key
     * @return Budget cap struct
     */
    function getBudgetCap(bytes32 category) external view returns (BudgetCap memory);

    /**
     * @notice Get remaining budget for a category in the current period
     * @param category Budget category key
     * @return Remaining amount that can be spent
     */
    function remainingBudget(bytes32 category) external view returns (uint256);

    /**
     * @notice Get the global period duration
     * @return Period duration in seconds
     */
    function periodDuration() external view returns (uint48);

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory);
}
