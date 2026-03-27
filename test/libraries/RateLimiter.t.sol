// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {RateLimiter} from "../../src/libraries/RateLimiter.sol";

/**
 * @title RateLimiterTest
 * @notice Tests for NIST AC-7 compliant rate limiting
 */
contract RateLimiterTest is Test {
    using RateLimiter for RateLimiter.Config;

    // ============================================
    // STATE
    // ============================================

    RateLimiterHarness public harness;

    // Test parameters
    uint64 constant MAX_PER_WINDOW = 10;
    uint64 constant WINDOW_DURATION = 1 hours;
    uint64 constant COOLDOWN_DURATION = 30 minutes;
    uint64 constant GLOBAL_MAX = 100;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        harness = new RateLimiterHarness();
        harness.initialize(MAX_PER_WINDOW, WINDOW_DURATION, COOLDOWN_DURATION, GLOBAL_MAX);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsCorrectValues() public view {
        (
            uint64 maxPerWindow,
            uint64 windowDuration,
            uint64 cooldownDuration,
            bool enabled,
            uint64 globalCount,
            uint64 globalWindowStart,
            uint64 globalMaxPerWindow
        ) = harness.getConfig();

        assertEq(maxPerWindow, MAX_PER_WINDOW, "Max per window set");
        assertEq(windowDuration, WINDOW_DURATION, "Window duration set");
        assertEq(cooldownDuration, COOLDOWN_DURATION, "Cooldown duration set");
        assertTrue(enabled, "Should be enabled");
        assertEq(globalCount, 0, "Global count starts at 0");
        assertEq(globalWindowStart, block.timestamp, "Global window start is now");
        assertEq(globalMaxPerWindow, GLOBAL_MAX, "Global max set");
    }

    function test_initialize_revertsOnZeroMaxPerWindow() public {
        RateLimiterHarness h = new RateLimiterHarness();
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidConfig.selector, "maxPerWindow cannot be 0"));
        h.initialize(0, WINDOW_DURATION, COOLDOWN_DURATION, GLOBAL_MAX);
    }

    function test_initialize_revertsOnZeroWindow() public {
        RateLimiterHarness h = new RateLimiterHarness();
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidConfig.selector, "window cannot be 0"));
        h.initialize(MAX_PER_WINDOW, 0, COOLDOWN_DURATION, GLOBAL_MAX);
    }

    function test_initialize_allowsZeroGlobalMax() public {
        RateLimiterHarness h = new RateLimiterHarness();
        h.initialize(MAX_PER_WINDOW, WINDOW_DURATION, COOLDOWN_DURATION, 0);
        (,,,,,, uint64 globalMax) = h.getConfig();
        assertEq(globalMax, 0, "Global max can be 0 (disabled)");
    }

    function test_isInitialized_returnsTrueAfterInit() public view {
        assertTrue(harness.isInitialized(), "Should be initialized");
    }

    function test_isInitialized_returnsFalseBeforeInit() public {
        RateLimiterHarness h = new RateLimiterHarness();
        assertFalse(h.isInitialized(), "Should not be initialized");
    }

    // ============================================
    // CHECK TESTS
    // ============================================

    function test_check_incrementsCount() public {
        harness.check(user1);
        (uint64 count,,) = harness.getUserState(user1);
        assertEq(count, 1, "Count should be 1");

        harness.check(user1);
        (count,,) = harness.getUserState(user1);
        assertEq(count, 2, "Count should be 2");
    }

    function test_check_allowsExactlyMaxCalls() public {
        // Should allow exactly MAX_PER_WINDOW calls
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            bool allowed = harness.check(user1);
            assertTrue(allowed, "Should be allowed up to limit");
        }

        // The next call should revert (user is locked)
        vm.expectRevert();
        harness.check(user1);
    }

    function test_check_locksAfterMaxCalls() public {
        // Make MAX_PER_WINDOW calls - all should succeed
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        // User should now be locked
        (uint64 count,, uint64 lockedUntil) = harness.getUserState(user1);
        assertEq(count, MAX_PER_WINDOW, "Count should be at max");
        assertEq(lockedUntil, block.timestamp + COOLDOWN_DURATION, "User should be locked");
    }

    function test_check_revertsWithUserLockedAfterMax() public {
        // Make MAX_PER_WINDOW calls
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        // Next call should revert with UserLocked (not RateLimitExceeded)
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.UserLocked.selector, user1, COOLDOWN_DURATION));
        harness.check(user1);
    }

    function test_check_revertsWhileLocked() public {
        // Make MAX_PER_WINDOW calls to trigger lockout
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        // Advance time but stay in lockout
        vm.warp(block.timestamp + COOLDOWN_DURATION / 2);

        // Should revert with UserLocked
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.UserLocked.selector, user1, COOLDOWN_DURATION / 2));
        harness.check(user1);
    }

    function test_check_resetsAfterLockout() public {
        // Make MAX_PER_WINDOW calls to trigger lockout
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        // Advance past lockout
        vm.warp(block.timestamp + COOLDOWN_DURATION + 1);

        // Should reset and allow check
        bool allowed = harness.check(user1);
        assertTrue(allowed, "Should be allowed after lockout");

        // Count should be 1
        (uint64 count,,) = harness.getUserState(user1);
        assertEq(count, 1, "Count should be 1 after reset");
    }

    function test_check_resetsOnNewWindow() public {
        // Increment count but don't hit limit
        for (uint256 i = 0; i < MAX_PER_WINDOW - 2; i++) {
            harness.check(user1);
        }
        (uint64 count,,) = harness.getUserState(user1);
        assertEq(count, MAX_PER_WINDOW - 2, "Count should be max - 2");

        // Advance past window
        vm.warp(block.timestamp + WINDOW_DURATION + 1);

        // Check should start fresh count
        harness.check(user1);
        (count,,) = harness.getUserState(user1);
        assertEq(count, 1, "Count should be 1 in new window");
    }

    function test_check_tracksUsersIndependently() public {
        // User1 makes 5 calls
        for (uint256 i = 0; i < 5; i++) {
            harness.check(user1);
        }

        // User2 makes 3 calls
        for (uint256 i = 0; i < 3; i++) {
            harness.check(user2);
        }

        (uint64 count1,,) = harness.getUserState(user1);
        (uint64 count2,,) = harness.getUserState(user2);

        assertEq(count1, 5, "User1 count should be 5");
        assertEq(count2, 3, "User2 count should be 3");
    }

    function test_check_passesWhenDisabled() public {
        harness.setEnabled(false);

        // Should pass unlimited times
        for (uint256 i = 0; i < 100; i++) {
            bool allowed = harness.check(user1);
            assertTrue(allowed, "Should always be allowed when disabled");
        }
    }

    function test_check_emitsWarningAt80Percent() public {
        // 80% of 10 = 8
        for (uint256 i = 0; i < 7; i++) {
            harness.check(user1);
        }

        // The 8th call should emit warning
        vm.expectEmit(true, false, false, true);
        emit RateLimiter.RateLimitWarning(user1, 8, MAX_PER_WINDOW);
        harness.check(user1);
    }

    function test_check_emitsRateLimitHit() public {
        // Make MAX_PER_WINDOW - 1 calls first
        for (uint256 i = 0; i < MAX_PER_WINDOW - 1; i++) {
            harness.check(user1);
        }

        uint256 expectedLockedUntil = block.timestamp + COOLDOWN_DURATION;

        // The MAX_PER_WINDOW-th call emits RateLimitHit but succeeds
        vm.expectEmit(true, false, false, true);
        emit RateLimiter.RateLimitHit(user1, MAX_PER_WINDOW, expectedLockedUntil);
        harness.check(user1);
    }

    function test_check_emitsUserUnlocked() public {
        // Make MAX_PER_WINDOW calls to trigger lockout
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        // Advance past lockout
        uint256 unlockTime = block.timestamp + COOLDOWN_DURATION + 1;
        vm.warp(unlockTime);

        // Should emit unlock event on next check
        vm.expectEmit(true, false, false, true);
        emit RateLimiter.UserUnlocked(user1, unlockTime);
        harness.check(user1);
    }

    // ============================================
    // GLOBAL LIMIT TESTS
    // ============================================

    function test_check_incrementsGlobalCount() public {
        harness.check(user1);
        (uint64 globalCount,,) = harness.getGlobalState();
        assertEq(globalCount, 1, "Global count should be 1");

        harness.check(user2);
        (globalCount,,) = harness.getGlobalState();
        assertEq(globalCount, 2, "Global count should be 2");
    }

    function test_check_revertsOnGlobalLimit() public {
        // Use many users to hit global limit without hitting per-user limit
        for (uint256 i = 0; i < GLOBAL_MAX; i++) {
            address user = address(uint160(1000 + i));
            harness.check(user);
        }

        // Next call should hit global limit
        address newUser = address(uint160(2000));
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.GlobalLimitExceeded.selector, GLOBAL_MAX, GLOBAL_MAX));
        harness.check(newUser);
    }

    function test_check_resetsGlobalCountOnNewWindow() public {
        // Make some calls
        for (uint256 i = 0; i < 50; i++) {
            address user = address(uint160(1000 + i));
            harness.check(user);
        }

        (uint64 globalCount,,) = harness.getGlobalState();
        assertEq(globalCount, 50, "Global count should be 50");

        // Advance past window
        vm.warp(block.timestamp + WINDOW_DURATION + 1);

        // Global count should reset on next check
        harness.check(user1);
        (globalCount,,) = harness.getGlobalState();
        assertEq(globalCount, 1, "Global count should be 1 after window reset");
    }

    function test_check_emitsGlobalLimitHit() public {
        // Use many users to approach global limit
        for (uint256 i = 0; i < GLOBAL_MAX; i++) {
            address user = address(uint160(1000 + i));
            harness.check(user);
        }

        vm.expectEmit(true, false, false, true);
        emit RateLimiter.GlobalLimitHit(block.timestamp, GLOBAL_MAX);

        address newUser = address(uint160(2000));
        vm.expectRevert();
        harness.check(newUser);
    }

    function test_check_noGlobalLimitWhenZero() public {
        // Create new harness without global limit
        RateLimiterHarness h = new RateLimiterHarness();
        h.initialize(MAX_PER_WINDOW, WINDOW_DURATION, COOLDOWN_DURATION, 0);

        // Should allow many calls from different users
        for (uint256 i = 0; i < 200; i++) {
            address user = address(uint160(1000 + i));
            bool allowed = h.check(user);
            assertTrue(allowed, "Should be allowed without global limit");
        }
    }

    // ============================================
    // CAN ACT TESTS
    // ============================================

    function test_canAct_returnsTrueInitially() public view {
        (bool canAct_, uint256 remaining, uint256 lockedUntil) = harness.canAct(user1);
        assertTrue(canAct_, "Should be able to act");
        assertEq(remaining, MAX_PER_WINDOW, "Full capacity remaining");
        assertEq(lockedUntil, 0, "Not locked");
    }

    function test_canAct_decreasesRemaining() public {
        harness.check(user1);
        harness.check(user1);
        harness.check(user1);

        (bool canAct_, uint256 remaining,) = harness.canAct(user1);
        assertTrue(canAct_, "Should still be able to act");
        assertEq(remaining, MAX_PER_WINDOW - 3, "Remaining decreased by 3");
    }

    function test_canAct_returnsFalseWhenLocked() public {
        // Make MAX_PER_WINDOW calls to trigger lockout
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        (bool canAct_, uint256 remaining, uint256 lockedUntil) = harness.canAct(user1);
        assertFalse(canAct_, "Should not be able to act");
        assertEq(remaining, 0, "No remaining capacity");
        assertEq(lockedUntil, block.timestamp + COOLDOWN_DURATION, "Locked until cooldown ends");
    }

    function test_canAct_returnsMaxWhenDisabled() public {
        harness.setEnabled(false);

        (bool canAct_, uint256 remaining, uint256 lockedUntil) = harness.canAct(user1);
        assertTrue(canAct_, "Should be able to act");
        assertEq(remaining, type(uint256).max, "Unlimited remaining");
        assertEq(lockedUntil, 0, "Not locked");
    }

    function test_canAct_resetsAfterWindow() public {
        // Make some calls
        for (uint256 i = 0; i < 5; i++) {
            harness.check(user1);
        }

        (, uint256 remaining,) = harness.canAct(user1);
        assertEq(remaining, MAX_PER_WINDOW - 5, "Should have 5 less remaining");

        // Advance past window
        vm.warp(block.timestamp + WINDOW_DURATION + 1);

        (, remaining,) = harness.canAct(user1);
        assertEq(remaining, MAX_PER_WINDOW, "Should have full capacity in new window");
    }

    // ============================================
    // FORCE UNLOCK TESTS
    // ============================================

    function test_forceUnlock_unlocksUser() public {
        // Make MAX_PER_WINDOW calls to trigger lockout
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        // Force unlock
        vm.expectEmit(true, false, false, true);
        emit RateLimiter.UserUnlocked(user1, block.timestamp);
        harness.forceUnlock(user1);

        // Should be able to act again
        (bool canAct_,,) = harness.canAct(user1);
        assertTrue(canAct_, "Should be able to act after force unlock");

        // Count should be reset
        (uint64 count,, uint64 lockedUntil) = harness.getUserState(user1);
        assertEq(count, 0, "Count should be 0");
        assertEq(lockedUntil, 0, "Should not be locked");
    }

    function test_forceUnlock_allowsNewCalls() public {
        // Make MAX_PER_WINDOW calls to trigger lockout
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        harness.forceUnlock(user1);

        // Should be able to make calls again
        bool allowed = harness.check(user1);
        assertTrue(allowed, "Should be allowed after force unlock");
    }

    // ============================================
    // CONFIGURATION TESTS
    // ============================================

    function test_setEnabled_disablesRateLimiting() public {
        harness.setEnabled(false);
        assertFalse(harness.isEnabled(), "Should be disabled");

        harness.setEnabled(true);
        assertTrue(harness.isEnabled(), "Should be enabled");
    }

    function test_updateConfig_updatesValues() public {
        harness.updateConfig(20, 2 hours, 1 hours, 200);

        (uint64 maxPerWindow, uint64 windowDuration, uint64 cooldownDuration,,,, uint64 globalMaxPerWindow) =
            harness.getConfig();

        assertEq(maxPerWindow, 20, "Max per window updated");
        assertEq(windowDuration, 2 hours, "Window duration updated");
        assertEq(cooldownDuration, 1 hours, "Cooldown duration updated");
        assertEq(globalMaxPerWindow, 200, "Global max updated");
    }

    function test_updateConfig_skipsZeroValues() public {
        harness.updateConfig(0, 0, 0, 50);

        (uint64 maxPerWindow, uint64 windowDuration, uint64 cooldownDuration,,,, uint64 globalMaxPerWindow) =
            harness.getConfig();

        // Original values preserved
        assertEq(maxPerWindow, MAX_PER_WINDOW, "Max per window unchanged");
        assertEq(windowDuration, WINDOW_DURATION, "Window duration unchanged");
        assertEq(cooldownDuration, COOLDOWN_DURATION, "Cooldown duration unchanged");
        // Global max updated (0 = disabled)
        assertEq(globalMaxPerWindow, 50, "Global max updated");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_rateLimitBehavior(uint64 maxPerWindow, uint64 callCount) public {
        // Bound inputs
        maxPerWindow = uint64(bound(maxPerWindow, 1, 100));
        callCount = uint64(bound(callCount, 1, 150));

        RateLimiterHarness h = new RateLimiterHarness();
        h.initialize(maxPerWindow, WINDOW_DURATION, COOLDOWN_DURATION, 0);

        // User can make exactly maxPerWindow calls, then gets locked on the (maxPerWindow+1)th call
        bool shouldRevert = callCount > maxPerWindow;
        bool didRevert = false;
        uint64 successfulCalls = 0;

        for (uint64 i = 0; i < callCount; i++) {
            (bool canAct_,,) = h.canAct(user1);
            if (!canAct_) {
                didRevert = true;
                break;
            }

            try h.check(user1) {
                successfulCalls++;
            } catch {
                didRevert = true;
                break;
            }
        }

        if (shouldRevert) {
            assertTrue(didRevert, "Should have reverted after limit");
            assertEq(successfulCalls, maxPerWindow, "Should have made exactly maxPerWindow successful calls");
        }
    }

    function testFuzz_cooldownRespected(uint64 advanceTime) public {
        advanceTime = uint64(bound(advanceTime, 0, COOLDOWN_DURATION * 2));

        // Make MAX_PER_WINDOW calls to trigger lockout
        for (uint256 i = 0; i < MAX_PER_WINDOW; i++) {
            harness.check(user1);
        }

        uint256 originalLockEnd = block.timestamp + COOLDOWN_DURATION;
        vm.warp(block.timestamp + advanceTime);

        (bool canAct_, uint256 remaining, uint256 lockedUntil) = harness.canAct(user1);

        if (advanceTime < COOLDOWN_DURATION) {
            assertFalse(canAct_, "Should still be locked");
            assertEq(remaining, 0, "No remaining");
            assertEq(lockedUntil, originalLockEnd, "Lock end unchanged");
        } else {
            // After cooldown expires, canAct checks window expiry
            // Since the window also expired, count resets to 0
            assertTrue(canAct_, "Should be unlocked after cooldown");
            // Note: The view function doesn't actually reset state, but it calculates
            // as if the window reset. The lockedUntil field isn't reset until next check().
        }
    }

    function testFuzz_globalLimitDistributed(uint8 numUsers) public {
        numUsers = uint8(bound(numUsers, 1, 50));

        uint256 callsPerUser = GLOBAL_MAX / numUsers;
        uint256 totalCalls = 0;

        for (uint256 i = 0; i < numUsers; i++) {
            address user = address(uint160(1000 + i));
            for (uint256 j = 0; j < callsPerUser && j < MAX_PER_WINDOW - 1; j++) {
                try harness.check(user) {
                    totalCalls++;
                } catch {
                    // Global limit hit
                    break;
                }
            }
        }

        assertLe(totalCalls, GLOBAL_MAX, "Should not exceed global limit");
    }

    // ============================================
    // GAS TESTS
    // ============================================

    function test_check_gasEfficiency() public {
        // Warm up storage
        harness.check(user1);

        // Measure warm gas
        uint256 gasBefore = gasleft();
        harness.check(user1);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be < 7,000 gas for warm reads (includes global limit check overhead)
        assertLt(gasUsed, 7000, "Warm check should be < 7000 gas");
    }

    function test_canAct_gasEfficiency() public {
        // Warm up storage
        harness.check(user1);

        // Measure warm gas for view function
        uint256 gasBefore = gasleft();
        harness.canAct(user1);
        uint256 gasUsed = gasBefore - gasleft();

        // View should be very cheap
        assertLt(gasUsed, 5000, "canAct should be < 5000 gas");
    }
}

