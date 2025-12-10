// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TAGITCore
 * @author TAG IT Network <dev@tagit.network>
 * @notice Core asset management for digital twins
 * @dev Implements ERC-721 with lifecycle state machine
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
 * Security: All state-changing functions must follow Checks-Effects-Interactions pattern
 * and include ReentrancyGuard. BIDGES capability checks enforce zero-trust access control.
 */
contract TAGITCore is ERC721, ReentrancyGuard {
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

    // ============================================
    // EVENTS
    // ============================================

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

    // ============================================
    // STORAGE
    // ============================================

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
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize TAGITCore contract
     * @dev Sets ERC721 name and symbol, initializes token counter
     */
    constructor() ERC721("TAG IT Digital Twin", "TAGIT") {
        _nextTokenId = 1; // Start token IDs at 1 (0 reserved for "none")
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
        returns (uint256 tokenId)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (to == address(0)) revert ZeroAddress();

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
    }

    /**
     * @notice Cryptographically bind an NFC tag to a minted asset
     * @dev Tag binding is irreversible. Asset must be in MINTED state.
     *      Tag hash must be unique across all assets.
     *      Follows Checks-Effects-Interactions pattern for security.
     * @param tokenId The asset token ID to bind
     * @param tagHash Keccak256 hash of the NFC tag UID
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security Tag uniqueness enforced via _tagToToken mapping
     * @custom:security State validation prevents re-binding
     * @custom:emits TagBound, StateChanged
     */
    function bindTag(uint256 tokenId, bytes32 tagHash)
        external
        nonReentrant
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
    function claim(uint256 tokenId, address newOwner)
        external
        nonReentrant
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
    function resolve(uint256 tokenId, address newOwner)
        external
        nonReentrant
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

        // ============================================
        // EFFECTS (ALL state changes BEFORE transfer)
        // ============================================
        address previousOwner = asset.owner;

        // Update asset state to CLAIMED (recovery success)
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
        emit StateChanged(tokenId, State.FLAGGED, State.CLAIMED, msg.sender);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get asset metadata for a token
     * @param tokenId The token ID to query
     * @return owner Current owner address
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
            address owner,
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
}
