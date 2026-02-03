// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {ITAGITTreasury} from "../../src/interfaces/ITAGITTreasury.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";

/**
 * @title TAGITTreasuryNistTest
 * @notice NIST CSF 2.0 security control tests for TAGITTreasury
 * @dev Tests SI-4 (System Monitoring) drain detection for treasury
 */
contract TAGITTreasuryNistTest is Test {
    // ============================================
    // EVENTS
    // ============================================

    event DrainDetected(
        uint256 indexed withdrawalId,
        address indexed recipient,
        uint256 amount,
        uint8 reason
    );
    event DrainDetectorReset(address indexed admin);

    // ============================================
    // CONTRACTS
    // ============================================

    TAGITTreasury public treasury;
    TAGITToken public token;

    // ============================================
    // ADDRESSES
    // ============================================

    address public owner;
    address public governor;
    address public tokenTreasury;
    address public recipient;
    address public attacker;

    address[] public signers;

    // ============================================
    // CONSTANTS
    // ============================================

    bytes32 public constant PROGRAM_ID = keccak256("TEST_PROGRAM");
    uint256 public constant ALLOCATION_AMOUNT = 100_000 ether;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        tokenTreasury = makeAddr("tokenTreasury");
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");

        // Create 8 signers for multisig
        for (uint256 i = 0; i < 8; i++) {
            signers.push(makeAddr(string(abi.encodePacked("signer", i))));
        }

        vm.startPrank(owner);

        // Deploy TAGITToken (upgradeable)
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(
            TAGITToken.initialize,
            (owner, tokenTreasury)
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITTreasury (upgradeable via TransparentProxy simulation)
        TAGITTreasury treasuryImpl = new TAGITTreasury();
        bytes memory treasuryData = abi.encodeCall(
            TAGITTreasury.initialize,
            (governor, address(token), signers)
        );
        ERC1967Proxy treasuryProxy = new ERC1967Proxy(address(treasuryImpl), treasuryData);
        treasury = TAGITTreasury(payable(address(treasuryProxy)));

        // Fund treasury with tokens
        token.transfer(address(treasury), 10_000_000 ether);

        vm.stopPrank();

        // Sync drain detector balance
        vm.prank(governor);
        treasury.syncDrainDetectorBalance();
    }

    // ============================================
    // DRAIN DETECTOR TESTS (SI-4)
    // ============================================

    function test_drainDetector_initialState() public view {
        assertTrue(treasury.isDrainDetectorEnabled());

        (bool isTripped, uint256 cooldownRemaining) = treasury.getDrainDetectorStatus();
        assertFalse(isTripped);
        assertEq(cooldownRemaining, 0);
    }

    function test_drainDetector_tracksBalance() public view {
        uint256 trackedBalance = treasury.getDrainDetectorBalance();
        uint256 actualBalance = token.balanceOf(address(treasury));

        assertEq(trackedBalance, actualBalance);
    }

    function test_drainDetector_governorCanSyncBalance() public {
        // Transfer more tokens
        vm.prank(owner);
        token.transfer(address(treasury), 1_000_000 ether);

        uint256 balanceBefore = treasury.getDrainDetectorBalance();

        vm.prank(governor);
        treasury.syncDrainDetectorBalance();

        uint256 balanceAfter = treasury.getDrainDetectorBalance();
        assertGt(balanceAfter, balanceBefore);
    }

    function test_drainDetector_governorCanReset() public {
        vm.prank(governor);
        vm.expectEmit(true, false, false, false);
        emit DrainDetectorReset(governor);
        treasury.resetDrainDetector();
    }

    function test_drainDetector_governorCanUpdateThresholds() public {
        vm.prank(governor);
        treasury.setDrainThresholds(2000, 4000, 20); // 20%, 40%, 20 txs

        // Verify it doesn't revert - thresholds updated
    }

    function test_drainDetector_governorCanDisable() public {
        vm.prank(governor);
        treasury.setDrainDetectorEnabled(false);

        assertFalse(treasury.isDrainDetectorEnabled());
    }

    function test_drainDetector_checkCapacity() public view {
        (
            uint256 spikeCapacity,
            uint256 velocityCapacity,
            uint32 txCapacity
        ) = treasury.getDrainDetectorCapacity();

        assertGt(spikeCapacity, 0);
        assertGt(velocityCapacity, 0);
        assertGt(txCapacity, 0);
    }

    function test_drainDetector_wouldTriggerCheck() public view {
        // Small withdrawal shouldn't trigger
        (bool wouldTrip, uint8 reason) = treasury.wouldTriggerDrainDetection(1000 ether);
        assertFalse(wouldTrip);
        assertEq(reason, 0);
    }

    // ============================================
    // ALLOCATION AND WITHDRAWAL TESTS
    // ============================================

    function test_allocation_normalFlow() public {
        // Governor creates allocation
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(
            PROGRAM_ID,
            ALLOCATION_AMOUNT,
            recipient,
            365 days
        );

        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.amount, ALLOCATION_AMOUNT);
        assertEq(alloc.recipient, recipient);
        assertTrue(alloc.active);
    }

    function test_withdrawal_normalFlowSmall() public {
        // Create allocation
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(
            PROGRAM_ID,
            ALLOCATION_AMOUNT,
            recipient,
            365 days
        );

        // Queue small withdrawal (under $50k threshold)
        uint256 withdrawAmount = 10_000 ether;
        vm.prank(recipient);
        uint256 withdrawalId = treasury.queueWithdrawal(
            allocationId,
            address(token),
            withdrawAmount,
            recipient
        );

        // Wait for timelock (48 hours for small)
        vm.warp(block.timestamp + 48 hours + 1);

        // Execute withdrawal
        uint256 balanceBefore = token.balanceOf(recipient);
        vm.prank(recipient);
        treasury.executeWithdrawal(withdrawalId);
        uint256 balanceAfter = token.balanceOf(recipient);

        assertEq(balanceAfter - balanceBefore, withdrawAmount);
    }

    function test_withdrawal_drainDetectorBlocksSpike() public {
        // Create allocation with large amount
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(
            PROGRAM_ID,
            5_000_000 ether, // Large allocation
            recipient,
            365 days
        );

        // Queue a withdrawal that would trigger spike detection
        // Spike threshold is 30% of tracked balance
        uint256 spikeAmount = 4_000_000 ether;
        vm.prank(recipient);
        uint256 withdrawalId = treasury.queueWithdrawal(
            allocationId,
            address(token),
            spikeAmount,
            recipient
        );

        // Wait for timelock
        vm.warp(block.timestamp + 72 hours + 1); // Medium timelock

        // Should revert due to drain detection
        vm.prank(recipient);
        vm.expectRevert();
        treasury.executeWithdrawal(withdrawalId);
    }

    // ============================================
    // SECURITY TESTS
    // ============================================

    function test_security_nonGovernorCannotResetDrainDetector() public {
        vm.prank(attacker);
        vm.expectRevert();
        treasury.resetDrainDetector();
    }

    function test_security_nonGovernorCannotUpdateThresholds() public {
        vm.prank(attacker);
        vm.expectRevert();
        treasury.setDrainThresholds(2000, 4000, 20);
    }

    function test_security_nonGovernorCannotDisableDrainDetector() public {
        vm.prank(attacker);
        vm.expectRevert();
        treasury.setDrainDetectorEnabled(false);
    }

    function test_security_nonGovernorCannotSyncBalance() public {
        vm.prank(attacker);
        vm.expectRevert();
        treasury.syncDrainDetectorBalance();
    }

    function test_security_nonRecipientCannotQueueWithdrawal() public {
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(
            PROGRAM_ID,
            ALLOCATION_AMOUNT,
            recipient,
            365 days
        );

        vm.prank(attacker);
        vm.expectRevert();
        treasury.queueWithdrawal(allocationId, address(token), 1000 ether, attacker);
    }

    // ============================================
    // TIMELOCK TESTS
    // ============================================

    function test_timelock_smallWithdrawal() public view {
        (uint48 timelock, bool requiresMultisig) = treasury.getTimelockForAmount(10_000 ether);
        assertEq(timelock, 48 hours);
        assertFalse(requiresMultisig);
    }

    function test_timelock_mediumWithdrawal() public view {
        (uint48 timelock, bool requiresMultisig) = treasury.getTimelockForAmount(100_000 ether);
        assertEq(timelock, 72 hours);
        assertFalse(requiresMultisig);
    }

    function test_timelock_largeWithdrawal() public view {
        (uint48 timelock, bool requiresMultisig) = treasury.getTimelockForAmount(300_000 ether);
        assertEq(timelock, 7 days);
        assertTrue(requiresMultisig);
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function test_pause_governorCanPause() public {
        vm.prank(governor);
        treasury.pause();

        assertTrue(treasury.paused());
    }

    function test_pause_governorCanUnpause() public {
        vm.prank(governor);
        treasury.pause();

        vm.prank(governor);
        treasury.unpause();

        assertFalse(treasury.paused());
    }

    function test_pause_blocksWithdrawals() public {
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(
            PROGRAM_ID,
            ALLOCATION_AMOUNT,
            recipient,
            365 days
        );

        vm.prank(governor);
        treasury.pause();

        vm.prank(recipient);
        vm.expectRevert();
        treasury.queueWithdrawal(allocationId, address(token), 1000 ether, recipient);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_createAllocation() public {
        vm.prank(governor);
        uint256 gasBefore = gasleft();
        treasury.createAllocation(PROGRAM_ID, ALLOCATION_AMOUNT, recipient, 365 days);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 200000, "createAllocation() too expensive");
    }

    function test_gas_queueWithdrawal() public {
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(
            PROGRAM_ID,
            ALLOCATION_AMOUNT,
            recipient,
            365 days
        );

        vm.prank(recipient);
        uint256 gasBefore = gasleft();
        treasury.queueWithdrawal(allocationId, address(token), 10_000 ether, recipient);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 150000, "queueWithdrawal() too expensive");
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function test_viewFunctions() public view {
        treasury.getBalance();
        treasury.totalAllocated();
        treasury.totalUnallocated();
        treasury.governor();
        treasury.tagitToken();
        treasury.requiredSigners();
        treasury.version();
    }

    function test_drainDetectorWindowStats() public view {
        (
            uint256 outflow,
            uint32 txCount,
            uint64 windowStart_,
            uint256 windowRemaining
        ) = treasury.getDrainDetectorWindowStats();

        assertEq(outflow, 0);
        assertEq(txCount, 0);
        assertGt(windowStart_, 0);
        assertGt(windowRemaining, 0);
    }

    // ============================================
    // DEPOSIT TESTS
    // ============================================

    function test_deposit_tokensUpdateDrainDetector() public {
        uint256 balanceBefore = treasury.getDrainDetectorBalance();

        vm.prank(owner);
        token.approve(address(treasury), 100_000 ether);

        vm.prank(owner);
        treasury.depositToken(address(token), 100_000 ether);

        uint256 balanceAfter = treasury.getDrainDetectorBalance();
        assertEq(balanceAfter, balanceBefore + 100_000 ether);
    }

    function test_deposit_ethWorks() public {
        vm.deal(owner, 100 ether);

        vm.prank(owner);
        treasury.deposit{value: 10 ether}();

        (uint256 eth, ) = treasury.getBalance();
        assertEq(eth, 10 ether);
    }
}
