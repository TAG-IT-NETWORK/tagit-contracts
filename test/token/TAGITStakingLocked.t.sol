// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITStaking} from "../../src/token/TAGITStaking.sol";
import {ITAGITStaking} from "../../src/interfaces/ITAGITStaking.sol";
import {GENESIS_SUPPLY, MIN_STAKE_FOR_REP, VERSION, BASIS_POINTS} from "../../src/libraries/Constants.sol";

/**
 * @title TAGITStakingLocked Tests
 * @notice Tests for locked staking with tier multipliers
 * @dev Covers happy-path and edge-case scenarios for stakeLocked/unlockStake
 */
contract TAGITStakingLockedTest is Test {
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

    uint256 public constant STAKE_AMOUNT = 1000 ether;
    uint256 public constant REWARD_AMOUNT = 10000 ether;

    // Events
    event LockedStakeCreated(
        address indexed user, uint256 indexed stakeId, uint256 amount, ITAGITStaking.LockTier tier, uint256 lockEnd
    );
    event LockedStakeReleased(address indexed user, uint256 indexed stakeId, uint256 amount, uint256 rewardBonus);
    event Staked(address indexed user, uint256 amount);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        governor = makeAddr("governor");
        emissions = makeAddr("emissions");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

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

        // Transfer tokens to users
        vm.startPrank(treasury);
        token.transfer(alice, 100_000 ether);
        token.transfer(bob, 100_000 ether);
        token.transfer(emissions, 1_000_000 ether);
        vm.stopPrank();

        // Users approve staking contract
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
        vm.prank(emissions);
        token.approve(address(staking), type(uint256).max);
    }

    // ============================================
    // HAPPY PATH: stakeLocked EACH TIER
    // ============================================

    function test_stakeLocked_tier30() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);

        assertEq(staking.lockedStakeCount(alice), 1);
        assertEq(staking.totalStaked(), STAKE_AMOUNT);

        // Effective balance = amount * 12000 / 10000 = 1.2x
        uint256 expectedEffective = (STAKE_AMOUNT * 12000) / BASIS_POINTS;
        assertEq(staking.effectiveBalance(alice), expectedEffective);
        assertEq(staking.totalEffectiveStaked(), expectedEffective);

        // Verify locked stake details
        ITAGITStaking.LockedStake[] memory stakes = staking.getLockedStakes(alice);
        assertEq(stakes.length, 1);
        assertEq(stakes[0].amount, STAKE_AMOUNT);
        assertEq(uint8(stakes[0].tier), uint8(ITAGITStaking.LockTier.TIER_30));
        assertEq(stakes[0].lockEnd, block.timestamp + 30 days);
        assertFalse(stakes[0].released);
    }

    function test_stakeLocked_tier90() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_90);

        uint256 expectedEffective = (STAKE_AMOUNT * 15000) / BASIS_POINTS;
        assertEq(staking.effectiveBalance(alice), expectedEffective);

        ITAGITStaking.LockedStake[] memory stakes = staking.getLockedStakes(alice);
        assertEq(stakes[0].lockEnd, block.timestamp + 90 days);
    }

    function test_stakeLocked_tier180() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_180);

        // 2.0x multiplier
        uint256 expectedEffective = (STAKE_AMOUNT * 20000) / BASIS_POINTS;
        assertEq(staking.effectiveBalance(alice), expectedEffective);

        ITAGITStaking.LockedStake[] memory stakes = staking.getLockedStakes(alice);
        assertEq(stakes[0].lockEnd, block.timestamp + 180 days);
    }

    function test_stakeLocked_emitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit LockedStakeCreated(alice, 0, STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30, block.timestamp + 30 days);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);
    }

    function test_stakeLocked_transfersTokens() public {
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_90);

        assertEq(token.balanceOf(alice), balanceBefore - STAKE_AMOUNT);
        assertEq(token.balanceOf(address(staking)), STAKE_AMOUNT);
    }

    // ============================================
    // HAPPY PATH: unlockStake AFTER EXPIRY
    // ============================================

    function test_unlockStake_tier30() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);

        // Warp past lock
        vm.warp(block.timestamp + 30 days + 1);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        staking.unlockStake(0);

        // Tokens returned
        assertEq(token.balanceOf(alice), balanceBefore + STAKE_AMOUNT);

        // State cleaned up
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.effectiveBalance(alice), 0);
        assertEq(staking.totalEffectiveStaked(), 0);

        // Marked as released
        ITAGITStaking.LockedStake[] memory stakes = staking.getLockedStakes(alice);
        assertTrue(stakes[0].released);
    }

    function test_unlockStake_tier90() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_90);

        vm.warp(block.timestamp + 90 days + 1);

        vm.prank(alice);
        staking.unlockStake(0);

        assertEq(staking.totalStaked(), 0);
        assertEq(staking.effectiveBalance(alice), 0);
    }

    function test_unlockStake_tier180() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_180);

        vm.warp(block.timestamp + 180 days + 1);

        vm.prank(alice);
        staking.unlockStake(0);

        assertEq(staking.totalStaked(), 0);
    }

    function test_unlockStake_emitsEvent() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);

        vm.warp(block.timestamp + 30 days + 1);

        // rewardBonus = amount * (12000 - 10000) / 10000 = 0.2 * amount
        uint256 expectedBonus = (STAKE_AMOUNT * 2000) / BASIS_POINTS;

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit LockedStakeReleased(alice, 0, STAKE_AMOUNT, expectedBonus);
        staking.unlockStake(0);
    }

    // ============================================
    // REWARD DISTRIBUTION WITH LOCKED STAKING
    // ============================================

    function test_lockedStake_boostedRewards() public {
        // Alice: flex stake 1000 tokens (1x)
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        // Bob: locked stake 1000 tokens at TIER_180 (2x effective)
        vm.prank(bob);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_180);

        // Add rewards
        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        // Wait
        vm.warp(block.timestamp + 1 days);

        uint256 aliceRewards = staking.pendingRewards(alice);
        uint256 bobRewards = staking.pendingRewards(bob);

        // Bob has 2x effective balance, so should get ~2x rewards
        // Alice effective = 1000, Bob effective = 2000, total effective = 3000
        // Alice gets 1/3, Bob gets 2/3
        assertGt(bobRewards, aliceRewards, "Locked staker should earn more");
        assertApproxEqRel(bobRewards, aliceRewards * 2, 0.01e18); // Within 1%
    }

    function test_flexAndLockedCombined() public {
        // Alice: flex stake + locked stake
        vm.prank(alice);
        staking.stake(STAKE_AMOUNT);

        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);

        // Effective = 1000 (flex) + 1000 * 1.2 (locked) = 2200
        uint256 expectedEffective = STAKE_AMOUNT + (STAKE_AMOUNT * 12000) / BASIS_POINTS;
        assertEq(staking.effectiveBalance(alice), expectedEffective);

        // Total actual staked = 2000
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 2);
    }

    function test_multipleLockedStakes() public {
        vm.startPrank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_90);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_180);
        vm.stopPrank();

        assertEq(staking.lockedStakeCount(alice), 3);
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 3);

        // Effective = 1000*1.2 + 1000*1.5 + 1000*2.0 = 4700
        uint256 expected = (STAKE_AMOUNT * 12000 + STAKE_AMOUNT * 15000 + STAKE_AMOUNT * 20000) / BASIS_POINTS;
        assertEq(staking.effectiveBalance(alice), expected);
    }

    // ============================================
    // EDGE CASES: REVERTS
    // ============================================

    function test_stakeLocked_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ITAGITStaking.ZeroAmount.selector);
        staking.stakeLocked(0, ITAGITStaking.LockTier.TIER_30);
    }

    function test_unlockStake_revert_earlyUnlock() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);

        // Try to unlock before lock expires (warp only 15 days)
        vm.warp(block.timestamp + 15 days);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITAGITStaking.LockNotExpired.selector, 0, block.timestamp - 15 days + 30 days, block.timestamp
            )
        );
        staking.unlockStake(0);
    }

    function test_unlockStake_revert_invalidStakeId() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITAGITStaking.StakeNotFound.selector, 0));
        staking.unlockStake(0);
    }

    function test_unlockStake_revert_outOfBoundsStakeId() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITAGITStaking.StakeNotFound.selector, 99));
        staking.unlockStake(99);
    }

    function test_unlockStake_revert_doubleUnlock() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);

        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(alice);
        staking.unlockStake(0);

        // Second unlock should revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITAGITStaking.StakeNotFound.selector, 0));
        staking.unlockStake(0);
    }

    function test_stakeLocked_revert_whenPaused() public {
        vm.prank(governor);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30);
    }

    // ============================================
    // SELECTIVE UNLOCK: UNLOCK ONE, KEEP OTHERS
    // ============================================

    function test_unlockSpecificStake_preservesOthers() public {
        vm.startPrank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_30); // id=0
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_90); // id=1
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_180); // id=2
        vm.stopPrank();

        // Unlock only TIER_30 (id=0)
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(alice);
        staking.unlockStake(0);

        // TIER_30 released, others remain
        ITAGITStaking.LockedStake[] memory stakes = staking.getLockedStakes(alice);
        assertTrue(stakes[0].released);
        assertFalse(stakes[1].released);
        assertFalse(stakes[2].released);

        // Remaining effective: 1000*1.5 + 1000*2.0 = 3500
        uint256 expected = (STAKE_AMOUNT * 15000 + STAKE_AMOUNT * 20000) / BASIS_POINTS;
        assertEq(staking.effectiveBalance(alice), expected);
        assertEq(staking.totalStaked(), STAKE_AMOUNT * 2);
    }

    // ============================================
    // REWARD CLAIM WITH LOCKED STAKING
    // ============================================

    function test_claimRewards_withLockedStake() public {
        vm.prank(alice);
        staking.stakeLocked(STAKE_AMOUNT, ITAGITStaking.LockTier.TIER_180);

        vm.prank(emissions);
        staking.notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + 1 days);

        uint256 pending = staking.pendingRewards(alice);
        assertGt(pending, 0, "Should have pending rewards from locked stake");

        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = staking.claimRewards();

        assertEq(claimed, pending);
        assertEq(token.balanceOf(alice), balanceBefore + claimed);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_stakeLockedAndUnlock(uint256 amount, uint8 tierIndex) public {
        amount = bound(amount, 1 ether, 50_000 ether);
        tierIndex = uint8(bound(tierIndex, 0, 2));

        ITAGITStaking.LockTier tier = ITAGITStaking.LockTier(tierIndex);

        vm.prank(alice);
        staking.stakeLocked(amount, tier);

        assertEq(staking.totalStaked(), amount);
        assertEq(staking.lockedStakeCount(alice), 1);

        // Warp past lock
        uint256 duration = tierIndex == 0 ? 30 days : (tierIndex == 1 ? 90 days : 180 days);
        vm.warp(block.timestamp + duration + 1);

        vm.prank(alice);
        staking.unlockStake(0);

        assertEq(staking.totalStaked(), 0);
        assertEq(staking.effectiveBalance(alice), 0);
    }

    function testFuzz_effectiveBalanceCalculation(uint256 amount) public {
        amount = bound(amount, 1 ether, 50_000 ether);

        // Flex stake
        vm.prank(alice);
        staking.stake(amount);

        // Locked stake TIER_90 (1.5x)
        vm.prank(alice);
        staking.stakeLocked(amount, ITAGITStaking.LockTier.TIER_90);

        uint256 expected = amount + (amount * 15000) / BASIS_POINTS;
        assertEq(staking.effectiveBalance(alice), expected);
    }
}
