// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IIntegrationFactory
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for partner onboarding and integration management
 * @dev Manages partner configurations, payment routing, and multi-sig governance
 */
interface IIntegrationFactory {
    // ============================================
    // ENUMS
    // ============================================

    /// @notice Integration lifecycle status
    enum IntegrationStatus {
        ACTIVE,         // 0 - Fully operational
        GRACE_PERIOD,   // 1 - Deactivation requested, 30-day grace
        DEACTIVATED     // 2 - Permanently deactivated
    }

    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Partner integration configuration
    struct Integration {
        uint256 agentId;              // TAGITAgentIdentity token ID
        address partnerWallet;        // Partner's receiving wallet
        address paymentToken;         // ERC-20 for payments (address(0) = ETH)
        uint96 feeRate;               // Basis points (e.g., 500 = 5%)
        uint64 deployedAt;            // Deployment timestamp
        uint64 deactivateRequestedAt; // 0 = active, >0 = grace period
        bool active;                  // Currently active
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Zero amount not allowed
    error ZeroAmount();

    /// @notice Invalid agent ID
    error InvalidAgentId(uint256 agentId);

    /// @notice Agent already has an integration
    error AgentAlreadyIntegrated(uint256 agentId);

    /// @notice Integration not found
    error IntegrationNotFound(uint256 integrationId);

    /// @notice Integration is not active
    error IntegrationNotActive(uint256 integrationId);

    /// @notice Integration is in grace period
    error IntegrationInGracePeriod(uint256 integrationId);

    /// @notice Integration already deactivated
    error IntegrationAlreadyDeactivated(uint256 integrationId);

    /// @notice Grace period has not expired yet
    error GracePeriodNotExpired(uint256 integrationId, uint256 expiresAt);

    /// @notice Payment exceeds per-transaction cap
    error PaymentExceedsCap(uint256 amount, uint256 cap);

    /// @notice Fee rate exceeds maximum (10000 bps)
    error InvalidFeeRate(uint256 feeRate);

    /// @notice Insufficient multisig signatures
    error InsufficientSignatures(uint256 provided, uint256 required);

    /// @notice Invalid signature from non-signer
    error InvalidSignature(address signer);

    /// @notice Duplicate signer in signature array
    error DuplicateSigner(address signer);

    /// @notice Signer not found in signer list
    error SignerNotFound(address signer);

    /// @notice Cannot remove signer — minimum required
    error MinimumSignersRequired();

    /// @notice Signer already exists
    error SignerAlreadyExists(address signer);

    /// @notice Token transfer failed
    error TransferFailed();

    /// @notice Caller is not an authorized integrator
    error NotAuthorizedIntegrator(address caller);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a new partner integration is deployed
    event IntegrationDeployed(
        uint256 indexed integrationId,
        uint256 indexed agentId,
        address partnerWallet,
        address paymentToken,
        uint256 feeRate
    );

    /// @notice Emitted when a payment is processed through an integration
    event PaymentProcessed(
        uint256 indexed integrationId,
        address indexed payer,
        uint256 amount,
        uint256 protocolFee,
        uint256 toPartner
    );

    /// @notice Emitted when deactivation is requested (starts grace period)
    event IntegrationDeactivationRequested(
        uint256 indexed integrationId,
        uint256 gracePeriodEnds
    );

    /// @notice Emitted when integration is fully deactivated after grace period
    event IntegrationDeactivated(
        uint256 indexed integrationId,
        uint256 indexed agentId
    );

    /// @notice Emitted when integration is reactivated during grace period
    event IntegrationReactivated(uint256 indexed integrationId);

    /// @notice Emitted when max payment cap is updated
    event MaxPaymentUpdated(uint256 oldMax, uint256 newMax);

    /// @notice Emitted when a multisig signer is added
    event SignerAdded(address indexed signer);

    /// @notice Emitted when a multisig signer is removed
    event SignerRemoved(address indexed signer);

    /// @notice Emitted when an integrator is authorized
    event IntegratorAuthorized(address indexed integrator);

