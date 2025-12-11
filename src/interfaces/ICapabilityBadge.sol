// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICapabilityBadge
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for capability badges (ERC-1155)
 * @dev Transferable tokens representing WHAT someone can do
 *
 * Capability Badge System:
 * - Transferable: Can be transferred between accounts (ERC-1155)
 * - Revocable: Owner can revoke capabilities
 * - Multi-badge: One account can have multiple capabilities
 * - Quantity: Balance represents permission level (0 = no permission, ≥1 = has permission)
 *
 * Capability Categories:
 * 100-109: Core operations (MINT, BIND, ACTIVATE, CLAIM)
 * 110-119: Recovery operations (FLAG, RECOVERY_INIT, RECOVERY_APPROVE)
 * 120-129: Administrative (FREEZE, DAO_VOTE)
 * 130+:    Reserved for future use
 */
interface ICapabilityBadge {
    // ============================================
    // ERRORS
    // ============================================

    /**
     * @notice Invalid capability ID (e.g., zero)
     */
    error InvalidCapabilityId();

    /**
     * @notice Zero address provided where not allowed
     */
    error ZeroAddress();

    /**
     * @notice Account does not have required capability
     * @param account Account that lacks capability
     * @param capabilityId Capability ID that is missing
     */
    error CapabilityNotFound(address account, uint256 capabilityId);

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when capability is granted
     * @param account Recipient of the capability
     * @param capabilityId Capability ID granted
     * @param amount Number of capability tokens granted (typically 1)
     */
    event CapabilityGranted(address indexed account, uint256 indexed capabilityId, uint256 amount);

    /**
     * @notice Emitted when capability is revoked
     * @param account Account losing the capability
     * @param capabilityId Capability ID revoked
     * @param amount Number of capability tokens revoked
     */
    event CapabilityRevoked(address indexed account, uint256 indexed capabilityId, uint256 amount);

    // ============================================
    // CAPABILITY MANAGEMENT
    // ============================================

    /**
     * @notice Grant capability to account
     * @param account Recipient address
     * @param capabilityId Capability ID to grant
     * @return amount Number of tokens granted (typically 1)
     * @custom:security Only owner can call
     * @custom:emits CapabilityGranted
     */
    function grantCapability(address account, uint256 capabilityId) external returns (uint256 amount);

    /**
     * @notice Revoke capability from account
     * @param account Account to revoke from
     * @param capabilityId Capability ID to revoke
     * @custom:security Only owner can call
     * @custom:emits CapabilityRevoked
     */
    function revokeCapability(address account, uint256 capabilityId) external;

    /**
     * @notice Grant multiple capabilities to account in single transaction
     * @param account Recipient address
     * @param capabilityIds Array of capability IDs to grant
     * @custom:security Only owner can call
     * @custom:emits CapabilityGranted for each capability
     */
    function batchGrantCapabilities(address account, uint256[] calldata capabilityIds) external;

    /**
     * @notice Revoke multiple capabilities from account in single transaction
     * @param account Account to revoke from
     * @param capabilityIds Array of capability IDs to revoke
     * @custom:security Only owner can call
     * @custom:emits CapabilityRevoked for each capability
     */
    function batchRevokeCapabilities(address account, uint256[] calldata capabilityIds) external;

    /**
     * @notice Check if account has specific capability
     * @param account Address to check
     * @param capabilityId Capability ID to verify
     * @return bool True if account has capability (balance ≥ 1)
     * @custom:security View function, safe to call from any context
     */
    function hasCapability(address account, uint256 capabilityId) external view returns (bool);

    // NOTE: balanceOf(address account, uint256 id) is inherited from IERC1155
    // No need to redeclare it here as it would cause a conflict
}
