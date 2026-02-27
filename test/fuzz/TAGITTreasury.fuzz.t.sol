// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {ITAGITTreasury} from "../../src/interfaces/ITAGITTreasury.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title TAGITTreasuryFuzzTest
 * @notice Comprehensive fuzz tests for TAGITTreasury
 * @dev Covers allocations, withdrawals, timelock tiers, access control,
 *      emergency sweep signatures, and full lifecycle flows with randomized inputs.
 */
contract TAGITTreasuryFuzzTest is Test {
    using MessageHashUtils for bytes32;

    TAGITTreasury public treasury;
    TAGITTreasury public treasuryImpl;
    TAGITToken public token;

    // Actors
    address public owner;
    address public governor;
    address public tokenTreasury;
    address public recipient1;

    // Signers for multisig
    address[8] public signers;
    uint256[8] public signerKeys;

    // Constants
    uint256 public constant INITIAL_BALANCE = 10_000_000e18;
    bytes32 public constant ECOSYSTEM_GRANTS = keccak256("ECOSYSTEM_GRANTS");

    // Timelock constants (mirrored from contract)
    uint48 public constant TIMELOCK_SMALL = 48 hours;
    uint48 public constant TIMELOCK_MEDIUM = 72 hours;
    uint48 public constant TIMELOCK_LARGE = 7 days;
    uint256 public constant THRESHOLD_MEDIUM = 50_000e18;
    uint256 public constant THRESHOLD_LARGE = 250_000e18;
    uint256 public constant REQUIRED_SIGNERS = 6;

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        tokenTreasury = makeAddr("tokenTreasury");
        recipient1 = makeAddr("recipient1");

        // Generate 8 signer keys
        for (uint256 i = 0; i < 8; i++) {
            signerKeys[i] = uint256(keccak256(abi.encodePacked("signer", i)));
            signers[i] = vm.addr(signerKeys[i]);
        }

        vm.startPrank(owner);

        // Deploy token via proxy
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(TAGITToken.initialize, (owner, tokenTreasury));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        // Deploy treasury via proxy
        address[] memory signerArray = new address[](8);
        for (uint256 i = 0; i < 8; i++) {
            signerArray[i] = signers[i];
        }
        treasuryImpl = new TAGITTreasury();
        treasury = TAGITTreasury(
            payable(address(
                    new ERC1967Proxy(
                        address(treasuryImpl),
                        abi.encodeCall(TAGITTreasury.initialize, (governor, address(token), signerArray))
                    )
                ))
        );

        // Fund treasury with 10M tokens
        token.transfer(address(treasury), INITIAL_BALANCE);

        vm.stopPrank();
    }

    // ============================================
    // HELPER: Disable drain detector to avoid
    // interference with non-drain-related tests
    // ============================================

    function _disableDrainDetector() internal {
        vm.prank(governor);
        treasury.setDrainDetectorEnabled(false);
    }

    // ============================================
    // HELPER: Create a standard allocation for
    // withdrawal tests (small tier, no multisig)
    // ============================================

    function _createSmallAllocation(uint256 amount, uint48 duration) internal returns (uint256 allocationId) {
        vm.prank(governor);
        allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, amount, recipient1, duration);
    }

    // ============================================
    // HELPER: Build emergency sweep signatures
    // ============================================

    function _buildSweepSignatures(address tokenAddr, address to, uint256 count)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 sweepHash = keccak256(
            abi.encodePacked(
                "TAGIT_EMERGENCY_SWEEP", block.chainid, address(treasury), tokenAddr, to, treasury.sweepNonce()
            )
        );
        bytes32 ethHash = sweepHash.toEthSignedMessageHash();

        sigs = new bytes[](count);
        for (uint256 i = 0; i < count; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], ethHash);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    // ============================================
    // TEST 1: Allocation with random amounts
    // ============================================

    /**
     * @notice Fuzz test creating allocations with random amounts
     * @dev Verifies that any valid amount between 1 TAGIT and 10M TAGIT
     *      creates an allocation with correct state tracking.
     */
    function testFuzz_allocation_randomAmount(uint256 amount) public {
        amount = bound(amount, 1e18, 10_000_000e18);

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, amount, recipient1, 30 days);

        // Verify allocation was created with correct values
        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.amount, amount, "Allocation amount mismatch");
        assertEq(alloc.spent, 0, "Allocation spent should be 0");
        assertEq(alloc.recipient, recipient1, "Allocation recipient mismatch");
        assertTrue(alloc.active, "Allocation should be active");
        assertEq(alloc.programId, ECOSYSTEM_GRANTS, "ProgramId mismatch");

        // Verify global accounting
        assertEq(treasury.totalAllocated(), amount, "Total allocated mismatch");
        assertEq(treasury.totalUnallocated(), INITIAL_BALANCE - amount, "Total unallocated mismatch");
        assertEq(treasury.remainingAllocation(allocationId), amount, "Remaining allocation mismatch");
    }

    // ============================================
    // TEST 2: Allocation with random durations
    // ============================================

    /**
     * @notice Fuzz test creating allocations with random durations
     * @dev Verifies that any valid duration from 1 day to 730 days
     *      is accepted and the expiration is correctly computed.
     */
    function testFuzz_allocation_randomDuration(uint48 duration) public {
        duration = uint48(bound(uint256(duration), 1 days, 730 days));

        uint256 amount = 100_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, amount, recipient1, duration);

        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.amount, amount, "Amount mismatch");
        assertTrue(alloc.active, "Allocation should be active");
        assertEq(alloc.createdAt, uint48(block.timestamp), "createdAt mismatch");
        assertEq(alloc.expiresAt, uint48(block.timestamp) + duration, "expiresAt mismatch");

        // Verify the duration is in the valid range
        uint48 computedDuration = alloc.expiresAt - alloc.createdAt;
        assertGe(computedDuration, 1 days, "Duration below minimum");
        assertLe(computedDuration, 730 days, "Duration above maximum");
    }

    // ============================================
    // TEST 3: Withdrawal with random amounts
    // ============================================

    /**
     * @notice Fuzz test queuing withdrawals with random amounts within allocation
     * @dev Creates an allocation and queues a withdrawal for a random portion.
     *      Verifies the withdrawal is correctly recorded and allocation accounting updated.
     */
    function testFuzz_withdrawal_randomAmount(uint256 amount) public {
        // Bound to small tier to avoid multisig requirement on execute
        amount = bound(amount, 1e18, 49_999e18);

        // Create an allocation that covers the withdrawal amount
        uint256 allocAmount = 50_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), amount, recipient1);

        // Verify withdrawal was created with correct state
        ITAGITTreasury.PendingWithdrawal memory w = treasury.getWithdrawal(withdrawalId);
        assertEq(w.allocationId, allocationId, "Withdrawal allocationId mismatch");
        assertEq(w.amount, amount, "Withdrawal amount mismatch");
        assertEq(w.token, address(token), "Withdrawal token mismatch");
        assertEq(w.to, recipient1, "Withdrawal recipient mismatch");
        assertEq(uint256(w.status), uint256(ITAGITTreasury.WithdrawalStatus.PENDING), "Status should be PENDING");

        // Verify allocation spent was updated (CEI pattern pre-commits spend)
        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.spent, amount, "Allocation spent not updated");
        assertEq(treasury.remainingAllocation(allocationId), allocAmount - amount, "Remaining allocation mismatch");
    }

    // ============================================
    // TEST 4: Timelock tier verification
    // ============================================

    /**
     * @notice Fuzz test verifying correct timelock tier assignment for random amounts
     * @dev For any amount, the getTimelockForAmount function must return:
     *      - < 50k:  48 hours, no multisig
     *      - 50k-250k: 72 hours, no multisig
     *      - >= 250k: 7 days, multisig required
     */
    function testFuzz_withdrawal_timelockTiers(uint256 amount) public {
        // Bound to reasonable range (1 token to 10M tokens)
        amount = bound(amount, 1e18, 10_000_000e18);

        (uint48 timelockSeconds, bool requiresMultisig) = treasury.getTimelockForAmount(amount);

        if (amount >= THRESHOLD_LARGE) {
            // Large tier: 7 days + multisig
            assertEq(timelockSeconds, TIMELOCK_LARGE, "Large tier: wrong timelock");
            assertTrue(requiresMultisig, "Large tier: should require multisig");
        } else if (amount >= THRESHOLD_MEDIUM) {
            // Medium tier: 72 hours, no multisig
            assertEq(timelockSeconds, TIMELOCK_MEDIUM, "Medium tier: wrong timelock");
            assertFalse(requiresMultisig, "Medium tier: should not require multisig");
        } else {
            // Small tier: 48 hours, no multisig
            assertEq(timelockSeconds, TIMELOCK_SMALL, "Small tier: wrong timelock");
            assertFalse(requiresMultisig, "Small tier: should not require multisig");
        }
    }

    // ============================================
    // TEST 5: Execute withdrawal at various times after queuing
    // ============================================

    /**
     * @notice Fuzz test executing withdrawals at various times after the timelock
     * @dev Queues a small-tier withdrawal, then warps by the timelock + a random delta.
     *      Verifies that execution succeeds and tokens are transferred correctly.
     *      The drain detector is disabled so that repeated fuzz runs don't trip it.
     */
    function testFuzz_withdrawal_executeAfterTimelock(uint256 amount, uint256 timeDelta) public {
        _disableDrainDetector();

        // Small tier only (no multisig), at least 1 token
        amount = bound(amount, 1e18, 49_999e18);
        // Time after timelock: 1 second to 365 days extra
        timeDelta = bound(timeDelta, 1, 365 days);

        uint256 allocAmount = 50_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 730 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), amount, recipient1);

        // Warp past the timelock by the fuzzed timeDelta
        vm.warp(block.timestamp + TIMELOCK_SMALL + timeDelta);

        uint256 recipientBalanceBefore = token.balanceOf(recipient1);
        uint256 treasuryBalanceBefore = token.balanceOf(address(treasury));

        treasury.executeWithdrawal(withdrawalId);

        // Verify tokens transferred
        assertEq(token.balanceOf(recipient1), recipientBalanceBefore + amount, "Recipient did not receive tokens");
        assertEq(token.balanceOf(address(treasury)), treasuryBalanceBefore - amount, "Treasury balance not reduced");

        // Verify withdrawal status
        ITAGITTreasury.PendingWithdrawal memory w = treasury.getWithdrawal(withdrawalId);
        assertEq(uint256(w.status), uint256(ITAGITTreasury.WithdrawalStatus.EXECUTED), "Status should be EXECUTED");

        // Verify total allocated decreased
        assertEq(treasury.totalAllocated(), allocAmount - amount, "Total allocated not reduced after execution");
    }

    // ============================================
    // TEST 6: Non-governor callers revert on governance functions
    // ============================================

    /**
     * @notice Fuzz test that random non-governor addresses cannot call governance functions
     * @dev Tests createAllocation, closeAllocation, pause, unpause, setSigner, setGovernor,
     *      resetDrainDetector, setDrainThresholds, setDrainDetectorEnabled, and
     *      syncDrainDetectorBalance.
     */
    function testFuzz_nonGovernor_reverts(address caller) public {
        vm.assume(caller != governor);
        vm.assume(caller != address(0));

        // Test createAllocation reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.createAllocation(ECOSYSTEM_GRANTS, 1000e18, recipient1, 30 days);

        // First create an allocation so we can test closeAllocation access control
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, 1000e18, recipient1, 30 days);

        // closeAllocation: non-governor AND non-recipient should revert with NotRecipient
        vm.assume(caller != recipient1);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotRecipient.selector, caller, recipient1));
        treasury.closeAllocation(allocationId);

        // Test pause reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.pause();

        // Test unpause reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.unpause();

        // Test setSigner reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.setSigner(address(0xdead), true);

        // Test setGovernor reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.setGovernor(address(0xbeef));

        // Test resetDrainDetector reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.resetDrainDetector();

        // Test setDrainThresholds reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.setDrainThresholds(3000, 5000, 10);

        // Test setDrainDetectorEnabled reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.setDrainDetectorEnabled(false);

        // Test syncDrainDetectorBalance reverts for non-governor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, caller));
        treasury.syncDrainDetectorBalance();
    }

    // ============================================
    // TEST 7: Non-recipient callers revert on withdrawal
    // ============================================

    /**
     * @notice Fuzz test that random non-recipient addresses cannot queue or cancel withdrawals
     * @dev Creates an allocation for recipient1, then verifies that any other address
     *      (except governor for cancel) cannot queue withdrawals or cancel them.
     */
    function testFuzz_nonRecipient_reverts(address caller) public {
        vm.assume(caller != recipient1);
        vm.assume(caller != governor);
        vm.assume(caller != address(0));

        uint256 allocAmount = 100_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        // Non-recipient cannot queue a withdrawal
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotRecipient.selector, caller, recipient1));
        treasury.queueWithdrawal(allocationId, address(token), 1000e18, caller);

        // Queue a withdrawal as the real recipient so we can test cancel access control
        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), 1000e18, recipient1);

        // Non-recipient (and non-governor) cannot cancel a withdrawal
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotRecipient.selector, caller, recipient1));
        treasury.cancelWithdrawal(withdrawalId);
    }

    // ============================================
    // TEST 8: Emergency sweep with insufficient signers
    // ============================================

    /**
     * @notice Fuzz test that emergency sweep reverts when fewer than 6 signers provide signatures
     * @dev Generates between 0 and 5 valid signatures and verifies the sweep reverts
     *      with InsufficientSigners error.
     */
    function testFuzz_emergencySweep_insufficientSigners(uint8 signerCount) public {
        // Bound to 0-5 signers (anything < REQUIRED_SIGNERS=6)
        signerCount = uint8(bound(uint256(signerCount), 0, 5));

        address sweepRecipient = makeAddr("sweepRecipient");

        if (signerCount == 0) {
            // Zero signatures: pass an empty array
            bytes[] memory emptySigs = new bytes[](0);
            vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.InsufficientSigners.selector, REQUIRED_SIGNERS, 0));
            treasury.emergencySweep(address(token), sweepRecipient, emptySigs);
        } else {
            // 1-5 valid signatures
            bytes[] memory sigs = _buildSweepSignatures(address(token), sweepRecipient, signerCount);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ITAGITTreasury.InsufficientSigners.selector, REQUIRED_SIGNERS, uint256(signerCount)
                )
            );
            treasury.emergencySweep(address(token), sweepRecipient, sigs);
        }
    }

    // ============================================
    // TEST 9: Allocation exceeding balance reverts
    // ============================================

    /**
     * @notice Fuzz test that allocations exceeding the available treasury balance revert
     * @dev Generates amounts strictly greater than the initial balance and verifies
     *      the ExceedsBalance error is triggered. Also tests the case where a second
     *      allocation would exceed remaining unallocated funds.
     */
    function testFuzz_allocation_exceedsBalance(uint256 amount) public {
        // Case 1: amount exceeds total balance
        amount = bound(amount, INITIAL_BALANCE + 1, type(uint128).max);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.ExceedsBalance.selector, amount, INITIAL_BALANCE));
        treasury.createAllocation(ECOSYSTEM_GRANTS, amount, recipient1, 30 days);

        // Case 2: first allocation uses most of balance, second exceeds remainder
        uint256 firstAlloc = INITIAL_BALANCE - 1e18; // leaves 1 token unallocated
        vm.prank(governor);
        treasury.createAllocation(ECOSYSTEM_GRANTS, firstAlloc, recipient1, 30 days);

        uint256 remaining = INITIAL_BALANCE - firstAlloc; // 1e18
        uint256 overAmount = remaining + 1; // 1e18 + 1

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.ExceedsBalance.selector, overAmount, remaining));
        treasury.createAllocation(ECOSYSTEM_GRANTS, overAmount, recipient1, 30 days);
    }

    // ============================================
    // TEST 10: Full withdrawal lifecycle with random values
    // ============================================

    /**
     * @notice Fuzz test the complete allocation -> queue -> execute lifecycle
     * @dev With random amount and duration, verifies:
     *      1. Allocation is created with correct state
     *      2. Withdrawal is queued and allocation spent is updated
     *      3. Execution before timelock reverts
     *      4. Execution after timelock succeeds
     *      5. Token balances are correct after execution
     *      6. Global accounting (totalAllocated, totalUnallocated) is correct
     *      7. Double-execution reverts
     *
     *      Uses small tier amounts only to avoid multisig requirements.
     *      Drain detector is disabled to avoid interference from repeated fuzz runs.
     */
    function testFuzz_withdrawalFlow_fullCycle(uint256 amount, uint48 duration) public {
        _disableDrainDetector();

        // Small tier amounts only (avoid multisig requirement)
        amount = bound(amount, 1e18, 49_999e18);
        // Valid durations — must outlast timelock (PATCH-07: allocation expiry check)
        // Small amounts use 48h timelock, so duration must be > 48h + 1
        duration = uint48(bound(uint256(duration), 3 days, 730 days));

        uint256 treasuryBalanceBefore = token.balanceOf(address(treasury));

        // --- Step 1: Create allocation ---
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, amount, recipient1, duration);

        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.amount, amount, "Cycle: allocation amount mismatch");
        assertEq(alloc.spent, 0, "Cycle: allocation spent should be 0");
        assertTrue(alloc.active, "Cycle: allocation should be active");
        assertEq(alloc.expiresAt, uint48(block.timestamp) + duration, "Cycle: expiresAt mismatch");
        assertEq(treasury.totalAllocated(), amount, "Cycle: totalAllocated mismatch after create");

        // --- Step 2: Queue withdrawal ---
        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), amount, recipient1);

        ITAGITTreasury.PendingWithdrawal memory w = treasury.getWithdrawal(withdrawalId);
        assertEq(w.amount, amount, "Cycle: withdrawal amount mismatch");
        assertEq(w.allocationId, allocationId, "Cycle: withdrawal allocationId mismatch");
        assertEq(uint256(w.status), uint256(ITAGITTreasury.WithdrawalStatus.PENDING), "Cycle: should be PENDING");

        // Verify allocation spent was pre-committed
        alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.spent, amount, "Cycle: allocation spent should equal withdrawal amount");
        assertEq(treasury.remainingAllocation(allocationId), 0, "Cycle: remaining should be 0 after full withdrawal");

        // --- Step 3: Execution before timelock should revert ---
        (uint48 timelockForAmount,) = treasury.getTimelockForAmount(amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITAGITTreasury.TimelockNotPassed.selector, withdrawalId, w.executesAt, uint48(block.timestamp)
            )
        );
        treasury.executeWithdrawal(withdrawalId);

        // --- Step 4: Warp past timelock and execute ---
        vm.warp(block.timestamp + timelockForAmount + 1);

        uint256 recipientBalanceBefore = token.balanceOf(recipient1);

        treasury.executeWithdrawal(withdrawalId);

        // --- Step 5: Verify token balances ---
        assertEq(token.balanceOf(recipient1), recipientBalanceBefore + amount, "Cycle: recipient balance incorrect");
        assertEq(
            token.balanceOf(address(treasury)), treasuryBalanceBefore - amount, "Cycle: treasury balance incorrect"
        );

        // --- Step 6: Verify global accounting ---
        assertEq(treasury.totalAllocated(), 0, "Cycle: totalAllocated should be 0 after execution");
        assertEq(treasury.totalUnallocated(), treasuryBalanceBefore - amount, "Cycle: totalUnallocated incorrect");

        // --- Step 7: Double execution should revert ---
        w = treasury.getWithdrawal(withdrawalId);
        assertEq(uint256(w.status), uint256(ITAGITTreasury.WithdrawalStatus.EXECUTED), "Cycle: should be EXECUTED");

        vm.expectRevert(
            abi.encodeWithSelector(
                ITAGITTreasury.WithdrawalNotPending.selector, withdrawalId, ITAGITTreasury.WithdrawalStatus.EXECUTED
            )
        );
        treasury.executeWithdrawal(withdrawalId);
    }
}