    /// @notice Emitted when an integrator is revoked
    event IntegratorRevoked(address indexed integrator);

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Deploy a new partner integration
     * @param agentId TAGITAgentIdentity token ID
     * @param partnerWallet Partner's receiving wallet address
     * @param feeRate Protocol fee rate in basis points
     * @param paymentToken ERC-20 token for payments
     * @return integrationId The created integration ID
     */
    function deployIntegration(
        uint256 agentId,
        address partnerWallet,
        uint96 feeRate,
        address paymentToken
    ) external returns (uint256 integrationId);

    /**
     * @notice Process a payment through a partner integration
     * @dev Splits payment between protocol fee (via TAGITBurner) and partner
     * @param integrationId The target integration
     * @param amount Payment amount in payment token
     */
    function processPayment(uint256 integrationId, uint256 amount) external;

    /**
     * @notice Request deactivation of an integration (starts 30-day grace period)
     * @param integrationId The integration to deactivate
     */
    function deactivateIntegration(uint256 integrationId) external;

    /**
     * @notice Finalize deactivation after grace period expires
     * @param integrationId The integration to finalize
     */
    function executeDeactivation(uint256 integrationId) external;

    /**
     * @notice Reactivate an integration during grace period (requires multisig)
     * @param integrationId The integration to reactivate
     * @param signatures Multi-sig signatures from signers
     */
    function reactivateIntegration(
        uint256 integrationId,
        bytes[] calldata signatures
    ) external;

    // ============================================
    // ADMIN FUNCTIONS (MULTI-SIG)
    // ============================================

    /**
     * @notice Update the maximum payment per transaction (requires multisig)
     * @param newMax New maximum amount
     * @param signatures Multi-sig signatures
     */
    function setMaxPayment(uint256 newMax, bytes[] calldata signatures) external;

    /**
     * @notice Add a new multisig signer (requires multisig)
     * @param signer Address to add
     * @param signatures Multi-sig signatures
     */
    function addSigner(address signer, bytes[] calldata signatures) external;

    /**
     * @notice Remove a multisig signer (requires multisig)
     * @param signer Address to remove
     * @param signatures Multi-sig signatures
     */
    function removeSigner(address signer, bytes[] calldata signatures) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get integration details
     * @param integrationId The integration ID
     * @return integration The integration data
     */
    function getIntegration(uint256 integrationId)
        external view returns (Integration memory integration);

    /**
     * @notice Get integration ID for an agent
     * @param agentId The agent's token ID
     * @return integrationId The integration ID (0 if none)
     */
    function getIntegrationByAgent(uint256 agentId)
        external view returns (uint256 integrationId);

    /**
     * @notice Get integration status
     * @param integrationId The integration ID
     * @return status Current lifecycle status
     */
    function getIntegrationStatus(uint256 integrationId)
        external view returns (IntegrationStatus status);

    /**
     * @notice Check if integration is currently active
     * @param integrationId The integration ID
     * @return active True if active or in grace period
     */
    function isIntegrationActive(uint256 integrationId)
        external view returns (bool active);

    /// @notice Total integrations created
    function totalIntegrations() external view returns (uint256);

    /// @notice Currently active integrations
    function activeIntegrations() external view returns (uint256);

    /// @notice Maximum payment per transaction
    function maxPaymentPerTx() external view returns (uint256);

    /// @notice Get all multisig signers
    function getSigners() external view returns (address[] memory);

    /// @notice Required signature count for multisig operations
    function requiredSignatures() external view returns (uint256);

    /// @notice Contract version
    function version() external pure returns (string memory);

    /**
     * @notice Authorize an address to call processPayment
     * @param integrator Address to authorize
     */
    function grantIntegrator(address integrator) external;

    /**
     * @notice Revoke an integrator's authorization
     * @param integrator Address to revoke
     */
    function revokeIntegrator(address integrator) external;

    /**
     * @notice Check if an address is an authorized integrator
     * @param integrator Address to check
     * @return authorized Whether the address is authorized
     */
    function isAuthorizedIntegrator(address integrator) external view returns (bool authorized);
}
