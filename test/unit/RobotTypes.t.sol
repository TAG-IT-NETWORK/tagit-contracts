// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {
    SafetyClass,
    RobotActionPolicy,
    ACTION_SCAN,
    ACTION_MANIPULATE,
    ACTION_TRANSPORT,
    ACTION_INSPECT,
    ACTION_CLASSIFIED,
    BADGE_CHEF_BOT,
    BADGE_WAREHOUSE_OP,
    BADGE_INSPECTOR_BOT,
    BADGE_FACTORY_ARM,
    BADGE_SECURITY_BOT,
    BADGE_MEDICAL_BOT,
    CAP_ROBOT_SCAN,
    CAP_ROBOT_MANIPULATE,
    CAP_ROBOT_TRANSPORT,
    CAP_ROBOT_INSPECT,
    CAP_ROBOT_CLASSIFIED,
    BADGE_MANUFACTURER,
    BADGE_GOV_MIL
} from "../../src/libraries/RobotTypes.sol";

/**
 * @title RobotTypesTest
 * @notice Tests for ROB-T02 (struct/enum), ROB-T03 (identity badges), ROB-T04 (capabilities)
 * @dev Validates type definitions, badge issuance gating, and capability grants
 */
contract RobotTypesTest is Test {
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;
    TAGITAccess public tagitAccess;

    address public owner;
    address public manufacturer;
    address public govMil;
    address public robot1;
    address public robot2;
    address public unauthorized;

    function setUp() public {
        owner = address(this);
        manufacturer = makeAddr("manufacturer");
        govMil = makeAddr("govMil");
        robot1 = makeAddr("robot1");
        robot2 = makeAddr("robot2");
        unauthorized = makeAddr("unauthorized");

        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();

        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Grant manufacturer and gov/mil badges to issuers
        identityBadge.grantIdentity(manufacturer, BADGE_MANUFACTURER);
        identityBadge.grantIdentity(govMil, BADGE_GOV_MIL);
    }

    // ============================================
    // ROB-T02: STRUCT + ENUM DEFINITIONS
    // ============================================

    function test_safetyClass_values() public pure {
        assertEq(uint256(SafetyClass.STANDARD), 0);
        assertEq(uint256(SafetyClass.ELEVATED), 1);
        assertEq(uint256(SafetyClass.RESTRICTED), 2);
        assertEq(uint256(SafetyClass.CLASSIFIED), 3);
    }

    function test_actionBitmask_values() public pure {
        assertEq(ACTION_SCAN, 1);
        assertEq(ACTION_MANIPULATE, 2);
        assertEq(ACTION_TRANSPORT, 4);
        assertEq(ACTION_INSPECT, 8);
        assertEq(ACTION_CLASSIFIED, 16);
    }

    function test_actionBitmask_noOverlap() public pure {
        // Each action must be a unique power of 2
        uint256 all = ACTION_SCAN | ACTION_MANIPULATE | ACTION_TRANSPORT | ACTION_INSPECT | ACTION_CLASSIFIED;
        assertEq(all, 31); // 0x1F = 0b11111
    }

    function test_robotActionPolicy_construction() public pure {
        bytes32[] memory roles = new bytes32[](1);
        roles[0] = keccak256("WAREHOUSE");

        RobotActionPolicy memory policy = RobotActionPolicy({
            objectId: 42,
            safetyClass: SafetyClass.ELEVATED,
            allowedActions: ACTION_SCAN | ACTION_MANIPULATE,
            prohibitedActions: 0,
            authorizedRoles: roles,
            contextRequired: bytes32(0)
        });

        assertEq(policy.objectId, 42);
        assertEq(uint256(policy.safetyClass), uint256(SafetyClass.ELEVATED));
        assertEq(policy.allowedActions, ACTION_SCAN | ACTION_MANIPULATE);
        assertEq(policy.prohibitedActions, 0);
        assertEq(policy.authorizedRoles.length, 1);
        assertEq(policy.contextRequired, bytes32(0));
    }

    function test_denyOverridesAllow() public pure {
        // REQ-S3: prohibited always wins
        uint256 allowed = ACTION_SCAN | ACTION_MANIPULATE | ACTION_TRANSPORT;
        uint256 prohibited = ACTION_MANIPULATE; // explicitly deny manipulate

        uint256 effective = allowed & ~prohibited;

        // Manipulate should be stripped
        assertEq(effective, ACTION_SCAN | ACTION_TRANSPORT);
        assertEq(effective & ACTION_MANIPULATE, 0);
    }

    function test_emptyPolicy_isUnauthorized() public pure {
        RobotActionPolicy memory policy;
        // Default struct = all zeros = unauthorized
        assertEq(policy.objectId, 0);
        assertEq(policy.allowedActions, 0);
        assertEq(policy.prohibitedActions, 0);
        assertEq(policy.contextRequired, bytes32(0));
    }

    // ============================================
    // ROB-T03: ROBOT IDENTITY BADGES
    // ============================================

    function test_robotBadgeIds_inCorrectRange() public pure {
        // Range 30-39 per IdentityBadge category scheme
        assertTrue(BADGE_CHEF_BOT >= 30 && BADGE_CHEF_BOT < 40);
        assertTrue(BADGE_WAREHOUSE_OP >= 30 && BADGE_WAREHOUSE_OP < 40);
        assertTrue(BADGE_INSPECTOR_BOT >= 30 && BADGE_INSPECTOR_BOT < 40);
        assertTrue(BADGE_FACTORY_ARM >= 30 && BADGE_FACTORY_ARM < 40);
        assertTrue(BADGE_SECURITY_BOT >= 30 && BADGE_SECURITY_BOT < 40);
        assertTrue(BADGE_MEDICAL_BOT >= 30 && BADGE_MEDICAL_BOT < 40);
    }

    function test_robotBadgeIds_unique() public pure {
        // All badge IDs must be distinct
        assertTrue(BADGE_CHEF_BOT != BADGE_WAREHOUSE_OP);
        assertTrue(BADGE_CHEF_BOT != BADGE_INSPECTOR_BOT);
        assertTrue(BADGE_CHEF_BOT != BADGE_FACTORY_ARM);
        assertTrue(BADGE_CHEF_BOT != BADGE_SECURITY_BOT);
        assertTrue(BADGE_CHEF_BOT != BADGE_MEDICAL_BOT);
        assertTrue(BADGE_WAREHOUSE_OP != BADGE_INSPECTOR_BOT);
        assertTrue(BADGE_WAREHOUSE_OP != BADGE_FACTORY_ARM);
        assertTrue(BADGE_WAREHOUSE_OP != BADGE_SECURITY_BOT);
        assertTrue(BADGE_WAREHOUSE_OP != BADGE_MEDICAL_BOT);
    }

    function test_grantRobotIdentity_success() public {
        // Owner can grant robot identity badges
        identityBadge.grantIdentity(robot1, BADGE_CHEF_BOT);
        assertTrue(identityBadge.hasIdentity(robot1, BADGE_CHEF_BOT));
    }

    function test_grantRobotIdentity_allTypes() public {
        identityBadge.grantIdentity(robot1, BADGE_CHEF_BOT);
        identityBadge.grantIdentity(robot1, BADGE_WAREHOUSE_OP);
        identityBadge.grantIdentity(robot1, BADGE_INSPECTOR_BOT);
        identityBadge.grantIdentity(robot1, BADGE_FACTORY_ARM);
        identityBadge.grantIdentity(robot1, BADGE_SECURITY_BOT);
        identityBadge.grantIdentity(robot1, BADGE_MEDICAL_BOT);

        assertTrue(identityBadge.hasIdentity(robot1, BADGE_CHEF_BOT));
        assertTrue(identityBadge.hasIdentity(robot1, BADGE_WAREHOUSE_OP));
        assertTrue(identityBadge.hasIdentity(robot1, BADGE_INSPECTOR_BOT));
        assertTrue(identityBadge.hasIdentity(robot1, BADGE_FACTORY_ARM));
        assertTrue(identityBadge.hasIdentity(robot1, BADGE_SECURITY_BOT));
        assertTrue(identityBadge.hasIdentity(robot1, BADGE_MEDICAL_BOT));
    }

    function test_revokeRobotIdentity_success() public {
        identityBadge.grantIdentity(robot1, BADGE_CHEF_BOT);
        assertTrue(identityBadge.hasIdentity(robot1, BADGE_CHEF_BOT));

        identityBadge.revokeIdentity(robot1, BADGE_CHEF_BOT);
        assertFalse(identityBadge.hasIdentity(robot1, BADGE_CHEF_BOT));
    }

    function test_robotBadge_isSoulbound() public {
        identityBadge.grantIdentity(robot1, BADGE_WAREHOUSE_OP);

        uint256 tokenId = identityBadge.getTokenId(robot1, BADGE_WAREHOUSE_OP);
        assertTrue(identityBadge.locked(tokenId));
    }

    function test_issuerBadges_exist() public view {
        // Manufacturer and GovMil issuers should have badges from setUp
        assertTrue(identityBadge.hasIdentity(manufacturer, BADGE_MANUFACTURER));
        assertTrue(identityBadge.hasIdentity(govMil, BADGE_GOV_MIL));
    }

    // ============================================
    // ROB-T04: ROBOT CAPABILITY BADGES
    // ============================================

    function test_capabilityIds_inCorrectRange() public pure {
        // Range 120-129 per CapabilityBadge category scheme
        assertTrue(CAP_ROBOT_SCAN >= 120 && CAP_ROBOT_SCAN < 130);
        assertTrue(CAP_ROBOT_MANIPULATE >= 120 && CAP_ROBOT_MANIPULATE < 130);
        assertTrue(CAP_ROBOT_TRANSPORT >= 120 && CAP_ROBOT_TRANSPORT < 130);
        assertTrue(CAP_ROBOT_INSPECT >= 120 && CAP_ROBOT_INSPECT < 130);
        assertTrue(CAP_ROBOT_CLASSIFIED >= 120 && CAP_ROBOT_CLASSIFIED < 130);
    }

    function test_capabilityIds_unique() public pure {
        assertTrue(CAP_ROBOT_SCAN != CAP_ROBOT_MANIPULATE);
        assertTrue(CAP_ROBOT_SCAN != CAP_ROBOT_TRANSPORT);
        assertTrue(CAP_ROBOT_SCAN != CAP_ROBOT_INSPECT);
        assertTrue(CAP_ROBOT_SCAN != CAP_ROBOT_CLASSIFIED);
        assertTrue(CAP_ROBOT_MANIPULATE != CAP_ROBOT_TRANSPORT);
        assertTrue(CAP_ROBOT_MANIPULATE != CAP_ROBOT_INSPECT);
        assertTrue(CAP_ROBOT_MANIPULATE != CAP_ROBOT_CLASSIFIED);
    }

    function test_grantRobotCapability_success() public {
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_SCAN);
        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_SCAN));
    }

    function test_grantRobotCapability_allTypes() public {
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_SCAN);
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_MANIPULATE);
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_TRANSPORT);
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_INSPECT);
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_CLASSIFIED);

        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_SCAN));
        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_MANIPULATE));
        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_TRANSPORT));
        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_INSPECT));
        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_CLASSIFIED));
    }

    function test_revokeRobotCapability_success() public {
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_SCAN);
        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_SCAN));

        capabilityBadge.revokeCapability(robot1, CAP_ROBOT_SCAN);
        assertFalse(capabilityBadge.hasCapability(robot1, CAP_ROBOT_SCAN));
    }

    function test_batchGrantRobotCapabilities() public {
        uint256[] memory caps = new uint256[](3);
        caps[0] = CAP_ROBOT_SCAN;
        caps[1] = CAP_ROBOT_MANIPULATE;
        caps[2] = CAP_ROBOT_TRANSPORT;

        capabilityBadge.batchGrantCapabilities(robot1, caps);

        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_SCAN));
        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_MANIPULATE));
        assertTrue(capabilityBadge.hasCapability(robot1, CAP_ROBOT_TRANSPORT));
    }

    function test_robotCapability_viaAccess() public {
        // Test the TAGITAccess facade delegates correctly for robot caps
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_SCAN);
        assertTrue(tagitAccess.hasCapability(robot1, CAP_ROBOT_SCAN));
        assertFalse(tagitAccess.hasCapability(robot2, CAP_ROBOT_SCAN));
    }

    function test_robotIdentity_viaAccess() public {
        identityBadge.grantIdentity(robot1, BADGE_FACTORY_ARM);
        assertTrue(tagitAccess.hasIdentity(robot1, BADGE_FACTORY_ARM));
        assertFalse(tagitAccess.hasIdentity(robot2, BADGE_FACTORY_ARM));
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_denyAlwaysWins(uint256 allowed, uint256 denied) public pure {
        // REQ-S3: prohibited ALWAYS overrides allowed
        uint256 effective = allowed & ~denied;

        // No bit set in denied should survive in effective
        assertEq(effective & denied, 0);
    }

    function testFuzz_actionBitmask_commutative(uint256 a, uint256 b) public pure {
        // OR is commutative for action sets
        assertEq(a | b, b | a);
        // AND is commutative for deny masks
        assertEq(a & b, b & a);
    }
}
