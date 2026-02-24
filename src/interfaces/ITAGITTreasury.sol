// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITTreasury
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for protocol treasury with allocation tracking
 * @dev Manages fund custody, timelocked withdrawals, and emergency controls
 */
interface ITAGITTreasury {
    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice Status of a pending withdrawal
     */
    enum WithdrawalStatus {
        PENDING,    // 0 - Queued, waiting for timelock
        EXECUTED,   // 1 - Successfully executed
        CANCELED    // 2 - Canceled by recipient or governor
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Allocation data for a program
     * @dev Tracks budget, spending, and expiration for each program
     */
    struct Allocation {
        bytes32 programId;      // e.g., keccak256("ECOSYSTEM_GRANTS")
        uint256 amount;         // TAGIT allocated
        uint256 spent;          // TAGIT disbursed
        address recipient;      // Authorized spender
        uint48 createdAt;       // Allocation creation time
        uint48 expiresAt;       // Allocation deadline
        bool active;            // Whether allocation is active
    }

    /**
     * @notice Pending withdrawal data
     * @dev Tracks withdrawal queue with timelock enforcement
     */
    struct PendingWithdrawal {
        uint256 allocationId;   // Source allocation
        uint256 amount;         // Amount to withdraw
        address token;          // Token address (address(0) for ETH)
        address to;             // Recipient address
        uint48 queuedAt;        // When withdrawal was queued
        uint48 executesAt;      // When withdrawal can be executed
        WithdrawalStatus status;// Current status
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Caller is not the governor
    error NotGovernor(address caller);

    /// @notice Caller is not the allocation recipient
    error NotRecipient(address caller, address expected);

    /// @notice Allocation does not exist
    error AllocationNotFound(uint256 allocationId);

    /// @notice Allocation is not active
    error AllocationNotActive(uint256 allocationId);

    /// @notice Allocation has expired
    error AllocationExpired(uint256 allocationId, uint48 expiresAt);

    /// @notice Withdrawal exceeds remaining allocation
    error ExceedsAllocation(uint256 allocationId, uint256 requested, uint256 remaining);

    /// @notice Allocation exceeds available balance
    error ExceedsBalance(uint256 requested, uint256 available);

    /// @notice Withdrawal does not exist
    error WithdrawalNotFound(uint256 withdrawalId);

    /// @notice Withdrawal is not in pending status
    error WithdrawalNotPending(uint256 withdrawalId, WithdrawalStatus status);

    /// @notice Timelock has not passed
    error TimelockNotPassed(uint256 withdrawalId, uint48 executesAt, uint48 currentTime);

    /// @notice Insufficient multisig approvals for large withdrawal
    error InsufficientApprovals(uint256 required, uint256 actual);

    /// @notice Token transfer failed
    error TransferFailed(address token, address to, uint256 amount);

    /// @notice ETH transfer failed
    error ETHTransferFailed(address to, uint256 amount);

    /// @notice Invalid duration (zero or too long)
    error InvalidDuration(uint48 duration);

    /// @notice Caller not authorized for emergency sweep
    error NotAuthorizedForSweep(address caller);

    /// @notice Signature already used
    error SignatureAlreadyUsed(bytes32 sigHash);

    /// @notice Invalid signature
    error InvalidSignature(address signer);

    /// @notice Insufficient signers for emergency action
    error InsufficientSigners(uint256 required, uint256 provided);

    /// @notice PATCH-11: Withdrawal asset does not match allocated asset
    error AssetMismatch(address expected, address received);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when ETH is deposited
    event ETHDeposited(
        address indexed from,
        uint256 amount
    );

    /// @notice Emitted when tokens are deposited
    event TokenDeposited(
        address indexed token,
        address indexed from,
        uint256 amount
    );

    /// @notice Emitted when allocation is created
    event AllocationCreated(
        uint256 indexed allocationId,
        bytes32 indexed programId,
        address indexed recipient,
        uint256 amount,
        uint48 expiresAt
    );

    /// @notice Emitted when allocation is closed
    event AllocationClosed(
        uint256 indexed allocationId,
        uint256 unspentAmount
    );

    /// @notice Emitted when withdrawal is queued
    event WithdrawalQueued(
        uint256 indexed withdrawalId,
        uint256 indexed allocationId,
        address indexed to,
        address token,
        uint256 amount,
        uint48 executesAt
    );

    /// @notice Emitted when withdrawal is executed
    event WithdrawalExecuted(
        uint256 indexed withdrawalId,
        address indexed to,
        address token,
        uint256 amount
    );

    /// @notice Emitted when withdrawal is canceled
    event WithdrawalCanceled(
        uint256 indexed withdrawalId,
        address indexed canceledBy
    );

