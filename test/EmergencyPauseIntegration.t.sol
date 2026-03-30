// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {EmergencyPauseCoordinator} from "../src/emergency/EmergencyPauseCoordinator.sol";
import {IEmergencyPauseCoordinator} from "../src/interfaces/IEmergencyPauseCoordinator.sol";
import {IEmergencyPauseable} from "../src/interfaces/IEmergencyPauseable.sol";
import {MockPauseableContract} from "./mocks/MockPauseableContract.sol";

/**
 * @title EmergencyPauseIntegrationTest
 * @notice Integration tests simulating full emergency scenarios
 * @dev Tests atomic pause/unpause across multiple contracts,
 *      emergency escalation/recovery, and resilience to failures
 */
contract EmergencyPauseIntegrationTest is Test {
    EmergencyPauseCoordinator public coordinator;

    // Simulate a multi-contract protocol
    MockPauseableContract public staking;
    MockPauseableContract public programs;
    MockPauseableContract public recovery;
    MockPauseableContract public treasury;
    MockPauseableContract public bridge;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public securityTeam = makeAddr("securityTeam");

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    function setUp() public {
        coordinator = new EmergencyPauseCoordinator(admin, pauser);

        staking = new MockPauseableContract(address(coordinator));
        programs = new MockPauseableContract(address(coordinator));
        recovery = new MockPauseableContract(address(coordinator));
        treasury = new MockPauseableContract(address(coordinator));
        bridge = new MockPauseableContract(address(coordinator));

        // Register all contracts
        vm.startPrank(admin);
        coordinator.registerContract(address(staking));
        coordinator.registerContract(address(programs));
        coordinator.registerContract(address(recovery));
        coordinator.registerContract(address(treasury));
        coordinator.registerContract(address(bridge));

        // Grant security team pauser role
        coordinator.grantRole(PAUSER_ROLE, securityTeam);
        vm.stopPrank();
    }

    // ============================================
    // SCENARIO: Normal Emergency Pause + Recovery
    // ============================================

    function test_scenario_normalEmergencyPauseAndRecovery() public {
        // 1. All contracts active
        _assertAllUnpaused();

        // 2. Security team detects anomaly, triggers pause
        vm.prank(securityTeam);
        coordinator.pauseAll();

        // 3. All contracts paused atomically
        _assertAllPaused();
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.PAUSED));

        // 4. After investigation, security team unpauses
        vm.prank(securityTeam);
        coordinator.unpauseAll();

        // 5. All contracts active again
        _assertAllUnpaused();
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.ACTIVE));
    }

    // ============================================
    // SCENARIO: Emergency Escalation
    // ============================================

    function test_scenario_emergencyEscalation() public {
        // 1. Pauser detects critical vulnerability
        vm.prank(pauser);
        coordinator.escalateToEmergency();

        // 2. All paused and locked in EMERGENCY
        _assertAllPaused();
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.EMERGENCY));

        // 3. Security team (pauser) CANNOT unpause during emergency
        vm.prank(securityTeam);
        vm.expectRevert(IEmergencyPauseCoordinator.EmergencyRequiresAdmin.selector);
        coordinator.unpauseAll();

        // 4. Still paused
        _assertAllPaused();

        // 5. Admin (after thorough investigation) clears emergency
        vm.prank(admin);
        coordinator.unpauseAll();

        // 6. Protocol restored
        _assertAllUnpaused();
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.ACTIVE));
    }

    // ============================================
    // SCENARIO: Partial Failure Resilience
    // ============================================

    function test_scenario_partialFailureResilience() public {
        // One contract is broken
        bridge.setShouldFailPause(true);

        // Pause still succeeds for other contracts
        vm.prank(pauser);
        coordinator.pauseAll();

        assertTrue(staking.isPaused());
        assertTrue(programs.isPaused());
        assertTrue(recovery.isPaused());
        assertTrue(treasury.isPaused());
        assertFalse(bridge.isPaused()); // failed but didn't block others

        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.PAUSED));

        // Unpause - bridge fails to unpause (it was never paused anyway)
        bridge.setShouldFailUnpause(true);
        vm.prank(pauser);
        coordinator.unpauseAll();

        assertFalse(staking.isPaused());
        assertFalse(programs.isPaused());
        assertFalse(recovery.isPaused());
        assertFalse(treasury.isPaused());
    }

    // ============================================
    // SCENARIO: Dynamic Registry (Hot-swap)
    // ============================================

    function test_scenario_dynamicRegistryUpdate() public {
        // Pause all
        vm.prank(pauser);
        coordinator.pauseAll();
        _assertAllPaused();

        // Unpause
        vm.prank(pauser);
        coordinator.unpauseAll();

        // Admin removes bridge from registry
        vm.prank(admin);
        coordinator.deregisterContract(address(bridge));

        // Add new contract
        MockPauseableContract newContract = new MockPauseableContract(address(coordinator));
        vm.prank(admin);
        coordinator.registerContract(address(newContract));

        // Pause again - bridge not affected, new contract is
        vm.prank(pauser);
        coordinator.pauseAll();

        assertTrue(staking.isPaused());
        assertFalse(bridge.isPaused()); // deregistered
        assertTrue(newContract.isPaused()); // newly registered
    }

    // ============================================
    // SCENARIO: Multi-Pause Cycle Stress Test
    // ============================================

    function test_scenario_multiPauseCycleStress() public {
        for (uint256 i; i < 10; ++i) {
            vm.prank(pauser);
            coordinator.pauseAll();
            _assertAllPaused();

            vm.prank(pauser);
            coordinator.unpauseAll();
            _assertAllUnpaused();
        }

        // Verify final state is clean
        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.ACTIVE));
        assertEq(coordinator.registeredCount(), 5);
    }

    // ============================================
    // SCENARIO: Emergency Escalation from Paused
    // ============================================

    function test_scenario_escalateFromPaused() public {
        // First pause normally
        vm.prank(pauser);
        coordinator.pauseAll();

        // Then escalate to emergency
        vm.prank(pauser);
        coordinator.escalateToEmergency();

        assertEq(uint256(coordinator.systemState()), uint256(IEmergencyPauseCoordinator.SystemState.EMERGENCY));

        // Only admin can clear
        vm.prank(admin);
        coordinator.unpauseAll();
        _assertAllUnpaused();
    }

    // ============================================
    // SCENARIO: Coordinator-only access on mocks
    // ============================================

    function test_scenario_mockRejectsNonCoordinator() public {
        // Direct calls to mock should fail
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IEmergencyPauseable.OnlyCoordinator.selector, admin, address(coordinator))
        );
        staking.coordinatorPause();
    }

    // ============================================
    // HELPERS
    // ============================================

    function _assertAllPaused() internal view {
        assertTrue(staking.isPaused(), "staking should be paused");
        assertTrue(programs.isPaused(), "programs should be paused");
        assertTrue(recovery.isPaused(), "recovery should be paused");
        assertTrue(treasury.isPaused(), "treasury should be paused");
        assertTrue(bridge.isPaused(), "bridge should be paused");
    }

    function _assertAllUnpaused() internal view {
        assertFalse(staking.isPaused(), "staking should not be paused");
        assertFalse(programs.isPaused(), "programs should not be paused");
        assertFalse(recovery.isPaused(), "recovery should not be paused");
        assertFalse(treasury.isPaused(), "treasury should not be paused");
        assertFalse(bridge.isPaused(), "bridge should not be paused");
    }
}
