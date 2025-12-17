// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITAccess
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for BIDGES access control system
 * @dev Main controller interface for identity and capability verification
 *
 * BIDGES = Badge-based Identity & Delegation with Granular Execution Security
 *
 * This interface defines the access control layer that combines:
 * - Identity Badges: Soulbound tokens representing WHO someone is (ERC-5192)
 * - Capability Badges: Transferable tokens representing WHAT someone can do (ERC-1155)
 *
 * Security Model:
 * - Zero-trust: All actions require explicit capability grants
 * - Separation of concerns: Identity (who) vs capability (what)
 * - Revocable: Both identity and capability can be revoked by owner
 */
interface ITAGITAccess {
    // ============================================
    // ERRORS
    // ============================================

    /**
     * @notice Account lacks required capability
     * @param account Address attempting the operation
     * @param capabilityId Required capability ID
     */
    error MissingCapability(address account, uint256 capabilityId);

    /**
     * @notice Account lacks required identity badge
     * @param account Address attempting the operation
     * @param identityId Required identity badge ID
     */
    error MissingIdentity(address account, uint256 identityId);

    /**
     * @notice Invalid badge contract address
     */
    error InvalidBadgeContract();

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when identity badge contract is updated
     * @param previousBadge Previous badge contract address
     * @param newBadge New badge contract address
     */
    event IdentityBadgeUpdated(address indexed previousBadge, address indexed newBadge);

    /**
     * @notice Emitted when capability badge contract is updated
     * @param previousBadge Previous badge contract address
     * @param newBadge New badge contract address
     */
    event CapabilityBadgeUpdated(address indexed previousBadge, address indexed newBadge);

    // ============================================
    // CAPABILITY CHECKS
    // ============================================

    /**
     * @notice Check if account has specific capability
     * @param account Address to check
     * @param capabilityId Capability ID to verify
     * @return bool True if account has capability
     * @custom:security View function, safe to call from any context
     */
    function hasCapability(address account, uint256 capabilityId) external view returns (bool);

    /**
     * @notice Require account to have specific capability (reverts if not)
     * @param account Address to check
     * @param capabilityId Capability ID to require
     * @custom:security Reverts with MissingCapability if check fails
     */
    function requireCapability(address account, uint256 capabilityId) external view;

    // ============================================
    // IDENTITY CHECKS
    // ============================================

    /**
     * @notice Check if account has specific identity badge
     * @param account Address to check
     * @param identityId Identity badge ID to verify
     * @return bool True if account has identity badge
     * @custom:security View function, safe to call from any context
     */
    function hasIdentity(address account, uint256 identityId) external view returns (bool);

    /**
     * @notice Require account to have specific identity badge (reverts if not)
     * @param account Address to check
     * @param identityId Identity badge ID to require
     * @custom:security Reverts with MissingIdentity if check fails
     */
    function requireIdentity(address account, uint256 identityId) external view;

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Set the identity badge contract address
     * @param badge Address of the identity badge contract (ERC-5192)
     * @custom:security Only owner can call
     * @custom:emits IdentityBadgeUpdated
     */
    function setIdentityBadge(address badge) external;

    /**
     * @notice Set the capability badge contract address
     * @param badge Address of the capability badge contract (ERC-1155)
     * @custom:security Only owner can call
     * @custom:emits CapabilityBadgeUpdated
     */
    function setCapabilityBadge(address badge) external;

    /**
     * @notice Get the identity badge contract address
     * @return Address of identity badge contract
     */
    function identityBadge() external view returns (address);

    /**
     * @notice Get the capability badge contract address
     * @return Address of capability badge contract
     */
    function capabilityBadge() external view returns (address);
}
