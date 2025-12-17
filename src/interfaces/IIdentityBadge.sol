// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IIdentityBadge
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for soulbound identity badges (ERC-5192)
 * @dev Non-transferable tokens representing WHO someone is
 *
 * Identity Badge System:
 * - Soulbound: Cannot be transferred (locked = true)
 * - Revocable: Owner can revoke badges
 * - Single badge per type: One account = one badge per ID
 *
 * Badge Categories:
 * 1-9:   KYC levels (L1, L2, L3)
 * 10-19: Business entities (Manufacturer, Retailer)
 * 20-29: Government/Military (GOV_MIL, LAW_ENFORCEMENT)
 * 30+:   Reserved for future use
 */
interface IIdentityBadge {
    // ============================================
    // ERRORS
    // ============================================

    /**
     * @notice Badge is soulbound and cannot be transferred
     * @param tokenId The badge token ID
     */
    error BadgeLocked(uint256 tokenId);

    /**
     * @notice Account already has this identity badge
     * @param account Account that already has badge
     * @param badgeId Badge ID that already exists
     */
    error BadgeAlreadyGranted(address account, uint256 badgeId);

    /**
     * @notice Account does not have this identity badge
     * @param account Account that doesn't have badge
     * @param badgeId Badge ID that doesn't exist
     */
    error BadgeNotFound(address account, uint256 badgeId);

    /**
     * @notice Invalid badge ID (e.g., zero)
     */
    error InvalidBadgeId();

    /**
     * @notice Zero address provided where not allowed
     */
    error ZeroAddress();

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when identity badge is granted
     * @param account Recipient of the badge
     * @param badgeId Badge ID granted
     * @param tokenId NFT token ID representing the badge
     */
    event IdentityGranted(address indexed account, uint256 indexed badgeId, uint256 tokenId);

    /**
     * @notice Emitted when identity badge is revoked
     * @param account Account losing the badge
     * @param badgeId Badge ID revoked
     * @param tokenId NFT token ID that was burned
     */
    event IdentityRevoked(address indexed account, uint256 indexed badgeId, uint256 tokenId);

    // ============================================
    // BADGE MANAGEMENT
    // ============================================

    /**
     * @notice Grant identity badge to account
     * @param account Recipient address
     * @param badgeId Identity badge ID to grant
     * @return tokenId The NFT token ID representing this badge
     * @custom:security Only owner can call
     * @custom:security Reverts if account already has this badge
     * @custom:emits IdentityGranted
     */
    function grantIdentity(address account, uint256 badgeId) external returns (uint256 tokenId);

    /**
     * @notice Revoke identity badge from account
     * @param account Account to revoke from
     * @param badgeId Identity badge ID to revoke
     * @custom:security Only owner can call
     * @custom:security Burns the NFT representing the badge
     * @custom:emits IdentityRevoked
     */
    function revokeIdentity(address account, uint256 badgeId) external;

    /**
     * @notice Check if account has specific identity badge
     * @param account Address to check
     * @param badgeId Badge ID to verify
     * @return bool True if account has this identity badge
     * @custom:security View function, safe to call from any context
     */
    function hasIdentity(address account, uint256 badgeId) external view returns (bool);

    /**
     * @notice Get token ID for account's identity badge
     * @param account Address to check
     * @param badgeId Badge ID to query
     * @return tokenId Token ID representing the badge (0 if not found)
     */
    function getTokenId(address account, uint256 badgeId) external view returns (uint256 tokenId);

    // ============================================
    // ERC-5192 SOULBOUND INTERFACE
    // ============================================

    /**
     * @notice Check if token is locked (soulbound)
     * @param tokenId Token ID to check
     * @return bool Always returns true (all identity badges are soulbound)
     * @custom:security ERC-5192 standard function
     */
    function locked(uint256 tokenId) external view returns (bool);

    /**
     * @notice Emitted when token locked status changes
     * @dev For identity badges, this is emitted once on mint with locked=true
     * @param tokenId The token ID
     * @param locked Whether token is locked (always true for identity badges)
     */
    event Locked(uint256 tokenId, bool locked);
}
