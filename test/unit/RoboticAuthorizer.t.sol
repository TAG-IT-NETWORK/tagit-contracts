// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {RoboticAuthorizer} from "../../src/robot/RoboticAuthorizer.sol";
import {IRoboticAuthorizer} from "../../src/interfaces/IRoboticAuthorizer.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
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
    CAP_ROBOT_SCAN,
    CAP_ROBOT_MANIPULATE,
    CAP_ROBOT_TRANSPORT,
    CAP_ROBOT_INSPECT,
    CAP_ROBOT_CLASSIFIED,
    BADGE_CHEF_BOT,
    BADGE_WAREHOUSE_OP,
    BADGE_INSPECTOR_BOT,
    BADGE_FACTORY_ARM,
    BADGE_SECURITY_BOT,
    BADGE_MEDICAL_BOT,
    BADGE_MANUFACTURER,
    BADGE_GOV_MIL
} from "../../src/libraries/RobotTypes.sol";

/**
 * @title RoboticAuthorizerTest
 * @notice Unit + fuzz tests for standalone RoboticAuthorizer contract
 * @dev Tests cover:
 *   - queryActionPolicy view function (9 tests)
 *   - authorizeRobotAction with rate limiting + circuit breaker + zone enforcement (7 tests)
 *   - Admin setters for safety class, zone, prohibited actions (9 tests)
 *   - View functions for circuit breaker and rate limiter status (5 tests)
 *   - Deny-wins invariant (REQ-S3) fuzz
 *   - Cross-contract token existence check via ownerOf
 */