// ============================================
// TEST HARNESS
// ============================================

/**
 * @notice Test harness to expose internal library functions
 */
contract RateLimiterHarness {
    using RateLimiter for RateLimiter.Config;

    RateLimiter.Config private _config;
    mapping(address => RateLimiter.UserState) private _userStates;

    function initialize(uint64 maxPerWindow, uint64 windowDuration, uint64 cooldownDuration, uint64 globalMax)
        external
    {
        _config.initialize(maxPerWindow, windowDuration, cooldownDuration, globalMax);
    }

    function check(address user) external returns (bool) {
        return _config.check(_userStates, user);
    }

    function canAct(address user) external view returns (bool, uint256, uint256) {
        return _config.canAct(_userStates, user);
    }

    function forceUnlock(address user) external {
        RateLimiter.forceUnlock(_userStates, user);
    }

    function setEnabled(bool enabled) external {
        _config.setEnabled(enabled);
    }

    function updateConfig(uint64 maxPerWindow, uint64 windowDuration, uint64 cooldownDuration, uint64 globalMax)
        external
    {
        _config.updateConfig(maxPerWindow, windowDuration, cooldownDuration, globalMax);
    }

    function isInitialized() external view returns (bool) {
        return _config.isInitialized();
    }

    function isEnabled() external view returns (bool) {
        return _config.isEnabled();
    }

    function getUserState(address user) external view returns (uint64 count, uint64 windowStart, uint64 lockedUntil) {
        return RateLimiter.getUserState(_userStates, user);
    }

    function getGlobalState() external view returns (uint64 count, uint64 windowStart, uint256 remaining) {
        return _config.getGlobalState();
    }

    function getConfig()
        external
        view
        returns (
            uint64 maxPerWindow,
            uint64 windowDuration,
            uint64 cooldownDuration,
            bool enabled,
            uint64 globalCount,
            uint64 globalWindowStart,
            uint64 globalMaxPerWindow
        )
    {
        return (
            _config.maxPerWindow,
            _config.windowDuration,
            _config.cooldownDuration,
            _config.enabled,
            _config.globalCount,
            _config.globalWindowStart,
            _config.globalMaxPerWindow
        );
    }
}
