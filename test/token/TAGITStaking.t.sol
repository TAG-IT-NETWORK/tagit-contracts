// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITStaking} from "../../src/token/TAGITStaking.sol";
import {ITAGITStaking} from "../../src/interfaces/ITAGITStaking.sol";
import {GENESIS_SUPPLY, MIN_STAKE_FOR_REP, VERSION} from "../../src/libraries/Constants.sol";

/**
 * @title TAGITStaking Unit Tests
 * @notice Comprehensive tests for the TAGIT staking contract
 */
contract TAGITStakingTest is Test {
    TAGITToken public token;
    TAGITToken public tokenImpl;
    TAGITStaking public staking;
    TAGITStaking public stakingImpl;

    address public owner;
    address public treasury;
    address public governor;
    address public emissions;
    address public alice;
    address public bob;
    address public charlie;

    uint256 public constant STAKE_AMOUNT = 1000 ether;
    uint256 public constant REWARD_AMOUNT = 10000 ether;

    // Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);
    event EmissionsSet(address indexed emissions);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        governor = makeAddr("governor");
        emissions = makeAddr("emissions");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy TAGITToken
        tokenImpl = new TAGITToken();
        bytes memory tokenInitData = abi.encodeWithSelector(TAGITToken.initialize.selector, treasury, owner);
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITStaking
        stakingImpl = new TAGITStaking();
        bytes memory stakingInitData =
            abi.encodeWithSelector(TAGITStaking.initialize.selector, address(token), governor, owner);
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingInitData);
        staking = TAGITStaking(address(stakingProxy));

        // Set emissions address
        vm.prank(owner);
        staking.setEmissions(emissions);

        // Transfer tokens to users for testing
        vm.startPrank(treasury);
        token.transfer(alice, 100_000 ether);
        token.transfer(bob, 100_000 ether);
        token.transfer(charlie, 100_000 ether);
        token.transfer(emissions, 1_000_000 ether);
        vm.stopPrank();

        // Users approve staking contract
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(staking), type(uint256).max);
        vm.prank(emissions);
        token.approve(address(staking), type(uint256).max);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsToken() public view {
        assertEq(address(staking.token()), address(token));
    }

    function test_initialize_setsGovernor() public view {
        assertEq(staking.governor(), governor);
    }

    function test_initialize_setsEmissions() public view {
        assertEq(staking.emissions(), emissions);
    }

    function test_initialize_startsWithZeroTotalStaked() public view {
        assertEq(staking.totalStaked(), 0);
    }

    function test_initialize_revert_zeroToken() public {
        TAGITStaking newImpl = new TAGITStaking();
        bytes memory initData = abi.encodeWithSelector(TAGITStaking.initialize.selector, address(0), governor, owner);

        vm.expectRevert(ITAGITStaking.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_revert_zeroGovernor() public {
        TAGITStaking newImpl = new TAGITStaking();
        bytes memory initData =
            abi.encodeWithSelector(TAGITStaking.initialize.selector, address(token), address(0), owner);

        vm.expectRevert(ITAGITStaking.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============================================
    // STAKE TESTS
    // ============================================

    function test_stake_transfersTokens() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        assertEq(token.balanceOf(alice), balanceBefore - STAKE_AMOUNT);
        assertEq(token.balanceOf(address(staking)), STAKE_AMOUNT);
    }

    function test_stake_updatesBalance() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        assertEq(staking.stakedBalance(alice), STAKE_AMOUNT);
        assertEq(staking.totalStaked(), STAKE_AMOUNT);
    }

    function test_stake_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Staked(alice, STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
    }

    function test_stake_multipleStakes() public {
        vm.startPrank(alice);
        staking.stake(STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(staking.stakedBalance(alice), STAKE_AMOUNT * 2);
    }

    function test_stake_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ITAGITStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_stake_revert_whenPaused() public {
        vm.prank(governor);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause from OZ Pausable
        staking.stake(STAKE_AMOUNT);
    }

    // ============================================
    // UNSTAKE TESTS
    // ============================================

    function test_unstake_returnsTokens() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        staking.unstake(STAKE_AMOUNT);

        assertEq(token.balanceOf(alice), balanceBefore + STAKE_AMOUNT);
    }

    function test_unstake_updatesBalance() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(alice);
        staking.unstake(STAKE_AMOUNT / 2);

        assertEq(staking.stakedBalance(alice), STAKE_AMOUNT / 2);
        assertEq(staking.totalStaked(), STAKE_AMOUNT / 2);
    }

    function test_unstake_emitsEvent() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Unstaked(alice, STAKE_AMOUNT);
        staking.unstake(STAKE_AMOUNT);
    }

    function test_unstake_revert_zeroAmount() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(ITAGITStaking.ZeroAmount.selector);
        staking.unstake(0);
    }

    function test_unstake_revert_exceedsBalance() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITStaking.InsufficientStake.selector, STAKE_AMOUNT * 2, STAKE_AMOUNT)
        );
        staking.unstake(STAKE_AMOUNT * 2);
    }

    // ============================================
    // REWARD TESTS
    // ============================================

    function test_notifyReward_onlyEmissions() public {
        vm.prank(alice);
        vm.expectRevert(ITAGITStaking.Unauthorized.selector);
        staking.notifyRewardAmount(REWARD_AMOUNT);
    }

    function test_notifyReward_addsRewards() public {
        vm.prank(emissions);
        vm.expectEmit(false, false, false, true);
        emit RewardAdded(REWARD_AMOUNT);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        assertGt(staking.rewardRate(), 0);
    }

    function test_claimRewards_calculatesCorrectly() public {
        // Alice stakes
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        // Add rewards
        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        // Wait for some time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        uint256 pending = staking.pendingRewards(alice);
        assertGt(pending, 0, "Should have pending rewards");

        // Claim
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = staking.claimRewards();

        assertEq(claimed, pending);
        assertEq(token.balanceOf(alice), balanceBefore + claimed);
    }

    function test_claimRewards_zeroIfNoStake() public {
        // Add rewards but don't stake
        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + 1 days);

        assertEq(staking.pendingRewards(alice), 0);
    }

    function test_claimRewards_emitsEvent() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + 1 days);

        uint256 pending = staking.pendingRewards(alice);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit RewardsClaimed(alice, pending);
        staking.claimRewards();
    }

    function test_claimRewards_revert_nothingToClaim() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        // No rewards added, nothing to claim
        vm.prank(alice);
        vm.expectRevert(ITAGITStaking.NoRewardsToClaim.selector);
        staking.claimRewards();
    }

    function test_multipleStakers_fairDistribution() public {
        // Alice and Bob stake equal amounts
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);
        vm.prank(bob);
        staking.stake(STAKE_AMOUNT);

        // Add rewards
        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        // Wait
        vm.warp(block.timestamp + 1 days);

        // Both should have approximately equal rewards
        uint256 aliceRewards = staking.pendingRewards(alice);
        uint256 bobRewards = staking.pendingRewards(bob);

        assertApproxEqRel(aliceRewards, bobRewards, 0.01e18); // Within 1%
    }

    function test_proportionalRewards() public {
        // Alice stakes 2x more than Bob
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT * 2);
        vm.prank(bob);
        staking.stake(STAKE_AMOUNT);

        // Add rewards
        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        // Wait
        vm.warp(block.timestamp + 1 days);

        // Alice should have ~2x Bob's rewards
        uint256 aliceRewards = staking.pendingRewards(alice);
        uint256 bobRewards = staking.pendingRewards(bob);

        assertApproxEqRel(aliceRewards, bobRewards * 2, 0.01e18);
    }

    // ============================================
    // GOVERNOR TESTS
    // ============================================

    function test_setRewardRate_success() public {
        uint256 newRate = 1e15; // 0.001 per second

        vm.prank(governor);
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(0, newRate);
        staking.setRewardRate(newRate);

        assertEq(staking.rewardRate(), newRate);
    }

    function test_setRewardRate_revert_notGovernor() public {
        vm.prank(alice);
        vm.expectRevert(ITAGITStaking.Unauthorized.selector);
        staking.setRewardRate(1e15);
    }

    function test_pause_blocksStaking() public {
        vm.prank(governor);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert();
        staking.stake(STAKE_AMOUNT);
    }

    function test_unpause_allowsStaking() public {
        vm.prank(governor);
        staking.pause();

        vm.prank(governor);
        staking.unpause();

        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        assertEq(staking.stakedBalance(alice), STAKE_AMOUNT);
    }

    function test_setGovernor_success() public {
        address newGovernor = makeAddr("newGovernor");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit GovernorUpdated(governor, newGovernor);
        staking.setGovernor(newGovernor);

        assertEq(staking.governor(), newGovernor);
    }

    function test_setGovernor_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.setGovernor(makeAddr("newGovernor"));
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_qualifiesForRepBoost_true() public {
        vm.prank(alice);
        staking.stake(MIN_STAKE_FOR_REP);

        assertTrue(staking.qualifiesForRepBoost(alice));
    }

    function test_qualifiesForRepBoost_false() public {
        vm.prank(alice);
        staking.stake(MIN_STAKE_FOR_REP - 1);

        assertFalse(staking.qualifiesForRepBoost(alice));
    }

    function test_version() public view {
        assertEq(staking.version(), VERSION);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_stakeUnstake(uint256 amount) public {
        amount = bound(amount, 1, 50_000 ether);

        vm.prank(alice);
        staking.stake(amount);

        assertEq(staking.stakedBalance(alice), amount);

        vm.prank(alice);
        staking.unstake(amount);

        assertEq(staking.stakedBalance(alice), 0);
    }

    function testFuzz_rewardsAccrual(uint256 stakeAmount, uint256 timeElapsed) public {
        stakeAmount = bound(stakeAmount, 1 ether, 50_000 ether);
        timeElapsed = bound(timeElapsed, 1 hours, 7 days);

        vm.prank(alice);
        staking.stake(stakeAmount);

        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + timeElapsed);

        uint256 rewards = staking.pendingRewards(alice);
        assertGt(rewards, 0, "Should accrue rewards over time");
    }

    // ============================================
    // INVARIANT TESTS
    // ============================================

    function test_invariant_totalStakedEqualsSum() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);
        vm.prank(bob);
        staking.stake(STAKE_AMOUNT * 2);
        vm.prank(charlie);
        staking.stake(STAKE_AMOUNT * 3);

        uint256 sum = staking.stakedBalance(alice) + staking.stakedBalance(bob) + staking.stakedBalance(charlie);

        assertEq(staking.totalStaked(), sum);

        // After unstaking
        vm.prank(alice);
        staking.unstake(STAKE_AMOUNT / 2);

        sum = staking.stakedBalance(alice) + staking.stakedBalance(bob) + staking.stakedBalance(charlie);

        assertEq(staking.totalStaked(), sum);
    }

    function test_invariant_stakingContractFunded() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);
        vm.prank(bob);
        staking.stake(STAKE_AMOUNT * 2);

        // Contract should hold all staked tokens
        assertEq(token.balanceOf(address(staking)), staking.totalStaked());
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_stake() public {
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        staking.stake(STAKE_AMOUNT);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 180,000 (includes SafeERC20 transferFrom + storage updates)
        assertLt(gasUsed, 180000, "stake() exceeds gas target");
    }

    function test_gas_unstake() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        staking.unstake(STAKE_AMOUNT);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 80,000
        assertLt(gasUsed, 80000, "unstake() exceeds gas target");
    }

    function test_gas_claimRewards() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        staking.claimRewards();
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 80,000 (includes ERC20 transfer + reward calculation)
        assertLt(gasUsed, 80000, "claimRewards() exceeds gas target");
    }

    // ============================================
    // UPGRADE TESTS
    // ============================================

    function test_upgrade_preservesState() public {
        // Stake some tokens
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        // Add rewards
        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        uint256 stakedBefore = staking.stakedBalance(alice);
        uint256 totalStakedBefore = staking.totalStaked();
        uint256 rewardRateBefore = staking.rewardRate();

        // Upgrade
        TAGITStaking newImpl = new TAGITStaking();
        vm.prank(owner);
        staking.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(staking.stakedBalance(alice), stakedBefore);
        assertEq(staking.totalStaked(), totalStakedBefore);
        assertEq(staking.rewardRate(), rewardRateBefore);
    }

    function test_upgrade_revert_notOwner() public {
        TAGITStaking newImpl = new TAGITStaking();

        vm.prank(alice);
        vm.expectRevert();
        staking.upgradeToAndCall(address(newImpl), "");
    }

    // ============================================
    // EDGE CASE TESTS
    // ============================================

    function test_edgeCase_stakeAfterRewardsNotified() public {
        // Notify rewards first
        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        // Stake after
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        // Wait and check rewards
        vm.warp(block.timestamp + 1 days);

        assertGt(staking.pendingRewards(alice), 0);
    }

    function test_edgeCase_multipleNotifyRewards() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        // Multiple reward notifications
        vm.startPrank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + 3 days);
        staking.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Should extend rewards
        assertGt(staking.periodFinish(), block.timestamp);
    }

    function test_edgeCase_claimMultipleTimes() public {
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        // Claim multiple times
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 claim1 = staking.claimRewards();

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 claim2 = staking.claimRewards();

        // Both claims should have value
        assertGt(claim1, 0);
        assertGt(claim2, 0);
    }

    function test_edgeCase_setEmissions_onlyOnce() public {
        // Already set in setUp, try to set again
        vm.prank(owner);
        vm.expectRevert(ITAGITStaking.EmissionsAlreadySet.selector);
        staking.setEmissions(makeAddr("newEmissions"));
    }
}
