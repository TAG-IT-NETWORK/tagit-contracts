// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {CircuitBreaker} from "../libraries/CircuitBreaker.sol";
import {RateLimiter} from "../libraries/RateLimiter.sol";

/**
 * @title TAGITCore
 * @author TAG IT Network <dev@tagit.network>
 * @notice Core asset management for digital twins
 * @dev Implements ERC-721 with lifecycle state machine behind UUPS proxy
 *
 * This contract manages the lifecycle of physical assets represented as NFTs (Digital Twins).
 * Each asset progresses through a state machine from minting to end-of-life, with cryptographic
 * binding to physical NFC tags and multi-signal verification.
 *
 * State Machine:
 * NONE → MINTED → BOUND → ACTIVATED → CLAIMED → FLAGGED → RECYCLED
 *                                              ↓
 *                                          RECYCLED
 *
 * Upgradeability:
 * - UUPS proxy pattern (EIP-1822) — owner-authorized upgrades only
 * - Owner should be a TimelockController (48hr delay) controlled by Gnosis Safe 3-of-5
 * - UpgradeScheduled event emitted on every upgrade for transparency
 *
 * Security: All state-changing functions must follow Checks-Effects-Interactions pattern
 * and include ReentrancyGuard. BIDGES capability checks enforce zero-trust access control.
 */
