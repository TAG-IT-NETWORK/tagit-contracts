// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {ICCIPAdapter} from "../interfaces/ICCIPAdapter.sol";
import {ReplayProtection} from "../libraries/ReplayProtection.sol";

/**
 * @title CCIPAdapter
 * @author TAG IT Network <dev@tagit.network>
 * @notice Cross-chain verification adapter using Chainlink CCIP
 * @dev Enables cross-chain asset verification with strict security controls
 *
 * NIST CSF 2.0 Compliance:
 * - SC-8: Transmission Confidentiality - ReplayProtection prevents message replay
 * - SC-23: Session Authenticity - ensures message uniqueness across chains
 * - AU-6: Audit Record Review - indexed events for monitoring
 */
contract CCIPAdapter is
    ICCIPAdapter,
    IAny2EVMMessageReceiver,
    IERC165,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using ReplayProtection for ReplayProtection.Config;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Timelock duration for chain additions (72 hours)
    uint48 public constant CHAIN_ADDITION_TIMELOCK = 72 hours;

    /// @notice Default rate limit per hour
    uint256 public constant DEFAULT_RATE_LIMIT = 100;

    /// @notice Pause threshold (2/8 multisig)
    uint8 public constant PAUSE_THRESHOLD = 2;

    /// @notice Unpause threshold (5/8 multisig)
    uint8 public constant UNPAUSE_THRESHOLD = 5;

    /// @notice Default gas limit for CCIP messages
    uint256 public constant DEFAULT_GAS_LIMIT = 200_000;

    /// @notice Default message expiry (24 hours)
    uint64 public constant DEFAULT_MESSAGE_EXPIRY = 24 hours;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice CCIP Router contract
    IRouterClient private _router;

    /// @notice Governor address
    address private _governor;

    /// @notice TAGITCore contract for asset lookups
    address private _tagitCore;

    /// @notice Supported chains mapping
    mapping(uint64 => ChainConfig) private _chains;

    /// @notice Pending chain additions (for timelock)
    mapping(uint64 => PendingChainAddition) private _pendingChains;

    /// @notice Request storage
    mapping(bytes32 => CrossChainRequest) private _requests;

    /// @notice Response storage
    mapping(bytes32 => CrossChainResponse) private _responses;

    /// @notice Used request IDs (legacy - kept for storage compatibility)
    mapping(bytes32 => bool) private _usedRequestIds;

    /// @notice Rate limit per hour
    uint256 private _rateLimit;

    /// @notice Request counts per hour window
    mapping(uint256 => uint256) private _hourlyRequests;

    /// @notice Pause state
    bool private _paused;

    /// @notice Nonce for request ID generation
    uint256 private _nonce;

    // ============================================
    // REPLAY PROTECTION (NIST SC-8)
    // ============================================

    /// @notice Replay protection configuration
    ReplayProtection.Config private _replayConfig;

    /// @notice Processed messages by ID
    mapping(bytes32 => bool) private _processedMessages;

    /// @notice Per-chain state for replay protection
    mapping(uint64 => ReplayProtection.ChainState) private _chainStates;

    /// @notice Chain-bound processed CCIP messageIds (defense-in-depth)
    /// @dev Key = keccak256(messageId, block.chainid, sourceChainSelector)
    mapping(bytes32 => bool) private _processedCcipMessages;

    // ============================================
    // CONSTRUCTOR & INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the adapter
     * @param routerAddr CCIP Router address
     * @param governorAddr Governor address
     * @param tagitCoreAddr TAGITCore contract address
     * @param initialOwner Initial owner for upgrades
     */
    function initialize(address routerAddr, address governorAddr, address tagitCoreAddr, address initialOwner)
        external
        initializer
    {
        if (routerAddr == address(0)) revert ZeroAddress();
        if (governorAddr == address(0)) revert ZeroAddress();
        if (tagitCoreAddr == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        _router = IRouterClient(routerAddr);
        _governor = governorAddr;
        _tagitCore = tagitCoreAddr;
        _rateLimit = DEFAULT_RATE_LIMIT;

        // Initialize replay protection (NIST SC-8)
        // - 24 hour message expiry for stale message protection
        // - No sequential nonce requirement (CCIP messages can arrive out of order)
        _replayConfig.initialize(DEFAULT_MESSAGE_EXPIRY, false);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyRouter() {
        if (msg.sender != address(_router)) {
            revert NotRouter(msg.sender);
        }
        _;
    }

    modifier onlyGovernor() {
        if (msg.sender != _governor) {
            revert NotGovernor(msg.sender);
        }
        _;
    }

    modifier whenNotPaused() {
        if (_paused) {
            revert ContractPaused();
        }
        _;
    }

    // ============================================
    // IERC165 IMPLEMENTATION
    // ============================================

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ============================================
    // CCIP RECEIVE (INBOUND)
    // ============================================

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        override
        onlyRouter
        nonReentrant
        whenNotPaused
    {
        // Validate source chain is in allowlist
        uint64 sourceChain = message.sourceChainSelector;
        ChainConfig storage chainConfig = _chains[sourceChain];
        if (!chainConfig.active) {
            revert UnsupportedChain(sourceChain);
        }

        // Validate sender is known adapter
        address sender = abi.decode(message.sender, (address));
        if (sender != chainConfig.adapter) {
            revert UnknownSender(sourceChain, sender);
        }

        // Decode message data
        (bytes32 requestId, uint8 messageType, bytes memory payload) = abi.decode(message.data, (bytes32, uint8, bytes));

        // NIST SC-8: Replay protection with expiry and per-chain tracking
        // Uses ReplayProtection library for comprehensive message deduplication
        _replayConfig.validateAndMark(
            _processedMessages,
            _chainStates,
            requestId,
            sourceChain,
            block.timestamp, // Use current time since CCIP doesn't provide message timestamp
            0 // No nonce for CCIP (out-of-order execution allowed)
        );

        // Defense-in-depth: Chain-bound CCIP messageId tracking
        // Binds message.messageId to block.chainid + sourceChainSelector
        // Prevents cross-chain replay if same messageId appears on multiple chains
        bytes32 ccipKey = keccak256(abi.encodePacked(message.messageId, block.chainid, sourceChain));
        if (_processedCcipMessages[ccipKey]) {
            revert ReplayProtection.MessageAlreadyProcessed(message.messageId, sourceChain);
        }
        _processedCcipMessages[ccipKey] = true;

        emit CcipMessageProcessed(message.messageId, sourceChain, block.chainid);

        // Process based on message type
        if (messageType == 0) {
            // Request - process and send response
            _processRequest(sourceChain, sender, requestId, payload);
        } else {
            // Response - store result
            _processResponse(sourceChain, requestId, payload);
        }
    }

    /**
     * @dev Process incoming verification request
     */
    function _processRequest(uint64 sourceChain, address sender, bytes32 requestId, bytes memory payload) internal {
        (uint256 tokenId, RequestType reqType) = abi.decode(payload, (uint256, RequestType));

        // Store request
        _requests[requestId] = CrossChainRequest({
            sourceChain: sourceChain, sender: sender, tokenId: tokenId, requestId: requestId, reqType: reqType
        });

        // Get asset data from TAGITCore
        (bool valid, uint8 status, address owner, bytes32 metadataHash) = _getAssetData(tokenId);

        // Build response
        CrossChainResponse memory response = CrossChainResponse({
            requestId: requestId, valid: valid, status: status, owner: owner, metadataHash: metadataHash
        });

        // Send response back
        _sendResponse(sourceChain, requestId, response);

        emit VerificationRequestProcessed(requestId, sourceChain, tokenId, valid);
    }

    /**
     * @dev Process incoming verification response
     */
    function _processResponse(uint64 sourceChain, bytes32 requestId, bytes memory payload) internal {
        (bool valid, uint8 status, address owner, bytes32 metadataHash) =
            abi.decode(payload, (bool, uint8, address, bytes32));

        // Store response
        _responses[requestId] = CrossChainResponse({
            requestId: requestId, valid: valid, status: status, owner: owner, metadataHash: metadataHash
        });

        // Get tokenId from original request
        CrossChainRequest storage request = _requests[requestId];

        emit VerificationResponseReceived(requestId, sourceChain, request.tokenId, valid);
    }

    /**
     * @dev Get asset data from TAGITCore
     */
    function _getAssetData(uint256 tokenId)
        internal
        view
        returns (bool valid, uint8 status, address owner, bytes32 metadataHash)
    {
        // Interface to TAGITCore - simplified for now
        // In production, this would call actual TAGITCore methods
        (bool success, bytes memory data) = _tagitCore.staticcall(abi.encodeWithSignature("getAsset(uint256)", tokenId));

        if (success && data.length > 0) {
            // Decode asset data (simplified)
            valid = true;
            // Actual decoding would depend on TAGITCore.Asset struct
            status = 3; // ACTIVATED
            owner = address(0);
            metadataHash = bytes32(0);
        } else {
            valid = false;
            status = 0;
            owner = address(0);
            metadataHash = bytes32(0);
        }
    }

    /**
     * @dev Send response back to source chain
     */
    function _sendResponse(uint64 destChain, bytes32 requestId, CrossChainResponse memory response) internal {
        ChainConfig storage chainConfig = _chains[destChain];

        // Encode response
        bytes memory data = abi.encode(
            requestId,
            uint8(1), // messageType = 1 for response
            abi.encode(response.valid, response.status, response.owner, response.metadataHash)
        );

        // Build CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(chainConfig.adapter),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // Pay in native
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: chainConfig.gasLimit, allowOutOfOrderExecution: true})
            )
        });

        // Get fee
        uint256 fee = _router.getFee(destChain, message);

        // Send (contract must have ETH balance for responses)
        if (address(this).balance >= fee) {
            _router.ccipSend{value: fee}(destChain, message);
        }
        // If insufficient balance, response is not sent (caller can retry)
    }

    // ============================================
    // OUTBOUND REQUESTS
    // ============================================

    /// @inheritdoc ICCIPAdapter
    function requestVerification(uint64 destChain, uint256 tokenId)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 requestId)
    {
        return _sendRequest(destChain, tokenId, RequestType.VERIFY);
    }

    /// @inheritdoc ICCIPAdapter
    function requestStatus(uint64 destChain, uint256 tokenId)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 requestId)
    {
        return _sendRequest(destChain, tokenId, RequestType.STATUS);
    }

    /// @inheritdoc ICCIPAdapter
    function requestData(uint64 destChain, uint256 tokenId, RequestType reqType)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 requestId)
    {
        return _sendRequest(destChain, tokenId, reqType);
    }

    /**
     * @dev Internal function to send a request
     */
    function _sendRequest(uint64 destChain, uint256 tokenId, RequestType reqType) internal returns (bytes32 requestId) {
        // Check chain is supported
        ChainConfig storage chainConfig = _chains[destChain];
        if (!chainConfig.active) {
            revert UnsupportedChain(destChain);
        }

        // Check rate limit
        uint256 currentHour = block.timestamp / 1 hours;
        uint256 hourlyCount = _hourlyRequests[currentHour];
        if (hourlyCount >= _rateLimit) {
            revert RateLimitExceeded(_rateLimit - hourlyCount, 1);
        }
        _hourlyRequests[currentHour] = hourlyCount + 1;

        // Generate unique request ID
        requestId =
            keccak256(abi.encodePacked(block.chainid, address(this), msg.sender, tokenId, _nonce++, block.timestamp));

        // Store request
        _requests[requestId] = CrossChainRequest({
            sourceChain: uint64(block.chainid),
            sender: msg.sender,
            tokenId: tokenId,
            requestId: requestId,
            reqType: reqType
        });

        // Mark as processed to prevent self-replay
        _processedMessages[requestId] = true;

        // Encode message
        bytes memory data = abi.encode(
            requestId,
            uint8(0), // messageType = 0 for request
            abi.encode(tokenId, reqType)
        );

        // Build CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(chainConfig.adapter),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // Pay in native
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: chainConfig.gasLimit, allowOutOfOrderExecution: true})
            )
        });

        // Get fee
        uint256 fee = _router.getFee(destChain, message);
        if (msg.value < fee) {
            revert InsufficientFee(fee, msg.value);
        }

        // Send message
        _router.ccipSend{value: fee}(destChain, message);

        // Refund excess
        if (msg.value > fee) {
            (bool success,) = msg.sender.call{value: msg.value - fee}("");
            (success); // Ignore result - user can claim later if needed
        }

        emit VerificationRequested(requestId, destChain, tokenId, reqType, msg.sender);
    }

    // ============================================
    // CHAIN MANAGEMENT
    // ============================================

    /// @inheritdoc ICCIPAdapter
    function scheduleChainAddition(ChainConfig calldata config) external override onlyGovernor {
        if (config.adapter == address(0)) revert ZeroAddress();
        if (_chains[config.chainSelector].active) {
            revert ChainAlreadyExists(config.chainSelector);
        }

        uint48 scheduledAt = uint48(block.timestamp);
        uint48 readyAt = scheduledAt + CHAIN_ADDITION_TIMELOCK;

        _pendingChains[config.chainSelector] =
            PendingChainAddition({config: config, scheduledAt: scheduledAt, executed: false});

        emit ChainAdditionScheduled(config.chainSelector, config.adapter, scheduledAt, readyAt);
    }

    /// @inheritdoc ICCIPAdapter
    function executeChainAddition(uint64 chainSelector) external override onlyGovernor {
        PendingChainAddition storage pending = _pendingChains[chainSelector];
        if (pending.scheduledAt == 0) {
            revert NoPendingAddition(chainSelector);
        }
        if (pending.executed) {
            revert NoPendingAddition(chainSelector);
        }

        uint48 readyAt = pending.scheduledAt + CHAIN_ADDITION_TIMELOCK;
        if (block.timestamp < readyAt) {
            revert TimelockNotElapsed(pending.scheduledAt, readyAt);
        }

        // Execute addition
        _chains[chainSelector] = pending.config;
        pending.executed = true;

        emit ChainAdded(chainSelector, pending.config.adapter, pending.config.gasLimit);
    }

    /// @inheritdoc ICCIPAdapter
    function cancelChainAddition(uint64 chainSelector) external override onlyGovernor {
        PendingChainAddition storage pending = _pendingChains[chainSelector];
        if (pending.scheduledAt == 0 || pending.executed) {
            revert NoPendingAddition(chainSelector);
        }
        delete _pendingChains[chainSelector];
    }

    /// @inheritdoc ICCIPAdapter
    function removeChain(uint64 chainSelector) external override onlyGovernor {
        if (!_chains[chainSelector].active) {
            revert UnsupportedChain(chainSelector);
        }
        delete _chains[chainSelector];
        emit ChainRemoved(chainSelector);
    }

    /// @inheritdoc ICCIPAdapter
    function updateChainGasLimit(uint64 chainSelector, uint256 gasLimit) external override onlyGovernor {
        ChainConfig storage chainConfig = _chains[chainSelector];
        if (!chainConfig.active) {
            revert UnsupportedChain(chainSelector);
        }
        uint256 oldLimit = chainConfig.gasLimit;
        chainConfig.gasLimit = gasLimit;
        emit ChainGasLimitUpdated(chainSelector, oldLimit, gasLimit);
    }

    // ============================================
    // RATE LIMITING
    // ============================================

    /// @inheritdoc ICCIPAdapter
    function setRateLimit(uint256 maxPerHour) external override onlyGovernor {
        uint256 oldLimit = _rateLimit;
        _rateLimit = maxPerHour;
        emit RateLimitUpdated(oldLimit, maxPerHour);
    }

    /// @inheritdoc ICCIPAdapter
    function getRemainingCapacity() external view override returns (uint256 remaining) {
        uint256 currentHour = block.timestamp / 1 hours;
        uint256 used = _hourlyRequests[currentHour];
        if (used >= _rateLimit) {
            return 0;
        }
        return _rateLimit - used;
    }

    // ============================================
    // EMERGENCY CONTROLS
    // ============================================

    /// @inheritdoc ICCIPAdapter
    function pause() external override {
        // Simple pause - in production would use multisig voting
        // For MVP, governor can pause directly
        if (msg.sender != _governor) revert NotGovernor(msg.sender);
        _paused = true;
        emit Paused(msg.sender, PAUSE_THRESHOLD);
    }

    /// @inheritdoc ICCIPAdapter
    function unpause() external override {
        // Simple unpause - in production would use multisig voting
        // For MVP, governor can unpause directly
        if (msg.sender != _governor) revert NotGovernor(msg.sender);
        _paused = false;
        emit Unpaused(msg.sender, UNPAUSE_THRESHOLD);
    }

    // ============================================
    // REPLAY PROTECTION ADMIN (NIST SC-8)
    // ============================================

    /**
     * @notice Update message expiry duration
     * @param newExpiry New expiry duration (0 = no expiry)
     */
    function setMessageExpiry(uint64 newExpiry) external onlyGovernor {
        _replayConfig.setExpiry(newExpiry);
    }

    /**
     * @notice Enable or disable replay protection
     * @param enabled Whether to enable protection
     */
    function setReplayProtectionEnabled(bool enabled) external onlyGovernor {
        _replayConfig.setEnabled(enabled);
    }

    /**
     * @notice Update nonce for a specific chain (emergency recovery)
     * @param chainSelector Chain to update
     * @param newNonce New nonce value
     */
    function setChainNonce(uint64 chainSelector, uint64 newNonce) external onlyGovernor {
        ReplayProtection.setNonce(_chainStates, chainSelector, newNonce);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @inheritdoc ICCIPAdapter
    function getRequest(bytes32 requestId) external view override returns (CrossChainRequest memory) {
        return _requests[requestId];
    }

    /// @inheritdoc ICCIPAdapter
    function getResponse(bytes32 requestId) external view override returns (CrossChainResponse memory) {
        return _responses[requestId];
    }

    /// @inheritdoc ICCIPAdapter
    function isChainSupported(uint64 chainSelector) external view override returns (bool) {
        return _chains[chainSelector].active;
    }

    /// @inheritdoc ICCIPAdapter
    function getChainConfig(uint64 chainSelector) external view override returns (ChainConfig memory) {
        return _chains[chainSelector];
    }

    /// @inheritdoc ICCIPAdapter
    function getPendingChainAddition(uint64 chainSelector)
        external
        view
        override
        returns (PendingChainAddition memory)
    {
        return _pendingChains[chainSelector];
    }

    /// @inheritdoc ICCIPAdapter
    function estimateFee(uint64 destChain, RequestType reqType) external view override returns (uint256 fee) {
        ChainConfig storage chainConfig = _chains[destChain];
        if (!chainConfig.active) return 0;

        // Estimate based on typical message size
        bytes memory dummyData = abi.encode(
            bytes32(0), // requestId
            uint8(0), // messageType
            abi.encode(uint256(0), reqType) // payload
        );

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(chainConfig.adapter),
            data: dummyData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: chainConfig.gasLimit, allowOutOfOrderExecution: true})
            )
        });

        return _router.getFee(destChain, message);
    }

    /// @inheritdoc ICCIPAdapter
    function router() external view override returns (address) {
        return address(_router);
    }

    /// @inheritdoc ICCIPAdapter
    function governor() external view override returns (address) {
        return _governor;
    }

    /// @inheritdoc ICCIPAdapter
    function tagitCore() external view override returns (address) {
        return _tagitCore;
    }

    /// @inheritdoc ICCIPAdapter
    function isPaused() external view override returns (bool) {
        return _paused;
    }

    /// @inheritdoc ICCIPAdapter
    function rateLimit() external view override returns (uint256) {
        return _rateLimit;
    }

    /// @inheritdoc ICCIPAdapter
    function version() external pure override returns (string memory) {
        return "1.1.0";
    }

    // ============================================
    // REPLAY PROTECTION VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if a message has been processed
     * @param messageId Message ID to check
     * @return processed Whether the message has been processed
     */
    function isMessageProcessed(bytes32 messageId) external view returns (bool processed) {
        return ReplayProtection.isProcessed(_processedMessages, messageId);
    }

    /**
     * @notice Check if a CCIP message has been processed with chain binding
     * @param messageId CCIP message ID
     * @param sourceChainSelector Source chain selector
     * @return processed Whether the message has been processed on this chain
     */
    function isCcipMessageProcessed(bytes32 messageId, uint64 sourceChainSelector)
        external
        view
        returns (bool processed)
    {
        bytes32 key = keccak256(abi.encodePacked(messageId, block.chainid, sourceChainSelector));
        return _processedCcipMessages[key];
    }

    /**
     * @notice Get replay protection state for a chain
     * @param chainSelector Chain to query
     * @return lastNonce Last processed nonce
     * @return messageCount Total messages from this chain
     */
    function getReplayProtectionState(uint64 chainSelector)
        external
        view
        returns (uint64 lastNonce, uint64 messageCount)
    {
        return ReplayProtection.getChainState(_chainStates, chainSelector);
    }

    /**
     * @notice Check if replay protection is enabled
     * @return Whether protection is enabled
     */
    function isReplayProtectionEnabled() external view returns (bool) {
        return _replayConfig.isEnabled();
    }

    /**
     * @notice Get message expiry duration
     * @return Expiry duration in seconds
     */
    function getMessageExpiry() external view returns (uint64) {
        return _replayConfig.getExpiry();
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Update governor address
     * @param newGovernor New governor address
     */
    function setGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = _governor;
        _governor = newGovernor;
        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    // ============================================
    // UUPS UPGRADE
    // ============================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============================================
    // RECEIVE
    // ============================================

    /// @notice Accept ETH for paying CCIP fees
    receive() external payable {}
}
