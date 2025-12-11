// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {IIdentityBadge} from "../../src/interfaces/IIdentityBadge.sol";

/**
 * @title IdentityBadgeTest
 * @notice Comprehensive test suite for IdentityBadge (Soulbound ERC-5192)
 * @dev Tests cover grant, revoke, soulbound properties, and access control
 */
contract IdentityBadgeTest is Test {
    // ============================================
    // STATE VARIABLES
    // ============================================

    IdentityBadge public identityBadge;

    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // Badge IDs (from CLAUDE.md)
    uint256 public constant BADGE_KYC_L1 = 1;
    uint256 public constant BADGE_KYC_L2 = 2;
    uint256 public constant BADGE_KYC_L3 = 3;
    uint256 public constant BADGE_MANUFACTURER = 10;
    uint256 public constant BADGE_RETAILER = 11;
    uint256 public constant BADGE_GOV_MIL = 20;
    uint256 public constant BADGE_LAW_ENFORCEMENT = 21;

    // ============================================
    // EVENTS (for testing)
    // ============================================

    event IdentityGranted(address indexed account, uint256 indexed badgeId, uint256 tokenId);
    event IdentityRevoked(address indexed account, uint256 indexed badgeId, uint256 tokenId);
    event Locked(uint256 tokenId, bool locked);

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        identityBadge = new IdentityBadge();
    }

    // ============================================
    // GRANT IDENTITY TESTS
    // ============================================

    /**
     * @notice Test successful identity grant
     * @dev Should mint NFT, emit events, mark as soulbound
     */
    function test_grantIdentity_success() public {
        // Grant KYC_L1 to user1
        uint256 tokenId = identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Verify token was minted
        assertEq(tokenId, 1, "First token ID should be 1");
        assertEq(identityBadge.ownerOf(tokenId), user1, "Token owner should be user1");

        // Verify identity badge mapping
        assertTrue(identityBadge.hasIdentity(user1, BADGE_KYC_L1), "User should have KYC_L1");
        assertEq(identityBadge.getTokenId(user1, BADGE_KYC_L1), tokenId, "Token ID should match");

        // Verify soulbound (locked)
        assertTrue(identityBadge.locked(tokenId), "Token should be locked (soulbound)");
    }

    /**
     * @notice Test granting multiple badges to same user
     * @dev User can have multiple identity badges
     */
    function test_grantIdentity_multipleBadges() public {
        // Grant multiple badges to user1
        uint256 tokenId1 = identityBadge.grantIdentity(user1, BADGE_KYC_L1);
        uint256 tokenId2 = identityBadge.grantIdentity(user1, BADGE_MANUFACTURER);

        // Verify both badges exist
        assertTrue(identityBadge.hasIdentity(user1, BADGE_KYC_L1), "Should have KYC_L1");
        assertTrue(identityBadge.hasIdentity(user1, BADGE_MANUFACTURER), "Should have MANUFACTURER");

        // Verify different token IDs
        assertEq(tokenId1, 1, "First token ID");
        assertEq(tokenId2, 2, "Second token ID");
    }

    /**
     * @notice Test grant reverts when caller is not owner
     * @dev Only contract owner can grant badges
     */
    function test_grantIdentity_revert_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        identityBadge.grantIdentity(user1, BADGE_KYC_L1);
    }

    /**
     * @notice Test grant reverts when badge already granted
     * @dev Cannot grant same badge twice to same account
     */
    function test_grantIdentity_revert_alreadyGranted() public {
        // Grant badge first time
        identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Try to grant same badge again
        vm.expectRevert(
            abi.encodeWithSelector(IIdentityBadge.BadgeAlreadyGranted.selector, user1, BADGE_KYC_L1)
        );
        identityBadge.grantIdentity(user1, BADGE_KYC_L1);
    }

    /**
     * @notice Test grant reverts on zero address
     * @dev Cannot grant badge to zero address
     */
    function test_grantIdentity_revert_zeroAddress() public {
        vm.expectRevert(IIdentityBadge.ZeroAddress.selector);
        identityBadge.grantIdentity(address(0), BADGE_KYC_L1);
    }

    /**
     * @notice Test grant reverts on invalid badge ID
     * @dev Cannot grant badge with ID 0
     */
    function test_grantIdentity_revert_invalidBadgeId() public {
        vm.expectRevert(IIdentityBadge.InvalidBadgeId.selector);
        identityBadge.grantIdentity(user1, 0);
    }

    /**
     * @notice Test grant emits correct events
     * @dev Should emit IdentityGranted and Locked events
     */
    function test_grantIdentity_emitsEvents() public {
        // Expect IdentityGranted event
        vm.expectEmit(true, true, false, true);
        emit IdentityGranted(user1, BADGE_KYC_L1, 1);

        // Expect Locked event (ERC-5192)
        vm.expectEmit(false, false, false, true);
        emit Locked(1, true);

        identityBadge.grantIdentity(user1, BADGE_KYC_L1);
    }

    // ============================================
    // REVOKE IDENTITY TESTS
    // ============================================

    /**
     * @notice Test successful identity revoke
     * @dev Should burn NFT, emit event, update mappings
     */
    function test_revokeIdentity_success() public {
        // Grant badge first
        uint256 tokenId = identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Revoke badge
        identityBadge.revokeIdentity(user1, BADGE_KYC_L1);

        // Verify badge removed
        assertFalse(identityBadge.hasIdentity(user1, BADGE_KYC_L1), "User should not have badge");
        assertEq(identityBadge.getTokenId(user1, BADGE_KYC_L1), 0, "Token ID should be 0");

        // Verify NFT burned (should revert on ownerOf)
        vm.expectRevert();
        identityBadge.ownerOf(tokenId);
    }

    /**
     * @notice Test revoke when caller is not owner
     * @dev Only contract owner can revoke badges
     */
    function test_revokeIdentity_revert_notOwner() public {
        // Grant badge first
        identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Try to revoke as unauthorized
        vm.prank(unauthorized);
        vm.expectRevert();
        identityBadge.revokeIdentity(user1, BADGE_KYC_L1);
    }

    /**
     * @notice Test revoke reverts when badge not found
     * @dev Cannot revoke badge that was never granted
     */
    function test_revokeIdentity_revert_notFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(IIdentityBadge.BadgeNotFound.selector, user1, BADGE_KYC_L1)
        );
        identityBadge.revokeIdentity(user1, BADGE_KYC_L1);
    }

    /**
     * @notice Test revoke emits event
     * @dev Should emit IdentityRevoked event
     */
    function test_revokeIdentity_emitsEvent() public {
        // Grant badge first
        uint256 tokenId = identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Expect IdentityRevoked event
        vm.expectEmit(true, true, false, true);
        emit IdentityRevoked(user1, BADGE_KYC_L1, tokenId);

        identityBadge.revokeIdentity(user1, BADGE_KYC_L1);
    }

    // ============================================
    // HAS IDENTITY TESTS
    // ============================================

    /**
     * @notice Test hasIdentity returns correctly
     * @dev Should return true for granted badges, false otherwise
     */
    function test_hasIdentity_returnsCorrectly() public {
        // Initially false
        assertFalse(identityBadge.hasIdentity(user1, BADGE_KYC_L1), "Should not have badge initially");

        // Grant badge
        identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Now true
        assertTrue(identityBadge.hasIdentity(user1, BADGE_KYC_L1), "Should have badge after grant");

        // Revoke badge
        identityBadge.revokeIdentity(user1, BADGE_KYC_L1);

        // False again
        assertFalse(identityBadge.hasIdentity(user1, BADGE_KYC_L1), "Should not have badge after revoke");
    }

    // ============================================
    // SOULBOUND (ERC-5192) TESTS
    // ============================================

    /**
     * @notice Test locked() always returns true
     * @dev CRITICAL: All identity badges are soulbound (locked)
     */
    function test_locked_alwaysReturnsTrue() public {
        // Grant badge
        uint256 tokenId = identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Verify locked
        assertTrue(identityBadge.locked(tokenId), "Token must be locked (soulbound)");
    }

    /**
     * @notice Test transfer reverts
     * @dev CRITICAL: Soulbound tokens cannot be transferred
     */
    function test_transfer_reverts() public {
        // Grant badge
        uint256 tokenId = identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Try to transfer (should revert with BadgeLocked)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IIdentityBadge.BadgeLocked.selector, tokenId));
        identityBadge.transferFrom(user1, user2, tokenId);
    }

    /**
     * @notice Test safeTransferFrom reverts
     * @dev CRITICAL: Soulbound tokens cannot be transferred (safe version)
     */
    function test_safeTransferFrom_reverts() public {
        // Grant badge
        uint256 tokenId = identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Try to safe transfer (should revert with BadgeLocked)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IIdentityBadge.BadgeLocked.selector, tokenId));
        identityBadge.safeTransferFrom(user1, user2, tokenId);
    }

    /**
     * @notice Test approve reverts
     * @dev CRITICAL: Cannot approve transfers for soulbound tokens
     */
    function test_approve_reverts() public {
        // Grant badge
        uint256 tokenId = identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Try to approve (should revert with BadgeLocked)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IIdentityBadge.BadgeLocked.selector, tokenId));
        identityBadge.approve(user2, tokenId);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    /**
     * @notice Fuzz test: grant identity with random addresses and badge IDs
     * @dev Should succeed for any valid address and badge ID
     */
    function testFuzz_grantIdentity(address account, uint256 badgeId) public {
        // Assume valid parameters
        vm.assume(account != address(0));
        vm.assume(account.code.length == 0);
        // Bound badgeId to reasonable range to avoid too many rejections
        badgeId = bound(badgeId, 1, 100);

        // Grant badge
        uint256 tokenId = identityBadge.grantIdentity(account, badgeId);

        // Verify
        assertTrue(identityBadge.hasIdentity(account, badgeId), "Should have badge");
        assertEq(identityBadge.ownerOf(tokenId), account, "Should own token");
        assertTrue(identityBadge.locked(tokenId), "Should be locked");
    }

    /**
     * @notice Fuzz test: grant and revoke cycle
     * @dev Should handle grant/revoke cycle correctly
     */
    function testFuzz_grantRevokeIdentity(address account, uint256 badgeId) public {
        // Assume valid parameters
        vm.assume(account != address(0));
        vm.assume(account.code.length == 0);
        // Bound badgeId to reasonable range to avoid too many rejections
        badgeId = bound(badgeId, 1, 100);

        // Grant badge
        identityBadge.grantIdentity(account, badgeId);
        assertTrue(identityBadge.hasIdentity(account, badgeId), "Should have badge");

        // Revoke badge
        identityBadge.revokeIdentity(account, badgeId);
        assertFalse(identityBadge.hasIdentity(account, badgeId), "Should not have badge");
    }
}
