// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {DrainDetector} from "../../src/libraries/DrainDetector.sol";

/**
 * @title DrainDetectorTest
 * @notice Tests for NIST SI-4 compliant drain detection
 */
contract DrainDetectorTest is Test {
    using DrainDetector for DrainDetector.Config;

    // ============================================
    // STATE
    // ============================================

    DrainDetectorHarness public harness;

    // Test parameters
    uint64 constant WINDOW_DURATION = 1 hours;
    uint16 constant SPIKE_THRESHOLD_BPS = 1000; // 10% max single withdrawal
    uint16 constant VELOCITY_THRESHOLD_BPS = 2500; // 25% max cumulative per window
    uint32 constant MAX_TX_PER_WINDOW = 50;
    uint64 constant COOLDOWN_DURATION = 30 minutes;
    uint128 constant INITIAL_BALANCE = 1000 ether;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        harness = new DrainDetectorHarness();
        harness.initialize(
            WINDOW_DURATION,
            SPIKE_THRESHOLD_BPS,
            VELOCITY_THRESHOLD_BPS,
            MAX_TX_PER_WINDOW,
            COOLDOWN_DURATION,
            INITIAL_BALANCE
        );
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsCorrectValues() public view {
        (
            uint64 windowDuration,
            uint64 windowStart,
            uint16 spikeThreshold,
            uint16 velocityThreshold,
            uint32 maxTx,
            bool enabled,
            bool tripped,
            uint128 balance
        ) = harness.getConfig();

        assertEq(windowDuration, WINDOW_DURATION, "Window duration set");
        assertEq(windowStart, block.timestamp, "Window start is now");
        assertEq(spikeThreshold, SPIKE_THRESHOLD_BPS, "Spike threshold set");
        assertEq(velocityThreshold, VELOCITY_THRESHOLD_BPS, "Velocity threshold set");
        assertEq(maxTx, MAX_TX_PER_WINDOW, "Max tx set");
        assertTrue(enabled, "Enabled by default");
        assertFalse(tripped, "Not tripped initially");
        assertEq(balance, INITIAL_BALANCE, "Balance set");
    }

    function test_initialize_revertsOnZeroWindow() public {
        DrainDetectorHarness h = new DrainDetectorHarness();
        vm.expectRevert(abi.encodeWithSelector(DrainDetector.InvalidConfig.selector, "window cannot be 0"));
        h.initialize(0, SPIKE_THRESHOLD_BPS, VELOCITY_THRESHOLD_BPS, MAX_TX_PER_WINDOW, COOLDOWN_DURATION, INITIAL_BALANCE);
    }

    function test_initialize_revertsOnZeroSpikeThreshold() public {
        DrainDetectorHarness h = new DrainDetectorHarness();
        vm.expectRevert(abi.encodeWithSelector(DrainDetector.InvalidConfig.selector, "spike threshold invalid"));
        h.initialize(WINDOW_DURATION, 0, VELOCITY_THRESHOLD_BPS, MAX_TX_PER_WINDOW, COOLDOWN_DURATION, INITIAL_BALANCE);
    }

    function test_initialize_revertsOnExcessiveSpikeThreshold() public {
        DrainDetectorHarness h = new DrainDetectorHarness();
        vm.expectRevert(abi.encodeWithSelector(DrainDetector.InvalidConfig.selector, "spike threshold invalid"));
        h.initialize(WINDOW_DURATION, 10001, VELOCITY_THRESHOLD_BPS, MAX_TX_PER_WINDOW, COOLDOWN_DURATION, INITIAL_BALANCE);
    }

    function test_initialize_revertsOnZeroVelocityThreshold() public {
        DrainDetectorHarness h = new DrainDetectorHarness();
        vm.expectRevert(abi.encodeWithSelector(DrainDetector.InvalidConfig.selector, "velocity threshold invalid"));
        h.initialize(WINDOW_DURATION, SPIKE_THRESHOLD_BPS, 0, MAX_TX_PER_WINDOW, COOLDOWN_DURATION, INITIAL_BALANCE);
    }

    function test_initialize_revertsOnZeroMaxTx() public {
        DrainDetectorHarness h = new DrainDetectorHarness();
        vm.expectRevert(abi.encodeWithSelector(DrainDetector.InvalidConfig.selector, "maxTx cannot be 0"));
        h.initialize(WINDOW_DURATION, SPIKE_THRESHOLD_BPS, VELOCITY_THRESHOLD_BPS, 0, COOLDOWN_DURATION, INITIAL_BALANCE);
    }

    function test_initialize_revertsOnZeroCooldown() public {
        DrainDetectorHarness h = new DrainDetectorHarness();
        vm.expectRevert(abi.encodeWithSelector(DrainDetector.InvalidConfig.selector, "cooldown cannot be 0"));
        h.initialize(WINDOW_DURATION, SPIKE_THRESHOLD_BPS, VELOCITY_THRESHOLD_BPS, MAX_TX_PER_WINDOW, 0, INITIAL_BALANCE);
    }

    function test_isInitialized_returnsTrueAfterInit() public view {
        assertTrue(harness.isInitialized(), "Should be initialized");
    }

    function test_isInitialized_returnsFalseBeforeInit() public {
        DrainDetectorHarness h = new DrainDetectorHarness();
        assertFalse(h.isInitialized(), "Should not be initialized");
    }

    // ============================================
    // SPIKE DETECTION TESTS
    // ============================================

    function test_checkWithdrawal_allowsBelowSpikeThreshold() public {
        // 10% of 1000 ETH = 100 ETH threshold
        uint256 safeAmount = 99 ether;
        uint8 result = harness.checkWithdrawal(safeAmount);
        assertEq(result, 0, "Should allow below threshold");
    }

    function test_checkWithdrawal_detectsSpike() public {
        // 10% of 1000 ETH = 100 ETH threshold
        uint256 spikeAmount = 101 ether;

        uint8 result = harness.checkWithdrawal(spikeAmount);
        assertEq(result, 1, "Should return spike reason code");

        (bool isTripped,) = harness.status();
        assertTrue(isTripped, "Should be tripped");
    }

    function test_checkWithdrawal_emitsSpikeAlert() public {
        uint256 spikeAmount = 101 ether;

        vm.expectEmit(true, false, false, true);
        emit DrainDetector.SpikeAlert(block.timestamp, spikeAmount, SPIKE_THRESHOLD_BPS, INITIAL_BALANCE);

        harness.checkWithdrawal(spikeAmount);
    }

    function test_checkWithdrawal_emitsSpikeWarningAt80Percent() public {
        // 80% of 100 ETH threshold = 80 ETH
        uint256 warningAmount = 81 ether;
        uint256 threshold = (INITIAL_BALANCE * SPIKE_THRESHOLD_BPS) / 10000;

        vm.expectEmit(true, false, false, true);
        emit DrainDetector.DrainWarning(block.timestamp, 1, warningAmount, threshold);
        harness.checkWithdrawal(warningAmount);
    }

    // ============================================
    // VELOCITY DETECTION TESTS
    // ============================================

    function test_checkWithdrawal_allowsBelowVelocityThreshold() public {
        // 25% of 1000 ETH = 250 ETH cumulative threshold
        // Do 3 withdrawals of 80 ETH each = 240 ETH (below 250)
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);

        // Check window stats
        (uint256 outflow,,,) = harness.windowStats();
        assertEq(outflow, 240 ether, "Cumulative outflow tracked");
    }

    function test_checkWithdrawal_detectsVelocityBreach() public {
        // 25% of 1000 ETH = 250 ETH threshold
        // First withdrawal of 80 ETH OK
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);

        // Fourth withdrawal would push to 320 ETH > 250 ETH threshold
        uint8 result = harness.checkWithdrawal(80 ether);
        assertEq(result, 2, "Should return velocity reason code");

        (bool isTripped,) = harness.status();
        assertTrue(isTripped, "Should be tripped");
    }

    function test_checkWithdrawal_emitsVelocityAlert() public {
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);

        vm.expectEmit(true, false, false, true);
        emit DrainDetector.VelocityAlert(block.timestamp, 320 ether, VELOCITY_THRESHOLD_BPS, INITIAL_BALANCE);

        harness.checkWithdrawal(80 ether);
    }

    function test_checkWithdrawal_emitsVelocityWarningAt80Percent() public {
        // 80% of 250 ETH = 200 ETH
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);

        uint256 velocityThreshold = (INITIAL_BALANCE * VELOCITY_THRESHOLD_BPS) / 10000;

        // This pushes to 210 ETH (> 200 ETH warning threshold)
        vm.expectEmit(true, false, false, true);
        emit DrainDetector.DrainWarning(block.timestamp, 2, 210 ether, velocityThreshold);
        harness.checkWithdrawal(50 ether);
    }

    // ============================================
    // FREQUENCY DETECTION TESTS
    // ============================================

    function test_checkWithdrawal_allowsBelowFrequencyThreshold() public {
        // Do MAX_TX_PER_WINDOW - 1 transactions
        for (uint256 i = 0; i < MAX_TX_PER_WINDOW - 1; i++) {
            harness.checkWithdrawal(1 ether);
        }

        (, uint32 txCount,,) = harness.windowStats();
        assertEq(txCount, MAX_TX_PER_WINDOW - 1, "Tx count tracked");
    }

    function test_checkWithdrawal_detectsFrequencyBreach() public {
        // Do exactly MAX_TX_PER_WINDOW transactions
        for (uint256 i = 0; i < MAX_TX_PER_WINDOW; i++) {
            harness.checkWithdrawal(1 ether);
        }

        // Next should detect breach
        uint8 result = harness.checkWithdrawal(1 ether);
        assertEq(result, 3, "Should return frequency reason code");

        (bool isTripped,) = harness.status();
        assertTrue(isTripped, "Should be tripped");
    }

    function test_checkWithdrawal_emitsFrequencyAlert() public {
        for (uint256 i = 0; i < MAX_TX_PER_WINDOW; i++) {
            harness.checkWithdrawal(1 ether);
        }

        vm.expectEmit(true, false, false, true);
        emit DrainDetector.FrequencyAlert(block.timestamp, MAX_TX_PER_WINDOW + 1, MAX_TX_PER_WINDOW);

        harness.checkWithdrawal(1 ether);
    }

    function test_checkWithdrawal_emitsFrequencyWarningAt80Percent() public {
        // 80% of 50 = 40
        for (uint256 i = 0; i < 40; i++) {
            harness.checkWithdrawal(1 ether);
        }

        // 41st tx should emit warning
        vm.expectEmit(true, false, false, true);
        emit DrainDetector.DrainWarning(block.timestamp, 3, 41, MAX_TX_PER_WINDOW);
        harness.checkWithdrawal(1 ether);
    }

    // ============================================
    // TRIP AND COOLDOWN TESTS
    // ============================================

    function test_checkWithdrawal_tripsOnSpike() public {
        harness.checkWithdrawal(101 ether);

        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertTrue(isTripped, "Should be tripped");
        assertEq(cooldownRemaining, COOLDOWN_DURATION, "Full cooldown");
    }

    function test_checkWithdrawal_emitsDetectorTripped() public {
        uint256 expectedCooldownEnds = block.timestamp + COOLDOWN_DURATION;

        vm.expectEmit(true, false, false, true);
        emit DrainDetector.DetectorTripped(block.timestamp, 1, expectedCooldownEnds);

        harness.checkWithdrawal(101 ether);
    }

    function test_checkWithdrawal_revertsInCooldown() public {
        // Trip the detector
        harness.checkWithdrawal(101 ether);

        // Try again in cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION / 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                DrainDetector.DetectorCooldown.selector,
                COOLDOWN_DURATION / 2
            )
        );
        harness.checkWithdrawal(1 ether);
    }

    function test_checkWithdrawal_resetsAfterCooldown() public {
        // Trip the detector
        harness.checkWithdrawal(101 ether);

        // Advance past cooldown
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1);

        // Should reset and allow
        uint8 result = harness.checkWithdrawal(50 ether);
        assertEq(result, 0, "Should allow after cooldown");

        (bool isTripped,) = harness.status();
        assertFalse(isTripped, "Should not be tripped after reset");
    }

    function test_checkWithdrawal_emitsDetectorReset() public {
        // Trip
        harness.checkWithdrawal(101 ether);

        uint256 cooldownEnds = block.timestamp + COOLDOWN_DURATION;
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1);

        vm.expectEmit(true, false, false, true);
        emit DrainDetector.DetectorReset(block.timestamp, cooldownEnds);
        harness.checkWithdrawal(50 ether);
    }

    // ============================================
    // WINDOW RESET TESTS
    // ============================================

    function test_checkWithdrawal_resetsWindowAfterDuration() public {
        // Build up outflow
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);

        (uint256 outflow, uint32 txCount,,) = harness.windowStats();
        assertEq(outflow, 160 ether, "Outflow accumulated");
        assertEq(txCount, 2, "Tx count accumulated");

        // Advance past window
        vm.warp(block.timestamp + WINDOW_DURATION + 1);

        // Window should reset
        (outflow, txCount,,) = harness.windowStats();
        assertEq(outflow, 0, "Outflow reset");
        assertEq(txCount, 0, "Tx count reset");

        // Can make large withdrawal again
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);
        // 240 ETH < 250 ETH threshold
    }

    // ============================================
    // BALANCE TRACKING TESTS
    // ============================================

    function test_recordWithdrawal_updatesBalance() public {
        harness.checkWithdrawal(50 ether);
        harness.recordWithdrawal(50 ether);

        assertEq(harness.getBalance(), 950 ether, "Balance decreased");
    }

    function test_recordWithdrawal_emitsBalanceUpdated() public {
        harness.checkWithdrawal(50 ether);

        vm.expectEmit(false, false, false, true);
        emit DrainDetector.BalanceUpdated(1000 ether, 950 ether);
        harness.recordWithdrawal(50 ether);
    }

    function test_recordDeposit_updatesBalance() public {
        harness.recordDeposit(100 ether);
        assertEq(harness.getBalance(), 1100 ether, "Balance increased");
    }

    function test_recordDeposit_capsAtMax() public {
        harness.recordDeposit(type(uint128).max);
        assertEq(harness.getBalance(), type(uint128).max, "Balance capped");
    }

    function test_setBalance_updatesDirectly() public {
        harness.setBalance(500 ether);
        assertEq(harness.getBalance(), 500 ether, "Balance set directly");
    }

    // ============================================
    // FORCE RESET TESTS
    // ============================================

    function test_forceReset_resetsTrippedDetector() public {
        // Trip
        harness.checkWithdrawal(101 ether);

        address admin = makeAddr("admin");

        vm.expectEmit(true, true, false, true);
        emit DrainDetector.DetectorForceReset(block.timestamp, admin);
        harness.forceReset(admin);

        (bool isTripped,) = harness.status();
        assertFalse(isTripped, "Should not be tripped after force reset");
    }

    function test_forceReset_resetsWindowStats() public {
        harness.checkWithdrawal(50 ether);
        harness.checkWithdrawal(50 ether);

        address admin = makeAddr("admin");
        harness.forceReset(admin);

        (uint256 outflow, uint32 txCount,,) = harness.windowStats();
        assertEq(outflow, 0, "Outflow reset");
        assertEq(txCount, 0, "Tx count reset");
    }

    // ============================================
    // ENABLED/DISABLED TESTS
    // ============================================

    function test_checkWithdrawal_allowsAllWhenDisabled() public {
        harness.setEnabled(false);

        // Should allow spike
        uint8 result = harness.checkWithdrawal(500 ether);
        assertEq(result, 0, "Should allow when disabled");
    }

    function test_isEnabled_returnsCorrectState() public {
        assertTrue(harness.isEnabled(), "Should be enabled");
        harness.setEnabled(false);
        assertFalse(harness.isEnabled(), "Should be disabled");
    }

    // ============================================
    // WOULD TRIGGER VIEW TESTS
    // ============================================

    function test_wouldTrigger_detectsSpike() public view {
        (bool wouldTrip, uint8 reason) = harness.wouldTrigger(101 ether);
        assertTrue(wouldTrip, "Should detect spike");
        assertEq(reason, 1, "Reason should be spike");
    }

    function test_wouldTrigger_detectsVelocity() public {
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);

        (bool wouldTrip, uint8 reason) = harness.wouldTrigger(20 ether);
        assertTrue(wouldTrip, "Should detect velocity breach");
        assertEq(reason, 2, "Reason should be velocity");
    }

    function test_wouldTrigger_detectsFrequency() public {
        for (uint256 i = 0; i < MAX_TX_PER_WINDOW; i++) {
            harness.checkWithdrawal(1 ether);
        }

        (bool wouldTrip, uint8 reason) = harness.wouldTrigger(1 ether);
        assertTrue(wouldTrip, "Should detect frequency breach");
        assertEq(reason, 3, "Reason should be frequency");
    }

    function test_wouldTrigger_returnsFalseForSafe() public view {
        (bool wouldTrip, uint8 reason) = harness.wouldTrigger(50 ether);
        assertFalse(wouldTrip, "Should not trigger for safe amount");
        assertEq(reason, 0, "No reason");
    }

    // ============================================
    // REMAINING CAPACITY TESTS
    // ============================================

    function test_remainingCapacity_fullInitially() public view {
        (uint256 spike, uint256 velocity, uint32 txCap) = harness.remainingCapacity();

        assertEq(spike, 100 ether, "Spike capacity = 10%");
        assertEq(velocity, 250 ether, "Velocity capacity = 25%");
        assertEq(txCap, MAX_TX_PER_WINDOW, "Full tx capacity");
    }

    function test_remainingCapacity_decreasesWithWithdrawals() public {
        harness.checkWithdrawal(80 ether);
        harness.checkWithdrawal(80 ether);

        (uint256 spike, uint256 velocity, uint32 txCap) = harness.remainingCapacity();

        assertEq(spike, 100 ether, "Spike unchanged (per-tx)");
        assertEq(velocity, 90 ether, "Velocity decreased");
        assertEq(txCap, MAX_TX_PER_WINDOW - 2, "Tx capacity decreased");
    }

    function test_remainingCapacity_maxWhenDisabled() public {
        harness.setEnabled(false);

        (uint256 spike, uint256 velocity, uint32 txCap) = harness.remainingCapacity();

        assertEq(spike, type(uint256).max, "Max spike when disabled");
        assertEq(velocity, type(uint256).max, "Max velocity when disabled");
        assertEq(txCap, type(uint32).max, "Max tx when disabled");
    }

    // ============================================
    // THRESHOLD UPDATE TESTS
    // ============================================

    function test_updateThresholds_updatesSpike() public {
        harness.updateThresholds(2000, 0, 0); // 20%

        (,, uint16 spikeThreshold,,,,,) = harness.getConfig();
        assertEq(spikeThreshold, 2000, "Spike updated");
    }

    function test_updateThresholds_updatesVelocity() public {
        harness.updateThresholds(0, 5000, 0); // 50%

        (,,, uint16 velocityThreshold,,,,) = harness.getConfig();
        assertEq(velocityThreshold, 5000, "Velocity updated");
    }

    function test_updateThresholds_updatesMaxTx() public {
        harness.updateThresholds(0, 0, 100);

        (,,,, uint32 maxTx,,,) = harness.getConfig();
        assertEq(maxTx, 100, "MaxTx updated");
    }

    function test_updateThresholds_revertsOnInvalidSpike() public {
        vm.expectRevert(abi.encodeWithSelector(DrainDetector.InvalidConfig.selector, "spike threshold invalid"));
        harness.updateThresholds(10001, 0, 0);
    }

    function test_updateThresholds_revertsOnInvalidVelocity() public {
        vm.expectRevert(abi.encodeWithSelector(DrainDetector.InvalidConfig.selector, "velocity threshold invalid"));
        harness.updateThresholds(0, 10001, 0);
    }

    // ============================================
    // STATUS TESTS
    // ============================================

    function test_status_notTrippedInitially() public view {
        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertFalse(isTripped, "Not tripped initially");
        assertEq(cooldownRemaining, 0, "No cooldown");
    }

    function test_status_cooldownDecreases() public {
        // Trip
        harness.checkWithdrawal(101 ether);

        vm.warp(block.timestamp + 10 minutes);

        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertTrue(isTripped, "Still tripped");
        assertEq(cooldownRemaining, COOLDOWN_DURATION - 10 minutes, "Cooldown decreased");
    }

    function test_status_notTrippedAfterCooldown() public {
        // Trip
        harness.checkWithdrawal(101 ether);

        vm.warp(block.timestamp + COOLDOWN_DURATION + 1);

        (bool isTripped, uint256 cooldownRemaining) = harness.status();
        assertFalse(isTripped, "Not tripped after cooldown");
        assertEq(cooldownRemaining, 0, "No cooldown remaining");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_spikeDetection(uint256 amount, uint128 balance) public {
        balance = uint128(bound(balance, 1 ether, 1000000 ether));
        amount = bound(amount, 0, balance * 2);

        DrainDetectorHarness h = new DrainDetectorHarness();
        h.initialize(
            WINDOW_DURATION,
            SPIKE_THRESHOLD_BPS, // 10%
            VELOCITY_THRESHOLD_BPS,
            MAX_TX_PER_WINDOW,
            COOLDOWN_DURATION,
            balance
        );

        uint256 spikeThreshold = (uint256(balance) * SPIKE_THRESHOLD_BPS) / 10000;
        bool shouldTrip = amount > spikeThreshold;

        uint8 result = h.checkWithdrawal(amount);

        if (shouldTrip) {
            assertEq(result, 1, "Should return spike reason code");
            (bool isTripped,) = h.status();
            assertTrue(isTripped, "Should trip on spike");
        } else {
            assertEq(result, 0, "Should return OK");
            (bool isTripped,) = h.status();
            assertFalse(isTripped, "Should not trip below threshold");
        }
    }

    function testFuzz_velocityAccumulation(uint8 numWithdrawals) public {
        numWithdrawals = uint8(bound(numWithdrawals, 1, 50));

        // Use small amounts to avoid spike detection
        uint256 amountPerTx = 4 ether; // Well below 10% spike threshold
        uint256 totalExpected = 0;
        bool tripped = false;

        for (uint256 i = 0; i < numWithdrawals; i++) {
            uint256 newTotal = totalExpected + amountPerTx;
            uint256 velocityThreshold = (INITIAL_BALANCE * VELOCITY_THRESHOLD_BPS) / 10000;

            uint8 result = harness.checkWithdrawal(amountPerTx);
            if (result > 0) {
                tripped = true;
                break;
            }
            totalExpected = newTotal;
        }

        (uint256 outflow,,,) = harness.windowStats();
        // Note: outflow is only updated on successful checks, so it should match totalExpected
        if (!tripped) {
            assertEq(outflow, totalExpected, "Outflow matches expected");
        }
    }

    function testFuzz_cooldownRespected(uint64 advanceTime) public {
        advanceTime = uint64(bound(advanceTime, 0, COOLDOWN_DURATION * 2));

        // Trip the detector
        harness.checkWithdrawal(101 ether);

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

    function test_checkWithdrawal_gasEfficiency() public {
        // Warm up storage
        harness.checkWithdrawal(1 ether);

        // Measure warm gas
        uint256 gasBefore = gasleft();
        harness.checkWithdrawal(1 ether);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be < 5,000 gas for warm reads (spec target)
        assertLt(gasUsed, 5000, "Warm check should be < 5000 gas");
    }

    function test_wouldTrigger_gasEfficiency() public {
        // Warm up
        harness.checkWithdrawal(1 ether);

        // Measure view function gas
        uint256 gasBefore = gasleft();
        harness.wouldTrigger(50 ether);
        uint256 gasUsed = gasBefore - gasleft();

        // View should be cheaper
        assertLt(gasUsed, 4000, "View should be < 4000 gas");
    }
}

// ============================================
// TEST HARNESS
// ============================================

/**
 * @notice Test harness to expose internal library functions
 */
contract DrainDetectorHarness {
    using DrainDetector for DrainDetector.Config;

    DrainDetector.Config private _config;

    function initialize(
        uint64 windowDuration,
        uint16 spikeThresholdBps,
        uint16 velocityThresholdBps,
        uint32 maxTxPerWindow,
        uint64 cooldownDuration,
        uint128 initialBalance
    ) external {
        _config.initialize(
            windowDuration,
            spikeThresholdBps,
            velocityThresholdBps,
            maxTxPerWindow,
            cooldownDuration,
            initialBalance
        );
    }

    function checkWithdrawal(uint256 amount) external returns (uint8) {
        return _config.checkWithdrawal(amount);
    }

    function recordWithdrawal(uint256 amount) external {
        _config.recordWithdrawal(amount);
    }

    function recordDeposit(uint256 amount) external {
        _config.recordDeposit(amount);
    }

    function forceReset(address admin) external {
        _config.forceReset(admin);
    }

    function setEnabled(bool enabled) external {
        _config.setEnabled(enabled);
    }

    function setBalance(uint128 newBalance) external {
        _config.setBalance(newBalance);
    }

    function updateThresholds(
        uint16 spikeThresholdBps,
        uint16 velocityThresholdBps,
        uint32 maxTxPerWindow
    ) external {
        _config.updateThresholds(spikeThresholdBps, velocityThresholdBps, maxTxPerWindow);
    }

    function status() external view returns (bool, uint256) {
        return _config.status();
    }

    function wouldTrigger(uint256 amount) external view returns (bool, uint8) {
        return _config.wouldTrigger(amount);
    }

    function windowStats() external view returns (uint256, uint32, uint64, uint256) {
        return _config.windowStats();
    }

    function remainingCapacity() external view returns (uint256, uint256, uint32) {
        return _config.remainingCapacity();
    }

    function isInitialized() external view returns (bool) {
        return _config.isInitialized();
    }

    function isEnabled() external view returns (bool) {
        return _config.isEnabled();
    }

    function getBalance() external view returns (uint256) {
        return _config.getBalance();
    }

    function getConfig() external view returns (
        uint64 windowDuration,
        uint64 windowStart,
        uint16 spikeThreshold,
        uint16 velocityThreshold,
        uint32 maxTx,
        bool enabled,
        bool tripped,
        uint128 balance
    ) {
        return (
            _config.windowDuration,
            _config.windowStart,
            _config.spikeThresholdBps,
            _config.velocityThresholdBps,
            _config.maxTxPerWindow,
            _config.enabled,
            _config.tripped,
            _config.trackedBalance
        );
    }
}
