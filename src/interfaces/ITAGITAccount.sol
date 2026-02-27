// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @title ITAGITAccount
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for ERC-4337 smart wallet with session keys and self-custody
 * @dev Enables gasless UX for email/social login users
 */
interface ITAGITAccount {
    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Session key configuration for temporary access
     * @param key Address of the session key
     * @param validAfter Timestamp when session becomes valid
     * @param validUntil Timestamp when session expires
     * @param allowedSelectors Function selectors this key can call
     * @param spendLimit Maximum value this key can spend (0 = no limit)
     */
    struct SessionKey {
        address key;
        uint48 validAfter;
        uint48 validUntil;
        bytes4[] allowedSelectors;
        uint256 spendLimit;
    }

    /**
     * @notice Guardian configuration for account recovery
     * @param guardians List of guardian addresses
     * @param threshold Number of guardians required for recovery
     * @param recoveryDelay Delay before recovery executes
     * @param protocolGuardian Whether TAG IT is still a guardian
     */
    struct GuardianConfig {
        address[] guardians;
        uint8 threshold;
        uint48 recoveryDelay;
        bool protocolGuardian;
    }

    /**
     * @notice Pending protocol guardian removal
     * @param requestedAt Timestamp when removal was requested
     * @param executed Whether removal has been executed
     */
    struct ProtocolGuardianRemoval {
        uint48 requestedAt;
        bool executed;
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Caller is not the EntryPoint
    error NotEntryPoint(address caller);

    /// @notice Caller is not the owner
    error NotOwner(address caller);

    /// @notice Caller is not an authorized session key
    error NotSessionKey(address caller);

    /// @notice Session key has expired
    error SessionKeyExpired(address key, uint48 validUntil);

    /// @notice Session key not yet valid
    error SessionKeyNotYetValid(address key, uint48 validAfter);

    /// @notice Selector not allowed for session key
    error SelectorNotAllowed(address key, bytes4 selector);

    /// @notice Spend limit exceeded
    error SpendLimitExceeded(address key, uint256 requested, uint256 limit);

    /// @notice Invalid signature
    error InvalidSignature();

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Guardian already exists
    error GuardianAlreadyExists(address guardian);

    /// @notice Guardian not found
    error GuardianNotFound(address guardian);

    /// @notice Cannot remove last guardian
    error CannotRemoveLastGuardian();

    /// @notice Invalid threshold
    error InvalidThreshold(uint8 threshold, uint8 guardianCount);

    /// @notice Protocol guardian removal not ready
    error RemovalNotReady(uint48 requestedAt, uint48 readyAt);

    /// @notice No pending removal request
    error NoPendingRemoval();

    /// @notice Account already initialized
    error AlreadyInitialized();

    /// @notice Caller is not the factory
    error NotFactory(address caller);

    /// @notice Execution failed
    error ExecutionFailed(address target, uint256 value, bytes data);

    /// @notice Batch length mismatch
    error BatchLengthMismatch();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when account is initialized
    event AccountInitialized(address indexed owner, bytes32 indexed emailHash, address indexed factory);

    /// @notice Emitted when session key is added
    event SessionKeyAdded(address indexed key, uint48 validAfter, uint48 validUntil, bytes4[] allowedSelectors);

    /// @notice Emitted when session key is revoked
    event SessionKeyRevoked(address indexed key);

    /// @notice Emitted when guardian is added
    event GuardianAdded(address indexed guardian, uint8 newThreshold);

    /// @notice Emitted when guardian is removed
    event GuardianRemoved(address indexed guardian, uint8 newThreshold);

    /// @notice Emitted when protocol guardian removal is requested
    event ProtocolGuardianRemovalRequested(uint48 requestedAt, uint48 readyAt);

    /// @notice Emitted when protocol guardian is removed
    event ProtocolGuardianRemoved();

    /// @notice Emitted when asset is exported
    event AssetExported(uint256 indexed tokenId, address indexed destination);

