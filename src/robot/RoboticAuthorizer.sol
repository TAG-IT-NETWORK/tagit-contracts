// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {IRoboticAuthorizer} from "../interfaces/IRoboticAuthorizer.sol";
import {CircuitBreaker} from "../libraries/CircuitBreaker.sol";
import {RateLimiter} from "../libraries/RateLimiter.sol";
import {
    SafetyClass,
    RobotActionPolicy,
    ACTION_SCAN,
    ACTION_MANIPULATE,
    ACTION_TRANSPORT,
    ACTION_INSPECT,
    ACTION_CLASSIFIED,
    CAP_ROBOT_SCAN,
    CAP_ROBOT_MANIPULATE,
    CAP_ROBOT_TRANSPORT,
    CAP_ROBOT_INSPECT,
    CAP_ROBOT_CLASSIFIED,
    BADGE_CHEF_BOT,
    BADGE_MEDICAL_BOT
} from "../libraries/RobotTypes.sol";

/**
 * @title RoboticAuthorizer
 * @author TAG IT Network <dev@tagit.network>
 * @notice Standalone robotic authorization for NFC-guided robot-object interactions
 * @dev Separated from TAGITCore for independent upgradeability and single responsibility.
 *      Reads TAGITCore via ERC-721 ownerOf() for token existence — no core modification needed.
 *      Uses TAGITAccess (BIDGES) for identity/capability badge verification.
 *
 * Security Invariants:
 * - REQ-S1: Robot must have valid soulbound identity badge before any authorization
 * - REQ-S3: prohibitedActions bitmask ALWAYS overrides allowedActions (deny-wins)
 * - REQ-S9: contextRequired zone must match robot's current zone proof
 * - NIST AC-7: Rate limiting per robot (100/hr) + global (5000/hr)
 * - NIST IR-4: Circuit breaker trips at 200 auth/hr, 15min cooldown
 *
 * @custom:security All state-changing functions follow CEI pattern
 * @custom:security UUPS proxy — owner-authorized upgrades only
 * @custom:security ReentrancyGuard on authorizeRobotAction
 */
