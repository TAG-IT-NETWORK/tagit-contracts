// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title ITAGITAccountFactory
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for creating ERC-4337 smart wallets
 * @dev Uses CREATE2 for deterministic deployment from email hash
 */
interface ITAGITAccountFactory {
    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Account already exists
    error AccountAlreadyExists(address account);

    /// @notice Invalid email hash (zero)
    error InvalidEmailHash();

    /// @notice Not authorized to create accounts
    error NotAuthorized(address caller);

    /// @notice PATCH-15: email hash not pre-verified
    error EmailNotVerified(bytes32 emailHash);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when account is created
    event AccountCreated(
        address indexed account,
        bytes32 indexed emailHash,
        uint256 salt,
        address indexed owner
    );

    /// @notice Emitted when implementation is updated
    event ImplementationUpdated(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    /// @notice Emitted when protocol guardian is updated
    event ProtocolGuardianUpdated(
        address indexed oldGuardian,
        address indexed newGuardian
    );

    /// @notice Emitted when governor is updated
    event GovernorUpdated(
        address indexed oldGovernor,
        address indexed newGovernor
    );

    /// @notice PATCH-15: Emitted when email hash is pre-verified
    event EmailVerified(bytes32 indexed emailHash, address indexed verifier);

    /// @notice PATCH-15: Emitted when email verifier is updated
    event EmailVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);

    // ============================================
    // ACCOUNT CREATION
    // ============================================

    /**
     * @notice Create a new smart account from email hash
     * @dev Uses CREATE2 for deterministic address
     * @param emailHash Keccak256 hash of user's email
     * @param salt Additional salt for uniqueness
     * @return account Address of the created account
     */
    function createAccount(
        bytes32 emailHash,
        uint256 salt
    ) external returns (address account);

    /**
     * @notice Create account with initial owner
     * @dev Called when user already has a signing key
     * @param emailHash Keccak256 hash of user's email
     * @param salt Additional salt for uniqueness
     * @param initialOwner Initial owner address (signer)
     * @return account Address of the created account
     */
    function createAccountWithOwner(
        bytes32 emailHash,
        uint256 salt,
        address initialOwner
    ) external returns (address account);

    /**
     * @notice Get counterfactual address for an account
     * @dev Returns the address before deployment
     * @param emailHash Keccak256 hash of user's email
     * @param salt Additional salt for uniqueness
     * @return account Deterministic account address
     */
    function getAddress(
        bytes32 emailHash,
        uint256 salt
    ) external view returns (address account);

    /**
     * @notice Check if account exists at address
     * @param account Account address to check
     * @return exists True if account is deployed
     */
    function isAccount(address account) external view returns (bool exists);

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Update account implementation (Governor only)
     * @dev New accounts will use the new implementation
     * @param newImplementation New implementation address
     */
    function setImplementation(address newImplementation) external;

    /**
     * @notice Update protocol guardian address (Governor only)
     * @dev Guardian address used for new account recovery
     * @param newGuardian New guardian address
     */
    function setProtocolGuardian(address newGuardian) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get account implementation address
     * @return implementation Implementation address
     */
    function accountImplementation() external view returns (address implementation);

    /**
     * @notice Get protocol guardian address
     * @return guardian Guardian address
     */
    function protocolGuardian() external view returns (address guardian);

    /**
     * @notice Get EntryPoint address
     * @return entryPoint EntryPoint contract
     */
    function entryPoint() external view returns (address entryPoint);

    /**
     * @notice Get TAGITCore address
     * @return core Core contract
     */
    function tagitCore() external view returns (address core);

    /**
     * @notice Get total accounts created
     * @return count Number of accounts
     */
    function totalAccounts() external view returns (uint256 count);

    /**
     * @notice Get contract version
     * @return version Version string
     */
    function version() external pure returns (string memory version);
}
