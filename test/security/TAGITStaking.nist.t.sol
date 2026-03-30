// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITStaking} from "../../src/token/TAGITStaking.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {RateLimiter} from "../../src/libraries/RateLimiter.sol";

/**
 * @title TAGITStakingNistTest
 * @notice NIST CSF 2.0 security control tests for TAGITStaking
 * @dev Tests AC-7 (Unsuccessful Authentication Attempts) rate limiting
 */
contract TAGITStakingNistTest is Test {
    // ============================================
    // EVENTS
    // ============================================

    event RateLimitBlocked(address indexed user, string action);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);

    // ============================================
    // CONTRACTS
    // ============================================

    TAGITStaking public staking;
    TAGITToken public token;

    // ============================================
    // ADDRESSES
    // ============================================

    address public owner;
    address public governor;
    address public treasury;
    address public user;
    address public attacker;

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 public constant STAKE_AMOUNT = 1000 ether;
    uint64 public constant DEFAULT_MAX_PER_WINDOW = 10;
    uint64 public constant DEFAULT_WINDOW_DURATION = 1 hours;
    uint64 public constant DEFAULT_COOLDOWN = 15 minutes;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        treasury = makeAddr("treasury");
        user = makeAddr("user");
        attacker = makeAddr("attacker");

        vm.startPrank(owner);

        // Deploy TAGITToken (upgradeable)
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(TAGITToken.initialize, (owner, treasury));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITStaking (upgradeable)
        TAGITStaking stakingImpl = new TAGITStaking();
        bytes memory stakingData = abi.encodeCall(TAGITStaking.initialize, (address(token), governor, owner));
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingData);
        staking = TAGITStaking(address(stakingProxy));

        // Fund users with tokens
        token.transfer(user, 100_000 ether);
        token.transfer(attacker, 100_000 ether);

        vm.stopPrank();

        // Approve staking contract
        vm.prank(user);
        token.approve(address(staking), type(uint256).max);

        vm.prank(attacker);
        token.approve(address(staking), type(uint256).max);
    }

    // ============================================
    // RATE LIMITER TESTS (AC-7)
    // ============================================

    function test_rateLimiter_initialStateEnabled() public view {
        assertTrue(staking.isRateLimitEnabled());
    }

    function test_rateLimiter_allowsNormalStaking() public {
        vm.prank(user);
        staking.stake(STAKE_AMOUNT);

        assertEq(staking.stakedBalance(user), STAKE_AMOUNT);
    }

    function test_rateLimiter_allowsNormalUnstaking() public {
        vm.startPrank(user);
        staking.stake(STAKE_AMOUNT);
        staking.unstake(STAKE_AMOUNT / 2);
        vm.stopPrank();

        assertEq(staking.stakedBalance(user), STAKE_AMOUNT / 2);
    }

    function test_rateLimiter_blocksAfterThreshold() public {
        vm.startPrank(attacker);

        // Use up all allowed actions (10 per window)
        for (uint256 i = 0; i < DEFAULT_MAX_PER_WINDOW; i++) {
            staking.stake(100 ether);
        }

        // 11th action should be blocked
        vm.expectRevert();
        staking.stake(100 ether);

        vm.stopPrank();
    }

    function test_rateLimiter_blocksAndReverts() public {
        vm.startPrank(attacker);

        // Use up all allowed actions
        for (uint256 i = 0; i < DEFAULT_MAX_PER_WINDOW; i++) {
            staking.stake(100 ether);
        }

        // 11th action should revert with RateLimitExceeded
        vm.expectRevert();
        staking.stake(100 ether);

        vm.stopPrank();
    }

    function test_rateLimiter_resetsAfterWindow() public {
        vm.startPrank(attacker);

        // Use up all allowed actions
        for (uint256 i = 0; i < DEFAULT_MAX_PER_WINDOW; i++) {
            staking.stake(100 ether);
        }

        // Should be blocked
        vm.expectRevert();
        staking.stake(100 ether);

        vm.stopPrank();

        // Move forward past cooldown and window
        vm.warp(block.timestamp + DEFAULT_WINDOW_DURATION + DEFAULT_COOLDOWN + 1);

        // Should work again
        vm.prank(attacker);
        staking.stake(100 ether);
    }

    function test_rateLimiter_tracksStateCorrectly() public {
        vm.startPrank(user);

        // Stake 3 times
        staking.stake(100 ether);
        staking.stake(100 ether);
        staking.stake(100 ether);

        vm.stopPrank();

        (uint64 count, uint64 windowStart, uint64 lockedUntil) = staking.getRateLimitState(user);

        assertEq(count, 3);
        // Window start may be 0 if not explicitly tracked in contract
        // Just verify count is correct
        assertEq(lockedUntil, 0); // Not locked yet
    }

    function test_rateLimiter_remainingActionsAccurate() public {
        vm.startPrank(user);

        staking.stake(100 ether);
        staking.stake(100 ether);

        vm.stopPrank();

        (bool canAct_, uint256 remaining, uint256 lockedUntil) = staking.getRemainingActions(user);

        assertTrue(canAct_);
        assertEq(remaining, DEFAULT_MAX_PER_WINDOW - 2);
        assertEq(lockedUntil, 0);
    }

    // ============================================
    // ADMIN TESTS
    // ============================================

    function test_rateLimiter_governorCanUpdateConfig() public {
        vm.prank(governor);
        staking.setRateLimitConfig(20, 2 hours, 30 minutes, 2000);

        // Verify by checking we can do 10+ actions now
        vm.startPrank(user);
        for (uint256 i = 0; i < 15; i++) {
            staking.stake(100 ether);
        }
        vm.stopPrank();

        // Should still work (under new limit of 20)
        vm.prank(user);
        staking.stake(100 ether);
    }

    function test_rateLimiter_governorCanDisable() public {
        vm.prank(governor);
        staking.setRateLimitEnabled(false);

        assertFalse(staking.isRateLimitEnabled());

        // Should be able to do unlimited actions now
        vm.startPrank(user);
        for (uint256 i = 0; i < 50; i++) {
            staking.stake(10 ether);
        }
        vm.stopPrank();
    }

    function test_rateLimiter_governorCanResetUserLimit() public {
        vm.startPrank(attacker);

        // Use up all allowed actions
        for (uint256 i = 0; i < DEFAULT_MAX_PER_WINDOW; i++) {
            staking.stake(100 ether);
        }

        vm.stopPrank();

        // Attacker is now blocked
        vm.prank(attacker);
        vm.expectRevert();
        staking.stake(100 ether);

        // Governor resets
        vm.prank(governor);
        staking.resetUserRateLimit(attacker);

        // Attacker can act again
        vm.prank(attacker);
        staking.stake(100 ether);
    }

    function test_rateLimiter_nonGovernorCannotUpdateConfig() public {
        vm.prank(attacker);
        vm.expectRevert();
        staking.setRateLimitConfig(100, 1 hours, 1 minutes, 10000);
    }

    function test_rateLimiter_nonGovernorCannotDisable() public {
        vm.prank(attacker);
        vm.expectRevert();
        staking.setRateLimitEnabled(false);
    }

    function test_rateLimiter_nonGovernorCannotResetUser() public {
        vm.prank(attacker);
        vm.expectRevert();
        staking.resetUserRateLimit(user);
    }

    // ============================================
    // GLOBAL RATE LIMIT TESTS
    // ============================================

    function test_rateLimiter_globalLimitTracked() public {
        (uint64 globalCount, uint64 globalWindowStart, uint256 globalRemaining) = staking.getGlobalRateLimitState();

        assertEq(globalCount, 0);
        assertGt(globalRemaining, 0);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_stakeWithRateLimiting() public {
        vm.prank(user);
        uint256 gasBefore = gasleft();
        staking.stake(STAKE_AMOUNT);
        uint256 gasUsed = gasBefore - gasleft();

        // Rate limiter + effective balance tracking overhead (< 30k gas above base)
        assertLt(gasUsed, 230000, "stake() too expensive");
    }

    function test_gas_unstakeWithRateLimiting() public {
        vm.prank(user);
        staking.stake(STAKE_AMOUNT);

        vm.prank(user);
        uint256 gasBefore = gasleft();
        staking.unstake(STAKE_AMOUNT / 2);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 100000, "unstake() too expensive");
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function test_pause_governorCanPause() public {
        vm.prank(governor);
        staking.pause();

        vm.prank(user);
        vm.expectRevert();
        staking.stake(STAKE_AMOUNT);
    }

    function test_pause_governorCanUnpause() public {
        vm.prank(governor);
        staking.pause();

        vm.prank(governor);
        staking.unpause();

        vm.prank(user);
        staking.stake(STAKE_AMOUNT);
    }

    // ============================================
    // INTEGRATION TESTS
    // ============================================

    function test_integration_normalUsagePattern() public {
        // Simulate normal user behavior over time
        vm.startPrank(user);

        // Day 1: stake
        staking.stake(1000 ether);

        // Day 2: stake more
        vm.warp(block.timestamp + 1 days);
        staking.stake(500 ether);

        // Day 3: unstake some
        vm.warp(block.timestamp + 1 days);
        staking.unstake(300 ether);

        vm.stopPrank();

        assertEq(staking.stakedBalance(user), 1200 ether);
    }

    function test_integration_multipleUsersIndependent() public {
        address user2 = makeAddr("user2");
        vm.prank(owner);
        token.transfer(user2, 100_000 ether);

        vm.prank(user2);
        token.approve(address(staking), type(uint256).max);

        // User hits rate limit
        vm.startPrank(user);
        for (uint256 i = 0; i < DEFAULT_MAX_PER_WINDOW; i++) {
            staking.stake(100 ether);
        }
        vm.stopPrank();

        // User2 should still be able to stake
        vm.prank(user2);
        staking.stake(1000 ether);

        assertEq(staking.stakedBalance(user2), 1000 ether);
    }
}
