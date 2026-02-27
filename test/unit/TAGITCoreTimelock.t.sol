// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title TAGITCoreTimelockTest
 * @notice Tests for TAGITCore admin operations through TimelockController (48hr delay)
 * @dev Validates that all owner-gated functions enforce the timelock delay
 */
contract TAGITCoreTimelockTest is Test {
    TAGITCore public proxy;
    TimelockController public timelock;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public proposer;
    address public executor;
    address public attacker;

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    function setUp() public {
        proposer = makeAddr("proposer");
        executor = makeAddr("executor");
        attacker = makeAddr("attacker");

        // Deploy TimelockController with 48hr delay
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = proposer;
        executors[0] = executor;
        timelock = new TimelockController(
            TIMELOCK_DELAY,
            proposers,
            executors,
            address(0) // no admin
        );

        // Deploy TAGITCore behind proxy, owned by timelock
        TAGITCore implementation = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (address(timelock)));
        ERC1967Proxy erc1967Proxy = new ERC1967Proxy(address(implementation), initData);
        proxy = TAGITCore(address(erc1967Proxy));

        // Deploy access control
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Configure access controller through timelock (schedule + wait + execute)
        bytes memory setAccessData = abi.encodeCall(TAGITCore.setAccessController, (address(tagitAccess)));

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, setAccessData, bytes32(0), bytes32(0), TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(executor);
        timelock.execute(address(proxy), 0, setAccessData, bytes32(0), bytes32(0));
    }

    // ============================================
    // TIMELOCK OWNERSHIP TESTS
    // ============================================

    function test_timelock_ownerIsTimelock() public view {
        assertEq(proxy.owner(), address(timelock));
    }

    function test_timelock_accessControllerSet() public view {
        assertEq(address(proxy.accessController()), address(tagitAccess));
    }

    // ============================================
    // DIRECT CALLS REVERT (bypass timelock)
    // ============================================

    function test_timelock_directSetAccessControllerReverts() public {
        vm.prank(proposer);
        vm.expectRevert();
        proxy.setAccessController(address(0));
    }

    function test_timelock_directResetCircuitBreakerReverts() public {
        vm.prank(proposer);
        vm.expectRevert();
        proxy.resetFlagCircuitBreaker();
    }

    function test_timelock_directUnlockMinterReverts() public {
        vm.prank(proposer);
        vm.expectRevert();
        proxy.unlockMinter(attacker);
    }

    function test_timelock_directSetThresholdReverts() public {
        vm.prank(proposer);
        vm.expectRevert();
        proxy.setFlagCircuitBreakerThreshold(100);
    }

    function test_timelock_directSetRateLimitReverts() public {
        vm.prank(proposer);
        vm.expectRevert();
        proxy.setMintRateLimitEnabled(false);
    }

    function test_timelock_attackerCannotCallDirectly() public {
        vm.prank(attacker);
        vm.expectRevert();
        proxy.setAccessController(address(0));
    }

    // ============================================
    // SCHEDULE + EXECUTE FLOW TESTS
    // ============================================

    function test_timelock_scheduleAndExecuteSetThreshold() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (100));
        bytes32 salt = keccak256("threshold_update_1");

        // Schedule
        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        // Cannot execute before delay
        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);

        // Warp past delay
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Execute succeeds
        vm.prank(executor);
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);
    }

    function test_timelock_scheduleAndExecuteResetCircuitBreaker() public {
        bytes memory data = abi.encodeCall(TAGITCore.resetFlagCircuitBreaker, ());
        bytes32 salt = keccak256("cb_reset_1");

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(executor);
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);

        // Verify circuit breaker is not tripped
        (bool isTripped,) = proxy.getFlagCircuitBreakerStatus();
        assertEq(isTripped, false);
    }

    function test_timelock_scheduleAndExecuteUnlockMinter() public {
        address user = makeAddr("rate_limited_user");
        bytes memory data = abi.encodeCall(TAGITCore.unlockMinter, (user));
        bytes32 salt = keccak256("unlock_1");

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(executor);
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);
    }

    function test_timelock_scheduleAndExecuteSetRateLimit() public {
        bytes memory data = abi.encodeCall(TAGITCore.setMintRateLimitEnabled, (false));
        bytes32 salt = keccak256("rate_limit_1");

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(executor);
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);
    }

    // ============================================
    // 48-HOUR DELAY ENFORCEMENT TESTS
    // ============================================

    function test_timelock_cannotExecuteBeforeDelay() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (200));
        bytes32 salt = keccak256("early_exec_1");

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        // Try executing 1 second before delay expires
        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);

        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);
    }

    function test_timelock_canExecuteExactlyAtDelay() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (200));
        bytes32 salt = keccak256("exact_delay_1");

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        // Warp exactly to delay
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(executor);
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);
    }

    function test_timelock_canExecuteAfterDelay() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (200));
        bytes32 salt = keccak256("after_delay_1");

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        // Warp well past delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 7 days);

        vm.prank(executor);
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);
    }

    // ============================================
    // ROLE ENFORCEMENT TESTS
    // ============================================

    function test_timelock_onlyProposerCanSchedule() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (100));
        bytes32 salt = keccak256("unauth_schedule_1");

        vm.prank(attacker);
        vm.expectRevert();
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);
    }

    function test_timelock_onlyExecutorCanExecute() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (100));
        bytes32 salt = keccak256("unauth_exec_1");

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(attacker);
        vm.expectRevert();
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);
    }

    // ============================================
    // CANCEL TESTS
    // ============================================

    function test_timelock_proposerCanCancel() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (100));
        bytes32 salt = keccak256("cancel_test_1");

        // Schedule
        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        // Get operation ID
        bytes32 opId = timelock.hashOperation(address(proxy), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(opId));

        // Cancel
        vm.prank(proposer);
        timelock.cancel(opId);

        // Verify cancelled
        assertFalse(timelock.isOperationPending(opId));
    }

    function test_timelock_attackerCannotCancel() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (100));
        bytes32 salt = keccak256("cancel_attack_1");

        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);

        bytes32 opId = timelock.hashOperation(address(proxy), 0, data, bytes32(0), salt);

        vm.prank(attacker);
        vm.expectRevert();
        timelock.cancel(opId);
    }

    // ============================================
    // MINIMUM DELAY TESTS
    // ============================================

    function test_timelock_minimumDelayIs48Hours() public view {
        assertEq(timelock.getMinDelay(), TIMELOCK_DELAY);
    }

    function test_timelock_cannotScheduleBelowMinDelay() public {
        bytes memory data = abi.encodeCall(TAGITCore.setFlagCircuitBreakerThreshold, (100));
        bytes32 salt = keccak256("low_delay_1");

        vm.prank(proposer);
        vm.expectRevert();
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY - 1);
    }
}
