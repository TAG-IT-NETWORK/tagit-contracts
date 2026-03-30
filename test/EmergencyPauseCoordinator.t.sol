// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {EmergencyPauseCoordinator} from "../src/emergency/EmergencyPauseCoordinator.sol";
import {IEmergencyPauseCoordinator} from "../src/interfaces/IEmergencyPauseCoordinator.sol";
import {IEmergencyPauseable} from "../src/interfaces/IEmergencyPauseable.sol";
import {MockPauseableContract} from "./mocks/MockPauseableContract.sol";

/**
 * @title EmergencyPauseCoordinatorTest
 * @notice Unit tests for EmergencyPauseCoordinator
 * @dev Tests cover:
 *   - Deployment and constructor validation
 *   - registerContract() / deregisterContract()
 *   - pauseAll() state transitions
 *   - unpauseAll() state transitions
 *   - Access control (unauthorized callers revert)
 *   - Double-pause / double-unpause revert
 *   - Emergency escalation
 */
contract EmergencyPauseCoordinatorTest is Test {
    EmergencyPauseCoordinator public coordinator;
    MockPauseableContract public mockA;
    MockPauseableContract public mockB;
    MockPauseableContract public mockC;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public unauthorized = makeAddr("unauthorized");

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    function setUp() public {
        coordinator = new EmergencyPauseCoordinator(admin, pauser);
        mockA = new MockPauseableContract(address(coordinator));
        mockB = new MockPauseableContract(address(coordinator));
        mockC = new MockPauseableContract(address(coordinator));
    }

    // ============================================
    // DEPLOYMENT TESTS
    // ============================================

    function test_deployment_setsAdmin() public view {
        assertTrue(coordinator.hasRole(coordinator.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_deployment_setsPauser() public view {
        assertTrue(coordinator.hasRole(PAUSER_ROLE, pauser));
    }

    function test_deployment_initialStateActive() public view {
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.ACTIVE));
    }

    function test_deployment_emptyRegistry() public view {
        assertEq(coordinator.registeredCount(), 0);
        assertEq(coordinator.getRegistry().length, 0);
    }

    function test_deployment_revert_zeroAdmin() public {
        vm.expectRevert(IEmergencyPauseCoordinator.ZeroAddress.selector);
        new EmergencyPauseCoordinator(address(0), pauser);
    }

    function test_deployment_revert_zeroPauser() public {
        vm.expectRevert(IEmergencyPauseCoordinator.ZeroAddress.selector);
        new EmergencyPauseCoordinator(admin, address(0));
    }

    // ============================================
    // REGISTER CONTRACT TESTS
    // ============================================

    function test_registerContract_success() public {
        vm.prank(admin);
        coordinator.registerContract(address(mockA));

        assertTrue(coordinator.isRegistered(address(mockA)));
        assertEq(coordinator.registeredCount(), 1);

        address[] memory registry = coordinator.getRegistry();
        assertEq(registry.length, 1);
        assertEq(registry[0], address(mockA));
    }

    function test_registerContract_multiple() public {
        vm.startPrank(admin);
        coordinator.registerContract(address(mockA));
        coordinator.registerContract(address(mockB));
        coordinator.registerContract(address(mockC));
        vm.stopPrank();

        assertEq(coordinator.registeredCount(), 3);
        assertTrue(coordinator.isRegistered(address(mockA)));
        assertTrue(coordinator.isRegistered(address(mockB)));
        assertTrue(coordinator.isRegistered(address(mockC)));
    }

    function test_registerContract_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IEmergencyPauseCoordinator.ContractRegistered(address(mockA), admin);

        vm.prank(admin);
        coordinator.registerContract(address(mockA));
    }

    function test_registerContract_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        coordinator.registerContract(address(mockA));
    }

    function test_registerContract_revert_alreadyRegistered() public {
        vm.startPrank(admin);
        coordinator.registerContract(address(mockA));

        vm.expectRevert(abi.encodeWithSelector(IEmergencyPauseCoordinator.AlreadyRegistered.selector, address(mockA)));
        coordinator.registerContract(address(mockA));
        vm.stopPrank();
    }

    function test_registerContract_revert_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IEmergencyPauseCoordinator.ZeroAddress.selector);
        coordinator.registerContract(address(0));
    }

    function test_registerContract_revert_notAContract() public {
        address eoa = makeAddr("eoa");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEmergencyPauseCoordinator.NotAContract.selector, eoa));
        coordinator.registerContract(eoa);
    }

    // ============================================
    // DEREGISTER CONTRACT TESTS
    // ============================================

    function test_deregisterContract_success() public {
        vm.startPrank(admin);
        coordinator.registerContract(address(mockA));
        coordinator.deregisterContract(address(mockA));
        vm.stopPrank();

        assertFalse(coordinator.isRegistered(address(mockA)));
        assertEq(coordinator.registeredCount(), 0);
    }

    function test_deregisterContract_emitsEvent() public {
        vm.startPrank(admin);
        coordinator.registerContract(address(mockA));

        vm.expectEmit(true, true, false, false);
        emit IEmergencyPauseCoordinator.ContractDeregistered(address(mockA), admin);
        coordinator.deregisterContract(address(mockA));
        vm.stopPrank();
    }

    function test_deregisterContract_revert_notRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IEmergencyPauseCoordinator.NotRegistered.selector, address(mockA)));
        coordinator.deregisterContract(address(mockA));
    }

    function test_deregisterContract_revert_unauthorized() public {
        vm.prank(admin);
        coordinator.registerContract(address(mockA));

        vm.prank(unauthorized);
        vm.expectRevert();
        coordinator.deregisterContract(address(mockA));
    }

    function test_deregisterContract_revert_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IEmergencyPauseCoordinator.ZeroAddress.selector);
        coordinator.deregisterContract(address(0));
    }

    // ============================================
    // PAUSE ALL TESTS
    // ============================================

    function test_pauseAll_pausesRegisteredContracts() public {
        vm.startPrank(admin);
        coordinator.registerContract(address(mockA));
        coordinator.registerContract(address(mockB));
        vm.stopPrank();

        vm.prank(pauser);
        coordinator.pauseAll();

        assertTrue(mockA.isPaused());
        assertTrue(mockB.isPaused());
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.PAUSED));
    }

    function test_pauseAll_emitsEvents() public {
        vm.prank(admin);
        coordinator.registerContract(address(mockA));

        vm.expectEmit(true, true, true, true);
        emit IEmergencyPauseCoordinator.SystemStateChanged(
            IEmergencyPauseCoordinator.SystemState.ACTIVE, IEmergencyPauseCoordinator.SystemState.PAUSED, pauser
        );

        vm.prank(pauser);
        coordinator.pauseAll();
    }

    function test_pauseAll_emptyRegistry() public {
        vm.prank(pauser);
        coordinator.pauseAll();

        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.PAUSED));
    }

    function test_pauseAll_revert_alreadyPaused() public {
        vm.startPrank(pauser);
        coordinator.pauseAll();

        vm.expectRevert(IEmergencyPauseCoordinator.AlreadyPaused.selector);
        coordinator.pauseAll();
        vm.stopPrank();
    }

    function test_pauseAll_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        coordinator.pauseAll();
    }

    function test_pauseAll_continuesOnIndividualFailure() public {
        MockPauseableContract failingMock = new MockPauseableContract(address(coordinator));
        failingMock.setShouldFailPause(true);

        vm.startPrank(admin);
        coordinator.registerContract(address(failingMock));
        coordinator.registerContract(address(mockA));
        vm.stopPrank();

        vm.prank(pauser);
        coordinator.pauseAll();

        // mockA should still be paused even though failingMock failed
        assertTrue(mockA.isPaused());
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.PAUSED));
    }

    // ============================================
    // UNPAUSE ALL TESTS
    // ============================================

    function test_unpauseAll_unpausesRegisteredContracts() public {
        vm.startPrank(admin);
        coordinator.registerContract(address(mockA));
        coordinator.registerContract(address(mockB));
        vm.stopPrank();

        vm.prank(pauser);
        coordinator.pauseAll();

        vm.prank(pauser);
        coordinator.unpauseAll();

        assertFalse(mockA.isPaused());
        assertFalse(mockB.isPaused());
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.ACTIVE));
    }

    function test_unpauseAll_emitsEvents() public {
        vm.prank(admin);
        coordinator.registerContract(address(mockA));

        vm.prank(pauser);
        coordinator.pauseAll();

        vm.expectEmit(true, true, true, true);
        emit IEmergencyPauseCoordinator.SystemStateChanged(
            IEmergencyPauseCoordinator.SystemState.PAUSED, IEmergencyPauseCoordinator.SystemState.ACTIVE, pauser
        );

        vm.prank(pauser);
        coordinator.unpauseAll();
    }

    function test_unpauseAll_revert_notPaused() public {
        vm.prank(pauser);
        vm.expectRevert(IEmergencyPauseCoordinator.NotPaused.selector);
        coordinator.unpauseAll();
    }

    function test_unpauseAll_revert_unauthorized() public {
        vm.prank(pauser);
        coordinator.pauseAll();

        vm.prank(unauthorized);
        vm.expectRevert();
        coordinator.unpauseAll();
    }

    // ============================================
    // DOUBLE PAUSE / DOUBLE UNPAUSE
    // ============================================

    function test_doublePause_reverts() public {
        vm.startPrank(pauser);
        coordinator.pauseAll();

        vm.expectRevert(IEmergencyPauseCoordinator.AlreadyPaused.selector);
        coordinator.pauseAll();
        vm.stopPrank();
    }

    function test_doubleUnpause_reverts() public {
        vm.startPrank(pauser);
        coordinator.pauseAll();
        coordinator.unpauseAll();

        vm.expectRevert(IEmergencyPauseCoordinator.NotPaused.selector);
        coordinator.unpauseAll();
        vm.stopPrank();
    }

    // ============================================
    // EMERGENCY ESCALATION TESTS
    // ============================================

    function test_escalateToEmergency_fromActive() public {
        vm.prank(admin);
        coordinator.registerContract(address(mockA));

        vm.prank(pauser);
        coordinator.escalateToEmergency();

        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.EMERGENCY));
        assertTrue(mockA.isPaused());
    }

    function test_escalateToEmergency_fromPaused() public {
        vm.startPrank(pauser);
        coordinator.pauseAll();
        coordinator.escalateToEmergency();
        vm.stopPrank();

        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.EMERGENCY));
    }

    function test_escalateToEmergency_revert_alreadyEmergency() public {
        vm.startPrank(pauser);
        coordinator.escalateToEmergency();

        vm.expectRevert(
            abi.encodeWithSelector(
                IEmergencyPauseCoordinator.InvalidSystemState.selector,
                IEmergencyPauseCoordinator.SystemState.EMERGENCY,
                IEmergencyPauseCoordinator.SystemState.PAUSED
            )
        );
        coordinator.escalateToEmergency();
        vm.stopPrank();
    }

    function test_escalateToEmergency_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        coordinator.escalateToEmergency();
    }

    function test_emergency_unpause_requiresAdmin() public {
        vm.prank(pauser);
        coordinator.escalateToEmergency();

        // Pauser cannot unpause from emergency
        vm.prank(pauser);
        vm.expectRevert(IEmergencyPauseCoordinator.EmergencyRequiresAdmin.selector);
        coordinator.unpauseAll();

        // Admin can unpause from emergency
        vm.prank(admin);
        coordinator.unpauseAll();

        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.ACTIVE));
    }

    // ============================================
    // ACCESS CONTROL EDGE CASES
    // ============================================

    function test_pauserCannotRegister() public {
        vm.prank(pauser);
        vm.expectRevert();
        coordinator.registerContract(address(mockA));
    }

    function test_pauserCannotDeregister() public {
        vm.prank(admin);
        coordinator.registerContract(address(mockA));

        vm.prank(pauser);
        vm.expectRevert();
        coordinator.deregisterContract(address(mockA));
    }

    function test_adminCanGrantPauserRole() public {
        address newPauser = makeAddr("newPauser");
        vm.prank(admin);
        coordinator.grantRole(PAUSER_ROLE, newPauser);

        assertTrue(coordinator.hasRole(PAUSER_ROLE, newPauser));

        // New pauser can pause
        vm.prank(newPauser);
        coordinator.pauseAll();
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.PAUSED));
    }

    function test_adminCanRevokePauserRole() public {
        vm.prank(admin);
        coordinator.revokeRole(PAUSER_ROLE, pauser);

        vm.prank(pauser);
        vm.expectRevert();
        coordinator.pauseAll();
    }

    // ============================================
    // FULL LIFECYCLE TEST
    // ============================================

    function test_fullLifecycle_pauseUnpause() public {
        // Register contracts
        vm.startPrank(admin);
        coordinator.registerContract(address(mockA));
        coordinator.registerContract(address(mockB));
        coordinator.registerContract(address(mockC));
        vm.stopPrank();

        // Verify initial state
        assertFalse(mockA.isPaused());
        assertFalse(mockB.isPaused());
        assertFalse(mockC.isPaused());

        // Pause all
        vm.prank(pauser);
        coordinator.pauseAll();

        assertTrue(mockA.isPaused());
        assertTrue(mockB.isPaused());
        assertTrue(mockC.isPaused());

        // Unpause all
        vm.prank(pauser);
        coordinator.unpauseAll();

        assertFalse(mockA.isPaused());
        assertFalse(mockB.isPaused());
        assertFalse(mockC.isPaused());

        // Deregister one, pause again
        vm.prank(admin);
        coordinator.deregisterContract(address(mockB));

        vm.prank(pauser);
        coordinator.pauseAll();

        assertTrue(mockA.isPaused());
        assertFalse(mockB.isPaused()); // deregistered, not affected
        assertTrue(mockC.isPaused());
    }
}
