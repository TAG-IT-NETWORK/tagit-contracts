// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ICapabilityBadge} from "../../src/interfaces/ICapabilityBadge.sol";

/**
 * @title CapabilityBadgeTest
 * @notice Comprehensive test suite for CapabilityBadge (Transferable ERC-1155)
 * @dev Tests cover grant, revoke, batch operations, and transferability
 */
contract CapabilityBadgeTest is Test {
    // ============================================
    // STATE VARIABLES
    // ============================================

    CapabilityBadge public capabilityBadge;

    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // Capability IDs (from CLAUDE.md)
    uint256 public constant CAP_MINT = 100;
    uint256 public constant CAP_BIND = 101;
    uint256 public constant CAP_ACTIVATE = 102;
    uint256 public constant CAP_CLAIM = 103;
    uint256 public constant CAP_FLAG = 104;
    uint256 public constant CAP_RECOVERY_INIT = 105;
    uint256 public constant CAP_RECOVERY_APPROVE = 106;
    uint256 public constant CAP_FREEZE = 107;
    uint256 public constant CAP_DAO_VOTE = 108;

    // ============================================
    // EVENTS (for testing)
    // ============================================

    event CapabilityGranted(address indexed account, uint256 indexed capabilityId, uint256 amount);
    event CapabilityRevoked(address indexed account, uint256 indexed capabilityId, uint256 amount);

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        capabilityBadge = new CapabilityBadge();
    }

    // ============================================
    // GRANT CAPABILITY TESTS
    // ============================================

    /**
     * @notice Test successful capability grant
     * @dev Should mint ERC-1155 token, balance = 1
     */
    function test_grantCapability_success() public {
        // Grant CAP_MINT to user1
        uint256 amount = capabilityBadge.grantCapability(user1, CAP_MINT);

        // Verify amount granted is 1
        assertEq(amount, 1, "Amount should be 1");

        // Verify capability granted
        assertTrue(capabilityBadge.hasCapability(user1, CAP_MINT), "User should have CAP_MINT");
        assertEq(capabilityBadge.balanceOf(user1, CAP_MINT), 1, "Balance should be 1");
    }

    /**
     * @notice Test granting multiple capabilities to same user
     * @dev User can have multiple capabilities
     */
    function test_grantCapability_multipleCapabilities() public {
        // Grant multiple capabilities to user1
        capabilityBadge.grantCapability(user1, CAP_MINT);
        capabilityBadge.grantCapability(user1, CAP_BIND);
        capabilityBadge.grantCapability(user1, CAP_ACTIVATE);

        // Verify all capabilities exist
        assertTrue(capabilityBadge.hasCapability(user1, CAP_MINT), "Should have CAP_MINT");
        assertTrue(capabilityBadge.hasCapability(user1, CAP_BIND), "Should have CAP_BIND");
        assertTrue(capabilityBadge.hasCapability(user1, CAP_ACTIVATE), "Should have CAP_ACTIVATE");
    }

    /**
     * @notice Test grant reverts when caller is not owner
     * @dev Only contract owner can grant capabilities
     */
    function test_grantCapability_revert_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        capabilityBadge.grantCapability(user1, CAP_MINT);
    }

    /**
     * @notice Test grant reverts on zero address
     * @dev Cannot grant capability to zero address
     */
    function test_grantCapability_revert_zeroAddress() public {
        vm.expectRevert(ICapabilityBadge.ZeroAddress.selector);
        capabilityBadge.grantCapability(address(0), CAP_MINT);
    }

    /**
     * @notice Test grant reverts on invalid capability ID
     * @dev Cannot grant capability with ID 0
     */
    function test_grantCapability_revert_invalidCapabilityId() public {
        vm.expectRevert(ICapabilityBadge.InvalidCapabilityId.selector);
        capabilityBadge.grantCapability(user1, 0);
    }

    /**
     * @notice Test grant emits correct event
     * @dev Should emit CapabilityGranted event
     */
    function test_grantCapability_emitsEvent() public {
        // Expect CapabilityGranted event
        vm.expectEmit(true, true, false, true);
        emit CapabilityGranted(user1, CAP_MINT, 1);

        capabilityBadge.grantCapability(user1, CAP_MINT);
    }

    /**
     * @notice Test granting same capability twice increases balance
     * @dev ERC-1155 allows multiple tokens of same ID
     */
    function test_grantCapability_twice() public {
        // Grant capability twice
        capabilityBadge.grantCapability(user1, CAP_MINT);
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Verify balance is 2
        assertEq(capabilityBadge.balanceOf(user1, CAP_MINT), 2, "Balance should be 2");
        assertTrue(capabilityBadge.hasCapability(user1, CAP_MINT), "Should still have capability");
    }

    // ============================================
    // REVOKE CAPABILITY TESTS
    // ============================================

    /**
     * @notice Test successful capability revoke
     * @dev Should burn ERC-1155 token, balance = 0
     */
    function test_revokeCapability_success() public {
        // Grant capability first
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Revoke capability
        capabilityBadge.revokeCapability(user1, CAP_MINT);

        // Verify capability removed
        assertFalse(capabilityBadge.hasCapability(user1, CAP_MINT), "User should not have capability");
        assertEq(capabilityBadge.balanceOf(user1, CAP_MINT), 0, "Balance should be 0");
    }

    /**
     * @notice Test revoke when caller is not owner
     * @dev Only contract owner can revoke capabilities
     */
    function test_revokeCapability_revert_notOwner() public {
        // Grant capability first
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Try to revoke as unauthorized
        vm.prank(unauthorized);
        vm.expectRevert();
        capabilityBadge.revokeCapability(user1, CAP_MINT);
    }

    /**
     * @notice Test revoke reverts when capability not found
     * @dev Cannot revoke capability that was never granted
     */
    function test_revokeCapability_revert_notFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(ICapabilityBadge.CapabilityNotFound.selector, user1, CAP_MINT)
        );
        capabilityBadge.revokeCapability(user1, CAP_MINT);
    }

    /**
     * @notice Test revoke emits event
     * @dev Should emit CapabilityRevoked event
     */
    function test_revokeCapability_emitsEvent() public {
        // Grant capability first
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Expect CapabilityRevoked event
        vm.expectEmit(true, true, false, true);
        emit CapabilityRevoked(user1, CAP_MINT, 1);

        capabilityBadge.revokeCapability(user1, CAP_MINT);
    }

    /**
     * @notice Test revoking when balance is 2 reduces to 1
     * @dev Should only revoke 1 token at a time
     */
    function test_revokeCapability_multipleBalance() public {
        // Grant capability twice
        capabilityBadge.grantCapability(user1, CAP_MINT);
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Revoke once
        capabilityBadge.revokeCapability(user1, CAP_MINT);

        // Verify balance is 1, still has capability
        assertEq(capabilityBadge.balanceOf(user1, CAP_MINT), 1, "Balance should be 1");
        assertTrue(capabilityBadge.hasCapability(user1, CAP_MINT), "Should still have capability");
    }

    // ============================================
    // BATCH GRANT TESTS
    // ============================================

    /**
     * @notice Test batch grant of multiple capabilities
     * @dev Should grant all capabilities in single transaction
     */
    function test_batchGrantCapabilities_success() public {
        // Prepare capability IDs
        uint256[] memory capIds = new uint256[](3);
        capIds[0] = CAP_MINT;
        capIds[1] = CAP_BIND;
        capIds[2] = CAP_ACTIVATE;

        // Batch grant
        capabilityBadge.batchGrantCapabilities(user1, capIds);

        // Verify all capabilities granted
        assertTrue(capabilityBadge.hasCapability(user1, CAP_MINT), "Should have CAP_MINT");
        assertTrue(capabilityBadge.hasCapability(user1, CAP_BIND), "Should have CAP_BIND");
        assertTrue(capabilityBadge.hasCapability(user1, CAP_ACTIVATE), "Should have CAP_ACTIVATE");
    }

    /**
     * @notice Test batch grant reverts when not owner
     */
    function test_batchGrantCapabilities_revert_notOwner() public {
        uint256[] memory capIds = new uint256[](1);
        capIds[0] = CAP_MINT;

        vm.prank(unauthorized);
        vm.expectRevert();
        capabilityBadge.batchGrantCapabilities(user1, capIds);
    }

    /**
     * @notice Test batch grant reverts on zero address
     */
    function test_batchGrantCapabilities_revert_zeroAddress() public {
        uint256[] memory capIds = new uint256[](1);
        capIds[0] = CAP_MINT;

        vm.expectRevert(ICapabilityBadge.ZeroAddress.selector);
        capabilityBadge.batchGrantCapabilities(address(0), capIds);
    }

    /**
     * @notice Test batch grant emits events for all capabilities
     */
    function test_batchGrantCapabilities_emitsEvents() public {
        uint256[] memory capIds = new uint256[](2);
        capIds[0] = CAP_MINT;
        capIds[1] = CAP_BIND;

        // Expect events for both capabilities
        vm.expectEmit(true, true, false, true);
        emit CapabilityGranted(user1, CAP_MINT, 1);
        vm.expectEmit(true, true, false, true);
        emit CapabilityGranted(user1, CAP_BIND, 1);

        capabilityBadge.batchGrantCapabilities(user1, capIds);
    }

    // ============================================
    // BATCH REVOKE TESTS
    // ============================================

    /**
     * @notice Test batch revoke of multiple capabilities
     * @dev Should revoke all capabilities in single transaction
     */
    function test_batchRevokeCapabilities_success() public {
        // Grant capabilities first
        uint256[] memory capIds = new uint256[](3);
        capIds[0] = CAP_MINT;
        capIds[1] = CAP_BIND;
        capIds[2] = CAP_ACTIVATE;

        capabilityBadge.batchGrantCapabilities(user1, capIds);

        // Batch revoke
        capabilityBadge.batchRevokeCapabilities(user1, capIds);

        // Verify all capabilities removed
        assertFalse(capabilityBadge.hasCapability(user1, CAP_MINT), "Should not have CAP_MINT");
        assertFalse(capabilityBadge.hasCapability(user1, CAP_BIND), "Should not have CAP_BIND");
        assertFalse(capabilityBadge.hasCapability(user1, CAP_ACTIVATE), "Should not have CAP_ACTIVATE");
    }

    /**
     * @notice Test batch revoke reverts when not owner
     */
    function test_batchRevokeCapabilities_revert_notOwner() public {
        uint256[] memory capIds = new uint256[](1);
        capIds[0] = CAP_MINT;

        capabilityBadge.grantCapability(user1, CAP_MINT);

        vm.prank(unauthorized);
        vm.expectRevert();
        capabilityBadge.batchRevokeCapabilities(user1, capIds);
    }

    /**
     * @notice Test batch revoke emits events for all capabilities
     */
    function test_batchRevokeCapabilities_emitsEvents() public {
        // Grant first
        uint256[] memory capIds = new uint256[](2);
        capIds[0] = CAP_MINT;
        capIds[1] = CAP_BIND;
        capabilityBadge.batchGrantCapabilities(user1, capIds);

        // Expect events for both revocations
        vm.expectEmit(true, true, false, true);
        emit CapabilityRevoked(user1, CAP_MINT, 1);
        vm.expectEmit(true, true, false, true);
        emit CapabilityRevoked(user1, CAP_BIND, 1);

        capabilityBadge.batchRevokeCapabilities(user1, capIds);
    }

    // ============================================
    // HAS CAPABILITY TESTS
    // ============================================

    /**
     * @notice Test hasCapability returns correctly
     * @dev Should return true for granted capabilities, false otherwise
     */
    function test_hasCapability_returnsCorrectly() public {
        // Initially false
        assertFalse(capabilityBadge.hasCapability(user1, CAP_MINT), "Should not have capability initially");

        // Grant capability
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Now true
        assertTrue(capabilityBadge.hasCapability(user1, CAP_MINT), "Should have capability after grant");

        // Revoke capability
        capabilityBadge.revokeCapability(user1, CAP_MINT);

        // False again
        assertFalse(capabilityBadge.hasCapability(user1, CAP_MINT), "Should not have capability after revoke");
    }

    // ============================================
    // TRANSFERABILITY TESTS (Unlike IdentityBadge)
    // ============================================

    /**
     * @notice Test capability CAN be transferred
     * @dev CRITICAL: Unlike identity badges, capability badges are transferable
     */
    function test_transfer_success() public {
        // Grant capability to user1
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Transfer from user1 to user2
        vm.prank(user1);
        capabilityBadge.safeTransferFrom(user1, user2, CAP_MINT, 1, "");

        // Verify transfer successful
        assertFalse(capabilityBadge.hasCapability(user1, CAP_MINT), "User1 should not have capability");
        assertTrue(capabilityBadge.hasCapability(user2, CAP_MINT), "User2 should have capability");
        assertEq(capabilityBadge.balanceOf(user1, CAP_MINT), 0, "User1 balance should be 0");
        assertEq(capabilityBadge.balanceOf(user2, CAP_MINT), 1, "User2 balance should be 1");
    }

    /**
     * @notice Test batch transfer of multiple capabilities
     */
    function test_batchTransfer_success() public {
        // Grant multiple capabilities to user1
        capabilityBadge.grantCapability(user1, CAP_MINT);
        capabilityBadge.grantCapability(user1, CAP_BIND);

        // Prepare batch transfer
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = CAP_MINT;
        ids[1] = CAP_BIND;
        amounts[0] = 1;
        amounts[1] = 1;

        // Batch transfer
        vm.prank(user1);
        capabilityBadge.safeBatchTransferFrom(user1, user2, ids, amounts, "");

        // Verify both capabilities transferred
        assertFalse(capabilityBadge.hasCapability(user1, CAP_MINT), "User1 should not have CAP_MINT");
        assertFalse(capabilityBadge.hasCapability(user1, CAP_BIND), "User1 should not have CAP_BIND");
        assertTrue(capabilityBadge.hasCapability(user2, CAP_MINT), "User2 should have CAP_MINT");
        assertTrue(capabilityBadge.hasCapability(user2, CAP_BIND), "User2 should have CAP_BIND");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    /**
     * @notice Fuzz test: grant capability with random addresses and capability IDs
     * @dev Should succeed for any valid address and capability ID
     */
    function testFuzz_grantCapability(address account, uint256 capabilityId) public {
        // Assume valid parameters
        vm.assume(account != address(0));
        vm.assume(account.code.length == 0);
        // Bound capabilityId to reasonable range
        capabilityId = bound(capabilityId, 1, 200);

        // Grant capability
        uint256 amount = capabilityBadge.grantCapability(account, capabilityId);

        // Verify
        assertEq(amount, 1, "Amount should be 1");
        assertTrue(capabilityBadge.hasCapability(account, capabilityId), "Should have capability");
        assertEq(capabilityBadge.balanceOf(account, capabilityId), 1, "Balance should be 1");
    }

    /**
     * @notice Fuzz test: grant and revoke cycle
     * @dev Should handle grant/revoke cycle correctly
     */
    function testFuzz_grantRevokeCapability(address account, uint256 capabilityId) public {
        // Assume valid parameters
        vm.assume(account != address(0));
        vm.assume(account.code.length == 0);
        // Bound capabilityId to reasonable range
        capabilityId = bound(capabilityId, 1, 200);

        // Grant capability
        capabilityBadge.grantCapability(account, capabilityId);
        assertTrue(capabilityBadge.hasCapability(account, capabilityId), "Should have capability");

        // Revoke capability
        capabilityBadge.revokeCapability(account, capabilityId);
        assertFalse(capabilityBadge.hasCapability(account, capabilityId), "Should not have capability");
    }
}
