// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RobotTypes
 * @author TAG IT Network <dev@tagit.network>
 * @notice Type definitions for NFC-guided robotic authorization
 * @dev Defines safety classifications, action policies, and bitmask constants
 *      for robot-object interactions per PRD-ROB-001 and SEC-ROB-001
 *
 * Security Invariants:
 * - REQ-S3: prohibitedActions bitmask ALWAYS overrides allowedActions (deny wins)
 * - REQ-S1: Robot must have valid soulbound identity badge before any authorization
 * - REQ-S9: contextRequired zone must match robot's current zone proof
 *
 * @custom:security Action bitmask calculation: effectiveActions = allowedActions & ~prohibitedActions
 */

// ============================================
// SAFETY CLASSIFICATION
// ============================================

/**
 * @notice Safety classification levels for robotic interactions
 * @dev Maps to capability requirements — higher class = more capabilities needed
 *
 * STANDARD:   Basic scan/read operations, any authorized robot
 * ELEVATED:   Manipulation/transport, requires additional capability badges
 * RESTRICTED: Inspection/quality control, requires certified operator
 * CLASSIFIED: Defense/military operations, requires GOV_MIL identity badge
 */
enum SafetyClass {
    STANDARD, // 0 — Basic operations
    ELEVATED, // 1 — Manipulation/transport
    RESTRICTED, // 2 — Inspection/certified
    CLASSIFIED // 3 — Defense/military
}

// ============================================
// ACTION BITMASK CONSTANTS
// ============================================

/// @dev Robot action bitmask values — each action is a single bit
/// @custom:security Deny-list bitmask always overrides allow-list (REQ-S3)

uint256 constant ACTION_SCAN = 1 << 0; // 0x01 — Read-only NFC scan
uint256 constant ACTION_MANIPULATE = 1 << 1; // 0x02 — Pick up, move object
uint256 constant ACTION_TRANSPORT = 1 << 2; // 0x04 — Zone-to-zone transfer
uint256 constant ACTION_INSPECT = 1 << 3; // 0x08 — Quality inspection
uint256 constant ACTION_CLASSIFIED = 1 << 4; // 0x10 — Defense/classified access

// ============================================
// ROBOT IDENTITY BADGE IDs (ERC-5192 soulbound)
// ============================================

/// @dev Robot identity badge IDs — range 30-39 per IdentityBadge category scheme
/// Issuance gated by MANUFACTURER (10) or GOV_MIL (20) badge
uint256 constant BADGE_CHEF_BOT = 30;
uint256 constant BADGE_WAREHOUSE_OP = 31;
uint256 constant BADGE_INSPECTOR_BOT = 32;
uint256 constant BADGE_FACTORY_ARM = 33;
uint256 constant BADGE_SECURITY_BOT = 34;
uint256 constant BADGE_MEDICAL_BOT = 35;

// ============================================
// ROBOT CAPABILITY BADGE IDs (ERC-1155)
// ============================================

/// @dev Robot capability IDs — range 120-129 per CapabilityBadge category scheme
/// Maps 1:1 to action bitmask permissions
uint256 constant CAP_ROBOT_SCAN = 120;
uint256 constant CAP_ROBOT_MANIPULATE = 121;
uint256 constant CAP_ROBOT_TRANSPORT = 122;
uint256 constant CAP_ROBOT_INSPECT = 123;
uint256 constant CAP_ROBOT_CLASSIFIED = 124;

// ============================================
// ISSUER BADGE IDs (from existing IdentityBadge categories)
// ============================================

/// @dev Badge IDs required to issue robot identity badges
uint256 constant BADGE_MANUFACTURER = 10;
uint256 constant BADGE_GOV_MIL = 20;

// ============================================
// ROBOT ACTION POLICY STRUCT
// ============================================

/**
 * @notice Policy defining what actions a robot can perform on a specific object
 * @dev Returned by queryActionPolicy() — ephemeral, not stored on-chain
 *
 * @param objectId       Token ID of the object being acted upon
 * @param safetyClass    Safety classification of the object
 * @param allowedActions Bitmask of permitted actions based on robot capabilities
 * @param prohibitedActions Bitmask of explicitly denied actions (ALWAYS overrides allowed)
 * @param authorizedRoles Array of role identifiers the robot satisfies
 * @param contextRequired Zone ID where robot must be located (bytes32(0) = any zone)
 *
 * @custom:security Effective actions = allowedActions & ~prohibitedActions (REQ-S3)
 * @custom:security Empty policy (all zeros) = unauthorized robot
 */
struct RobotActionPolicy {
    uint256 objectId;
    SafetyClass safetyClass;
    uint256 allowedActions;
    uint256 prohibitedActions;
    bytes32[] authorizedRoles;
    bytes32 contextRequired;
}
