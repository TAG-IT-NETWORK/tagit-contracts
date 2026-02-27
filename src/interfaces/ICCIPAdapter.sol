// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICCIPAdapter
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for cross-chain verification via Chainlink CCIP
 * @dev Enables cross-chain asset verification requests and responses
 */
interface ICCIPAdapter {
    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice Type of cross-chain request
     */
    enum RequestType {
        VERIFY, // Verify asset authenticity
        STATUS, // Get asset lifecycle status
        OWNERSHIP, // Get current owner
        FULL // Full asset data
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Cross-chain verification request
     * @param sourceChain CCIP chain selector of source
     * @param sender Address of requesting contract
     * @param tokenId Asset to verify
     * @param requestId Unique request identifier
     * @param reqType Type of request
     */
    struct CrossChainRequest {
        uint64 sourceChain;
        address sender;
        uint256 tokenId;
        bytes32 requestId;
        RequestType reqType;
    }

    /**
     * @notice Cross-chain verification response
     * @param requestId Matching request ID
     * @param valid Whether asset is valid/authentic
     * @param status Asset lifecycle status (0-6)
     * @param owner Current asset owner
     * @param metadataHash IPFS metadata hash
     */
    struct CrossChainResponse {
        bytes32 requestId;
        bool valid;
        uint8 status;
        address owner;
        bytes32 metadataHash;
    }

    /**
     * @notice Configuration for a supported chain
     * @param chainSelector CCIP chain selector ID
     * @param adapter Remote CCIPAdapter address on that chain
     * @param active Whether chain is currently active
     * @param gasLimit Gas limit for callbacks to that chain
     */
    struct ChainConfig {
        uint64 chainSelector;
        address adapter;
        bool active;
        uint256 gasLimit;
    }

    /**
     * @notice Pending chain addition (for timelock)
     * @param config Chain configuration to add
     * @param scheduledAt Timestamp when scheduled
     * @param executed Whether addition was executed
     */
    struct PendingChainAddition {
        ChainConfig config;
        uint48 scheduledAt;
        bool executed;
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Caller is not the CCIP router
    error NotRouter(address caller);

    /// @notice Caller is not the governor
    error NotGovernor(address caller);

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Chain is not supported
    error UnsupportedChain(uint64 chainSelector);

    /// @notice Sender is not a known adapter
    error UnknownSender(uint64 chainSelector, address sender);

    /// @notice Request ID already used (replay protection)
    error RequestIdAlreadyUsed(bytes32 requestId);

    /// @notice Insufficient fee for CCIP message
    error InsufficientFee(uint256 required, uint256 provided);

    /// @notice Rate limit exceeded
    error RateLimitExceeded(uint256 remaining, uint256 requested);

    /// @notice Chain addition timelock not elapsed
    error TimelockNotElapsed(uint48 scheduledAt, uint48 readyAt);

    /// @notice No pending chain addition
    error NoPendingAddition(uint64 chainSelector);

    /// @notice Chain already exists
    error ChainAlreadyExists(uint64 chainSelector);

    /// @notice Contract is paused
    error ContractPaused();

    /// @notice Invalid threshold for pause/unpause
    error InvalidThreshold(uint8 required, uint8 provided);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when verification request is sent
    event VerificationRequested(
        bytes32 indexed requestId,
        uint64 indexed destChain,
        uint256 indexed tokenId,
        RequestType reqType,
        address requester
    );

    /// @notice Emitted when verification response is received
    event VerificationResponseReceived(
        bytes32 indexed requestId, uint64 indexed sourceChain, uint256 indexed tokenId, bool valid
    );

    /// @notice Emitted when verification request is processed
    event VerificationRequestProcessed(
        bytes32 indexed requestId, uint64 indexed sourceChain, uint256 indexed tokenId, bool success
    );

    /// @notice Emitted when a CCIP message is processed with chain-bound tracking
    event CcipMessageProcessed(bytes32 indexed messageId, uint64 indexed sourceChainSelector, uint256 chainId);

    /// @notice Emitted when chain addition is scheduled
    event ChainAdditionScheduled(uint64 indexed chainSelector, address adapter, uint48 scheduledAt, uint48 readyAt);

    /// @notice Emitted when chain is added
    event ChainAdded(uint64 indexed chainSelector, address indexed adapter, uint256 gasLimit);

    /// @notice Emitted when chain is removed
    event ChainRemoved(uint64 indexed chainSelector);

    /// @notice Emitted when chain gas limit is updated
    event ChainGasLimitUpdated(uint64 indexed chainSelector, uint256 oldLimit, uint256 newLimit);

    /// @notice Emitted when rate limit is updated
    event RateLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /// @notice Emitted when contract is paused
    event Paused(address indexed by, uint8 signaturesCollected);

