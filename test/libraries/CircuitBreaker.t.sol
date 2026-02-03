// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {CircuitBreaker} from "../../src/libraries/CircuitBreaker.sol";

/**
 * @title CircuitBreakerTest
 * @notice Tests for NIST IR-4 compliant circuit breaker
 */
contract CircuitBreakerTest is Test {
    using CircuitBreaker for CircuitBreaker.Config;

    // ============================================
    // STATE
    // ============================================

    CircuitBreakerHarness public harness;

    // Test parameters
    uint32 constant THRESHOLD = 10;
    uint64 constant WINDOW_DURATION = 1 hours;
    uint64 constant COOLDOWN_DURATION = 30 minutes;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        harness = new CircuitBreakerHarness();
        harness.initialize(THRESHOLD, WINDOW_DURATION, COOLDOWN_DURATION);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsCorrectValues() public view {
        (
            uint64 windowStart,
            uint64 cooldownEnds,
            uint64 count,
            uint32 threshold,
            bool tripped,
            uint64 windowDuration,
            uint64 cooldownDuration
        ) = harness.getConfig();

        assertEq(threshold, THRESHOLD, "Threshold set");
        assertEq(windowDuration, WINDOW_DURATION, "Window duration set");
        assertEq(cooldownDuration, COOLDOWN_DURATION, "Cooldown duration set");
        assertEq(windowStart, block.timestamp, "Window start is now");
        assertEq(cooldownEnds, 0, "No cooldown initially");
        assertEq(count, 0, "Count starts at 0");
        assertFalse(tripped, "Not tripped initially");
    }

    function test_initialize_revertsOnZeroThreshold() public {
        CircuitBreakerHarness h = new CircuitBreakerHarness();
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.InvalidConfig.selector, "threshold cannot be 0"));
        h.initialize(0, WINDOW_DURATION, COOLDOWN_DURATION);
    }

    function test_initialize_revertsOnZeroWindow() public {
        CircuitBreakerHarness h = new CircuitBreakerHarness();
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.InvalidConfig.selector, "window cannot be 0"));
        h.initialize(THRESHOLD, 0, COOLDOWN_DURATION);
    }

    function test_initialize_revertsOnZeroCooldown() public {
        CircuitBreakerHarness h = new CircuitBreakerHarness();
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.InvalidConfig.selector, "cooldown cannot be 0"));
        h.initialize(THRESHOLD, WINDOW_DURATION, 0);
    }

    function test_isInitialized_returnsTrueAfterInit() public view {
        assertTrue(harness.isInitialized(), "Should be initialized");
    }

    function test_isInitialized_returnsFalseBeforeInit() public {
        CircuitBreakerHarness h = new CircuitBreakerHarness();
        assertFalse(h.isInitialized(), "Should not be initialized");
    }

    // ============================================
    // CHECK TESTS
    // ============================================

    function test_check_incrementsCount() public {
        harness.check();
        assertEq(harness.currentCount(), 1, "Count should be 1");

        harness.check();
        assertEq(harness.currentCount(), 2, "Count should be 2");

        harness.check();
        assertEq(harness.currentCount(), 3, "Count should be 3");
    }

    function test_check_tripsAtThreshold() public {
        // Call check() threshold times
        for (uint256 i = 0; i < THRESHOLD - 1; i++) {
            bool tripped = harness.check();
            assertFalse(tripped, "Should not trip before threshold");
        }

        // This call should trip
        bool tripped = harness.check();
        assertTrue(tripped, "Should trip at threshold");

        // Verify status
        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertTrue(isTripped, "Should be tripped");
        assertEq(cooldownRemaining, COOLDOWN_DURATION, "Cooldown should be full");
    }

    function test_check_revertsInCooldown() public {
        // Trip the circuit
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }

        // Advance time but stay in cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION / 2);

        // Should revert with remaining time
        vm.expectRevert(
            abi.encodeWithSelector(
                CircuitBreaker.CircuitBreakerCooldown.selector,
                COOLDOWN_DURATION / 2
            )
        );
        harness.check();
    }

    function test_check_resetsAfterCooldown() public {
        // Trip the circuit
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }

        // Advance past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1);

        // Should reset and allow check
        bool tripped = harness.check();
        assertFalse(tripped, "Should not trip after reset");

        // Count should be 1 (from this check)
        assertEq(harness.currentCount(), 1, "Count should be 1 after reset");

        // Status should show not tripped
        (bool isTripped,) = harness.status();
        assertFalse(isTripped, "Should not be tripped after cooldown");
    }

    function test_check_resetsOnNewWindow() public {
        // Increment count but don't trip
        for (uint256 i = 0; i < THRESHOLD - 2; i++) {
            harness.check();
        }
        assertEq(harness.currentCount(), THRESHOLD - 2, "Count should be threshold - 2");

        // Advance past window
        vm.warp(block.timestamp + WINDOW_DURATION + 1);

        // Count should reset
        assertEq(harness.currentCount(), 0, "Count should be 0 in new window");

        // Check should start fresh count
        harness.check();
        assertEq(harness.currentCount(), 1, "Count should be 1 in new window");
    }

    function test_check_emitsWarningAt80Percent() public {
        // 80% of 10 = 8
        for (uint256 i = 0; i < 7; i++) {
            harness.check();
        }

        // The 8th call should emit warning
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.CircuitWarning(block.timestamp, 8, THRESHOLD);
        harness.check();
    }

    function test_check_emitsCircuitTripped() public {
        for (uint256 i = 0; i < THRESHOLD - 1; i++) {
            harness.check();
        }

        uint256 expectedCooldownEnds = block.timestamp + COOLDOWN_DURATION;

        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.CircuitTripped(
            block.timestamp,
            THRESHOLD,
            THRESHOLD,
            expectedCooldownEnds
        );
        harness.check();
    }

    function test_check_emitsCircuitReset() public {
        // Trip
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }

        uint256 expectedPreviousCooldown = block.timestamp + COOLDOWN_DURATION;

        // Advance past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1);

        // Reset should emit event
        vm.expectEmit(true, false, false, true);
        emit CircuitBreaker.CircuitReset(block.timestamp, expectedPreviousCooldown);
        harness.check();
    }

    // ============================================
    // STATUS TESTS
    // ============================================

    function test_status_notTrippedInitially() public view {
        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertFalse(isTripped, "Should not be tripped initially");
        assertEq(cooldownRemaining, 0, "No cooldown initially");
    }

    function test_status_trippedAfterThreshold() public {
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }

        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertTrue(isTripped, "Should be tripped");
        assertEq(cooldownRemaining, COOLDOWN_DURATION, "Full cooldown");
    }

    function test_status_cooldownDecreases() public {
        // Trip
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }

        // Advance time
        vm.warp(block.timestamp + 10 minutes);

        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertTrue(isTripped, "Still tripped");
        assertEq(cooldownRemaining, COOLDOWN_DURATION - 10 minutes, "Cooldown decreased");
    }

    function test_status_notTrippedAfterCooldown() public {
        // Trip
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }

        // Advance past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1);

        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertFalse(isTripped, "Should not be tripped after cooldown");
        assertEq(cooldownRemaining, 0, "No cooldown remaining");
    }

    // ============================================
    // FORCE RESET TESTS
    // ============================================

    function test_forceReset_resetsTrippedCircuit() public {
        // Trip
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }

        address admin = makeAddr("admin");

        // Force reset
        vm.expectEmit(true, true, false, true);
        emit CircuitBreaker.CircuitForceReset(block.timestamp, admin);
        harness.forceReset(admin);

        // Verify reset
        (bool isTripped,) = harness.status();
        assertFalse(isTripped, "Should not be tripped after force reset");
        assertEq(harness.currentCount(), 0, "Count should be 0");
    }

    function test_forceReset_resetsCountAndWindow() public {
        // Increment count
        for (uint256 i = 0; i < 5; i++) {
            harness.check();
        }

        address admin = makeAddr("admin");
        harness.forceReset(admin);

        assertEq(harness.currentCount(), 0, "Count should be 0");
    }

    // ============================================
    // CAPACITY TESTS
    // ============================================

    function test_remainingCapacity_fullInitially() public view {
        assertEq(harness.remainingCapacity(), THRESHOLD, "Full capacity initially");
    }

    function test_remainingCapacity_decreasesWithChecks() public {
        harness.check();
        assertEq(harness.remainingCapacity(), THRESHOLD - 1, "Capacity decreased by 1");

        harness.check();
        harness.check();
        assertEq(harness.remainingCapacity(), THRESHOLD - 3, "Capacity decreased by 3");
    }

    function test_remainingCapacity_zeroWhenTripped() public {
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }
        assertEq(harness.remainingCapacity(), 0, "Zero capacity when tripped");
    }

    function test_remainingCapacity_resetsWithNewWindow() public {
        for (uint256 i = 0; i < 5; i++) {
            harness.check();
        }

        vm.warp(block.timestamp + WINDOW_DURATION + 1);

        assertEq(harness.remainingCapacity(), THRESHOLD, "Full capacity in new window");
    }

    // ============================================
    // CONFIGURATION TESTS
    // ============================================

    function test_setThreshold_updatesValue() public {
        harness.setThreshold(20);
        (,,, uint32 threshold,,,) = harness.getConfig();
        assertEq(threshold, 20, "Threshold updated");
    }

    function test_setThreshold_revertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.InvalidConfig.selector, "threshold cannot be 0"));
        harness.setThreshold(0);
    }

    function test_setCooldown_updatesValue() public {
        harness.setCooldown(2 hours);
        (,,,,,, uint64 cooldownDuration) = harness.getConfig();
        assertEq(cooldownDuration, 2 hours, "Cooldown updated");
    }

    function test_setCooldown_revertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.InvalidConfig.selector, "cooldown cannot be 0"));
        harness.setCooldown(0);
    }

    function test_setWindow_updatesValue() public {
        harness.setWindow(2 hours);
        (,,,,, uint64 windowDuration,) = harness.getConfig();
        assertEq(windowDuration, 2 hours, "Window updated");
    }

    function test_setWindow_revertsOnZero() public {
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.InvalidConfig.selector, "window cannot be 0"));
        harness.setWindow(0);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_thresholdBehavior(uint32 threshold, uint64 callCount) public {
        // Bound inputs
        threshold = uint32(bound(threshold, 1, 1000));
        callCount = uint64(bound(callCount, 1, 1500));

        CircuitBreakerHarness h = new CircuitBreakerHarness();
        h.initialize(threshold, WINDOW_DURATION, COOLDOWN_DURATION);

        bool shouldTrip = callCount >= threshold;
        bool didTrip = false;

        for (uint64 i = 0; i < callCount; i++) {
            (bool isTripped,) = h.status();
            if (isTripped) {
                // In cooldown - skip this iteration
                break;
            }

            bool tripped = h.check();
            if (tripped) {
                didTrip = true;
                break;
            }
        }

        if (shouldTrip) {
            assertTrue(didTrip, "Should have tripped");
        }
    }

    function testFuzz_cooldownRespected(uint64 advanceTime) public {
        advanceTime = uint64(bound(advanceTime, 0, COOLDOWN_DURATION * 2));

        // Trip the circuit
        for (uint256 i = 0; i < THRESHOLD; i++) {
            harness.check();
        }

        vm.warp(block.timestamp + advanceTime);

        (bool isTripped, uint256 remaining) = harness.status();

        if (advanceTime < COOLDOWN_DURATION) {
            assertTrue(isTripped, "Should still be tripped");
            assertEq(remaining, COOLDOWN_DURATION - advanceTime, "Remaining matches");
        } else {
            assertFalse(isTripped, "Should not be tripped after cooldown");
            assertEq(remaining, 0, "No remaining cooldown");
        }
    }

    // ============================================
    // GAS TESTS
    // ============================================

    function test_check_gasEfficiency() public {
        // Warm up storage
        harness.check();

        // Measure warm gas
        uint256 gasBefore = gasleft();
        harness.check();
        uint256 gasUsed = gasBefore - gasleft();

        // Should be < 3,000 gas for warm reads (spec target)
        assertLt(gasUsed, 3000, "Warm check should be < 3000 gas");
    }
}

