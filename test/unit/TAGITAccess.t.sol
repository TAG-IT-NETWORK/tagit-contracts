// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ITAGITAccess} from "../../src/interfaces/ITAGITAccess.sol";

/**
 * @title TAGITAccessTest
 * @notice Comprehensive test suite for TAGITAccess (BIDGES Controller)
 * @dev Tests cover badge management, delegation, and access control enforcement
 */
contract TAGITAccessTest is Test {
    // ============================================
    // STATE VARIABLES
    // ============================================

    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // Test badge/capability IDs
    uint256 public constant BADGE_KYC_L1 = 1;
    uint256 public constant BADGE_MANUFACTURER = 10;
    uint256 public constant CAP_MINT = 100;
    uint256 public constant CAP_BIND = 101;

    // ============================================
    // EVENTS (for testing)
    // ============================================

    event IdentityBadgeUpdated(address indexed previousBadge, address indexed newBadge);
    event CapabilityBadgeUpdated(address indexed previousBadge, address indexed newBadge);

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        // Deploy badge contracts
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();

        // Deploy TAGITAccess
        tagitAccess = new TAGITAccess();
    }

    // ============================================
    // SET IDENTITY BADGE TESTS
    // ============================================

    /**
     * @notice Test successful identity badge contract update
     */
    function test_setIdentityBadge_success() public {
        // Set identity badge contract
        tagitAccess.setIdentityBadge(address(identityBadge));

        // Verify stored address
        assertEq(tagitAccess.identityBadge(), address(identityBadge), "Identity badge should be set");
    }

    /**
     * @notice Test setIdentityBadge reverts when not owner
     */
    function test_setIdentityBadge_revert_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        tagitAccess.setIdentityBadge(address(identityBadge));
    }

    /**
     * @notice Test setIdentityBadge reverts on zero address
     */
    function test_setIdentityBadge_revert_zeroAddress() public {
        vm.expectRevert(ITAGITAccess.InvalidBadgeContract.selector);
        tagitAccess.setIdentityBadge(address(0));
    }

    /**
     * @notice Test setIdentityBadge emits event
     */
    function test_setIdentityBadge_emitsEvent() public {
        // Expect event
        vm.expectEmit(true, true, false, false);
        emit IdentityBadgeUpdated(address(0), address(identityBadge));

        tagitAccess.setIdentityBadge(address(identityBadge));
    }

    // ============================================
    // SET CAPABILITY BADGE TESTS
    // ============================================

    /**
     * @notice Test successful capability badge contract update
     */
    function test_setCapabilityBadge_success() public {
        // Set capability badge contract
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Verify stored address
        assertEq(tagitAccess.capabilityBadge(), address(capabilityBadge), "Capability badge should be set");
    }

    /**
     * @notice Test setCapabilityBadge reverts when not owner
     */
    function test_setCapabilityBadge_revert_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        tagitAccess.setCapabilityBadge(address(capabilityBadge));
    }

    /**
     * @notice Test setCapabilityBadge reverts on zero address
     */
    function test_setCapabilityBadge_revert_zeroAddress() public {
        vm.expectRevert(ITAGITAccess.InvalidBadgeContract.selector);
        tagitAccess.setCapabilityBadge(address(0));
    }

    /**
     * @notice Test setCapabilityBadge emits event
     */
    function test_setCapabilityBadge_emitsEvent() public {
        // Expect event
        vm.expectEmit(true, true, false, false);
        emit CapabilityBadgeUpdated(address(0), address(capabilityBadge));

        tagitAccess.setCapabilityBadge(address(capabilityBadge));
    }

    // ============================================
    // HAS CAPABILITY TESTS (Delegation)
    // ============================================

    /**
     * @notice Test hasCapability correctly delegates to CapabilityBadge
     */
    function test_hasCapability_delegatesToBadge() public {
        // Setup: Set capability badge contract
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Initially false
        assertFalse(tagitAccess.hasCapability(user1, CAP_MINT), "Should not have capability initially");

        // Grant capability via badge contract
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Now should return true via delegation
        assertTrue(tagitAccess.hasCapability(user1, CAP_MINT), "Should have capability after grant");
    }

    /**
     * @notice Test hasCapability returns false when badge not set
     */
    function test_hasCapability_returnsFalseWhenNotSet() public {
        // Badge contract not set, should return false
        assertFalse(tagitAccess.hasCapability(user1, CAP_MINT), "Should return false when badge not set");
    }

    // ============================================
    // HAS IDENTITY TESTS (Delegation)
    // ============================================

    /**
     * @notice Test hasIdentity correctly delegates to IdentityBadge
     */
    function test_hasIdentity_delegatesToBadge() public {
        // Setup: Set identity badge contract
        tagitAccess.setIdentityBadge(address(identityBadge));

        // Initially false
        assertFalse(tagitAccess.hasIdentity(user1, BADGE_KYC_L1), "Should not have identity initially");

        // Grant identity via badge contract
        identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Now should return true via delegation
        assertTrue(tagitAccess.hasIdentity(user1, BADGE_KYC_L1), "Should have identity after grant");
    }

    /**
     * @notice Test hasIdentity returns false when badge not set
     */
    function test_hasIdentity_returnsFalseWhenNotSet() public {
        // Badge contract not set, should return false
        assertFalse(tagitAccess.hasIdentity(user1, BADGE_KYC_L1), "Should return false when badge not set");
    }

    // ============================================
    // REQUIRE CAPABILITY TESTS
    // ============================================

    /**
     * @notice Test requireCapability succeeds when capability exists
     */
    function test_requireCapability_success() public {
        // Setup
        tagitAccess.setCapabilityBadge(address(capabilityBadge));
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Should not revert
        tagitAccess.requireCapability(user1, CAP_MINT);
    }

    /**
     * @notice Test requireCapability reverts when capability missing
     */
    function test_requireCapability_revert_missing() public {
        // Setup
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Should revert with MissingCapability
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingCapability.selector, user1, CAP_MINT));
        tagitAccess.requireCapability(user1, CAP_MINT);
    }

    /**
     * @notice Test requireCapability reverts when badge not set
     */
    function test_requireCapability_revert_badgeNotSet() public {
        // Badge contract not set
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingCapability.selector, user1, CAP_MINT));
        tagitAccess.requireCapability(user1, CAP_MINT);
    }

    // ============================================
    // REQUIRE IDENTITY TESTS
    // ============================================

    /**
     * @notice Test requireIdentity succeeds when identity exists
     */
    function test_requireIdentity_success() public {
        // Setup
        tagitAccess.setIdentityBadge(address(identityBadge));
        identityBadge.grantIdentity(user1, BADGE_KYC_L1);

        // Should not revert
        tagitAccess.requireIdentity(user1, BADGE_KYC_L1);
    }

    /**
     * @notice Test requireIdentity reverts when identity missing
     */
    function test_requireIdentity_revert_missing() public {
        // Setup
        tagitAccess.setIdentityBadge(address(identityBadge));

        // Should revert with MissingIdentity
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingIdentity.selector, user1, BADGE_KYC_L1));
        tagitAccess.requireIdentity(user1, BADGE_KYC_L1);
    }

    /**
     * @notice Test requireIdentity reverts when badge not set
     */
    function test_requireIdentity_revert_badgeNotSet() public {
        // Badge contract not set
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingIdentity.selector, user1, BADGE_KYC_L1));
        tagitAccess.requireIdentity(user1, BADGE_KYC_L1);
    }

    // ============================================
    // INTEGRATION TESTS
    // ============================================

    /**
     * @notice Test full BIDGES workflow
     * @dev Grant both identity and capability, verify both checks work
     */
    function test_fullBIDGESWorkflow() public {
        // Setup both badge contracts
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Grant identity and capability
        identityBadge.grantIdentity(user1, BADGE_MANUFACTURER);
        capabilityBadge.grantCapability(user1, CAP_MINT);

        // Verify both checks pass
        assertTrue(tagitAccess.hasIdentity(user1, BADGE_MANUFACTURER), "Should have identity");
        assertTrue(tagitAccess.hasCapability(user1, CAP_MINT), "Should have capability");

        // Verify require functions don't revert
        tagitAccess.requireIdentity(user1, BADGE_MANUFACTURER);
        tagitAccess.requireCapability(user1, CAP_MINT);
    }

    /**
     * @notice Test updating badge contracts
     */
    function test_updateBadgeContracts() public {
        // Set initial contracts
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Deploy new contracts
        IdentityBadge newIdentityBadge = new IdentityBadge();
        CapabilityBadge newCapabilityBadge = new CapabilityBadge();

        // Update to new contracts
        vm.expectEmit(true, true, false, false);
        emit IdentityBadgeUpdated(address(identityBadge), address(newIdentityBadge));
        tagitAccess.setIdentityBadge(address(newIdentityBadge));

        vm.expectEmit(true, true, false, false);
        emit CapabilityBadgeUpdated(address(capabilityBadge), address(newCapabilityBadge));
        tagitAccess.setCapabilityBadge(address(newCapabilityBadge));

        // Verify updated
        assertEq(tagitAccess.identityBadge(), address(newIdentityBadge), "Identity badge should be updated");
        assertEq(tagitAccess.capabilityBadge(), address(newCapabilityBadge), "Capability badge should be updated");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    /**
     * @notice Fuzz test: access control with random accounts and IDs
     */
    function testFuzz_accessControl(address account, uint256 identityId, uint256 capabilityId) public {
        // Assume valid parameters
        vm.assume(account != address(0));
        vm.assume(account.code.length == 0);
        identityId = bound(identityId, 1, 100);
        capabilityId = bound(capabilityId, 1, 200);

        // Setup
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Initially should not have either
        assertFalse(tagitAccess.hasIdentity(account, identityId), "Should not have identity initially");
        assertFalse(tagitAccess.hasCapability(account, capabilityId), "Should not have capability initially");

        // Grant both
        identityBadge.grantIdentity(account, identityId);
        capabilityBadge.grantCapability(account, capabilityId);

        // Now should have both
        assertTrue(tagitAccess.hasIdentity(account, identityId), "Should have identity after grant");
        assertTrue(tagitAccess.hasCapability(account, capabilityId), "Should have capability after grant");

        // Require functions should succeed
        tagitAccess.requireIdentity(account, identityId);
        tagitAccess.requireCapability(account, capabilityId);
    }
}
