// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IIdentityBadge} from "../interfaces/IIdentityBadge.sol";

/**
 * @title IdentityBadge
 * @author TAG IT Network <dev@tagit.network>
 * @notice Soulbound identity badges (ERC-5192) representing WHO someone is
 * @dev Non-transferable NFTs for identity verification in BIDGES system
 *
 * Identity Badge System:
 * - Soulbound: Cannot be transferred after minting (ERC-5192)
 * - Revocable: Owner can revoke badges via burning
 * - One badge per type: Each account can have one badge per badge ID
 * - Zero-trust: All badge checks are explicit and verifiable on-chain
 *
 * Badge Categories — ONE flat, protocol-wide registry. A badge id means the same thing to
 * every contract that reads it, so a range must never be reused for a second purpose:
 * 1-9:   KYC levels (KYC_L1=1, KYC_L2=2, KYC_L3=3)
 * 10-19: Business entities (MANUFACTURER=10, RETAILER=11)
 * 20-29: Government/Military (GOV_MIL=20, LAW_ENFORCEMENT=21)
 * 30-39: Robot classes (RobotTypes: CHEF=30 .. MEDICAL=35); TAGITGovernor reads DEV=30
 * 40-49: Regulatory (TAGITGovernor: REGULATORY=40)
 * 50-69: Loyalty tiers (TAGITPrograms: BASIC_VERIFIER=50, CERTIFIED_VERIFIER=51, GOVERNANCE=60)
 * 70-79: AIRP jury seats (TAGITRecovery: JUROR=70, SENIOR_JUROR=71, ARBITER=72, TRIBUNAL=73)
 * 80+:   Reserved for future use
 *
 * Security:
 * - Soulbound enforced via _update() override (blocks ALL transfers)
 * - Only contract owner can grant/revoke badges
 * - Custom errors for gas efficiency
 * - Events emit for all state changes
 */