    /// @notice Emitted when emergency sweep is executed
    event EmergencySweep(
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 signerCount
    );

    /// @notice Emitted when governor is updated
    event GovernorUpdated(
        address indexed oldGovernor,
        address indexed newGovernor
    );

    /// @notice Emitted when multisig signer is added/removed
    event SignerUpdated(
        address indexed signer,
        bool active
    );

    // ============================================
    // DEPOSIT FUNCTIONS
    // ============================================

    /**
     * @notice Receive ETH deposits
     * @dev Can be called by anyone (e.g., TAGITBurner)
     */
    function deposit() external payable;

    /**
     * @notice Receive ERC20 token deposits
     * @param token Token address
     * @param amount Amount to deposit
     */
    function depositToken(address token, uint256 amount) external;

    // ============================================
    // ALLOCATION FUNCTIONS
    // ============================================

    /**
     * @notice Create a new allocation (Governor only)
     * @param programId Program identifier (e.g., keccak256("ECOSYSTEM_GRANTS"))
     * @param amount TAGIT amount to allocate
     * @param recipient Authorized spender address
     * @param duration Duration in seconds until expiration
     * @return allocationId The created allocation ID
     */
    function createAllocation(
        bytes32 programId,
        uint256 amount,
        address recipient,
        uint48 duration
    ) external returns (uint256 allocationId);

    /**
     * @notice Close an allocation and return unspent funds
     * @param allocationId The allocation to close
     */
    function closeAllocation(uint256 allocationId) external;

    // ============================================
    // WITHDRAWAL FUNCTIONS
    // ============================================

    /**
     * @notice Queue a withdrawal from an allocation
     * @param allocationId Source allocation
     * @param token Token to withdraw (address(0) for ETH)
     * @param amount Amount to withdraw
     * @param to Recipient address
     * @return withdrawalId The created withdrawal ID
     */
    function queueWithdrawal(
        uint256 allocationId,
        address token,
        uint256 amount,
        address to
    ) external returns (uint256 withdrawalId);

    /**
     * @notice Execute a pending withdrawal after timelock
     * @param withdrawalId The withdrawal to execute
     */
    function executeWithdrawal(uint256 withdrawalId) external;

    /**
     * @notice Cancel a pending withdrawal
     * @param withdrawalId The withdrawal to cancel
     */
    function cancelWithdrawal(uint256 withdrawalId) external;

    // ============================================
    // EMERGENCY FUNCTIONS
    // ============================================

    /**
     * @notice Emergency sweep funds (requires 6/8 multisig)
     * @param token Token to sweep (address(0) for ETH)
     * @param to Recipient address
     * @param signatures Array of signatures from signers
     */
    function emergencySweep(
        address token,
        address to,
        bytes[] calldata signatures
    ) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get allocation details
     * @param allocationId The allocation ID
     * @return allocation The allocation data
     */
    function getAllocation(uint256 allocationId) external view returns (Allocation memory allocation);

    /**
     * @notice Get pending withdrawal details
     * @param withdrawalId The withdrawal ID
     * @return withdrawal The withdrawal data
     */
    function getWithdrawal(uint256 withdrawalId) external view returns (PendingWithdrawal memory withdrawal);

    /**
     * @notice Get treasury balances
     * @return eth ETH balance
     * @return tagit TAGIT token balance
     */
    function getBalance() external view returns (uint256 eth, uint256 tagit);

    /**
     * @notice Get total allocated amount
     * @return Total TAGIT in active allocations
     */
    function totalAllocated() external view returns (uint256);

    /**
     * @notice Get total unallocated amount
     * @return Available TAGIT not in allocations
     */
    function totalUnallocated() external view returns (uint256);

    /**
     * @notice Get remaining amount in an allocation
     * @param allocationId The allocation ID
     * @return Remaining TAGIT that can be withdrawn
     */
    function remainingAllocation(uint256 allocationId) external view returns (uint256);

    /**
     * @notice Get governor address
     * @return Governor contract address
     */
    function governor() external view returns (address);

    /**
     * @notice Get TAGIT token address
     * @return Token contract address
     */
    function tagitToken() external view returns (address);

    /**
     * @notice Check if address is a signer
     * @param signer Address to check
     * @return True if signer is active
     */
    function isSigner(address signer) external view returns (bool);

    /**
     * @notice Get required signers for emergency actions
     * @return Required number of signers
     */
    function requiredSigners() external view returns (uint256);

    /**
     * @notice Calculate timelock for a withdrawal amount
     * @param amount Withdrawal amount
     * @return timelockSeconds Timelock duration in seconds
     * @return requiresMultisig Whether multisig is required
     */
    function getTimelockForAmount(uint256 amount) external view returns (
        uint48 timelockSeconds,
        bool requiresMultisig
    );

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory);
}