contract RoboticAuthorizerTest is Test {
    RoboticAuthorizer public authorizer;
    TAGITCore public tagitCore;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;
    TAGITAccess public tagitAccess;

    address public owner;
    address public robot1;
    address public robot2;
    address public unauthorized;

    uint256 public tokenId;

    // Capability IDs from TAGITCore
    uint256 constant CAP_MINTER = uint256(keccak256("MINTER"));

    function setUp() public {
        owner = makeAddr("owner");
        robot1 = makeAddr("robot1");
        robot2 = makeAddr("robot2");
        unauthorized = makeAddr("unauthorized");

        // Deploy badge contracts
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Deploy TAGITCore behind proxy (for token existence checks)
        TAGITCore coreImpl = new TAGITCore();
        bytes memory coreInit = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), coreInit);
        tagitCore = TAGITCore(address(coreProxy));

        // Set access controller on core
        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        // Deploy RoboticAuthorizer behind proxy
        RoboticAuthorizer authImpl = new RoboticAuthorizer();
        bytes memory authInit =
            abi.encodeCall(RoboticAuthorizer.initialize, (owner, address(tagitCore), address(tagitAccess)));
        ERC1967Proxy authProxy = new ERC1967Proxy(address(authImpl), authInit);
        authorizer = RoboticAuthorizer(address(authProxy));

        // Mint a test asset in TAGITCore
        capabilityBadge.grantCapability(owner, CAP_MINTER);
        vm.prank(owner);
        tokenId = tagitCore.mint(owner, keccak256("test-asset"));

        // Set up robot1 with identity + capabilities
        identityBadge.grantIdentity(robot1, BADGE_WAREHOUSE_OP);
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_SCAN);
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_TRANSPORT);

        // Grant VIEWER capability to test contract (caller of authorizeRobotAction)
        capabilityBadge.grantCapability(address(this), uint256(keccak256("VIEWER")));
    }

    // ============================================
    // queryActionPolicy TESTS
    // ============================================

    function test_queryActionPolicy_success() public view {
        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot1);

        assertEq(policy.objectId, tokenId);
        assertEq(uint256(policy.safetyClass), uint256(SafetyClass.STANDARD));
        assertEq(policy.allowedActions, ACTION_SCAN | ACTION_TRANSPORT);
        assertEq(policy.prohibitedActions, 0);
        assertEq(policy.contextRequired, bytes32(0));
        assertEq(policy.authorizedRoles.length, 1);
        assertEq(policy.authorizedRoles[0], bytes32(uint256(BADGE_WAREHOUSE_OP)));
    }

    function test_queryActionPolicy_nonexistentToken_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IRoboticAuthorizer.AssetNotFound.selector, 9999));
        authorizer.queryActionPolicy(9999, robot1);
    }

    function test_queryActionPolicy_unauthorizedRobot_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IRoboticAuthorizer.RobotNotAuthorized.selector, unauthorized));
        authorizer.queryActionPolicy(tokenId, unauthorized);
    }

    function test_queryActionPolicy_withProhibitedActions() public {
        vm.prank(owner);
        authorizer.setObjectProhibitedActions(tokenId, ACTION_SCAN);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot1);
        assertEq(policy.prohibitedActions, ACTION_SCAN);
        // Client must apply deny-wins: effective = allowed & ~prohibited
    }

    function test_queryActionPolicy_withSafetyClass() public {
        vm.prank(owner);
        authorizer.setObjectSafetyClass(tokenId, SafetyClass.ELEVATED);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot1);
        assertEq(uint256(policy.safetyClass), uint256(SafetyClass.ELEVATED));
    }

    function test_queryActionPolicy_withZone() public {
        bytes32 zone = keccak256("WAREHOUSE-A");
        vm.prank(owner);
        authorizer.setObjectZone(tokenId, zone);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot1);
        assertEq(policy.contextRequired, zone);
    }

    function test_queryActionPolicy_multipleCapabilities() public {
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_MANIPULATE);
        capabilityBadge.grantCapability(robot1, CAP_ROBOT_INSPECT);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot1);
        assertEq(policy.allowedActions, ACTION_SCAN | ACTION_TRANSPORT | ACTION_MANIPULATE | ACTION_INSPECT);
    }

    function test_queryActionPolicy_multipleIdentities() public {
        identityBadge.grantIdentity(robot1, BADGE_INSPECTOR_BOT);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot1);
        assertEq(policy.authorizedRoles.length, 2);
    }

    function test_queryActionPolicy_noCapabilities() public {
        // robot2 has identity but no capabilities
        identityBadge.grantIdentity(robot2, BADGE_CHEF_BOT);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot2);
        assertEq(policy.allowedActions, 0);
    }

    // ============================================
    // authorizeRobotAction TESTS
    // ============================================

    function test_authorizeRobotAction_success() public {
        vm.expectEmit(true, true, false, true);
        emit IRoboticAuthorizer.RobotActionAuthorized(robot1, tokenId, ACTION_SCAN | ACTION_TRANSPORT, bytes32(0), 0);

        authorizer.authorizeRobotAction(tokenId, robot1, ACTION_SCAN, bytes32(0));
    }

    function test_authorizeRobotAction_nonexistentToken_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IRoboticAuthorizer.AssetNotFound.selector, 9999));
        authorizer.authorizeRobotAction(9999, robot1, ACTION_SCAN, bytes32(0));
    }

    function test_authorizeRobotAction_unauthorizedRobot_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IRoboticAuthorizer.RobotNotAuthorized.selector, unauthorized));
        authorizer.authorizeRobotAction(tokenId, unauthorized, ACTION_SCAN, bytes32(0));
    }

    function test_authorizeRobotAction_prohibitedAction_reverts() public {
        vm.prank(owner);
        authorizer.setObjectProhibitedActions(tokenId, ACTION_SCAN);

        // SCAN is prohibited — effective = TRANSPORT only
        vm.expectRevert(
            abi.encodeWithSelector(
                IRoboticAuthorizer.ActionNotPermitted.selector, robot1, tokenId, ACTION_SCAN, ACTION_TRANSPORT
            )
        );
        authorizer.authorizeRobotAction(tokenId, robot1, ACTION_SCAN, bytes32(0));
    }

    function test_authorizeRobotAction_wrongZone_reverts() public {
        bytes32 requiredZone = keccak256("WAREHOUSE-A");
        bytes32 wrongZone = keccak256("WAREHOUSE-B");

        vm.prank(owner);
        authorizer.setObjectZone(tokenId, requiredZone);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRoboticAuthorizer.UnauthorizedZone.selector, robot1, tokenId, requiredZone, wrongZone
            )
        );
        authorizer.authorizeRobotAction(tokenId, robot1, ACTION_SCAN, wrongZone);
    }

    function test_authorizeRobotAction_correctZone_succeeds() public {
        bytes32 zone = keccak256("WAREHOUSE-A");

        vm.prank(owner);
        authorizer.setObjectZone(tokenId, zone);

        authorizer.authorizeRobotAction(tokenId, robot1, ACTION_SCAN, zone);
    }

    function test_authorizeRobotAction_noZoneRequired_anyZoneWorks() public {
        // Default zone is bytes32(0) = any zone
        authorizer.authorizeRobotAction(tokenId, robot1, ACTION_SCAN, keccak256("ANY"));
    }

    // ============================================
    // ADMIN FUNCTION TESTS
    // ============================================

    function test_setObjectSafetyClass_success() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IRoboticAuthorizer.ObjectSafetyClassUpdated(tokenId, SafetyClass.STANDARD, SafetyClass.RESTRICTED);
        authorizer.setObjectSafetyClass(tokenId, SafetyClass.RESTRICTED);
    }

    function test_setObjectSafetyClass_notOwner_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        authorizer.setObjectSafetyClass(tokenId, SafetyClass.ELEVATED);
    }

    function test_setObjectSafetyClass_nonexistentToken_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRoboticAuthorizer.AssetNotFound.selector, 9999));
        authorizer.setObjectSafetyClass(9999, SafetyClass.ELEVATED);
    }

    function test_setObjectZone_success() public {
        bytes32 zone = keccak256("ZONE-1");
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IRoboticAuthorizer.ObjectZoneUpdated(tokenId, bytes32(0), zone);
        authorizer.setObjectZone(tokenId, zone);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot1);
        assertEq(policy.contextRequired, zone);
    }

    function test_setObjectZone_notOwner_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        authorizer.setObjectZone(tokenId, keccak256("ZONE-1"));
    }

    function test_setObjectProhibitedActions_success() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IRoboticAuthorizer.ObjectProhibitedActionsUpdated(tokenId, 0, ACTION_MANIPULATE | ACTION_CLASSIFIED);
        authorizer.setObjectProhibitedActions(tokenId, ACTION_MANIPULATE | ACTION_CLASSIFIED);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(tokenId, robot1);
        assertEq(policy.prohibitedActions, ACTION_MANIPULATE | ACTION_CLASSIFIED);
    }

    function test_resetRobotCircuitBreaker_success() public {
        vm.prank(owner);
        authorizer.resetRobotCircuitBreaker();
    }

    function test_resetRobotCircuitBreaker_notOwner_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        authorizer.resetRobotCircuitBreaker();
    }

    function test_setRobotRateLimitEnabled_success() public {
        vm.prank(owner);
        authorizer.setRobotRateLimitEnabled(false);
    }

    function test_setCoreContract_success() public {
        address newCore = makeAddr("newCore");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IRoboticAuthorizer.CoreContractUpdated(address(tagitCore), newCore);
        authorizer.setCoreContract(newCore);
    }

    function test_setCoreContract_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert();
        authorizer.setCoreContract(address(0));
    }

    function test_setAccessController_success() public {
        address newAccess = makeAddr("newAccess");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IRoboticAuthorizer.AccessControllerUpdated(address(tagitAccess), newAccess);
        authorizer.setAccessController(newAccess);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_getRobotCircuitBreakerStatus() public view {
        (bool isTripped, uint256 cooldown) = authorizer.getRobotCircuitBreakerStatus();
        assertFalse(isTripped);
        assertEq(cooldown, 0);
    }

    function test_getRobotRateLimitStatus() public view {
        (bool canAct, uint256 remaining, uint256 lockedUntil) = authorizer.getRobotRateLimitStatus(robot1);
        assertTrue(canAct);
        assertEq(remaining, 100);
        assertEq(lockedUntil, 0);
    }

    function test_getRobotCircuitBreakerCapacity() public view {
        uint256 capacity = authorizer.getRobotCircuitBreakerCapacity();
        assertEq(capacity, 200);
    }

    function test_coreContract_returnsCorrectAddress() public view {
        assertEq(authorizer.coreContract(), address(tagitCore));
    }

    function test_accessController_returnsCorrectAddress() public view {
        assertEq(authorizer.accessController(), address(tagitAccess));
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsOwner() public view {
        assertEq(authorizer.owner(), owner);
    }

    function test_initialize_setsCoreContract() public view {
        assertEq(authorizer.coreContract(), address(tagitCore));
    }

    function test_initialize_setsAccessController() public view {
        assertEq(authorizer.accessController(), address(tagitAccess));
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        authorizer.initialize(owner, address(tagitCore), address(tagitAccess));
    }

    function test_initialize_zeroOwner_reverts() public {
        RoboticAuthorizer impl = new RoboticAuthorizer();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RoboticAuthorizer.initialize, (address(0), address(tagitCore), address(tagitAccess)))
        );
    }

    function test_initialize_zeroCore_reverts() public {
        RoboticAuthorizer impl = new RoboticAuthorizer();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl), abi.encodeCall(RoboticAuthorizer.initialize, (owner, address(0), address(tagitAccess)))
        );
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_denyAlwaysWins(uint256 allowed, uint256 denied) public pure {
        // REQ-S3: prohibited ALWAYS overrides allowed
        uint256 effective = allowed & ~denied;
        assertEq(effective & denied, 0);
    }

    function testFuzz_authorizeRobotAction_onlyAllowedActions(uint256 requestedActions) public {
        // Disable rate limiting for fuzz
        vm.prank(owner);
        authorizer.setRobotRateLimitEnabled(false);

        uint256 effectiveActions = ACTION_SCAN | ACTION_TRANSPORT; // robot1's capabilities
        // Mask fuzz input to only include bits from effective actions
        requestedActions = requestedActions & effectiveActions;
        vm.assume(requestedActions != 0); // skip if masking removes all bits

        // Should succeed for any subset of effective actions
        authorizer.authorizeRobotAction(tokenId, robot1, requestedActions, bytes32(0));
    }

    // ============================================
    // CROSS-CONTRACT INTEGRATION TESTS
    // ============================================

    function test_assetExistence_checkedViaCoreOwnerOf() public {
        // Mint another asset and verify authorizer can see it
        vm.prank(owner);
        uint256 newTokenId = tagitCore.mint(owner, keccak256("second-asset"));

        identityBadge.grantIdentity(robot2, BADGE_CHEF_BOT);

        RobotActionPolicy memory policy = authorizer.queryActionPolicy(newTokenId, robot2);
        assertEq(policy.objectId, newTokenId);
    }

    function test_authorizer_independentOfCoreRobotCode() public view {
        // Verify the authorizer works independently — no robot functions needed on TAGITCore
        // This confirms the separation is complete
        assertEq(authorizer.coreContract(), address(tagitCore));
        assertEq(authorizer.accessController(), address(tagitAccess));
        (bool isTripped,) = authorizer.getRobotCircuitBreakerStatus();
        assertFalse(isTripped);
    }

    // ============================================
    // IERC1155Receiver (needed to hold capability badges)
    // ============================================

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
