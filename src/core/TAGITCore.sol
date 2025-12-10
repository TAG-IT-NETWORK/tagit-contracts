// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
contract TAGITCore {
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
}
