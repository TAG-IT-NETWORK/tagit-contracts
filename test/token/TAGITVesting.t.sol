// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITVesting} from "../../src/token/TAGITVesting.sol";
import {ITAGITVesting} from "../../src/interfaces/ITAGITVesting.sol";
import {
    GENESIS_SUPPLY,
    STANDARD_CLIFF,
    STANDARD_VESTING_DURATION,
    VERSION
} from "../../src/libraries/Constants.sol";

/**
 * @title TAGITVesting Unit Tests
 * @notice Comprehensive tests for the TAGIT vesting contract
 */
contract TAGITVestingTest is Test {
    TAGITToken public token;
    TAGITToken public tokenImpl;
    TAGITVesting public vesting;

    address public owner;
    address public treasury;
    address public alice;
    address public bob;
    address public charlie;

    uint256 public constant VEST_AMOUNT = 1_000_000 ether;
    uint256 public constant ONE_YEAR = 365 days;
    uint256 public constant FOUR_YEARS = 4 * 365 days;

    // Events
    event VestingCreated(
        address indexed beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration
    );
    event TokensClaimed(address indexed beneficiary, uint256 amount);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy TAGITToken
        tokenImpl = new TAGITToken();
        bytes memory tokenInitData = abi.encodeWithSelector(
            TAGITToken.initialize.selector,
            treasury,
            owner
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITVesting
        vesting = new TAGITVesting(address(token), owner);

        // Transfer tokens to vesting contract for grants
        vm.prank(treasury);
        token.transfer(address(vesting), 10_000_000 ether);
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function test_constructor_setsToken() public view {
        assertEq(address(vesting.token()), address(token));
    }

    function test_constructor_setsOwner() public view {
        assertEq(vesting.owner(), owner);
    }

    function test_constructor_revert_zeroToken() public {
        vm.expectRevert(ITAGITVesting.ZeroAddress.selector);
        new TAGITVesting(address(0), owner);
    }

    // ============================================
    // CREATE VEST TESTS
    // ============================================

    function test_createVest_setsCorrectSchedule() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        ITAGITVesting.VestingSchedule memory schedule = vesting.vestingSchedule(alice);

        assertEq(schedule.totalAmount, VEST_AMOUNT);
        assertEq(schedule.startTime, block.timestamp);
        assertEq(schedule.cliffDuration, ONE_YEAR);
        assertEq(schedule.vestingDuration, FOUR_YEARS);
        assertEq(schedule.claimed, 0);
    }

    function test_createVest_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit VestingCreated(alice, VEST_AMOUNT, block.timestamp, ONE_YEAR, FOUR_YEARS);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);
    }

    function test_createVest_updatesTotalAllocated() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        assertEq(vesting.totalAllocated(), VEST_AMOUNT);

        vm.prank(owner);
        vesting.createVest(bob, VEST_AMOUNT * 2, ONE_YEAR, FOUR_YEARS);

        assertEq(vesting.totalAllocated(), VEST_AMOUNT * 3);
    }

    function test_createVest_zeroCliff() public {
        // Zero cliff should be allowed (immediate vesting start)
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, 0, FOUR_YEARS);

        assertTrue(vesting.hasSchedule(alice));
    }

    function test_createVest_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vesting.createVest(bob, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);
    }

    function test_createVest_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ITAGITVesting.ZeroAddress.selector);
        vesting.createVest(address(0), VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);
    }

    function test_createVest_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(ITAGITVesting.ZeroAmount.selector);
        vesting.createVest(alice, 0, ONE_YEAR, FOUR_YEARS);
    }

    function test_createVest_revert_zeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(ITAGITVesting.ZeroDuration.selector);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, 0);
    }

    function test_createVest_revert_cliffExceedsVesting() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITVesting.CliffExceedsVesting.selector,
            FOUR_YEARS,
            ONE_YEAR
        ));
        vesting.createVest(alice, VEST_AMOUNT, FOUR_YEARS, ONE_YEAR);
    }

    function test_createVest_revert_duplicateBeneficiary() public {
        vm.startPrank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        vm.expectRevert(abi.encodeWithSelector(
            ITAGITVesting.ScheduleAlreadyExists.selector,
            alice
        ));
        vesting.createVest(alice, VEST_AMOUNT * 2, ONE_YEAR, FOUR_YEARS);
        vm.stopPrank();
    }

    // ============================================
    // CLAIM TESTS
    // ============================================

    function test_claim_revertsBeforeCliff() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Try to claim before cliff
        vm.warp(block.timestamp + 6 * 30 days); // 6 months

        uint256 cliffEnd = block.timestamp - 6 * 30 days + ONE_YEAR;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITVesting.CliffNotReached.selector,
            block.timestamp,
            cliffEnd
        ));
        vesting.claim();
    }

    function test_claim_partialAfterCliff() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Warp to exactly after cliff (1 year = 25% vested)
        vm.warp(block.timestamp + ONE_YEAR);

        uint256 expectedVested = VEST_AMOUNT / 4; // 25%
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit TokensClaimed(alice, expectedVested);
        vesting.claim();

        assertEq(token.balanceOf(alice), balanceBefore + expectedVested);
        assertEq(vesting.totalClaimed(alice), expectedVested);
    }

    function test_claim_halfwayVested() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Warp to 2 years (50% vested)
        vm.warp(block.timestamp + 2 * ONE_YEAR);

        uint256 expectedVested = VEST_AMOUNT / 2; // 50%

        vm.prank(alice);
        vesting.claim();

        assertEq(vesting.totalClaimed(alice), expectedVested);
    }

    function test_claim_fullAfterVestingComplete() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Warp past vesting end
        vm.warp(block.timestamp + FOUR_YEARS + 1 days);

        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        vesting.claim();

        assertEq(token.balanceOf(alice), balanceBefore + VEST_AMOUNT);
        assertEq(vesting.totalClaimed(alice), VEST_AMOUNT);
    }

    function test_claim_multipleClaimsOverTime() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // First claim at 1 year (25%)
        vm.warp(block.timestamp + ONE_YEAR);
        vm.prank(alice);
        vesting.claim();
        assertEq(vesting.totalClaimed(alice), VEST_AMOUNT / 4);

        // Second claim at 2 years (50% total, 25% new)
        vm.warp(block.timestamp + ONE_YEAR);
        vm.prank(alice);
        vesting.claim();
        assertEq(vesting.totalClaimed(alice), VEST_AMOUNT / 2);

        // Third claim at 4 years (100% total, 50% new)
        vm.warp(block.timestamp + 2 * ONE_YEAR);
        vm.prank(alice);
        vesting.claim();
        assertEq(vesting.totalClaimed(alice), VEST_AMOUNT);
    }

    function test_claim_revert_noSchedule() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITVesting.NoScheduleExists.selector,
            alice
        ));
        vesting.claim();
    }

    function test_claim_revert_nothingToClaim() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Claim at 1 year
        vm.warp(block.timestamp + ONE_YEAR);
        vm.prank(alice);
        vesting.claim();

        // Try to claim again immediately
        vm.prank(alice);
        vm.expectRevert(ITAGITVesting.NothingToClaim.selector);
        vesting.claim();
    }

    function test_claim_revert_afterFullyVested() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Claim full amount
        vm.warp(block.timestamp + FOUR_YEARS);
        vm.prank(alice);
        vesting.claim();

        // Try to claim again
        vm.warp(block.timestamp + ONE_YEAR);
        vm.prank(alice);
        vm.expectRevert(ITAGITVesting.NothingToClaim.selector);
        vesting.claim();
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_vestedAmount_beforeCliff() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        assertEq(vesting.vestedAmount(alice), 0);

        vm.warp(block.timestamp + 6 * 30 days);
        assertEq(vesting.vestedAmount(alice), 0);
    }

    function test_vestedAmount_linearCalculation() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // At 1 year (25%)
        vm.warp(block.timestamp + ONE_YEAR);
        assertEq(vesting.vestedAmount(alice), VEST_AMOUNT / 4);

        // At 2 years (50%)
        vm.warp(block.timestamp + ONE_YEAR);
        assertEq(vesting.vestedAmount(alice), VEST_AMOUNT / 2);

        // At 3 years (75%)
        vm.warp(block.timestamp + ONE_YEAR);
        assertEq(vesting.vestedAmount(alice), (VEST_AMOUNT * 3) / 4);

        // At 4 years (100%)
        vm.warp(block.timestamp + ONE_YEAR);
        assertEq(vesting.vestedAmount(alice), VEST_AMOUNT);
    }

    function test_vestedAmount_noSchedule() public view {
        assertEq(vesting.vestedAmount(alice), 0);
    }

    function test_claimableAmount_beforeCliff() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        assertEq(vesting.claimableAmount(alice), 0);
    }

    function test_claimableAmount_afterPartialClaim() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Claim at 1 year
        vm.warp(block.timestamp + ONE_YEAR);
        vm.prank(alice);
        vesting.claim();

        // Check claimable at 2 years
        vm.warp(block.timestamp + ONE_YEAR);
        assertEq(vesting.claimableAmount(alice), VEST_AMOUNT / 4);
    }

    function test_cliffEndTime() public {
        uint256 startTime = block.timestamp;
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        assertEq(vesting.cliffEndTime(alice), startTime + ONE_YEAR);
    }

    function test_vestingEndTime() public {
        uint256 startTime = block.timestamp;
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        assertEq(vesting.vestingEndTime(alice), startTime + FOUR_YEARS);
    }

    function test_hasSchedule() public {
        assertFalse(vesting.hasSchedule(alice));

        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        assertTrue(vesting.hasSchedule(alice));
    }

    function test_grantAmount() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        assertEq(vesting.grantAmount(alice), VEST_AMOUNT);
    }

    function test_version() public view {
        assertEq(vesting.version(), VERSION);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_claimTiming(uint256 timeElapsed) public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Bound to reasonable time range
        timeElapsed = bound(timeElapsed, ONE_YEAR, FOUR_YEARS + 365 days);

        vm.warp(block.timestamp + timeElapsed);

        uint256 expectedVested;
        if (timeElapsed >= FOUR_YEARS) {
            expectedVested = VEST_AMOUNT;
        } else {
            expectedVested = (VEST_AMOUNT * timeElapsed) / FOUR_YEARS;
        }

        assertEq(vesting.vestedAmount(alice), expectedVested);
    }

    function testFuzz_createVest_validParams(
        address beneficiary,
        uint256 amount,
        uint256 cliffDuration,
        uint256 vestingDuration
    ) public {
        vm.assume(beneficiary != address(0));
        vm.assume(beneficiary != address(vesting));
        amount = bound(amount, 1, 1_000_000 ether);
        vestingDuration = bound(vestingDuration, 1 days, 10 * 365 days);
        cliffDuration = bound(cliffDuration, 0, vestingDuration);

        vm.prank(owner);
        vesting.createVest(beneficiary, amount, cliffDuration, vestingDuration);

        assertEq(vesting.grantAmount(beneficiary), amount);
    }

    // ============================================
    // INVARIANT TESTS
    // ============================================

    function test_invariant_claimedNeverExceedsVested() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        // Multiple claims at different times
        uint256[] memory times = new uint256[](5);
        times[0] = ONE_YEAR;
        times[1] = ONE_YEAR + 6 * 30 days;
        times[2] = 2 * ONE_YEAR;
        times[3] = 3 * ONE_YEAR;
        times[4] = FOUR_YEARS;

        for (uint256 i = 0; i < times.length; i++) {
            vm.warp(block.timestamp + (i == 0 ? times[i] : times[i] - times[i-1]));

            if (vesting.claimableAmount(alice) > 0) {
                vm.prank(alice);
                vesting.claim();
            }

            assertLe(vesting.totalClaimed(alice), vesting.vestedAmount(alice));
        }
    }

    function test_invariant_vestingScheduleImmutable() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        ITAGITVesting.VestingSchedule memory before = vesting.vestingSchedule(alice);

        // Perform claims and time warps
        vm.warp(block.timestamp + 2 * ONE_YEAR);
        vm.prank(alice);
        vesting.claim();

        ITAGITVesting.VestingSchedule memory after_ = vesting.vestingSchedule(alice);

        // Verify immutable fields haven't changed
        assertEq(before.totalAmount, after_.totalAmount);
        assertEq(before.startTime, after_.startTime);
        assertEq(before.cliffDuration, after_.cliffDuration);
        assertEq(before.vestingDuration, after_.vestingDuration);
        // Only claimed should change
        assertGt(after_.claimed, before.claimed);
    }

    function test_invariant_totalClaimedMatchesSum() public {
        vm.startPrank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);
        vesting.createVest(bob, VEST_AMOUNT * 2, ONE_YEAR, FOUR_YEARS);
        vm.stopPrank();

        // Warp and claim
        vm.warp(block.timestamp + 2 * ONE_YEAR);

        vm.prank(alice);
        vesting.claim();
        vm.prank(bob);
        vesting.claim();

        uint256 aliceClaimed = vesting.totalClaimed(alice);
        uint256 bobClaimed = vesting.totalClaimed(bob);

        // Both should have claimed 50% of their grants
        assertEq(aliceClaimed, VEST_AMOUNT / 2);
        assertEq(bobClaimed, VEST_AMOUNT);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_createVest() public {
        vm.prank(owner);
        uint256 gasBefore = gasleft();
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 150,000
        assertLt(gasUsed, 150000, "createVest() exceeds gas target");
    }

    function test_gas_claim() public {
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);

        vm.warp(block.timestamp + 2 * ONE_YEAR);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        vesting.claim();
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 80,000
        assertLt(gasUsed, 80000, "claim() exceeds gas target");
    }

    // ============================================
    // EDGE CASE TESTS
    // ============================================

    function test_edgeCase_cliffEqualsVesting() public {
        // Cliff equals vesting duration (all at once at end)
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, FOUR_YEARS, FOUR_YEARS);

        // Before cliff
        vm.warp(block.timestamp + FOUR_YEARS - 1);
        assertEq(vesting.claimableAmount(alice), 0);

        // At cliff end (which is also vesting end)
        vm.warp(block.timestamp + 1);
        assertEq(vesting.claimableAmount(alice), VEST_AMOUNT);
    }

    function test_edgeCase_zeroCliff() public {
        // Zero cliff means vesting starts immediately
        vm.prank(owner);
        vesting.createVest(alice, VEST_AMOUNT, 0, FOUR_YEARS);

        // Should be able to claim immediately (small amount)
        vm.warp(block.timestamp + 1 days);

        uint256 expectedVested = (VEST_AMOUNT * 1 days) / FOUR_YEARS;
        assertEq(vesting.claimableAmount(alice), expectedVested);
    }

    function test_edgeCase_multipleVestingSchedules() public {
        vm.startPrank(owner);
        vesting.createVest(alice, VEST_AMOUNT, ONE_YEAR, FOUR_YEARS);
        vesting.createVest(bob, VEST_AMOUNT * 2, 6 * 30 days, 2 * ONE_YEAR);
        vesting.createVest(charlie, VEST_AMOUNT / 2, 0, ONE_YEAR);
        vm.stopPrank();

        assertEq(vesting.totalAllocated(), VEST_AMOUNT + VEST_AMOUNT * 2 + VEST_AMOUNT / 2);

        // Each beneficiary has independent schedule
        assertTrue(vesting.hasSchedule(alice));
        assertTrue(vesting.hasSchedule(bob));
        assertTrue(vesting.hasSchedule(charlie));
    }
}