// ============================================
// TEST HARNESS
// ============================================

/**
 * @notice Test harness to expose internal library functions
 */
contract CircuitBreakerHarness {
    using CircuitBreaker for CircuitBreaker.Config;

    CircuitBreaker.Config private _config;

    function initialize(
        uint32 threshold,
        uint64 windowDuration,
        uint64 cooldownDuration
    ) external {
        _config.initialize(threshold, windowDuration, cooldownDuration);
    }

    function check() external returns (bool) {
        return _config.check();
    }

    function status() external view returns (bool, uint256) {
        return _config.status();
    }

    function forceReset(address admin) external {
        _config.forceReset(admin);
    }

    function setThreshold(uint32 newThreshold) external {
        _config.setThreshold(newThreshold);
    }

    function setCooldown(uint64 newCooldown) external {
        _config.setCooldown(newCooldown);
    }

    function setWindow(uint64 newWindow) external {
        _config.setWindow(newWindow);
    }

    function currentCount() external view returns (uint64) {
        return _config.currentCount();
    }

    function remainingCapacity() external view returns (uint256) {
        return _config.remainingCapacity();
    }

    function isInitialized() external view returns (bool) {
        return _config.isInitialized();
    }

    function getConfig() external view returns (
        uint64 windowStart,
        uint64 cooldownEnds,
        uint64 count,
        uint32 threshold,
        bool tripped,
        uint64 windowDuration,
        uint64 cooldownDuration
    ) {
        return (
            _config.windowStart,
            _config.cooldownEnds,
            _config.count,
            _config.threshold,
            _config.tripped,
            _config.windowDuration,
            _config.cooldownDuration
        );
    }
}
