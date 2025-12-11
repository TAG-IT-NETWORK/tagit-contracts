// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {IIdentityBadge} from "../interfaces/IIdentityBadge.sol";
import {ICapabilityBadge} from "../interfaces/ICapabilityBadge.sol";

/**
 * @title TAGITAccess
 * @author TAG IT Network <dev@tagit.network>
 * @notice Facade controller for BIDGES access control system
 * @dev Combines IdentityBadge and CapabilityBadge into unified access control interface
 *
 * BIDGES = Badge-based Identity & Delegation with Granular Execution Security
 *
 * Architecture:
 * - Facade Pattern: Provides unified interface for identity + capability checks
 * - Delegation Pattern: Delegates to underlying badge contracts
 * - Separation of Concerns: Identity (WHO) vs Capability (WHAT)
 *
 * Components:
 * - IdentityBadge: Soulbound ERC-721 tokens (who you are)
 * - CapabilityBadge: Transferable ERC-1155 tokens (what you can do)
 *
 * Usage:
 * 1. Deploy IdentityBadge and CapabilityBadge contracts
 * 2. Set badge contract addresses via setIdentityBadge() and setCapabilityBadge()
 * 3. Grant badges via underlying badge contracts
 * 4. Use this contract for all access control checks
 *
 * Security:
 * - Zero-trust: Returns false if badge contracts not set
 * - Owner-only admin functions
 * - Custom errors for gas efficiency
 * - Events for all state changes
 */
contract TAGITAccess is Ownable, ITAGITAccess {
    // ============================================
    // STORAGE
    // ============================================

    /// @notice Identity badge contract (ERC-5192 soulbound)
    address private _identityBadge;

    /// @notice Capability badge contract (ERC-1155 transferable)
    address private _capabilityBadge;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize TAGITAccess contract
     * @dev Sets owner, badge contracts can be set later
     */
    constructor() Ownable(msg.sender) {
        // Badge contracts start as address(0), can be set later
    }

    // ============================================
    // ADMIN FUNCTIONS (OWNER ONLY)
    // ============================================

    /**
     * @notice Set the identity badge contract address
     * @dev Only owner can update. Emits IdentityBadgeUpdated event.
     * @param badge Address of the identity badge contract (ERC-5192)
     * @custom:security Only owner can call
     * @custom:security Reverts on zero address
     * @custom:emits IdentityBadgeUpdated
     */
    function setIdentityBadge(address badge) external onlyOwner {
        // ============================================
        // CHECKS
        // ============================================
        if (badge == address(0)) revert InvalidBadgeContract();

        // ============================================
        // EFFECTS
        // ============================================
        address previousBadge = _identityBadge;
        _identityBadge = badge;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit IdentityBadgeUpdated(previousBadge, badge);
    }

    /**
     * @notice Set the capability badge contract address
     * @dev Only owner can update. Emits CapabilityBadgeUpdated event.
     * @param badge Address of the capability badge contract (ERC-1155)
     * @custom:security Only owner can call
     * @custom:security Reverts on zero address
     * @custom:emits CapabilityBadgeUpdated
     */
    function setCapabilityBadge(address badge) external onlyOwner {
        // ============================================
        // CHECKS
        // ============================================
        if (badge == address(0)) revert InvalidBadgeContract();

        // ============================================
        // EFFECTS
        // ============================================
        address previousBadge = _capabilityBadge;
        _capabilityBadge = badge;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit CapabilityBadgeUpdated(previousBadge, badge);
    }

    // ============================================
    // CAPABILITY CHECKS (DELEGATION)
    // ============================================

    /**
     * @notice Check if account has specific capability
     * @dev Delegates to CapabilityBadge contract. Returns false if badge not set.
     * @param account Address to check
     * @param capabilityId Capability ID to verify
     * @return bool True if account has capability
     * @custom:security View function, safe to call from any context
     * @custom:security Returns false if capability badge not set (zero-trust)
     */
    function hasCapability(address account, uint256 capabilityId)
        external
        view
        returns (bool)
    {
        // Zero-trust: Return false if badge contract not set
        if (_capabilityBadge == address(0)) return false;

        // Delegate to CapabilityBadge contract
        return ICapabilityBadge(_capabilityBadge).hasCapability(account, capabilityId);
    }

    /**
     * @notice Require account to have specific capability (reverts if not)
     * @dev Checks via delegation, reverts with MissingCapability if check fails.
     * @param account Address to check
     * @param capabilityId Capability ID to require
     * @custom:security Reverts with MissingCapability if check fails
     * @custom:security Reverts if capability badge not set
     */
    function requireCapability(address account, uint256 capabilityId) external view {
        // Check via delegation (handles both "not set" and "not granted" cases)
        if (!this.hasCapability(account, capabilityId)) {
            revert MissingCapability(account, capabilityId);
        }
    }

    // ============================================
    // IDENTITY CHECKS (DELEGATION)
    // ============================================

    /**
     * @notice Check if account has specific identity badge
     * @dev Delegates to IdentityBadge contract. Returns false if badge not set.
     * @param account Address to check
     * @param identityId Identity badge ID to verify
     * @return bool True if account has identity badge
     * @custom:security View function, safe to call from any context
     * @custom:security Returns false if identity badge not set (zero-trust)
     */
    function hasIdentity(address account, uint256 identityId)
        external
        view
        returns (bool)
    {
        // Zero-trust: Return false if badge contract not set
        if (_identityBadge == address(0)) return false;

        // Delegate to IdentityBadge contract
        return IIdentityBadge(_identityBadge).hasIdentity(account, identityId);
    }

    /**
     * @notice Require account to have specific identity badge (reverts if not)
     * @dev Checks via delegation, reverts with MissingIdentity if check fails.
     * @param account Address to check
     * @param identityId Identity badge ID to require
     * @custom:security Reverts with MissingIdentity if check fails
     * @custom:security Reverts if identity badge not set
     */
    function requireIdentity(address account, uint256 identityId) external view {
        // Check via delegation (handles both "not set" and "not granted" cases)
        if (!this.hasIdentity(account, identityId)) {
            revert MissingIdentity(account, identityId);
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the identity badge contract address
     * @return Address of identity badge contract
     */
    function identityBadge() external view returns (address) {
        return _identityBadge;
    }

    /**
     * @notice Get the capability badge contract address
     * @return Address of capability badge contract
     */
    function capabilityBadge() external view returns (address) {
        return _capabilityBadge;
    }
}
