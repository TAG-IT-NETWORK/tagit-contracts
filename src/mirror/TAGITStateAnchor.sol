// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TAGITStateAnchor
 * @author TAG IT Network <dev@tagit.network>
 * @notice Stores state roots from the primary chain for cross-chain verification.
 * @dev Deployed on the mirror chain. An authorized anchor (relayer) posts
 *      keccak256(state, owner, timestamp) hashes. Anyone can verify.
 *
 * @custom:security Append-only by design — no delete functions.
 *      onlyAnchor modifier restricts posting to the authorized relayer key.
 */
contract TAGITStateAnchor is Ownable {
    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────
    error NotAnchor();
    error ZeroAddress();
    error InvalidRoot();

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────
    event StateRootPosted(uint256 indexed tokenId, bytes32 root, uint256 timestamp);
    event HeartbeatPosted(uint256 timestamp);
    event AnchorRotated(address indexed oldAnchor, address indexed newAnchor);

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    /// @notice Authorized relayer address that can post state roots.
    address public anchor;

    /// @notice Last heartbeat timestamp.
    uint256 public lastHeartbeat;

    /// @notice tokenId → latest state root hash.
    mapping(uint256 => bytes32) public stateRoots;

    /// @notice tokenId → timestamp of last state root update.
    mapping(uint256 => uint256) public lastUpdated;

    // ──────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────

    modifier onlyAnchor() {
        if (msg.sender != anchor) revert NotAnchor();
        _;
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    /// @param _anchor Initial authorized relayer address.
    constructor(address _anchor) Ownable(msg.sender) {
        if (_anchor == address(0)) revert ZeroAddress();
        anchor = _anchor;
        lastHeartbeat = block.timestamp;
    }

    // ──────────────────────────────────────────────
    // Write Functions
    // ──────────────────────────────────────────────

    /// @notice Post a state root for a given tokenId.
    /// @param tokenId The asset token ID from the primary chain.
    /// @param root keccak256(abi.encodePacked(state, owner, timestamp)) hash.
    function postStateRoot(uint256 tokenId, bytes32 root) external onlyAnchor {
        if (root == bytes32(0)) revert InvalidRoot();

        stateRoots[tokenId] = root;
        lastUpdated[tokenId] = block.timestamp;
        lastHeartbeat = block.timestamp;

        emit StateRootPosted(tokenId, root, block.timestamp);
    }

    /// @notice Post a heartbeat to prove the relayer is alive.
    function postHeartbeat() external onlyAnchor {
        lastHeartbeat = block.timestamp;
        emit HeartbeatPosted(block.timestamp);
    }

    /// @notice Rotate the anchor key. Owner-only for security.
    /// @param newAnchor New authorized relayer address.
    function rotateAnchor(address newAnchor) external onlyOwner {
        if (newAnchor == address(0)) revert ZeroAddress();
        address oldAnchor = anchor;
        anchor = newAnchor;
        emit AnchorRotated(oldAnchor, newAnchor);
    }

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    /// @notice Verify that a state matches the anchored root.
    /// @param tokenId The asset token ID.
    /// @param state The lifecycle state (uint8 cast to uint256).
    /// @param owner The asset owner address.
    /// @param timestamp The state timestamp.
    /// @return valid True if the computed hash matches the stored root.
    function verifyState(uint256 tokenId, uint256 state, address owner, uint256 timestamp)
        external
        view
        returns (bool valid)
    {
        bytes32 computed = keccak256(abi.encodePacked(state, owner, timestamp));
        return stateRoots[tokenId] == computed;
    }

    /// @notice Seconds since the last state root update for a tokenId.
    /// @param tokenId The asset token ID.
    /// @return age Seconds since last update. Returns type(uint256).max if never updated.
    function syncAge(uint256 tokenId) external view returns (uint256 age) {
        uint256 updated = lastUpdated[tokenId];
        if (updated == 0) return type(uint256).max;
        return block.timestamp - updated;
    }

    /// @notice Seconds since the last heartbeat from the relayer.
    /// @return age Seconds since last heartbeat.
    function systemSyncAge() external view returns (uint256 age) {
        return block.timestamp - lastHeartbeat;
    }
}
