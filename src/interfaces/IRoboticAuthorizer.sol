// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafetyClass, RobotActionPolicy} from "../libraries/RobotTypes.sol";

/**
 * @title IRoboticAuthorizer
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for standalone robotic authorization contract
 * @dev Separated from TAGITCore for independent upgradeability and SoC.
 *      Manages robot-object action policies, rate limiting, circuit breaker,
 *      and zone enforcement via ERC-8004 badge gating.
 *
 * @custom:security REQ-S1: Robot must have valid soulbound identity badge
 * @custom:security REQ-S3: prohibitedActions ALWAYS overrides allowedActions (deny-wins)
 * @custom:security REQ-S9: contextRequired zone must match robot's zone proof
 */
interface IRoboticAuthorizer {
    // ============================================
    // ERRORS
    // ============================================

    /// @notice Robot does not have a valid soulbound identity badge (REQ-S1)
    error RobotNotAuthorized(address robot);

    /// @notice Robot is in wrong zone for the requested object (REQ-S9)
    error UnauthorizedZone(address robot, uint256 tokenId, bytes32 required, bytes32 provided);

    /// @notice Requested action not permitted by robot's effective policy
    error ActionNotPermitted(address robot, uint256 tokenId, uint256 requested, uint256 effective);

    /// @notice Asset does not exist in TAGITCore
    error AssetNotFound(uint256 tokenId);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a robot is authorized to act on an object
    event RobotActionAuthorized(
        address indexed robot, uint256 indexed tokenId, uint256 actions, bytes32 zone, uint256 indexed safetyClass
    );

    /// @notice Emitted when object safety classification is updated
    event ObjectSafetyClassUpdated(uint256 indexed tokenId, SafetyClass previousClass, SafetyClass newClass);

    /// @notice Emitted when object zone requirement is updated
    event ObjectZoneUpdated(uint256 indexed tokenId, bytes32 previousZone, bytes32 newZone);

    /// @notice Emitted when object prohibited actions are updated
    event ObjectProhibitedActionsUpdated(uint256 indexed tokenId, uint256 previousActions, uint256 newActions);

    /// @notice Emitted when core contract reference is updated
    event CoreContractUpdated(address indexed previousCore, address indexed newCore);

    /// @notice Emitted when access controller is updated
    event AccessControllerUpdated(address indexed previousController, address indexed newController);

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /// @notice Query the action policy for a robot on a specific object (view only)
    function queryActionPolicy(uint256 tokenId, address robotAddress)
        external
        view
        returns (RobotActionPolicy memory policy);

    /// @notice Authorize a robot to perform actions on an object (state-changing)
    function authorizeRobotAction(uint256 tokenId, address robotAddress, uint256 requestedActions, bytes32 zoneProof)
        external;

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Update the safety classification for an object
    /// @param tokenId The asset token ID
    /// @param safetyClass The new SafetyClass enum value
    function setObjectSafetyClass(uint256 tokenId, SafetyClass safetyClass) external;

    /// @notice Update the required zone for an object
    /// @param tokenId The asset token ID
    /// @param zone The new zone identifier (bytes32-encoded)
    function setObjectZone(uint256 tokenId, bytes32 zone) external;

    /// @notice Update the prohibited action bitmask for an object
    /// @param tokenId The asset token ID
    /// @param prohibitedActions Bitmask of actions that are denied (deny-wins over allow)
    function setObjectProhibitedActions(uint256 tokenId, uint256 prohibitedActions) external;

    /// @notice Reset the robot authorization circuit breaker after cooldown
    function resetRobotCircuitBreaker() external;

    /// @notice Enable or disable robot-level rate limiting
    /// @param enabled Whether rate limiting is active
    function setRobotRateLimitEnabled(bool enabled) external;

    /// @notice Update the TAGITCore contract reference
    /// @param core New TAGITCore contract address
    function setCoreContract(address core) external;

    /// @notice Update the TAGITAccess controller reference
    /// @param controller New TAGITAccess contract address
    function setAccessController(address controller) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Check whether the circuit breaker is currently tripped
    /// @return isTripped True if the breaker is active
    /// @return cooldownRemaining Seconds until the breaker resets (0 if not tripped)
    function getRobotCircuitBreakerStatus() external view returns (bool isTripped, uint256 cooldownRemaining);

    /// @notice Check rate limit status for a specific robot
    /// @param robot The robot wallet address
    /// @return canAct Whether the robot can currently perform actions
    /// @return remaining Number of actions remaining in the current window
    /// @return lockedUntil Timestamp when the rate limit resets (0 if not locked)
    function getRobotRateLimitStatus(address robot)
        external
        view
        returns (bool canAct, uint256 remaining, uint256 lockedUntil);

    /// @notice Get remaining capacity before circuit breaker trips
    /// @return Number of robot authorization operations before circuit trips
    function getRobotCircuitBreakerCapacity() external view returns (uint256);

    /// @notice Get the TAGITCore contract address
    /// @return The current TAGITCore contract address
    function coreContract() external view returns (address);

    /// @notice Get the TAGITAccess controller address
    /// @return The current access controller address
    function accessController() external view returns (address);
}
