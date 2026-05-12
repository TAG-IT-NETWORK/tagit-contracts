// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ReputationStaking} from "../../src/staking/ReputationStaking.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ReputationStakingTest is Test {
    ReputationStaking internal staking;
    MockERC20 internal token;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xBEEF);
    address internal bob = address(0xCAFE);

    function setUp() public {
        token = new MockERC20();
        staking = new ReputationStaking(address(token), owner);

        token.mint(alice, 10_000 * 1e18);
        token.mint(bob, 10_000 * 1e18);

        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
    }

    // ------------------------ constructor ------------------------

    function test_constructor_revert_zeroToken() public {
        vm.expectRevert(ReputationStaking.ZeroAddress.selector);
        new ReputationStaking(address(0), owner);
    }

    function test_constructor_revert_zeroOwner() public {
        // OZ Ownable's constructor reverts first with OwnableInvalidOwner
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new ReputationStaking(address(token), address(0));
    }

    function test_constructor_setsToken() public view {
        assertEq(address(staking.stakingToken()), address(token));
        assertEq(staking.owner(), owner);
    }

    // ------------------------ stake ------------------------

    function test_stake_success() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);

        (uint256 amount, uint64 stakedAt,) = staking.positionOf(alice);
        assertEq(amount, 100 * 1e18);
        assertEq(stakedAt, uint64(block.timestamp));
        assertEq(staking.totalStaked(), 100 * 1e18);
        assertEq(token.balanceOf(address(staking)), 100 * 1e18);
    }

    function test_stake_revert_zero() public {
        vm.prank(alice);
        vm.expectRevert(ReputationStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_stake_revert_belowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReputationStaking.BelowMinimumStake.selector, 99 * 1e18, 100 * 1e18));
        staking.stake(99 * 1e18);
    }

    function test_stake_topUp_keepsStakedAt() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);
        (, uint64 firstStakedAt,) = staking.positionOf(alice);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.stake(50 * 1e18);

        (uint256 amount, uint64 stakedAt,) = staking.positionOf(alice);
        assertEq(amount, 150 * 1e18);
        assertEq(stakedAt, firstStakedAt);
    }

    function test_stake_revert_paused() public {
        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert();
        staking.stake(100 * 1e18);
    }

    // ------------------------ unstake ------------------------

    function test_unstake_revert_nothingStaked() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReputationStaking.NothingStaked.selector, alice));
        staking.unstake(1);
    }

    function test_unstake_revert_lockNotExpired() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);

        vm.prank(alice);
        vm.expectRevert();
        staking.unstake(50 * 1e18);
    }

    function test_unstake_success_afterLock() public {
        vm.prank(alice);
        staking.stake(200 * 1e18);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        staking.unstake(50 * 1e18);

        (uint256 amount,,) = staking.positionOf(alice);
        assertEq(amount, 150 * 1e18);
        assertEq(staking.totalStaked(), 150 * 1e18);
    }

    function test_unstake_full_clearsPosition() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        staking.unstake(100 * 1e18);

        (uint256 amount, uint64 stakedAt,) = staking.positionOf(alice);
        assertEq(amount, 0);
        assertEq(stakedAt, 0);
        assertEq(staking.totalStaked(), 0);
    }

    function test_unstake_revert_insufficient() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReputationStaking.InsufficientStake.selector, 200 * 1e18, 100 * 1e18));
        staking.unstake(200 * 1e18);
    }

    // ------------------------ reputation ------------------------

    function test_reputation_zeroBeforeMinStake() public view {
        assertEq(staking.reputationOf(alice), 0);
    }

    function test_reputation_growsWithTime() public {
        vm.prank(alice);
        staking.stake(100 * 1e18);

        vm.warp(block.timestamp + 10 days);
        // 100e18 * 10 days / 1 day = 1000e18
        assertEq(staking.reputationOf(alice), 1000 * 1e18);
    }

    function test_isUnlocked_flow() public {
        assertFalse(staking.isUnlocked(alice));

        vm.prank(alice);
        staking.stake(100 * 1e18);
        assertFalse(staking.isUnlocked(alice));

        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(staking.isUnlocked(alice));
    }

    // ------------------------ pause ------------------------

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        staking.pause();
    }

    function test_unpause_resumesStaking() public {
        vm.prank(owner);
        staking.pause();
        vm.prank(owner);
        staking.unpause();

        vm.prank(alice);
        staking.stake(100 * 1e18);
        (uint256 amount,,) = staking.positionOf(alice);
        assertEq(amount, 100 * 1e18);
    }
}