contract TAGITCore is
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using CircuitBreaker for CircuitBreaker.Config;
    using RateLimiter for RateLimiter.Config;

    // ============================================
    // STATE MACHINE
    // ============================================

    /**
     * @notice Asset lifecycle states
     * @dev State can only move forward except for recovery (FLAGGED → CLAIMED)
     * @custom:security State transitions are strictly enforced - see isValidTransition
     */
    enum State {
        NONE,       // 0 - Default/not created
        MINTED,     // 1 - NFT exists, no tag bound
        BOUND,      // 2 - Tag cryptographically linked
        ACTIVATED,  // 3 - QA passed, ready for distribution
        CLAIMED,    // 4 - Owned by end consumer
        FLAGGED,    // 5 - Lost/stolen/recall initiated
        RECYCLED    // 6 - End of life, permanently retired
    }

    // ============================================
    // BIDGES CAPABILITIES (Access Control)
    // ============================================

    /**
     * @notice Capability constants for BIDGES access control
     * @dev Each lifecycle function requires a specific capability from TAGITAccess
     * @custom:security Capabilities are derived using keccak256 for gas efficiency
     */
    bytes32 public constant MINTER_CAPABILITY = keccak256("MINTER");
    bytes32 public constant BINDER_CAPABILITY = keccak256("BINDER");
    bytes32 public constant ACTIVATOR_CAPABILITY = keccak256("ACTIVATOR");
    bytes32 public constant CLAIMER_CAPABILITY = keccak256("CLAIMER");
    bytes32 public constant FLAGGER_CAPABILITY = keccak256("FLAGGER");
    bytes32 public constant RESOLVER_CAPABILITY = keccak256("RESOLVER");
    bytes32 public constant RECYCLER_CAPABILITY = keccak256("RECYCLER");
    bytes32 public constant VIEWER_CAPABILITY = keccak256("VIEWER");
    bytes32 public constant AUDITOR_CAPABILITY = keccak256("AUDITOR");

    /// @notice Number of independent resolver approvals required before resolve() can execute
    /// @dev Testnet: set to 1 for demo workflows. Mainnet: raise to 2 (2-of-3 multisig)
    uint256 public constant RESOLVE_QUORUM = 1;

    /// @notice Maximum number of assets that can be minted in a single batch call
    /// @dev Prevents block gas limit DoS attacks on batchMint
    uint256 public constant MAX_BATCH_SIZE = 100;

    // ============================================
    // DATA STRUCTURES
    // ============================================

    /**
     * @notice Gas-optimized asset metadata structure
     * @dev Packed into single 32-byte storage slot to minimize gas costs
     *
     * Layout (32 bytes total):
     * - owner: 20 bytes (address)
     * - timestamp: 8 bytes (uint64) - sufficient until year 2554
     * - state: 1 byte (uint8/State enum)
     * - flags: 1 byte (uint8) - bit flags for future use
     * - reserved: 2 bytes (uint16) - reserved for future metadata
     *
     * @custom:security Packed struct saves ~15,000 gas per mint vs unpacked
     */
    struct Asset {
        address owner;       // 20 bytes - Current owner address
        uint64 timestamp;    // 8 bytes - Last state change timestamp
        State state;         // 1 byte - Current lifecycle state
        uint8 flags;         // 1 byte - Bit flags (reserved for future use)
        uint16 reserved;     // 2 bytes - Reserved for future metadata
    }   // Total: 32 bytes = 1 storage slot

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /**
     * @notice Token does not exist
     * @param tokenId The non-existent token ID
     */
    error TokenNotFound(uint256 tokenId);

    /**
     * @notice Asset is in wrong state for requested operation
     * @param tokenId The asset token ID
     * @param current Current state of the asset
     * @param required Required state for the operation
     */
    error InvalidState(uint256 tokenId, State current, State required);

    /**
     * @notice Caller lacks required capability
     * @param caller Address attempting the operation
     * @param requiredCapability Capability ID required (from BIDGES)
     */
    error Unauthorized(address caller, uint256 requiredCapability);

    /**
     * @notice Zero address provided where not allowed
     */
    error ZeroAddress();

    /**
     * @notice NFC tag hash already bound to another asset
     * @param tagHash The tag hash that is already in use
     */
    error TagAlreadyBound(bytes32 tagHash);

    /**
     * @notice Invalid state transition attempted
     * @param from Current state
     * @param to Requested state
     */
    error InvalidTransition(State from, State to);

    /**
     * @notice Invalid token ID (e.g., zero)
     */
    error InvalidTokenId();

    /**
     * @notice Invalid tag hash (e.g., zero hash)
     */
    error InvalidTagHash();

    /**
     * @notice Invalid access controller address
     */
    error InvalidAccessController();

    /**
     * @notice Resolver has already approved this token's resolution
     * @param tokenId The asset token ID
     * @param approver Address that already approved
     */
    error AlreadyApproved(uint256 tokenId, address approver);

    /**
     * @notice Resolve quorum not yet reached
     * @param tokenId The asset token ID
     * @param current Current number of approvals
     * @param required Required number of approvals
     */
    error QuorumNotReached(uint256 tokenId, uint256 current, uint256 required);

    /**
     * @notice Proposed newOwner does not match previously approved recipient
     * @param tokenId The asset token ID
     * @param expected The previously approved recipient
     * @param provided The mismatching recipient provided
     */
    error RecipientMismatch(uint256 tokenId, address expected, address provided);

    /**
     * @notice Oracle signature verification failed
     */
    error InvalidOracleSignature();

    /**
     * @notice Trusted oracle address not set
     */
    error OracleNotSet();

    /**
     * @notice Batch size exceeds maximum allowed
     * @param provided Number of items in the batch
     * @param maximum Maximum allowed batch size
     */
    error BatchTooLarge(uint256 provided, uint256 maximum);

    /**
     * @notice External ERC721 transfers are disabled (PATCH-09)
     * @dev Assets must move through lifecycle functions (claim, resolve)
     */
    error TransferDisabled();

    /**
     * @notice Array lengths do not match in batch operation
     * @param recipientsLength Length of the recipients array
     * @param metadataLength Length of the metadata array
     */
    error ArrayLengthMismatch(uint256 recipientsLength, uint256 metadataLength);

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when access controller is updated
     * @param previousController Previous access controller address
     * @param newController New access controller address
     */
    event AccessControllerUpdated(
        address indexed previousController,
        address indexed newController
    );

    /**
     * @notice Emitted when new asset NFT is minted
     * @param tokenId Unique token ID of the minted asset
     * @param to Initial owner address
     * @param metadata IPFS hash or metadata identifier
     * @custom:security Event provides immutable audit trail
     */
    event AssetMinted(
        uint256 indexed tokenId,
        address indexed to,
        bytes32 metadata
    );

    /**
     * @notice Emitted on every state transition
     * @param tokenId Asset token ID
     * @param from Previous state
     * @param to New state
     * @param actor Address that triggered the transition
     * @custom:security Enables full lifecycle tracking and audit
     */
    event StateChanged(
        uint256 indexed tokenId,
        State from,
        State to,
        address actor
    );

    /**
     * @notice Emitted when NFC tag is bound to asset
     * @param tokenId Asset token ID
     * @param tagHash Keccak256 hash of NFC tag UID
     * @custom:security Tag binding is irreversible - provides cryptographic proof
     */
    event TagBound(
        uint256 indexed tokenId,
        bytes32 indexed tagHash
    );

    /**
     * @notice Emitted when a contract upgrade is authorized
     * @param oldImplementation Address of the current implementation
     * @param newImplementation Address of the new implementation
     * @param scheduledBy Address that authorized the upgrade
     * @custom:security Transparency event — allows monitoring of upgrade schedule
     */
    event UpgradeScheduled(
        address indexed oldImplementation,
        address indexed newImplementation,
        address indexed scheduledBy
    );

    /**
     * @notice Emitted on every custody/state change for full audit trail
     * @dev prevStateHash = keccak256(abi.encode(assetId, fromState, fromOwner, block.number - 1))
     *      This creates a cryptographically linkable chain of custody events.
     * @param assetId Token ID of the asset
     * @param fromState Previous lifecycle state (uint8-encoded)
     * @param toState New lifecycle state (uint8-encoded)
     * @param fromOwner Owner before the transition
     * @param toOwner Owner after the transition
     * @param timestamp Block timestamp of the transition
     * @param prevStateHash Hash linking to previous state for chain-of-custody verification
     * @custom:security CMMC audit trail — every custody change cryptographically linkable
     * @custom:security NIST 800-53 AU-9 — immutable on-chain audit log
     */
    event CustodyTransfer(
        uint256 indexed assetId,
        uint8 fromState,
        uint8 toState,
        address indexed fromOwner,
        address indexed toOwner,
        uint256 timestamp,
        bytes32 prevStateHash
    );

    /**
     * @notice Emitted when a resolver approves a flagged asset's resolution
     * @param tokenId The asset token ID
     * @param approver Address of the resolver who approved
     * @param approvalCount Total approvals after this one
     */
    event ResolveApproved(
        uint256 indexed tokenId,
        address indexed approver,
        uint256 approvalCount
    );

    /**
     * @notice Emitted when the trusted NFC oracle address is updated
     * @param previousOracle Previous oracle address
     * @param newOracle New oracle address
     */
    event TrustedOracleUpdated(
        address indexed previousOracle,
        address indexed newOracle
    );

    // ============================================
    // STORAGE
    // ============================================

    /// @notice TAGITAccess controller for BIDGES capability checks
    /// @dev If address(0), capability checks are bypassed (backward compatibility)
    ITAGITAccess public accessController;

    /// @notice Mapping from token ID to Asset metadata
    mapping(uint256 => Asset) private _assets;

    /// @notice Mapping from NFC tag hash to token ID (prevents duplicate binding)
    mapping(bytes32 => uint256) private _tagToToken;

    /// @notice Mapping from token ID to NFC tag hash (for reverse lookup)
    mapping(uint256 => bytes32) private _tokenToTag;

    /// @notice Counter for next token ID (starts at 1)
    uint256 private _nextTokenId;

    /// @notice Total number of assets minted
    uint256 private _totalSupply;

    // ============================================
    // NIST CSF 2.0 COMPLIANCE STORAGE
    // ============================================

    /// @notice Circuit breaker for flag operations (NIST IR-4)
    /// @dev Trips if too many flags occur in a window - prevents mass flagging attacks
    CircuitBreaker.Config private _flagCircuitBreaker;

    /// @notice Rate limiter for mint operations (NIST AC-7)
    /// @dev Prevents spam minting attacks
    RateLimiter.Config private _mintRateLimiter;

    /// @notice Per-user rate limit state for minting
    mapping(address => RateLimiter.UserState) private _mintRateLimits;

    // ============================================
    // RESOLVE QUORUM STORAGE (PATCH-02)
    // ============================================

    /// @notice Tracks which resolvers have approved a given token's resolution
    /// @dev Keyed by round-id (hash of tokenId + nonce) to invalidate stale approvals across cycles
    mapping(uint256 => mapping(address => bool)) private _resolveApprovals;

    /// @notice Number of resolver approvals collected per token
    mapping(uint256 => uint256) private _resolveApprovalCount;

    /// @notice Proposed newOwner for resolution (set by first approver)
    mapping(uint256 => address) private _resolveRecipient;

    /// @notice Per-token nonce incremented on each resolve — invalidates stale approval entries
    mapping(uint256 => uint256) private _resolveNonce;

    // ============================================
    // TOKEN URI AUTHORIZATION STORAGE (PATCH-04)
    // ============================================

    /// @notice Redacted metadata URI returned to unauthorized callers
    /// @dev ITAR compliance — defense asset metadata must not be accessible without authorization
    string private _redactedURI;

    // ============================================
    // NFC ORACLE STORAGE (PATCH-06)
    // ============================================

    /// @notice Address of the trusted NFC oracle that signs challenge-response attestations
    /// @dev Must be set before bindTag() can be called. Configurable by admin.
    address public trustedOracle;

    /// @notice Storage gap for future upgrades (ERC-7201 compatible)
    /// @dev Reserve 34 slots (reduced from 35 after adding trustedOracle)
    uint256[34] private __gap;

    // ============================================
    // CONSTRUCTOR (disabled for proxy)
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================
    // INITIALIZER (replaces constructor for proxy)
    // ============================================

    /**
     * @notice Initialize TAGITCore contract (called once via proxy)
     * @dev Replaces constructor for UUPS proxy pattern. Sets ERC721 name/symbol,
     *      initializes Ownable, sets up NIST compliance controls.
     * @param initialOwner Address that will own this contract (should be TimelockController)
     * @custom:security Can only be called once (initializer modifier)
     * @custom:security Owner should be a TimelockController controlled by Gnosis Safe 3-of-5
     */
    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();

        // Initialize parent contracts
        __ERC721_init("TAG IT Digital Twin", "TAGIT");
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        // Start token IDs at 1 (0 reserved for "none")
        _nextTokenId = 1;

        // NIST IR-4: Circuit breaker for flag operations
        // Threshold: 50 flags per hour triggers circuit breaker
        // Cooldown: 30 minutes before operations resume
        _flagCircuitBreaker.initialize(
            50,             // threshold
            1 hours,        // window duration
            30 minutes      // cooldown duration
        );

        // NIST AC-7: Rate limiter for mint operations
        // Max: 100 mints per user per hour
        // Cooldown: 15 minutes after hitting limit
        // Global: 1000 mints per hour across all users
        _mintRateLimiter.initialize(
            100,            // max per user per window
            1 hours,        // window duration
            15 minutes,     // cooldown duration
            1000            // global max per window
        );
    }

    // ============================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================

    /**
     * @notice Authorize a contract upgrade (UUPS)
     * @dev Only owner (TimelockController) can authorize upgrades.
     *      Emits UpgradeScheduled for transparency — allows off-chain monitoring.
     * @param newImplementation Address of the new implementation contract
     * @custom:security Owner-only — should be behind TimelockController + Gnosis Safe
     * @custom:security UpgradeScheduled event enables 48hr monitoring window
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit UpgradeScheduled(
            ERC1967Utils.getImplementation(),
            newImplementation,
            msg.sender
        );
    }

    /**
     * @notice Get the current implementation address
     * @return The address of the current implementation contract
     */
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    // ============================================
    // ACCESS CONTROL
    // ============================================

    /**
     * @notice Set the TAGITAccess controller for capability checks
     * @dev Only owner can update. Setting to address(0) disables capability checks.
     * @param controller Address of the TAGITAccess controller (can be address(0))
     * @custom:security Only owner can call (goes through TimelockController 48hr delay)
     * @custom:security Allows address(0) to disable checks for backward compatibility
     * @custom:emits AccessControllerUpdated
     */
    function setAccessController(address controller) external onlyOwner {
        address previousController = address(accessController);
        accessController = ITAGITAccess(controller);
        emit AccessControllerUpdated(previousController, controller);
    }

    /**
     * @notice Modifier to require specific capability from msg.sender
     * @dev Checks capability via TAGITAccess. Bypasses check if accessController is address(0).
     * @param capability The capability ID required (e.g., MINTER_CAPABILITY)
     * @custom:security Zero-trust: Explicitly checks capability via accessController
     * @custom:security Bypass: If accessController == address(0), skip check (backward compatibility)
     */
    modifier requiresCapability(bytes32 capability) {
        // Bypass capability checks if accessController not set (backward compatibility)
        if (address(accessController) != address(0)) {
            // Delegate capability check to TAGITAccess
            // Will revert with MissingCapability if check fails
            accessController.requireCapability(msg.sender, uint256(capability));
        }
        _;
    }

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Mint a new Digital Twin NFT representing a physical asset
     * @dev Creates NFT in MINTED state. Tag binding happens separately via bindTag().
     *      Follows Checks-Effects-Interactions pattern for security.
     * @param to Initial owner address (typically manufacturer)
     * @param metadata IPFS hash or metadata identifier for the asset
     * @return tokenId The ID of the newly minted token
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security Zero address check prevents burning on mint
     * @custom:emits AssetMinted, StateChanged
     */
    function mint(address to, bytes32 metadata)
        external
        nonReentrant
        requiresCapability(MINTER_CAPABILITY)
        returns (uint256 tokenId)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (to == address(0)) revert ZeroAddress();

        // NIST AC-7: Rate limit check for spam prevention
        _mintRateLimiter.check(_mintRateLimits, msg.sender);

        // ============================================
        // EFFECTS
        // ============================================
        tokenId = _nextTokenId++;
        _totalSupply++;

        // Create asset in MINTED state
        _assets[tokenId] = Asset({
            owner: to,
            timestamp: uint64(block.timestamp),
            state: State.MINTED,
            flags: 0,
            reserved: 0
        });

        // Mint ERC721 token
        _mint(to, tokenId);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit AssetMinted(tokenId, to, metadata);
        emit StateChanged(tokenId, State.NONE, State.MINTED, msg.sender);

        // PATCH-03: CustodyTransfer audit trail
        bytes32 prevHash = keccak256(abi.encode(tokenId, uint8(State.NONE), address(0), block.number - 1));
        emit CustodyTransfer(tokenId, uint8(State.NONE), uint8(State.MINTED), address(0), to, block.timestamp, prevHash);
    }

    /**
     * @notice Batch mint Digital Twin NFTs for multiple recipients
     * @dev Capped at MAX_BATCH_SIZE (100) to prevent block gas limit DoS.
     *      Each mint follows the same logic as single mint().
     * @param recipients Array of owner addresses for each new asset
     * @param metadata Array of metadata identifiers (must match recipients length)
     * @return tokenIds Array of newly minted token IDs
     * @custom:security MAX_BATCH_SIZE prevents block gas limit DoS
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:emits AssetMinted, StateChanged, CustodyTransfer (per token)
     */
    function batchMint(address[] calldata recipients, bytes32[] calldata metadata)
        external
        nonReentrant
        requiresCapability(MINTER_CAPABILITY)
        returns (uint256[] memory tokenIds)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (recipients.length > MAX_BATCH_SIZE) {
            revert BatchTooLarge(recipients.length, MAX_BATCH_SIZE);
        }
        if (recipients.length != metadata.length) {
            revert ArrayLengthMismatch(recipients.length, metadata.length);
        }

        // ============================================
        // EFFECTS + INTERACTIONS (per token)
        // ============================================
        tokenIds = new uint256[](recipients.length);

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();

            // NIST AC-7: Rate limit check for spam prevention
            _mintRateLimiter.check(_mintRateLimits, msg.sender);

            uint256 tokenId = _nextTokenId++;
            _totalSupply++;

            _assets[tokenId] = Asset({
                owner: recipients[i],
                timestamp: uint64(block.timestamp),
                state: State.MINTED,
                flags: 0,
                reserved: 0
            });

            _mint(recipients[i], tokenId);

            emit AssetMinted(tokenId, recipients[i], metadata[i]);
            emit StateChanged(tokenId, State.NONE, State.MINTED, msg.sender);

            // PATCH-03: CustodyTransfer audit trail
            bytes32 prevHash = keccak256(abi.encode(tokenId, uint8(State.NONE), address(0), block.number - 1));
            emit CustodyTransfer(tokenId, uint8(State.NONE), uint8(State.MINTED), address(0), recipients[i], block.timestamp, prevHash);

            tokenIds[i] = tokenId;
        }
    }

    /**
     * @notice Cryptographically bind an NFC tag to a minted asset with oracle attestation
     * @dev Tag binding is irreversible. Asset must be in MINTED state.
     *      Tag hash must be unique across all assets.
     *      Oracle ECDSA signature required to prove physical NFC chip was scanned.
     *      Follows Checks-Effects-Interactions pattern for security.
     * @param tokenId The asset token ID to bind
     * @param tagHash Keccak256 hash of the NFC tag UID
     * @param challengeResponse NFC chip's response to the oracle challenge
     * @param oracleSignature ECDSA signature from trusted oracle attesting the challenge-response
     * @custom:security ECDSA.recover verifies oracle signed (tokenId, tagHash, challengeResponse)
     * @custom:security Prevents spoofing — cannot bind without physical NFC scan + oracle attestation
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security Tag uniqueness enforced via _tagToToken mapping
     * @custom:security State validation prevents re-binding
     * @custom:emits TagBound, StateChanged
     */
    function bindTag(uint256 tokenId, bytes32 tagHash, bytes calldata challengeResponse, bytes calldata oracleSignature)
        external
        nonReentrant
        requiresCapability(BINDER_CAPABILITY)
    {
        // ============================================
        // CHECKS
        // ============================================
        Asset storage asset = _assets[tokenId];

        // Verify token exists (owner will be address(0) if not minted)
        if (asset.owner == address(0)) revert TokenNotFound(tokenId);

        // Verify asset is in MINTED state (can only bind tags to freshly minted assets)
        if (asset.state != State.MINTED) {
            revert InvalidState(tokenId, asset.state, State.MINTED);
        }

        // Verify tag hash is not zero
        if (tagHash == bytes32(0)) revert InvalidTagHash();

        // Verify tag is not already bound to another asset
        if (_tagToToken[tagHash] != 0) revert TagAlreadyBound(tagHash);

        // PATCH-06: Verify oracle ECDSA signature
        if (trustedOracle == address(0)) revert OracleNotSet();
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recovered = ECDSA.recover(ethHash, oracleSignature);
        if (recovered != trustedOracle) revert InvalidOracleSignature();

        // ============================================
        // EFFECTS
        // ============================================
        // Update asset state to BOUND
        asset.state = State.BOUND;
        asset.timestamp = uint64(block.timestamp);

        // Store bidirectional tag mappings
        _tagToToken[tagHash] = tokenId;
        _tokenToTag[tokenId] = tagHash;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit TagBound(tokenId, tagHash);
        emit StateChanged(tokenId, State.MINTED, State.BOUND, msg.sender);

        // PATCH-03: CustodyTransfer audit trail
        bytes32 prevHash = keccak256(abi.encode(tokenId, uint8(State.MINTED), asset.owner, block.number - 1));
        emit CustodyTransfer(tokenId, uint8(State.MINTED), uint8(State.BOUND), asset.owner, asset.owner, block.timestamp, prevHash);
    }

    /**
     * @notice Activate a bound asset after QA approval
     * @dev Asset must be in BOUND state. Represents QA/quality control approval.
     *      Once activated, asset is ready for distribution/claiming.
     *      Follows Checks-Effects-Interactions pattern for security.
     * @param tokenId The asset token ID to activate
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security State validation ensures proper workflow (must bind before activate)
     * @custom:security In production, requires CAP_ACTIVATE capability (BIDGES)
     * @custom:emits StateChanged
     */
    function activate(uint256 tokenId)
        external
        nonReentrant
        requiresCapability(ACTIVATOR_CAPABILITY)
    {
        // ============================================
        // CHECKS
        // ============================================
        Asset storage asset = _assets[tokenId];

        // Verify token exists (owner will be address(0) if not minted)
        if (asset.owner == address(0)) revert TokenNotFound(tokenId);

        // Verify asset is in BOUND state (QA can only activate tag-bound assets)
        if (asset.state != State.BOUND) {
            revert InvalidState(tokenId, asset.state, State.BOUND);
        }

        // ============================================
        // EFFECTS
        // ============================================
        // Update asset state to ACTIVATED
        asset.state = State.ACTIVATED;
        asset.timestamp = uint64(block.timestamp);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit StateChanged(tokenId, State.BOUND, State.ACTIVATED, msg.sender);

        // PATCH-03: CustodyTransfer audit trail
        bytes32 prevHash = keccak256(abi.encode(tokenId, uint8(State.BOUND), asset.owner, block.number - 1));
        emit CustodyTransfer(tokenId, uint8(State.BOUND), uint8(State.ACTIVATED), asset.owner, asset.owner, block.timestamp, prevHash);
    }

    /**
     * @notice Transfer ownership of activated asset to end consumer
     * @dev CRITICAL: This function transfers both internal state AND ERC721 ownership.
     *      Asset must be in ACTIVATED state. Represents final consumer claiming the asset.
     *      Follows Checks-Effects-Interactions pattern STRICTLY for security.
     * @param tokenId The asset token ID to claim
     * @param newOwner Address of the new owner (end consumer)
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security State validation ensures only activated assets can be claimed
     * @custom:security Zero address check prevents accidental burns
     * @custom:security ALL state changes occur BEFORE ERC721 transfer
     * @custom:security In production, requires CAP_CLAIM capability or asset ownership
     * @custom:emits StateChanged
     */
    /// @dev Security: CEI (Checks-Effects-Interactions) order enforced.
    ///      1. CHECKS — validate state, ownership, and capability
    ///      2. EFFECTS — update asset.state, asset.owner, asset.timestamp in storage
    ///      3. INTERACTIONS — _transfer() and event emissions AFTER all state mutations
    ///      nonReentrant prevents reentry via onERC721Received or any callback.
    ///      _update() override blocks external ERC721 transfers, preventing ownership desync.
    function claim(uint256 tokenId, address newOwner)
        external
        nonReentrant
        requiresCapability(CLAIMER_CAPABILITY)
    {
        // ============================================
        // CHECKS
        // ============================================
        Asset storage asset = _assets[tokenId];

        // Verify token exists (owner will be address(0) if not minted)
        if (asset.owner == address(0)) revert TokenNotFound(tokenId);

        // Verify asset is in ACTIVATED state (can only claim QA-approved assets)
        if (asset.state != State.ACTIVATED) {
            revert InvalidState(tokenId, asset.state, State.ACTIVATED);
        }

        // Verify new owner is not zero address (prevent accidental burns)
        if (newOwner == address(0)) revert ZeroAddress();

        // ============================================
        // EFFECTS (ALL state changes BEFORE transfer)
        // ============================================
        address previousOwner = asset.owner;

        // Update asset state to CLAIMED
        asset.state = State.CLAIMED;
        asset.timestamp = uint64(block.timestamp);
        asset.owner = newOwner;

        // ============================================
        // INTERACTIONS (External calls LAST)
        // ============================================
        // Transfer ERC721 token ownership
        // NOTE: This must happen AFTER all state changes per Checks-Effects-Interactions
        _transfer(previousOwner, newOwner, tokenId);

        // Emit state change event
        emit StateChanged(tokenId, State.ACTIVATED, State.CLAIMED, msg.sender);

        // PATCH-03: CustodyTransfer audit trail
        bytes32 prevHash = keccak256(abi.encode(tokenId, uint8(State.ACTIVATED), previousOwner, block.number - 1));
        emit CustodyTransfer(tokenId, uint8(State.ACTIVATED), uint8(State.CLAIMED), previousOwner, newOwner, block.timestamp, prevHash);
    }

    /**
     * @notice Flag asset as lost, stolen, or subject to recall
     * @dev Asset must be in CLAIMED state. Initiates AIRP recovery protocol.
     *      Follows Checks-Effects-Interactions pattern for security.
     * @param tokenId The asset token ID to flag
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security State validation ensures only claimed assets can be flagged
     * @custom:security In production, requires CAP_FLAG capability
     * @custom:emits StateChanged
     */
    function flag(uint256 tokenId)
        external
        nonReentrant
        requiresCapability(FLAGGER_CAPABILITY)
    {
        // ============================================
        // CHECKS
        // ============================================
        Asset storage asset = _assets[tokenId];

        // Verify token exists (owner will be address(0) if not minted)
        if (asset.owner == address(0)) revert TokenNotFound(tokenId);

        // Verify asset is in CLAIMED state (can only flag consumer-owned assets)
        if (asset.state != State.CLAIMED) {
            revert InvalidState(tokenId, asset.state, State.CLAIMED);
        }

        // NIST IR-4: Circuit breaker check for mass flagging attacks
        // Trips if threshold exceeded, automatically resets after cooldown
        _flagCircuitBreaker.check();

        // ============================================
        // EFFECTS
        // ============================================
        // Update asset state to FLAGGED
        asset.state = State.FLAGGED;
        asset.timestamp = uint64(block.timestamp);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit StateChanged(tokenId, State.CLAIMED, State.FLAGGED, msg.sender);

        // PATCH-03: CustodyTransfer audit trail
        bytes32 prevHash = keccak256(abi.encode(tokenId, uint8(State.CLAIMED), asset.owner, block.number - 1));
        emit CustodyTransfer(tokenId, uint8(State.CLAIMED), uint8(State.FLAGGED), asset.owner, asset.owner, block.timestamp, prevHash);
    }

    /**
     * @notice Approve resolution of a flagged asset (2-of-3 multisig quorum)
     * @dev Requires RESOLVER_CAPABILITY. Asset must be FLAGGED. Each resolver can only
     *      approve once per token. First approver sets the recipient; subsequent approvers
     *      must agree on the same recipient.
     * @param tokenId The asset token ID to approve resolution for
     * @param newOwner Proposed recipient of the resolved asset
     * @custom:security STRIDE Tampering mitigation — prevents single compromised resolver
     * @custom:emits ResolveApproved
     */
    function approveResolve(uint256 tokenId, address newOwner)
        external
        nonReentrant
        requiresCapability(RESOLVER_CAPABILITY)
    {
        // ============================================
        // CHECKS
        // ============================================
        Asset storage asset = _assets[tokenId];

        // Verify token exists
        if (asset.owner == address(0)) revert TokenNotFound(tokenId);

        // Verify asset is in FLAGGED state
        if (asset.state != State.FLAGGED) {
            revert InvalidState(tokenId, asset.state, State.FLAGGED);
        }

        // Compute round key (invalidates stale approvals from previous resolve cycles)
        uint256 roundKey = uint256(keccak256(abi.encode(tokenId, _resolveNonce[tokenId])));

        // Verify caller hasn't already approved in this round
        if (_resolveApprovals[roundKey][msg.sender]) {
            revert AlreadyApproved(tokenId, msg.sender);
        }

        // Verify recipient matches (if not the first approval)
        if (_resolveApprovalCount[tokenId] > 0) {
            if (newOwner != _resolveRecipient[tokenId]) {
                revert RecipientMismatch(tokenId, _resolveRecipient[tokenId], newOwner);
            }
        }

        // ============================================
        // EFFECTS
        // ============================================
        // First approval sets the recipient
        if (_resolveApprovalCount[tokenId] == 0) {
            _resolveRecipient[tokenId] = newOwner;
        }

        _resolveApprovals[roundKey][msg.sender] = true;
        _resolveApprovalCount[tokenId]++;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit ResolveApproved(tokenId, msg.sender, _resolveApprovalCount[tokenId]);
    }

    /**
     * @notice Resolve AIRP recovery and return asset to rightful owner
     * @dev CRITICAL: This function transfers both internal state AND ERC721 ownership.
     *      Asset must be in FLAGGED state. This is the ONLY backward state transition.
     *      Follows Checks-Effects-Interactions pattern STRICTLY for security.
     * @param tokenId The asset token ID to resolve
     * @param newOwner Address of the rightful owner (recovery recipient)
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security State validation ensures only flagged assets can be resolved
     * @custom:security Zero address check prevents accidental burns
     * @custom:security ALL state changes occur BEFORE ERC721 transfer
     * @custom:security In production, requires CAP_RECOVERY_APPROVE capability
     * @custom:emits StateChanged
     */
    /// @dev Security: CEI (Checks-Effects-Interactions) order enforced.
    ///      1. CHECKS — validate state, quorum, recipient match
    ///      2. EFFECTS — update asset.state/owner/timestamp, clear approval state
    ///      3. INTERACTIONS — _transfer() and event emissions AFTER all state mutations
    ///      nonReentrant prevents reentry via onERC721Received or any callback.
    ///      _update() override blocks external ERC721 transfers, preventing ownership desync.
    function resolve(uint256 tokenId, address newOwner)
        external
        nonReentrant
        requiresCapability(RESOLVER_CAPABILITY)
    {
        // ============================================
        // CHECKS
        // ============================================
        Asset storage asset = _assets[tokenId];

        // Verify token exists (owner will be address(0) if not minted)
        if (asset.owner == address(0)) revert TokenNotFound(tokenId);

        // Verify asset is in FLAGGED state (can only resolve flagged assets)
        if (asset.state != State.FLAGGED) {
            revert InvalidState(tokenId, asset.state, State.FLAGGED);
        }

        // Verify new owner is not zero address (prevent accidental burns)
        if (newOwner == address(0)) revert ZeroAddress();

        // Verify resolve quorum has been reached (2-of-3 multisig)
        if (_resolveApprovalCount[tokenId] < RESOLVE_QUORUM) {
            revert QuorumNotReached(tokenId, _resolveApprovalCount[tokenId], RESOLVE_QUORUM);
        }

        // Verify newOwner matches the approved recipient
        if (newOwner != _resolveRecipient[tokenId]) {
            revert RecipientMismatch(tokenId, _resolveRecipient[tokenId], newOwner);
        }

        // ============================================
        // EFFECTS (ALL state changes BEFORE transfer)
        // ============================================
        address previousOwner = asset.owner;

        // Update asset state to CLAIMED (recovery success)
        asset.state = State.CLAIMED;
        asset.timestamp = uint64(block.timestamp);
        asset.owner = newOwner;

        // Clear resolve approval state and increment nonce to invalidate stale approvals
        _resolveApprovalCount[tokenId] = 0;
        delete _resolveRecipient[tokenId];
        _resolveNonce[tokenId]++;

        // ============================================
        // INTERACTIONS (External calls LAST)
        // ============================================
        // Transfer ERC721 token ownership
        // NOTE: This must happen AFTER all state changes per Checks-Effects-Interactions
        _transfer(previousOwner, newOwner, tokenId);

        // Emit state change event
        emit StateChanged(tokenId, State.FLAGGED, State.CLAIMED, msg.sender);

        // PATCH-03: CustodyTransfer audit trail
        bytes32 prevHash = keccak256(abi.encode(tokenId, uint8(State.FLAGGED), previousOwner, block.number - 1));
        emit CustodyTransfer(tokenId, uint8(State.FLAGGED), uint8(State.CLAIMED), previousOwner, newOwner, block.timestamp, prevHash);
    }

    /**
     * @notice Recycle asset at end-of-life
     * @dev Asset must be in CLAIMED or FLAGGED state. This is a terminal state - no transitions out.
     *      Ownership is NOT transferred (asset remains with current owner).
     *      Follows Checks-Effects-Interactions pattern for security.
     * @param tokenId The asset token ID to recycle
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security State validation ensures only claimed or flagged assets can be recycled
     * @custom:security Terminal state - RECYCLED has no outbound transitions
     * @custom:security In production, requires CAP_RECYCLE capability
     * @custom:emits StateChanged
     */
    function recycle(uint256 tokenId)
        external
        nonReentrant
        requiresCapability(RECYCLER_CAPABILITY)
    {
        // ============================================
        // CHECKS
        // ============================================
        Asset storage asset = _assets[tokenId];

        // Verify token exists (owner will be address(0) if not minted)
        if (asset.owner == address(0)) revert TokenNotFound(tokenId);

        // Verify asset is in CLAIMED or FLAGGED state (can only recycle end-of-lifecycle assets)
        State currentState = asset.state;
        if (currentState != State.CLAIMED && currentState != State.FLAGGED) {
            revert InvalidState(tokenId, currentState, State.CLAIMED);
        }

        // ============================================
        // EFFECTS
        // ============================================
        // Update asset state to RECYCLED (terminal state)
        asset.state = State.RECYCLED;
        asset.timestamp = uint64(block.timestamp);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit StateChanged(tokenId, currentState, State.RECYCLED, msg.sender);

        // PATCH-03: CustodyTransfer audit trail
        bytes32 prevHash = keccak256(abi.encode(tokenId, uint8(currentState), asset.owner, block.number - 1));
        emit CustodyTransfer(tokenId, uint8(currentState), uint8(State.RECYCLED), asset.owner, asset.owner, block.timestamp, prevHash);
    }

    // ============================================
    // TRANSFER RESTRICTION (PATCH-09)
    // ============================================

    /**
     * @notice Block external ERC721 transfers — assets must move through lifecycle
     * @dev OZ v5 ERC721 calls _update with auth=address(0) for internal operations
     *      (_mint, _transfer) and auth=msg.sender for external calls (transferFrom,
     *      safeTransferFrom). Reverting when auth != address(0) blocks all external
     *      transfers while allowing lifecycle functions that use _mint/_transfer.
     * @param to Destination address
     * @param tokenId Token being transferred
     * @param auth Address that authorized the transfer (address(0) for internal)
     * @return Previous owner address
     * @custom:security Prevents bypassing lifecycle state machine via direct transfer
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        if (auth != address(0)) revert TransferDisabled();
        return super._update(to, tokenId, auth);
    }

    // ============================================
    // TOKEN URI AUTHORIZATION (PATCH-04)
    // ============================================

    /**
     * @notice Returns token metadata URI with authorization gate
     * @dev Returns full URI only to asset owner, VIEWER_CAPABILITY holders, or AUDITOR_CAPABILITY holders.
     *      Unauthorized callers receive _redactedURI (ITAR compliance for defense assets).
     * @param tokenId The token ID to query
     * @return Token metadata URI (full or redacted based on caller authorization)
     * @custom:security ITAR compliance — defense asset metadata not accessible without authorization
     * @custom:security NIST 800-53 AC-6 — least privilege
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        // Check if caller is authorized to view full metadata
        bool isAuthorized = _assets[tokenId].owner == msg.sender;

        if (!isAuthorized && address(accessController) != address(0)) {
            // Check VIEWER_CAPABILITY
            try accessController.requireCapability(msg.sender, uint256(VIEWER_CAPABILITY)) {
                isAuthorized = true;
            } catch {}

            // Check AUDITOR_CAPABILITY if not already authorized
            if (!isAuthorized) {
                try accessController.requireCapability(msg.sender, uint256(AUDITOR_CAPABILITY)) {
                    isAuthorized = true;
                } catch {}
            }
        }

        if (!isAuthorized) {
            return _redactedURI;
        }

        return super.tokenURI(tokenId);
    }

    /**
     * @notice Set the redacted URI returned to unauthorized callers
     * @dev Only owner can update. Used for ITAR compliance on defense asset metadata.
     * @param redactedURI The redacted/minimal metadata URI
     * @custom:security Owner-only — goes through TimelockController 48hr delay
     */
    function setRedactedURI(string calldata redactedURI) external onlyOwner {
        _redactedURI = redactedURI;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get asset metadata for a token
     * @param tokenId The token ID to query
     * @return assetOwner Current owner address
     * @return timestamp Last state change timestamp
     * @return state Current lifecycle state
     * @return flags Bit flags (reserved for future use)
     * @return reserved Reserved field (future metadata)
     * @custom:security Returns memory copy, cannot modify storage directly
     */
    function getAsset(uint256 tokenId)
        external
        view
        returns (
            address assetOwner,
            uint64 timestamp,
            State state,
            uint8 flags,
            uint16 reserved
        )
    {
        Asset memory asset = _assets[tokenId];
        return (
            asset.owner,
            asset.timestamp,
            asset.state,
            asset.flags,
            asset.reserved
        );
    }

    /**
     * @notice Get total number of assets minted
     * @return Total supply of Digital Twin NFTs
     */
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @notice Get token ID bound to a specific NFC tag
     * @param tagHash The NFC tag hash to query
     * @return tokenId The token ID bound to this tag (0 if not bound)
     * @custom:security Returns 0 for unbound tags (safe default)
     */
    function getTokenByTag(bytes32 tagHash) external view returns (uint256) {
        return _tagToToken[tagHash];
    }

    /**
     * @notice Get NFC tag hash bound to a specific token
     * @param tokenId The token ID to query
     * @return tagHash The tag hash bound to this token (bytes32(0) if not bound)
     * @custom:security Returns zero hash for unbound tokens (safe default)
     */
    function getTagByToken(uint256 tokenId) external view returns (bytes32) {
        return _tokenToTag[tokenId];
    }

    /**
     * @notice Get current resolve-approval status for a flagged token
     * @param tokenId The token ID to query
     * @return approvalCount Number of resolver approvals collected
     * @return recipient Proposed newOwner (address(0) if no approvals yet)
     * @return quorumReached Whether the quorum threshold has been met
     */
    function getResolveApprovalStatus(uint256 tokenId)
        external
        view
        returns (uint256 approvalCount, address recipient, bool quorumReached)
    {
        approvalCount = _resolveApprovalCount[tokenId];
        recipient = _resolveRecipient[tokenId];
        quorumReached = approvalCount >= RESOLVE_QUORUM;
    }

    // ============================================
    // NFC ORACLE ADMIN (PATCH-06)
    // ============================================

    /**
     * @notice Set the trusted NFC oracle address for bindTag signature verification
     * @dev Only owner can update. Must be set before any bindTag() calls.
     * @param oracle Address of the trusted NFC oracle (cannot be address(0))
     * @custom:security Owner-only — goes through TimelockController 48hr delay
     * @custom:emits TrustedOracleUpdated
     */
    function setTrustedOracle(address oracle) external onlyOwner {
        if (oracle == address(0)) revert ZeroAddress();
        address previousOracle = trustedOracle;
        trustedOracle = oracle;
        emit TrustedOracleUpdated(previousOracle, oracle);
    }

    // ============================================
    // NIST CSF 2.0 COMPLIANCE - ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Force reset the flag circuit breaker (admin emergency action)
     * @dev Only owner can call. Should only be used after investigating the cause.
     * @custom:security NIST IR-4 manual override for incident response
     * @custom:security Goes through TimelockController 48hr delay
     */
    function resetFlagCircuitBreaker() external onlyOwner {
        _flagCircuitBreaker.forceReset(msg.sender);
    }

    /**
     * @notice Force unlock a rate-limited minter (admin action)
     * @dev Only owner can call. Clears rate limit state for a specific user.
     * @param user Address to unlock
     * @custom:security NIST AC-7 manual override for legitimate users
     * @custom:security Goes through TimelockController 48hr delay
     */
    function unlockMinter(address user) external onlyOwner {
        RateLimiter.forceUnlock(_mintRateLimits, user);
    }

    /**
     * @notice Update circuit breaker threshold (admin action)
     * @dev Only owner can call. Allows tuning based on operational needs.
     * @param newThreshold New threshold for circuit breaker
     * @custom:security NIST CM-3 configuration management
     * @custom:security Goes through TimelockController 48hr delay
     */
    function setFlagCircuitBreakerThreshold(uint32 newThreshold) external onlyOwner {
        _flagCircuitBreaker.setThreshold(newThreshold);
    }

    /**
     * @notice Enable or disable mint rate limiting (admin action)
     * @dev Only owner can call. Use for emergency bypass or planned events.
     * @param enabled Whether rate limiting is enabled
     * @custom:security NIST AC-7 operational control
     * @custom:security Goes through TimelockController 48hr delay
     */
    function setMintRateLimitEnabled(bool enabled) external onlyOwner {
        _mintRateLimiter.setEnabled(enabled);
    }

    // ============================================
    // NIST CSF 2.0 COMPLIANCE - VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get circuit breaker status for flag operations
     * @return isTripped Whether the circuit breaker is currently tripped
     * @return cooldownRemaining Seconds until cooldown ends (0 if not tripped)
     * @custom:security NIST SI-4 system monitoring
     */
    function getFlagCircuitBreakerStatus() external view returns (bool isTripped, uint256 cooldownRemaining) {
        return _flagCircuitBreaker.status();
    }

    /**
     * @notice Get rate limit status for a minter
     * @param user Address to check
     * @return canMint Whether the user can mint
     * @return remaining Remaining mints in current window
     * @return lockedUntil Lockout end timestamp (0 if not locked)
     * @custom:security NIST SI-4 system monitoring
     */
    function getMintRateLimitStatus(address user) external view returns (
        bool canMint,
        uint256 remaining,
        uint256 lockedUntil
    ) {
        return _mintRateLimiter.canAct(_mintRateLimits, user);
    }

    /**
     * @notice Get remaining capacity for flag circuit breaker
     * @return remaining Number of flag operations before circuit trips
     * @custom:security NIST AU-6 audit review capacity
     */
    function getFlagCircuitBreakerCapacity() external view returns (uint256) {
        return _flagCircuitBreaker.remainingCapacity();
    }
}
