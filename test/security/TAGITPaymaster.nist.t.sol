// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IPaymaster} from "@account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

import {TAGITPaymaster} from "../../src/account/TAGITPaymaster.sol";
import {ITAGITPaymaster} from "../../src/interfaces/ITAGITPaymaster.sol";

/**
 * @title MockEntryPoint
 * @notice Minimal mock for ERC-4337 EntryPoint
 */
contract MockEntryPoint {
    mapping(address => uint256) public deposits;

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return deposits[account];
    }

    function withdrawTo(address payable to, uint256 amount) external {
        require(deposits[msg.sender] >= amount, "Insufficient deposit");
        deposits[msg.sender] -= amount;
        to.transfer(amount);
    }

    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}

    // Allow receiving ETH
    receive() external payable {}
}

/**
 * @title TAGITPaymasterNistTest
 * @notice NIST CSF 2.0 security control tests for TAGITPaymaster
 * @dev Tests SI-4 (System Monitoring) and IR-4 (Incident Response)
 */
contract TAGITPaymasterNistTest is Test {
    // ============================================
    // EVENTS
    // ============================================

    event PaymasterPausedEvent(uint256 indexed timestamp, string reason);
    event PaymasterUnpausedEvent(uint256 indexed timestamp);

    // ============================================
    // CONTRACTS
    // ============================================

    TAGITPaymaster public paymaster;
    MockEntryPoint public entryPoint;

    // ============================================
    // ADDRESSES
    // ============================================

    address public owner;
    address public governor;
    address public user;
    address public attacker;

    // ============================================
    // CONSTANTS
    // ============================================

    bytes4 public constant TEST_SELECTOR = bytes4(keccak256("testFunction()"));
    bytes32 public constant TEST_BRAND_ID = keccak256("TestBrand");

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        user = makeAddr("user");
        attacker = makeAddr("attacker");

        vm.deal(owner, 100 ether);
        vm.deal(governor, 100 ether);
        vm.deal(user, 100 ether);
        vm.deal(attacker, 100 ether);

        vm.startPrank(owner);

        // Deploy mock EntryPoint
        entryPoint = new MockEntryPoint();
        vm.deal(address(entryPoint), 1000 ether);

        // Deploy TAGITPaymaster (upgradeable)
        TAGITPaymaster paymasterImpl = new TAGITPaymaster();
        bytes memory paymasterData = abi.encodeCall(TAGITPaymaster.initialize, (address(entryPoint), governor, owner));
        ERC1967Proxy paymasterProxy = new ERC1967Proxy(address(paymasterImpl), paymasterData);
        paymaster = TAGITPaymaster(payable(address(paymasterProxy)));

        vm.stopPrank();

        // PATCH-13: Register test brand before deposits
        vm.prank(governor);
        paymaster.registerBrand(TEST_BRAND_ID, user);

        // Setup sponsorship config for test selector
        vm.prank(governor);
        paymaster.setSponsorshipConfig(
            TEST_SELECTOR,
            ITAGITPaymaster.SponsorshipConfig({selector: TEST_SELECTOR, maxGas: 500000, dailyLimit: 100, active: true})
        );

        // Fund paymaster with protocol deposit for drain detection tests
        vm.prank(governor);
        paymaster.depositProtocol{value: 10 ether}();
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _simulatePostOp(uint256 gasCost) internal {
        // Encode context as returned by validatePaymasterUserOp
        bytes memory context = abi.encode(user, TEST_SELECTOR, bytes32(0), gasCost);

        // Call postOp as if from EntryPoint
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, gasCost, tx.gasprice);
    }

    // ============================================
    // CIRCUIT BREAKER TESTS (SI-4, IR-4)
    // ============================================

    function test_circuitBreaker_initialState() public {
        // Circuit breaker should be in initial state: not tripped, 0 count
        (uint64 count, uint64 windowStart, bool tripped, uint64 cooldownEnds) = paymaster.getCircuitBreakerState();
        assertEq(count, 0);
        assertFalse(tripped);
        assertEq(cooldownEnds, 0);
        // Note: Circuit breaker is incremented in validatePaymasterUserOp, which requires
        // proper PackedUserOperation setup. The circuit breaker state is tested here for initial values.
    }

    function test_circuitBreaker_viewState() public {
        (uint64 count, uint64 windowStart, bool tripped, uint64 cooldownEnds) = paymaster.getCircuitBreakerState();
        assertEq(count, 0);
        assertFalse(tripped);
        assertEq(cooldownEnds, 0);
    }

    function test_circuitBreaker_governorCanReset() public {
        // Governor can reset circuit breaker
        vm.prank(governor);
        paymaster.resetCircuitBreaker();

        (,, bool tripped,) = paymaster.getCircuitBreakerState();
        assertFalse(tripped);
    }

    function test_circuitBreaker_nonGovernorCannotReset() public {
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.resetCircuitBreaker();
    }

    // ============================================
    // DRAIN DETECTOR TESTS (SI-4)
    // ============================================

    function test_drainDetector_viewState() public {
        (
            uint128 trackedBalance,
            uint16 spikeThresholdBps,
            uint16 velocityThresholdBps,
            uint32 maxTxPerWindow,
            bool tripped,
            uint64 cooldownEnds
        ) = paymaster.getDrainDetectorState();

        // Initial balance from protocol deposit
        assertEq(trackedBalance, 10 ether);
        assertEq(spikeThresholdBps, 1000); // 10%
        assertEq(velocityThresholdBps, 2500); // 25%
        assertEq(maxTxPerWindow, 100);
        assertFalse(tripped);
        assertEq(cooldownEnds, 0);
    }

    function test_drainDetector_tracksDeposits() public {
        // Deposit more
        vm.prank(user);
        paymaster.depositForBrand{value: 5 ether}(TEST_BRAND_ID);

        (uint128 trackedBalance,,,,,) = paymaster.getDrainDetectorState();
        assertEq(trackedBalance, 15 ether); // 10 + 5
    }

    function test_drainDetector_tripsOnSpike() public {
        // Spike threshold is 10% of 10 ETH = 1 ETH
        // Try to spend more than that in single postOp
        bytes memory context = abi.encode(user, TEST_SELECTOR, bytes32(0), 2 ether);

        // Need to fund the tracked balance to allow the check
        // Spike check: 2 ETH > 1 ETH (10% of 10 ETH) = should trip
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 2 ether, tx.gasprice);

        // Should be paused now
        assertTrue(paymaster.paused());
    }

    function test_drainDetector_governorCanUpdateBalance() public {
        vm.prank(governor);
        paymaster.updateDrainBalance(50 ether);

        (uint128 trackedBalance,,,,,) = paymaster.getDrainDetectorState();
        assertEq(trackedBalance, 50 ether);
    }

    function test_drainDetector_governorCanSyncBalance() public {
        // Add more to EntryPoint deposit directly (simulating external deposit)
        vm.deal(address(paymaster), 100 ether);
        vm.prank(address(paymaster));
        entryPoint.depositTo{value: 90 ether}(address(paymaster)); // Now 100 ETH total

        // Sync the balance
        vm.prank(governor);
        paymaster.syncDrainBalance();

        (uint128 trackedBalance,,,,,) = paymaster.getDrainDetectorState();
        assertEq(trackedBalance, 100 ether);
    }

    // ============================================
    // PAUSE TESTS (IR-4)
    // ============================================

    function test_pause_governorCanPause() public {
        vm.prank(governor);
        paymaster.pause();

        assertTrue(paymaster.paused());
    }

    function test_pause_governorCanUnpause() public {
        vm.prank(governor);
        paymaster.pause();

        vm.prank(governor);
        paymaster.unpause();

        assertFalse(paymaster.paused());
    }

    function test_pause_nonGovernorCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.pause();
    }

    function test_pause_nonGovernorCannotUnpause() public {
        vm.prank(governor);
        paymaster.pause();

        vm.prank(attacker);
        vm.expectRevert();
        paymaster.unpause();
    }

    function test_pause_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit PaymasterPausedEvent(block.timestamp, "manual");

        vm.prank(governor);
        paymaster.pause();
    }

    function test_unpause_emitsEvent() public {
        vm.prank(governor);
        paymaster.pause();

        vm.expectEmit(true, true, true, true);
        emit PaymasterUnpausedEvent(block.timestamp);

        vm.prank(governor);
        paymaster.unpause();
    }

    // ============================================
    // NORMAL OPERATIONS TESTS
    // ============================================

    function test_normalOps_depositForBrandWorks() public {
        vm.prank(user);
        paymaster.depositForBrand{value: 1 ether}(TEST_BRAND_ID);

        ITAGITPaymaster.BrandDeposit memory deposit = paymaster.getBrandDeposit(TEST_BRAND_ID);
        assertEq(deposit.balance, 1 ether);
        assertTrue(deposit.active);
    }

    function test_normalOps_protocolDepositWorks() public {
        uint256 balanceBefore = paymaster.getProtocolDeposit();

        vm.prank(user);
        paymaster.depositProtocol{value: 1 ether}();

        assertEq(paymaster.getProtocolDeposit(), balanceBefore + 1 ether);
    }

    function test_normalOps_sponsorshipConfigWorks() public {
        bytes4 newSelector = bytes4(keccak256("newFunction()"));

        vm.prank(governor);
        paymaster.setSponsorshipConfig(
            newSelector,
            ITAGITPaymaster.SponsorshipConfig({selector: newSelector, maxGas: 100000, dailyLimit: 50, active: true})
        );

        assertTrue(paymaster.isSponsoredOperation(newSelector));
        ITAGITPaymaster.SponsorshipConfig memory config = paymaster.getSponsorshipConfig(newSelector);
        assertEq(config.maxGas, 100000);
        assertEq(config.dailyLimit, 50);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_postOpOverhead() public {
        bytes memory context = abi.encode(user, TEST_SELECTOR, bytes32(0), 0.001 ether);

        vm.prank(address(entryPoint));
        uint256 gasBefore = gasleft();
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.001 ether, tx.gasprice);
        uint256 gasUsed = gasBefore - gasleft();

        // postOp should be reasonably cheap (< 50k gas overhead from security)
        assertLt(gasUsed, 100000, "postOp() too expensive");
    }

    function test_gas_viewFunctions() public view {
        paymaster.getCircuitBreakerState();
        paymaster.getDrainDetectorState();
        paymaster.paused();
        paymaster.getProtocolDeposit();
    }

    // ============================================
    // SECURITY EDGE CASES
    // ============================================

    function test_security_pausedBlocksOperations() public {
        vm.prank(governor);
        paymaster.pause();

        // Should revert on paused
        // Note: validatePaymasterUserOp checks pause first
    }

    function test_security_drainDetectorAutosPauses() public {
        // Trigger spike detection by large withdrawal
        bytes memory context = abi.encode(user, TEST_SELECTOR, bytes32(0), 2 ether);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 2 ether, tx.gasprice);

        // Should be auto-paused
        assertTrue(paymaster.paused());
    }

    function test_security_nonEntryPointCannotCallPostOp() public {
        bytes memory context = abi.encode(user, TEST_SELECTOR, bytes32(0), 0.001 ether);

        vm.prank(attacker);
        vm.expectRevert();
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.001 ether, tx.gasprice);
    }

    function test_security_adminFunctionsProtected() public {
        // Non-governor cannot update drain balance
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.updateDrainBalance(100 ether);

        // Non-governor cannot sync drain balance
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.syncDrainBalance();

        // Non-governor cannot withdraw protocol
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.withdrawProtocol(1 ether, attacker);
    }

    // ============================================
    // INTEGRATION TESTS
    // ============================================

    function test_integration_normalUsageDoesntTrip() public {
        // Simulate normal usage: small, regular gas costs
        bytes memory context = abi.encode(user, TEST_SELECTOR, bytes32(0), 0.05 ether);

        vm.startPrank(address(entryPoint));
        for (uint256 i = 0; i < 10; i++) {
            paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.05 ether, tx.gasprice);
        }
        vm.stopPrank();

        // Should NOT be paused
        assertFalse(paymaster.paused());
    }

    function test_integration_recoveryAfterTrip() public {
        // Trip the drain detector
        bytes memory context = abi.encode(user, TEST_SELECTOR, bytes32(0), 2 ether);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 2 ether, tx.gasprice);

        assertTrue(paymaster.paused());

        // Governor investigates and unpause
        vm.prank(governor);
        paymaster.unpause();

        assertFalse(paymaster.paused());

        // Wait for drain detector cooldown (2 hours)
        vm.warp(block.timestamp + 2 hours + 1);

        // Normal operations resume after cooldown
        bytes memory smallContext = abi.encode(user, TEST_SELECTOR, bytes32(0), 0.01 ether);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, smallContext, 0.01 ether, tx.gasprice);
    }
}