    /// @notice Emitted when all assets are exported
    event AllAssetsExported(address indexed destination);

    /// @notice Emitted when execution succeeds
    event Executed(address indexed target, uint256 value, bytes data);

    // ============================================
    // ERC-4337 FUNCTIONS
    // ============================================

    /**
     * @notice Validate user operation signature and nonce
     * @param userOp The user operation
     * @param userOpHash Hash of the user operation
     * @param missingAccountFunds Funds to transfer to EntryPoint
     * @return validationData Packed validation result
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        returns (uint256 validationData);

    /**
     * @notice Execute a single call
     * @param dest Target address
     * @param value ETH value to send
     * @param func Calldata to execute
     */
    function execute(address dest, uint256 value, bytes calldata func) external;

    /**
     * @notice Execute multiple calls in batch
     * @param dest Target addresses
     * @param values ETH values to send
     * @param func Calldatas to execute
     */
    function executeBatch(address[] calldata dest, uint256[] calldata values, bytes[] calldata func) external;

    // ============================================
    // SESSION KEY MANAGEMENT
    // ============================================

    /**
     * @notice Add a new session key
     * @param key Session key configuration
     */
    function addSessionKey(SessionKey calldata key) external;

    /**
     * @notice Revoke a session key
     * @param key Address of the session key to revoke
     */
    function revokeSessionKey(address key) external;

    /**
     * @notice Check if a session key is valid for a selector
     * @param key Session key address
     * @param selector Function selector
     * @return valid True if the session key can call this selector
     */
    function isValidSessionKey(address key, bytes4 selector) external view returns (bool valid);

    /**
     * @notice Get session key details
     * @param key Session key address
     * @return sessionKey Session key configuration
     */
    function getSessionKey(address key) external view returns (SessionKey memory sessionKey);

    // ============================================
    // GUARDIAN MANAGEMENT
    // ============================================

    /**
     * @notice Add a guardian
     * @param guardian Guardian address
     * @param threshold New threshold
     */
    function addGuardian(address guardian, uint8 threshold) external;

    /**
     * @notice Remove a guardian
     * @param guardian Guardian to remove
     * @param threshold New threshold
     */
    function removeGuardian(address guardian, uint8 threshold) external;

    /**
     * @notice Request protocol guardian removal (7-day timelock)
     */
    function requestProtocolGuardianRemoval() external;

    /**
     * @notice Execute protocol guardian removal after timelock
     */
    function removeProtocolGuardian() external;

    /**
     * @notice Cancel pending protocol guardian removal
     */
    function cancelProtocolGuardianRemoval() external;

    /**
     * @notice Get guardian configuration
     * @return config Guardian configuration
     */
    function getGuardianConfig() external view returns (GuardianConfig memory config);

    // ============================================
    // SELF-CUSTODY (PRD-002)
    // ============================================

    /**
     * @notice Export a single asset to external wallet
     * @param tokenId Asset token ID
     * @param destination Destination address
     */
    function exportAsset(uint256 tokenId, address destination) external;

    /**
     * @notice Export all assets to external wallet
     * @param destination Destination address
     */
    function exportAllAssets(address destination) external;

    /**
     * @notice Request encrypted key export for full self-custody
     * @return encryptedKey Encrypted private key material
     */
    function requestKeyExport() external returns (bytes memory encryptedKey);

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get account owner
     * @return owner Owner address
     */
    function owner() external view returns (address owner);

    /**
     * @notice Get email hash (identity anchor)
     * @return emailHash Keccak256 hash of email
     */
    function emailHash() external view returns (bytes32 emailHash);

    /**
     * @notice Get EntryPoint address
     * @return entryPoint EntryPoint contract
     */
    function entryPoint() external view returns (address entryPoint);

    /**
     * @notice Get factory address
     * @return factory Factory contract
     */
    function factory() external view returns (address factory);

    /**
     * @notice Get contract version
     * @return version Version string
     */
    function version() external pure returns (string memory version);
}
