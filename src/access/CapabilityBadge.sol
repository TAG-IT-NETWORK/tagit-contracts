// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICapabilityBadge} from "../interfaces/ICapabilityBadge.sol";

/**
 * @title CapabilityBadge
 * @author TAG IT Network <dev@tagit.network>
 * @notice Transferable capability badges (ERC-1155) representing WHAT someone can do
 * @dev Multi-token NFTs for permission management in BIDGES system
 *
 * Capability Badge System:
 * - Transferable: Can be transferred between accounts (ERC-1155)
 * - Revocable: Owner can revoke capabilities via burning
 * - Multi-capability: One account can have multiple capabilities
 * - Quantity-based: Balance ≥ 1 = has permission, 0 = no permission
 * - Batch operations: Efficient multi-capability management
 *
 * Capability Categories (from CLAUDE.md):
 * 100-109: Core operations (MINT, BIND, ACTIVATE, CLAIM)
 * 110-119: Recovery operations (FLAG, RECOVERY_INIT, RECOVERY_APPROVE)
 * 120-129: Administrative (FREEZE, DAO_VOTE)
 * 130+:    Reserved for future use
 *
 * Security:
 * - Only contract owner can grant/revoke capabilities
 * - Custom errors for gas efficiency
 * - Events emit for all capability changes
 * - Follows Checks-Effects-Interactions pattern
 */
contract CapabilityBadge is ERC1155, Ownable, ICapabilityBadge {
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Amount of capability tokens granted per grant (always 1)
    uint256 private constant GRANT_AMOUNT = 1;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize CapabilityBadge contract
     * @dev Sets ERC1155 URI (empty for now), initializes Ownable
     */
    constructor() ERC1155("") Ownable(msg.sender) {
        // URI can be set later if metadata is needed for capabilities
    }

    // ============================================
    // CAPABILITY MANAGEMENT (OWNER ONLY)
    // ============================================

    /**
     * @notice Grant capability to account
     * @dev Mints 1 ERC-1155 token of the specified capability ID.
     *      Emits CapabilityGranted event.
     * @param account Recipient address
     * @param capabilityId Capability ID to grant
     * @return amount Number of tokens granted (always 1)
     * @custom:security Only owner can grant capabilities
     * @custom:security Zero address check prevents invalid grants
     * @custom:security Capability ID must be non-zero
     * @custom:emits CapabilityGranted
     */
    function grantCapability(address account, uint256 capabilityId) external onlyOwner returns (uint256 amount) {
        // ============================================
        // CHECKS
        // ============================================
        if (account == address(0)) revert ZeroAddress();
        if (capabilityId == 0) revert InvalidCapabilityId();

        // ============================================
        // EFFECTS
        // ============================================
        amount = GRANT_AMOUNT;

        // Mint capability token (ERC-1155)
        _mint(account, capabilityId, amount, "");

        // ============================================
        // INTERACTIONS
        // ============================================
        emit CapabilityGranted(account, capabilityId, amount);
    }

    /**
     * @notice Revoke capability from account
     * @dev Burns 1 ERC-1155 token of the specified capability ID.
     *      Emits CapabilityRevoked event.
     * @param account Account to revoke from
     * @param capabilityId Capability ID to revoke
     * @custom:security Only owner can revoke capabilities
     * @custom:security Reverts if account doesn't have capability
     * @custom:emits CapabilityRevoked
     */
    function revokeCapability(address account, uint256 capabilityId) external onlyOwner {
        // ============================================
        // CHECKS
        // ============================================
        uint256 balance = balanceOf(account, capabilityId);
        if (balance == 0) {
            revert CapabilityNotFound(account, capabilityId);
        }

        // ============================================
        // EFFECTS
        // ============================================
        uint256 amount = GRANT_AMOUNT;

        // Burn capability token (ERC-1155)
        _burn(account, capabilityId, amount);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit CapabilityRevoked(account, capabilityId, amount);
    }

    /**
     * @notice Grant multiple capabilities to account in single transaction
     * @dev Efficiently grants multiple capabilities using batch operations.
     *      Emits CapabilityGranted event for each capability.
     * @param account Recipient address
     * @param capabilityIds Array of capability IDs to grant
     * @custom:security Only owner can call
     * @custom:security Zero address check prevents invalid grants
     * @custom:emits CapabilityGranted for each capability
     */
    function batchGrantCapabilities(address account, uint256[] calldata capabilityIds) external onlyOwner {
        // ============================================
        // CHECKS
        // ============================================
        if (account == address(0)) revert ZeroAddress();

        uint256 length = capabilityIds.length;

        // Prepare amounts array (all 1s)
        uint256[] memory amounts = new uint256[](length);
        for (uint256 i = 0; i < length;) {
            amounts[i] = GRANT_AMOUNT;
            unchecked {
                ++i;
            }
        }

        // ============================================
        // EFFECTS
        // ============================================
        // Batch mint capability tokens (ERC-1155)
        _mintBatch(account, capabilityIds, amounts, "");

        // ============================================
        // INTERACTIONS
        // ============================================
        // Emit event for each capability
        for (uint256 i = 0; i < length;) {
            emit CapabilityGranted(account, capabilityIds[i], GRANT_AMOUNT);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Revoke multiple capabilities from account in single transaction
     * @dev Efficiently revokes multiple capabilities using batch operations.
     *      Emits CapabilityRevoked event for each capability.
     * @param account Account to revoke from
     * @param capabilityIds Array of capability IDs to revoke
     * @custom:security Only owner can call
     * @custom:emits CapabilityRevoked for each capability
     */
    function batchRevokeCapabilities(address account, uint256[] calldata capabilityIds) external onlyOwner {
        uint256 length = capabilityIds.length;

        // Prepare amounts array (all 1s)
        uint256[] memory amounts = new uint256[](length);
        for (uint256 i = 0; i < length;) {
            amounts[i] = GRANT_AMOUNT;
            unchecked {
                ++i;
            }
        }

        // ============================================
        // EFFECTS
        // ============================================
        // Batch burn capability tokens (ERC-1155)
        _burnBatch(account, capabilityIds, amounts);

        // ============================================
        // INTERACTIONS
        // ============================================
        // Emit event for each capability
        for (uint256 i = 0; i < length;) {
            emit CapabilityRevoked(account, capabilityIds[i], GRANT_AMOUNT);
            unchecked {
                ++i;
            }
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if account has specific capability
     * @param account Address to check
     * @param capabilityId Capability ID to verify
     * @return bool True if account has capability (balance ≥ 1)
     * @custom:security View function, safe to call from any context
     */
    function hasCapability(address account, uint256 capabilityId) external view returns (bool) {
        return balanceOf(account, capabilityId) >= 1;
    }
}
