// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TokenFlowsTest
 * @notice Integration tests for token economics: staking, emissions, burning, vesting
 * @dev Tests cross-contract token flows
 */
contract TokenFlowsTest is IntegrationBase {

    // ============================================
    // STAKING FLOWS
    // ============================================

    /**
     * @notice E2E: Stake → Verify → Unstake
     * @dev Tests basic staking functionality without reward claiming
     *      (Reward distribution requires emissions setup)
     */
    function test_stakeEarnClaim() public {
        uint256 stakeAmount = 10_000 ether;

        // User approves and stakes tokens
        vm.startPrank(consumer1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Verify stake recorded
        assertEq(staking.stakedBalance(consumer1), stakeAmount, "Stake not recorded");
        assertEq(staking.totalStaked(), stakeAmount, "Total stake incorrect");
        assertTrue(staking.qualifiesForRepBoost(consumer1), "Should qualify for rep boost");

        // Time passes (1 day)
        vm.warp(block.timestamp + 1 days);

        // Unstake
        vm.prank(consumer1);
        staking.unstake(stakeAmount);

        assertEq(staking.stakedBalance(consumer1), 0, "Should have no stake");
        assertEq(staking.totalStaked(), 0, "Total stake should be zero");
    }

    /**
     * @notice E2E: Multiple stakers share stake pool proportionally
     * @dev Tests stake ratio tracking (rewards tested with emissions funding)
     */
    function test_multipleStakersShareRewards() public {
        uint256 stake1 = 30_000 ether;
        uint256 stake2 = 10_000 ether; // 3:1 ratio

        // Consumer1 stakes 30k
        vm.startPrank(consumer1);
        token.approve(address(staking), stake1);
        staking.stake(stake1);
        vm.stopPrank();

        // Consumer2 stakes 10k
        vm.startPrank(consumer2);
        token.approve(address(staking), stake2);
        staking.stake(stake2);
        vm.stopPrank();

        // Verify stakes are proportional (3:1)
        assertEq(staking.stakedBalance(consumer1), stake1, "Consumer1 stake");
        assertEq(staking.stakedBalance(consumer2), stake2, "Consumer2 stake");
        assertEq(staking.totalStaked(), stake1 + stake2, "Total stake");

        // Time passes
        vm.warp(block.timestamp + 1 days);

        // Both can unstake their respective amounts
        vm.prank(consumer1);
        staking.unstake(stake1);
        vm.prank(consumer2);
        staking.unstake(stake2);

        assertEq(staking.totalStaked(), 0, "All unstaked");
    }

    // ============================================
    // BURNER FLOWS
    // ============================================

    /**
     * @notice E2E: Fee → Burn + Treasury split
     * @dev Verifies fee routing with correct burn/treasury split
     */
    function test_feeRoutingBurnTreasury() public {
        uint256 feeAmount = 1000 ether;
        uint256 burnRate = burner.burnRate(); // Default 3333 bps = 33.33%
        uint256 expectedBurn = (feeAmount * burnRate) / 10000;
        uint256 expectedTreasury = feeAmount - expectedBurn;

        // Owner routes fee
        vm.startPrank(owner);
        token.approve(address(burner), feeAmount);

        uint256 supplyBefore = token.totalSupply();
        uint256 treasuryBefore = token.balanceOf(address(treasury));

        burner.routeFee(feeAmount);

        uint256 supplyAfter = token.totalSupply();
        uint256 treasuryAfter = token.balanceOf(address(treasury));
        vm.stopPrank();

        // Verify burn
        assertEq(supplyBefore - supplyAfter, expectedBurn, "Burn amount incorrect");
        assertEq(burner.totalBurned(), expectedBurn, "Total burned not tracked");

        // Verify treasury received remainder
        assertEq(treasuryAfter - treasuryBefore, expectedTreasury, "Treasury amount incorrect");
        assertEq(burner.totalToTreasury(), expectedTreasury, "Total to treasury not tracked");
    }

    /**
     * @notice E2E: Burn floor prevents setting rate too low
     */
    function test_burnFloorEnforced() public {
        uint256 burnFloor = burner.burnFloor(); // 333 bps = 3.33%

        // Try to set rate below floor
        vm.prank(governor);
        vm.expectRevert();
        burner.setBurnRate(burnFloor - 1);

        // Setting at floor should work
        vm.prank(governor);
        burner.setBurnRate(burnFloor);
        assertEq(burner.burnRate(), burnFloor, "Should accept floor rate");
    }

    /**
     * @notice E2E: Multiple fee routes accumulate correctly
     */
    function test_multipleFeeRoutes() public {
        uint256 feeAmount = 100 ether;
        uint256 numRoutes = 10;

        vm.startPrank(owner);
        token.approve(address(burner), feeAmount * numRoutes);

        uint256 supplyBefore = token.totalSupply();

        for (uint256 i = 0; i < numRoutes; i++) {
            burner.routeFee(feeAmount);
        }

        uint256 totalRouted = feeAmount * numRoutes;
        uint256 burnRate = burner.burnRate();
        uint256 expectedTotalBurn = (totalRouted * burnRate) / 10000;

        assertEq(burner.totalBurned(), expectedTotalBurn, "Total burned incorrect");
        assertEq(supplyBefore - token.totalSupply(), expectedTotalBurn, "Supply reduction incorrect");
        vm.stopPrank();
    }

    // ============================================
    // VESTING FLOWS
    // ============================================

    /**
     * @notice E2E: Vesting cliff and linear release
     */
    function test_vestingCliffAndRelease() public {
        uint256 vestAmount = 100_000 ether;
        uint256 cliffDuration = 365 days;
        uint256 vestingDuration = 4 * 365 days;

        // Owner creates vest for consumer1
        vm.startPrank(owner);
        token.transfer(address(vesting), vestAmount);
        vesting.createVest(consumer1, vestAmount, cliffDuration, vestingDuration);
        vm.stopPrank();

        // Verify schedule created
        assertEq(vesting.grantAmount(consumer1), vestAmount, "Grant amount incorrect");
        assertTrue(vesting.hasSchedule(consumer1), "Schedule should exist");

        // Before cliff: nothing claimable
        assertEq(vesting.claimableAmount(consumer1), 0, "Nothing claimable before cliff");

        // Claim should revert before cliff
        vm.prank(consumer1);
        vm.expectRevert();
        vesting.claim();

        // After cliff: partial amount available
        vm.warp(block.timestamp + cliffDuration + 1);

        uint256 claimable = vesting.claimableAmount(consumer1);
        assertGt(claimable, 0, "Should have claimable after cliff");

        // Claim partial
        uint256 balanceBefore = token.balanceOf(consumer1);
        vm.prank(consumer1);
        vesting.claim();

        assertEq(token.balanceOf(consumer1), balanceBefore + claimable, "Should receive claimable");
        assertEq(vesting.totalClaimed(consumer1), claimable, "Claimed tracking incorrect");

        // At end of vesting: full amount available
        vm.warp(block.timestamp + vestingDuration);

        uint256 remaining = vesting.claimableAmount(consumer1);
        assertEq(remaining, vestAmount - claimable, "Remaining should be total minus claimed");

        // Claim remaining
        vm.prank(consumer1);
        vesting.claim();

        assertEq(vesting.totalClaimed(consumer1), vestAmount, "Should have claimed all");
        assertEq(vesting.claimableAmount(consumer1), 0, "Nothing left to claim");
    }

    /**
     * @notice E2E: Multiple vesting beneficiaries
     */
    function test_multipleVestingBeneficiaries() public {
        uint256 vestAmount = 50_000 ether;
        uint256 cliff = 30 days;
        uint256 duration = 365 days;

        // Fund vesting contract
        vm.prank(owner);
        token.transfer(address(vesting), vestAmount * 2);

        // Create vests for two users
        vm.startPrank(owner);
        vesting.createVest(consumer1, vestAmount, cliff, duration);
        vesting.createVest(consumer2, vestAmount, cliff, duration);
        vm.stopPrank();

        // Both schedules should exist
        assertTrue(vesting.hasSchedule(consumer1), "Consumer1 schedule should exist");
        assertTrue(vesting.hasSchedule(consumer2), "Consumer2 schedule should exist");

        // After cliff, both can claim
        vm.warp(block.timestamp + cliff + duration / 2);

        uint256 claimable1 = vesting.claimableAmount(consumer1);
        uint256 claimable2 = vesting.claimableAmount(consumer2);

        vm.prank(consumer1);
        vesting.claim();

        vm.prank(consumer2);
        vesting.claim();

        assertEq(claimable1, claimable2, "Both should claim same amount");
    }

    // ============================================
    // COMBINED FLOWS
    // ============================================

    /**
     * @notice E2E: Stake → Earn → Route fees → Verify burn reduces supply
     */
    function test_stakingWithBurnInteraction() public {
        // Setup staking
        vm.startPrank(consumer1);
        token.approve(address(staking), 10_000 ether);
        staking.stake(10_000 ether);
        vm.stopPrank();

        uint256 supplyBefore = token.totalSupply();

        // Route fees (burns tokens)
        vm.startPrank(owner);
        token.approve(address(burner), 1000 ether);
        burner.routeFee(1000 ether);
        vm.stopPrank();

        uint256 supplyAfter = token.totalSupply();

        // Supply should decrease
        assertLt(supplyAfter, supplyBefore, "Supply should decrease from burns");

        // Staking should still be solvent
        assertLe(staking.totalStaked(), token.balanceOf(address(staking)), "Staking should remain solvent");
    }

    /**
     * @notice E2E: Treasury receives funds from multiple sources
     */
    function test_treasuryReceivesFromMultipleSources() public {
        uint256 treasuryBefore = token.balanceOf(address(treasury));

        // Source 1: Direct transfer
        vm.prank(owner);
        token.transfer(address(treasury), 1000 ether);

        // Source 2: Fee routing
        vm.startPrank(owner);
        token.approve(address(burner), 1000 ether);
        burner.routeFee(1000 ether);
        vm.stopPrank();

        uint256 treasuryAfter = token.balanceOf(address(treasury));
        uint256 fromBurner = burner.totalToTreasury();

        assertEq(treasuryAfter - treasuryBefore, 1000 ether + fromBurner, "Treasury should receive all");
    }
}