    /// @notice Emitted when contract is unpaused
    event Unpaused(address indexed by, uint8 signaturesCollected);

    /// @notice Emitted when governor is updated
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    // ============================================
    // OUTBOUND REQUESTS
    // ============================================

    /**
     * @notice Send verification request to another chain
     * @param destChain Destination CCIP chain selector
     * @param tokenId Asset token ID to verify
     * @return requestId Unique request identifier
     */
    function requestVerification(uint64 destChain, uint256 tokenId) external payable returns (bytes32 requestId);

    /**
     * @notice Send status request to another chain
     * @param destChain Destination CCIP chain selector
     * @param tokenId Asset token ID
     * @return requestId Unique request identifier
     */
    function requestStatus(uint64 destChain, uint256 tokenId) external payable returns (bytes32 requestId);

    /**
     * @notice Send full data request to another chain
     * @param destChain Destination CCIP chain selector
     * @param tokenId Asset token ID
     * @param reqType Type of data requested
     * @return requestId Unique request identifier
     */
    function requestData(uint64 destChain, uint256 tokenId, RequestType reqType)
        external
        payable
        returns (bytes32 requestId);

    // ============================================
    // CHAIN MANAGEMENT (Governor only + Timelock)
    // ============================================

    /**
     * @notice Schedule a new chain addition (starts 72hr timelock)
     * @param config Chain configuration
     */
    function scheduleChainAddition(ChainConfig calldata config) external;

    /**
     * @notice Execute a pending chain addition after timelock
     * @param chainSelector Chain to add
     */
    function executeChainAddition(uint64 chainSelector) external;

    /**
     * @notice Cancel a pending chain addition
     * @param chainSelector Chain to cancel
     */
    function cancelChainAddition(uint64 chainSelector) external;

    /**
     * @notice Remove a chain from supported list
     * @param chainSelector Chain to remove
     */
    function removeChain(uint64 chainSelector) external;

    /**
     * @notice Update gas limit for a chain
     * @param chainSelector Chain to update
     * @param gasLimit New gas limit
     */
    function updateChainGasLimit(uint64 chainSelector, uint256 gasLimit) external;

    // ============================================
    // RATE LIMITING
    // ============================================

    /**
     * @notice Set the rate limit (Governor only)
     * @param maxPerHour Maximum requests per hour
     */
    function setRateLimit(uint256 maxPerHour) external;

    /**
     * @notice Get remaining capacity in current window
     * @return remaining Number of requests remaining
     */
    function getRemainingCapacity() external view returns (uint256 remaining);

    // ============================================
    // EMERGENCY CONTROLS
    // ============================================

    /**
     * @notice Pause contract (requires 2/8 multisig approval)
     */
    function pause() external;

    /**
     * @notice Unpause contract (requires 5/8 multisig approval)
     */
    function unpause() external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get request details by ID
     * @param requestId Request identifier
     * @return request Request details
     */
    function getRequest(bytes32 requestId) external view returns (CrossChainRequest memory request);

    /**
     * @notice Get response details by request ID
     * @param requestId Request identifier
     * @return response Response details
     */
    function getResponse(bytes32 requestId) external view returns (CrossChainResponse memory response);

    /**
     * @notice Check if chain is supported
     * @param chainSelector CCIP chain selector
     * @return supported True if chain is supported
     */
    function isChainSupported(uint64 chainSelector) external view returns (bool supported);

    /**
     * @notice Get chain configuration
     * @param chainSelector CCIP chain selector
     * @return config Chain configuration
     */
    function getChainConfig(uint64 chainSelector) external view returns (ChainConfig memory config);

    /**
     * @notice Get pending chain addition
     * @param chainSelector CCIP chain selector
     * @return pending Pending addition details
     */
    function getPendingChainAddition(uint64 chainSelector) external view returns (PendingChainAddition memory pending);

    /**
     * @notice Estimate fee for a request
     * @param destChain Destination chain selector
     * @param reqType Request type
     * @return fee Estimated fee in native token
     */
    function estimateFee(uint64 destChain, RequestType reqType) external view returns (uint256 fee);

    /**
     * @notice Get CCIP router address
     * @return router Router address
     */
    function router() external view returns (address router);

    /**
     * @notice Get governor address
     * @return governor Governor address
     */
    function governor() external view returns (address governor);

    /**
     * @notice Get TAGITCore address
     * @return core Core contract address
     */
    function tagitCore() external view returns (address core);

    /**
     * @notice Check if contract is paused
     * @return paused True if paused
     */
    function isPaused() external view returns (bool paused);

    /**
     * @notice Get current rate limit
     * @return maxPerHour Maximum requests per hour
     */
    function rateLimit() external view returns (uint256 maxPerHour);

    /**
     * @notice Get contract version
     * @return version Version string
     */
    function version() external pure returns (string memory version);
}