contract IdentityBadge is ERC721, Ownable, IIdentityBadge {
    // ============================================
    // STORAGE
    // ============================================

    /// @notice Mapping: (account address, badge ID) => token ID
    /// @dev Used to check if account has specific badge and get token ID
    mapping(address => mapping(uint256 => uint256)) private _accountBadgeToToken;

    /// @notice Counter for next token ID (starts at 1)
    uint256 private _nextTokenId;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize IdentityBadge contract
     * @dev Sets ERC721 name/symbol, initializes Ownable, starts token counter at 1
     */
    constructor() ERC721("TAG IT Identity Badge", "TAGIT-ID") Ownable(msg.sender) {
        _nextTokenId = 1; // Start token IDs at 1 (0 reserved for "none")
    }

    // ============================================
    // BADGE MANAGEMENT (OWNER ONLY)
    // ============================================

    /**
     * @notice Grant identity badge to account
     * @dev Mints soulbound NFT representing identity. Only owner can call.
     *      Emits IdentityGranted and Locked events.
     * @param account Recipient address
     * @param badgeId Identity badge ID to grant
     * @return tokenId The NFT token ID representing this badge
     * @custom:security Only owner can grant badges
     * @custom:security Reverts if account already has this badge
     * @custom:security Zero address check prevents invalid grants
     * @custom:security Badge ID must be non-zero
     * @custom:emits IdentityGranted, Locked (ERC-5192)
     */
    function grantIdentity(address account, uint256 badgeId) external onlyOwner returns (uint256 tokenId) {
        // ============================================
        // CHECKS
        // ============================================
        if (account == address(0)) revert ZeroAddress();
        if (badgeId == 0) revert InvalidBadgeId();
        if (_accountBadgeToToken[account][badgeId] != 0) {
            revert BadgeAlreadyGranted(account, badgeId);
        }

        // ============================================
        // EFFECTS
        // ============================================
        tokenId = _nextTokenId;
        unchecked {
            ++_nextTokenId; // Overflow impossible in practice
        }

        // Store mapping: (account, badgeId) => tokenId
        _accountBadgeToToken[account][badgeId] = tokenId;

        // Mint NFT (soulbound - cannot be transferred)
        _mint(account, tokenId);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit IdentityGranted(account, badgeId, tokenId);
        emit Locked(tokenId, true); // ERC-5192 standard event
    }

    /**
     * @notice Revoke identity badge from account
     * @dev Burns the NFT representing the badge. Only owner can call.
     *      Emits IdentityRevoked event.
     * @param account Account to revoke from
     * @param badgeId Identity badge ID to revoke
     * @custom:security Only owner can revoke badges
     * @custom:security Reverts if account doesn't have this badge
     * @custom:emits IdentityRevoked
     */
    function revokeIdentity(address account, uint256 badgeId) external onlyOwner {
        // ============================================
        // CHECKS
        // ============================================
        uint256 tokenId = _accountBadgeToToken[account][badgeId];
        if (tokenId == 0) {
            revert BadgeNotFound(account, badgeId);
        }

        // ============================================
        // EFFECTS
        // ============================================
        // Clear mapping
        delete _accountBadgeToToken[account][badgeId];

        // Burn NFT
        _burn(tokenId);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit IdentityRevoked(account, badgeId, tokenId);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if account has specific identity badge
     * @param account Address to check
     * @param badgeId Badge ID to verify
     * @return bool True if account has this identity badge
     * @custom:security View function, safe to call from any context
     */
    function hasIdentity(address account, uint256 badgeId) external view returns (bool) {
        return _accountBadgeToToken[account][badgeId] != 0;
    }

    /**
     * @notice Get token ID for account's identity badge
     * @param account Address to check
     * @param badgeId Badge ID to query
     * @return tokenId Token ID representing the badge (0 if not found)
     */
    function getTokenId(address account, uint256 badgeId) external view returns (uint256 tokenId) {
        return _accountBadgeToToken[account][badgeId];
    }

    // ============================================
    // ERC-5192 SOULBOUND INTERFACE
    // ============================================

    /**
     * @notice Check if token is locked (soulbound)
     * @param tokenId Token ID to check
     * @return bool Always returns true (all identity badges are soulbound)
     * @custom:security ERC-5192 standard function
     */
    function locked(uint256 tokenId) external pure returns (bool) {
        // Silence unused parameter warning
        tokenId;
        // All identity badges are permanently locked (soulbound)
        return true;
    }

    // ============================================
    // SOULBOUND ENFORCEMENT
    // ============================================

    /**
     * @notice Override _update to enforce soulbound behavior
     * @dev CRITICAL: Blocks ALL transfers except minting and burning
     *      This is the core mechanism that makes badges soulbound (ERC-5192)
     * @param to Recipient address (address(0) for burn)
     * @param tokenId Token ID being updated
     * @param auth Address authorized to perform the update
     * @return address Previous owner (from super._update)
     * @custom:security Reverts on ANY transfer attempt (from != address(0) && to != address(0))
     * @custom:security Allows minting (from == address(0))
     * @custom:security Allows burning (to == address(0))
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow minting (from == address(0))
        // Allow burning (to == address(0))
        // Block ALL transfers (from != address(0) && to != address(0))
        if (from != address(0) && to != address(0)) {
            revert BadgeLocked(tokenId);
        }

        return super._update(to, tokenId, auth);
    }

    /**
     * @notice Override approve to prevent approvals on soulbound tokens
     * @dev CRITICAL: Soulbound tokens cannot be approved for transfer
     * @param to Address to approve (unused)
     * @param tokenId Token ID to approve (used for error)
     * @custom:security Always reverts with BadgeLocked
     */
    function approve(address to, uint256 tokenId) public override {
        // Silence unused parameter warning
        to;
        // Soulbound tokens cannot be approved
        revert BadgeLocked(tokenId);
    }

    /**
     * @notice Override setApprovalForAll to prevent operator approvals
     * @dev CRITICAL: Soulbound tokens cannot have operators
     * @param operator Address to set approval for (unused)
     * @param approved Approval status (unused)
     * @custom:security Always reverts with BadgeLocked(0)
     */
    function setApprovalForAll(address operator, bool approved) public override {
        // Silence unused parameter warnings
        operator;
        approved;
        // Soulbound tokens cannot have operators
        revert BadgeLocked(0);
    }
}