contract RoboticAuthorizer is
    IRoboticAuthorizer,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using CircuitBreaker for CircuitBreaker.Config;
    using RateLimiter for RateLimiter.Config;

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Zero address provided where non-zero required
    error ZeroAddress();

    // ============================================
    // BIDGES CAPABILITIES (Access Control)
    // ============================================

    /// @notice Capability required to call authorizeRobotAction
    /// @custom:security Prevents unauthorized systems from consuming rate limit capacity
    bytes32 public constant VIEWER_CAPABILITY = keccak256("VIEWER");

    // ============================================
    // STORAGE
    // ============================================

    /// @notice TAGITCore contract for token existence checks (ERC-721)
    IERC721 private _coreContract;

    /// @notice TAGITAccess controller for badge verification
    ITAGITAccess private _accessController;

    /// @notice Safety classification per object (default STANDARD)
    mapping(uint256 => SafetyClass) private _objectSafetyClass;

    /// @notice Required zone per object (bytes32(0) = any zone allowed)
    mapping(uint256 => bytes32) private _objectZone;

    /// @notice Explicitly prohibited actions per object (bitmask)
    mapping(uint256 => uint256) private _objectProhibitedActions;

    /// @notice Circuit breaker for robot authorization queries (NIST IR-4)
    /// @custom:security Trips at 200 queries/hr, 15min cooldown
    CircuitBreaker.Config private _robotCircuitBreaker;

    /// @notice Rate limiter for robot authorization (NIST AC-7)
    /// @custom:security 100/robot/hr, 5000 global/hr, 10min cooldown
    RateLimiter.Config private _robotRateLimiter;

    /// @notice Per-robot rate limit state
    mapping(address => RateLimiter.UserState) private _robotRateLimits;

    /// @notice Storage gap for future upgrades (ERC-7201 compatible)
    /// @dev Reserve 40 slots for future storage variables
    uint256[40] private __gap;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a contract upgrade is authorized
    event UpgradeScheduled(address indexed oldImpl, address indexed newImpl, address indexed scheduledBy);

    // ============================================
    // CONSTRUCTOR (disabled for proxy)
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================
    // INITIALIZER
    // ============================================

    /**
     * @notice Initialize RoboticAuthorizer contract (called once via proxy)
     * @dev Sets up owner, core contract reference, access controller,
     *      and initializes rate limiter + circuit breaker.
     * @param initialOwner Address that will own this contract (should be TimelockController)
     * @param core Address of TAGITCore proxy (ERC-721)
     * @param access Address of TAGITAccess controller
     * @custom:security Can only be called once (initializer modifier)
     * @custom:security Owner should be a TimelockController controlled by Gnosis Safe 3-of-5
     */
    function initialize(address initialOwner, address core, address access) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (core == address(0)) revert ZeroAddress();

        if (access == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _coreContract = IERC721(core);
        _accessController = ITAGITAccess(access);

        // NIST IR-4: Circuit breaker — 200 queries/hr, 15min cooldown
        _robotCircuitBreaker.initialize(200, 1 hours, 15 minutes);

        // NIST AC-7: Rate limiter — 100/robot/hr, 10min cooldown, 5000 global/hr
        _robotRateLimiter.initialize(100, 1 hours, 10 minutes, 5000);
    }

    // ============================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================

    /**
     * @notice Authorize a contract upgrade (UUPS)
     * @dev Only owner (TimelockController) can authorize upgrades.
     * @param newImplementation Address of the new implementation contract
     * @custom:security Owner-only — should be behind TimelockController + Gnosis Safe
     * @custom:security UpgradeScheduled event enables monitoring window
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit UpgradeScheduled(ERC1967Utils.getImplementation(), newImplementation, msg.sender);
    }

    /**
     * @notice Get the current implementation address
     * @return The address of the current implementation contract
     */
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    // ============================================
    // ACCESS CONTROL MODIFIER
    // ============================================

    /**
     * @notice Modifier to require specific capability from msg.sender
     * @dev Checks capability via TAGITAccess. Reverts if accessController is address(0).
     * @param capability The capability ID required
     * @custom:security Zero-trust: Explicitly checks capability via accessController
     */
    modifier requiresCapability(bytes32 capability) {
        if (address(_accessController) == address(0)) revert ZeroAddress();
        _accessController.requireCapability(msg.sender, uint256(capability));
        _;
    }

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Query the action policy for a robot on a specific object (view only)
     * @dev Returns ephemeral RobotActionPolicy struct — not stored on-chain.
     *      Callers must apply deny-wins: effectiveActions = allowedActions & ~prohibitedActions
     *
     * @param tokenId Token ID of the object being acted upon
     * @param robotAddress Address of the robot requesting authorization
     * @return policy The computed action policy for this robot-object pair
     *
     * @custom:security REQ-S1: Robot must have valid soulbound identity badge (30-35)
     * @custom:security REQ-S3: prohibitedActions always overrides allowedActions (deny-wins)
     * @custom:security REQ-S9: contextRequired zone included for caller-side enforcement
     */
    function queryActionPolicy(uint256 tokenId, address robotAddress)
        external
        view
        returns (RobotActionPolicy memory policy)
    {
        // Check token exists via ERC-721 ownerOf
        _requireAssetExists(tokenId);

        // REQ-S1: Robot must have valid soulbound identity badge
        if (!_hasRobotIdentity(robotAddress)) revert RobotNotAuthorized(robotAddress);

        // Build policy
        policy.objectId = tokenId;
        policy.safetyClass = _objectSafetyClass[tokenId];
        policy.allowedActions = _buildRobotActions(robotAddress);
        policy.prohibitedActions = _objectProhibitedActions[tokenId];
        policy.contextRequired = _objectZone[tokenId];
        policy.authorizedRoles = _buildRobotRoles(robotAddress);
    }

    /**
     * @notice Authorize a robot to perform actions on an object (state-changing)
     * @dev Validates robot identity, capabilities, zone, and emits authorization event.
     *      Applies rate limiting (100/hr/robot) and circuit breaker (200/hr global).
     *      Follows CEI pattern: checks → effects (rate limit state) → interactions (event).
     *
     * @param tokenId Token ID of the object being acted upon
     * @param robotAddress Address of the robot requesting authorization
     * @param requestedActions Bitmask of actions the robot wants to perform
     * @param zoneProof Zone proof provided by the robot (must match object zone if set)
     *
     * @custom:security ReentrancyGuard prevents reentrancy attacks
     * @custom:security REQ-S1: Robot must have valid soulbound identity badge
     * @custom:security REQ-S3: Deny-wins bitmask enforced before action check
     * @custom:security REQ-S9: Zone enforcement — zoneProof must match object zone
     * @custom:security NIST AC-7: Rate limiting per robot (100/hr)
     * @custom:security NIST IR-4: Circuit breaker trips at 200 auth/hr
     */
    function authorizeRobotAction(uint256 tokenId, address robotAddress, uint256 requestedActions, bytes32 zoneProof)
        external
        nonReentrant
        requiresCapability(VIEWER_CAPABILITY)
    {
        // ============================================
        // CHECKS
        // ============================================

        // Check token exists via ERC-721 ownerOf
        _requireAssetExists(tokenId);

        // REQ-S1: Robot must have valid soulbound identity badge
        if (!_hasRobotIdentity(robotAddress)) revert RobotNotAuthorized(robotAddress);

        // Build effective actions (deny-wins, REQ-S3)
        uint256 allowedActions = _buildRobotActions(robotAddress);
        uint256 prohibitedActions = _objectProhibitedActions[tokenId];
        uint256 effectiveActions = allowedActions & ~prohibitedActions;

        // Check requested actions are within effective actions
        // NOTE: Parentheses required — != binds tighter than & in Solidity
        if ((requestedActions & ~effectiveActions) != 0) {
            revert ActionNotPermitted(robotAddress, tokenId, requestedActions, effectiveActions);
        }

        // ROB-T07: Zone enforcement (REQ-S9)
        bytes32 requiredZone = _objectZone[tokenId];
        if (requiredZone != bytes32(0) && zoneProof != requiredZone) {
            revert UnauthorizedZone(robotAddress, tokenId, requiredZone, zoneProof);
        }

        // ============================================
        // EFFECTS
        // ============================================

        // ROB-T06: Rate limit check (100/hr/robot) — modifies per-robot state
        _robotRateLimiter.check(_robotRateLimits, robotAddress);

        // ROB-T06: Circuit breaker check — modifies global counter
        _robotCircuitBreaker.check();

        // ============================================
        // INTERACTIONS
        // ============================================

        emit RobotActionAuthorized(
            robotAddress, tokenId, effectiveActions, requiredZone, uint256(_objectSafetyClass[tokenId])
        );
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Set the safety classification for an object
     * @dev Only owner can call. Higher safety class requires more robot capabilities.
     * @param tokenId Token ID of the object
     * @param safetyClass New safety classification
     * @custom:security Only owner (TimelockController) can modify safety classes
     * @custom:emits ObjectSafetyClassUpdated
     */
    function setObjectSafetyClass(uint256 tokenId, SafetyClass safetyClass) external onlyOwner {
        _requireAssetExists(tokenId);
        SafetyClass previousClass = _objectSafetyClass[tokenId];
        _objectSafetyClass[tokenId] = safetyClass;
        emit ObjectSafetyClassUpdated(tokenId, previousClass, safetyClass);
    }

    /**
     * @notice Set the required zone for an object
     * @dev Only owner can call. bytes32(0) = any zone allowed.
     * @param tokenId Token ID of the object
     * @param zone Required zone ID (bytes32(0) to clear zone requirement)
     * @custom:security Only owner (TimelockController) can modify zone requirements
     * @custom:emits ObjectZoneUpdated
     */
    function setObjectZone(uint256 tokenId, bytes32 zone) external onlyOwner {
        _requireAssetExists(tokenId);
        bytes32 previousZone = _objectZone[tokenId];
        _objectZone[tokenId] = zone;
        emit ObjectZoneUpdated(tokenId, previousZone, zone);
    }

    /**
     * @notice Set explicitly prohibited actions for an object
     * @dev Only owner can call. Prohibited actions ALWAYS override allowed (deny-wins, REQ-S3).
     * @param tokenId Token ID of the object
     * @param prohibitedActions Bitmask of prohibited actions
     * @custom:security Only owner (TimelockController) can modify prohibited actions
     * @custom:security REQ-S3: These actions are denied regardless of robot capabilities
     * @custom:emits ObjectProhibitedActionsUpdated
     */
    function setObjectProhibitedActions(uint256 tokenId, uint256 prohibitedActions) external onlyOwner {
        _requireAssetExists(tokenId);
        uint256 previousActions = _objectProhibitedActions[tokenId];
        _objectProhibitedActions[tokenId] = prohibitedActions;
        emit ObjectProhibitedActionsUpdated(tokenId, previousActions, prohibitedActions);
    }

    /**
     * @notice Force-reset the robot authorization circuit breaker
     * @dev Only owner can call. Use for emergency recovery after false-positive trips.
     * @custom:security Only owner (TimelockController) can reset circuit breaker
     * @custom:security NIST IR-4: Manual override for incident response
     */
    function resetRobotCircuitBreaker() external onlyOwner {
        _robotCircuitBreaker.forceReset(msg.sender);
    }

    /**
     * @notice Enable or disable robot rate limiting
     * @dev Only owner can call. Use for emergency bypass or planned events.
     * @param enabled Whether rate limiting is enabled
     * @custom:security NIST AC-7 operational control
     */
    function setRobotRateLimitEnabled(bool enabled) external onlyOwner {
        _robotRateLimiter.setEnabled(enabled);
    }

    /**
     * @notice Update the TAGITCore contract reference
     * @dev Only owner can call. Used if TAGITCore proxy is redeployed.
     * @param core Address of the new TAGITCore proxy (ERC-721)
     * @custom:security Only owner (TimelockController) can update core reference
     * @custom:emits CoreContractUpdated
     */
    function setCoreContract(address core) external onlyOwner {
        if (core == address(0)) revert ZeroAddress();
        address previous = address(_coreContract);
        _coreContract = IERC721(core);
        emit CoreContractUpdated(previous, core);
    }

    /**
     * @notice Update the TAGITAccess controller
     * @dev Only owner can call. Setting to address(0) disables capability checks.
     * @param controller Address of the TAGITAccess controller (can be address(0))
     * @custom:security Only owner (TimelockController) can update access controller
     * @custom:emits AccessControllerUpdated
     */
    function setAccessController(address controller) external onlyOwner {
        address previous = address(_accessController);
        _accessController = ITAGITAccess(controller);
        emit AccessControllerUpdated(previous, controller);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get robot circuit breaker status
     * @return isTripped Whether the circuit breaker is currently tripped
     * @return cooldownRemaining Seconds until cooldown ends (0 if not tripped)
     * @custom:security NIST SI-4 system monitoring
     */
    function getRobotCircuitBreakerStatus() external view returns (bool isTripped, uint256 cooldownRemaining) {
        return _robotCircuitBreaker.status();
    }

    /**
     * @notice Get rate limit status for a robot
     * @param robot Address to check
     * @return canAct Whether the robot can perform actions
     * @return remaining Remaining actions in current window
     * @return lockedUntil Lockout end timestamp (0 if not locked)
     * @custom:security NIST SI-4 system monitoring
     */
    function getRobotRateLimitStatus(address robot)
        external
        view
        returns (bool canAct, uint256 remaining, uint256 lockedUntil)
    {
        return _robotRateLimiter.canAct(_robotRateLimits, robot);
    }

    /**
     * @notice Get remaining capacity for robot circuit breaker
     * @return remaining Number of authorization operations before circuit trips
     * @custom:security NIST AU-6 audit review capacity
     */
    function getRobotCircuitBreakerCapacity() external view returns (uint256) {
        return _robotCircuitBreaker.remainingCapacity();
    }

    /// @notice Get the TAGITCore contract address
    function coreContract() external view returns (address) {
        return address(_coreContract);
    }

    /// @notice Get the TAGITAccess controller address
    function accessController() external view returns (address) {
        return address(_accessController);
    }

    // ============================================
    // INTERNAL HELPERS
    // ============================================

    /**
     * @notice Verify asset exists in TAGITCore via ERC-721 ownerOf
     * @dev Uses try-catch — ownerOf reverts with ERC721NonexistentToken for missing tokens
     * @param tokenId Token ID to verify
     * @custom:security Cross-contract call is read-only (STATICCALL), no reentrancy risk
     */
    function _requireAssetExists(uint256 tokenId) internal view {
        try _coreContract.ownerOf(tokenId) returns (
            address
        ) {
        // Token exists — continue
        }
        catch {
            revert AssetNotFound(tokenId);
        }
    }

    /**
     * @notice Check if address has any valid robot soulbound identity badge
     * @dev Checks all robot badge IDs in range 30-35 (BADGE_CHEF_BOT to BADGE_MEDICAL_BOT)
     * @param robot Address to check
     * @return True if robot has at least one valid identity badge
     * @custom:security REQ-S1: Robot must have valid soulbound identity badge
     */
    function _hasRobotIdentity(address robot) internal view returns (bool) {
        if (address(_accessController) == address(0)) return false;

        for (uint256 i = BADGE_CHEF_BOT; i <= BADGE_MEDICAL_BOT; i++) {
            if (_accessController.hasIdentity(robot, i)) return true;
        }
        return false;
    }

    /**
     * @notice Build allowed actions bitmask from robot's capability badges
     * @dev Maps each CAP_ROBOT_* capability to corresponding ACTION_* bit
     * @param robot Address to check capabilities for
     * @return actions Bitmask of allowed actions
     * @custom:security Only capabilities explicitly granted are included
     */
    function _buildRobotActions(address robot) internal view returns (uint256 actions) {
        if (address(_accessController) == address(0)) return 0;

        if (_accessController.hasCapability(robot, CAP_ROBOT_SCAN)) actions |= ACTION_SCAN;
        if (_accessController.hasCapability(robot, CAP_ROBOT_MANIPULATE)) actions |= ACTION_MANIPULATE;
        if (_accessController.hasCapability(robot, CAP_ROBOT_TRANSPORT)) actions |= ACTION_TRANSPORT;
        if (_accessController.hasCapability(robot, CAP_ROBOT_INSPECT)) actions |= ACTION_INSPECT;
        if (_accessController.hasCapability(robot, CAP_ROBOT_CLASSIFIED)) actions |= ACTION_CLASSIFIED;
    }

    /**
     * @notice Build authorized roles array from robot's identity badges
     * @dev Returns bytes32-encoded badge IDs for each identity badge the robot holds
     * @param robot Address to check identity badges for
     * @return roles Array of bytes32-encoded role identifiers
     */
    function _buildRobotRoles(address robot) internal view returns (bytes32[] memory roles) {
        if (address(_accessController) == address(0)) return new bytes32[](0);

        // Count roles first
        uint256 count = 0;
        for (uint256 i = BADGE_CHEF_BOT; i <= BADGE_MEDICAL_BOT; i++) {
            if (_accessController.hasIdentity(robot, i)) count++;
        }

        // Build roles array
        roles = new bytes32[](count);
        uint256 idx = 0;
        for (uint256 i = BADGE_CHEF_BOT; i <= BADGE_MEDICAL_BOT; i++) {
            if (_accessController.hasIdentity(robot, i)) {
                roles[idx++] = bytes32(i);
            }
        }
    }
}
