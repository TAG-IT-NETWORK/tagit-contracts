// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {ITAGITTreasury} from "../../src/interfaces/ITAGITTreasury.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TAGITTreasuryTest is Test {
    TAGITTreasury public treasury;
    TAGITTreasury public treasuryImpl;
    TAGITToken public token;

    // Actors
    address public owner;
    address public governor;
    address public tokenTreasury;
    address public recipient1;
    address public recipient2;
    address public alice;
    address public bob;

    // Signers for multisig
    address[8] public signers;
    uint256[8] public signerKeys;

    // Constants
    uint256 public constant INITIAL_BALANCE = 10_000_000e18;
    bytes32 public constant ECOSYSTEM_GRANTS = keccak256("ECOSYSTEM_GRANTS");
    bytes32 public constant LIQUIDITY = keccak256("LIQUIDITY");

    // Events
    event ETHDeposited(address indexed from, uint256 amount);
    event TokenDeposited(address indexed token, address indexed from, uint256 amount);
    event AllocationCreated(
        uint256 indexed allocationId,
        bytes32 indexed programId,
        address indexed recipient,
        uint256 amount,
        uint48 expiresAt
    );
    event AllocationClosed(uint256 indexed allocationId, uint256 unspentAmount);
    event WithdrawalQueued(
        uint256 indexed withdrawalId,
        uint256 indexed allocationId,
        address indexed to,
        address token,
        uint256 amount,
        uint48 executesAt
    );
    event WithdrawalExecuted(uint256 indexed withdrawalId, address indexed to, address token, uint256 amount);
    event WithdrawalCanceled(uint256 indexed withdrawalId, address indexed canceledBy);
    event EmergencySweep(address indexed token, address indexed to, uint256 amount, uint256 signerCount);

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        tokenTreasury = makeAddr("tokenTreasury");
        recipient1 = makeAddr("recipient1");
        recipient2 = makeAddr("recipient2");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Generate signer keys
        for (uint256 i = 0; i < 8; i++) {
            signerKeys[i] = uint256(keccak256(abi.encodePacked("signer", i)));
            signers[i] = vm.addr(signerKeys[i]);
        }

        vm.startPrank(owner);

        // Deploy token
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(TAGITToken.initialize, (owner, tokenTreasury));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        // Convert signers array to dynamic array
        address[] memory signerArray = new address[](8);
        for (uint256 i = 0; i < 8; i++) {
            signerArray[i] = signers[i];
        }

        // Deploy treasury
        treasuryImpl = new TAGITTreasury();
        treasury = TAGITTreasury(
            payable(address(
                    new ERC1967Proxy(
                        address(treasuryImpl),
                        abi.encodeCall(TAGITTreasury.initialize, (governor, address(token), signerArray))
                    )
                ))
        );

        // Fund treasury with tokens
        token.transfer(address(treasury), INITIAL_BALANCE);

        vm.stopPrank();
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialization() public view {
        assertEq(treasury.version(), "1.0.0");
        assertEq(treasury.governor(), governor);
        assertEq(treasury.tagitToken(), address(token));
        assertEq(treasury.requiredSigners(), 6);
    }

    function test_initialization_signers() public view {
        for (uint256 i = 0; i < 8; i++) {
            assertTrue(treasury.isSigner(signers[i]));
        }
    }

    function test_initialization_revert_zeroAddress() public {
        TAGITTreasury newTreasury = new TAGITTreasury();
        address[] memory signerArray = new address[](1);
        signerArray[0] = alice;

        vm.expectRevert(ITAGITTreasury.ZeroAddress.selector);
        new ERC1967Proxy(
            address(newTreasury), abi.encodeCall(TAGITTreasury.initialize, (address(0), address(token), signerArray))
        );
    }

    // ============================================
    // DEPOSIT TESTS
    // ============================================

    function test_deposit_eth() public {
        uint256 amount = 10 ether;

        vm.deal(alice, amount);
        vm.prank(alice);

        vm.expectEmit(true, false, false, true);
        emit ETHDeposited(alice, amount);

        treasury.deposit{value: amount}();

        (uint256 ethBalance,) = treasury.getBalance();
        assertEq(ethBalance, amount);
    }

    function test_deposit_eth_receive() public {
        uint256 amount = 5 ether;

        vm.deal(alice, amount);
        vm.prank(alice);

        (bool success,) = address(treasury).call{value: amount}("");
        assertTrue(success);

        (uint256 ethBalance,) = treasury.getBalance();
        assertEq(ethBalance, amount);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ITAGITTreasury.ZeroAmount.selector);
        treasury.deposit{value: 0}();
    }

    function test_depositToken() public {
        uint256 amount = 1000e18;

        vm.prank(owner);
        token.transfer(alice, amount);

        vm.startPrank(alice);
        token.approve(address(treasury), amount);

        vm.expectEmit(true, true, false, true);
        emit TokenDeposited(address(token), alice, amount);

        treasury.depositToken(address(token), amount);
        vm.stopPrank();

        (, uint256 tagitBalance) = treasury.getBalance();
        assertEq(tagitBalance, INITIAL_BALANCE + amount);
    }

    // ============================================
    // ALLOCATION TESTS
    // ============================================

    function test_createAllocation() public {
        uint256 amount = 100_000e18;
        uint48 duration = 30 days;

        vm.prank(governor);
        vm.expectEmit(true, true, true, true);
        emit AllocationCreated(1, ECOSYSTEM_GRANTS, recipient1, amount, uint48(block.timestamp + duration));

        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, amount, recipient1, duration);

        assertEq(allocationId, 1);
        assertEq(treasury.totalAllocated(), amount);
        assertEq(treasury.totalUnallocated(), INITIAL_BALANCE - amount);

        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.programId, ECOSYSTEM_GRANTS);
        assertEq(alloc.amount, amount);
        assertEq(alloc.spent, 0);
        assertEq(alloc.recipient, recipient1);
        assertTrue(alloc.active);
    }

    function test_createAllocation_revert_notGovernor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, alice));
        treasury.createAllocation(ECOSYSTEM_GRANTS, 100_000e18, recipient1, 30 days);
    }

    function test_createAllocation_revert_exceedsBalance() public {
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITTreasury.ExceedsBalance.selector, INITIAL_BALANCE + 1, INITIAL_BALANCE)
        );
        treasury.createAllocation(ECOSYSTEM_GRANTS, INITIAL_BALANCE + 1, recipient1, 30 days);
    }

    function test_createAllocation_revert_invalidDuration() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.InvalidDuration.selector, 0));
        treasury.createAllocation(ECOSYSTEM_GRANTS, 100_000e18, recipient1, 0);
    }

    function test_closeAllocation() public {
        uint256 amount = 100_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, amount, recipient1, 30 days);

        vm.prank(governor);
        vm.expectEmit(true, false, false, true);
        emit AllocationClosed(allocationId, amount);
        treasury.closeAllocation(allocationId);

        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertFalse(alloc.active);
        assertEq(treasury.totalAllocated(), 0);
    }

    // ============================================
    // WITHDRAWAL TESTS
    // ============================================

    function test_queueWithdrawal() public {
        uint256 allocAmount = 100_000e18;
        uint256 withdrawAmount = 10_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), withdrawAmount, alice);

        assertEq(withdrawalId, 1);

        ITAGITTreasury.PendingWithdrawal memory withdrawal = treasury.getWithdrawal(withdrawalId);
        assertEq(withdrawal.allocationId, allocationId);
        assertEq(withdrawal.amount, withdrawAmount);
        assertEq(withdrawal.to, alice);
        assertEq(uint256(withdrawal.status), uint256(ITAGITTreasury.WithdrawalStatus.PENDING));

        // Check allocation spent increased
        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.spent, withdrawAmount);
    }

    function test_queueWithdrawal_revert_notRecipient() public {
        uint256 allocAmount = 100_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotRecipient.selector, alice, recipient1));
        treasury.queueWithdrawal(allocationId, address(token), 10_000e18, alice);
    }

    function test_queueWithdrawal_revert_exceedsAllocation() public {
        uint256 allocAmount = 100_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(recipient1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITAGITTreasury.ExceedsAllocation.selector, allocationId, allocAmount + 1, allocAmount
            )
        );
        treasury.queueWithdrawal(allocationId, address(token), allocAmount + 1, alice);
    }

    function test_executeWithdrawal_afterTimelock() public {
        uint256 allocAmount = 40_000e18; // Small amount for 48h timelock
        uint256 withdrawAmount = 10_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), withdrawAmount, alice);

        // Advance past timelock (48 hours)
        vm.warp(block.timestamp + 48 hours + 1);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, false, true);
        emit WithdrawalExecuted(withdrawalId, alice, address(token), withdrawAmount);

        treasury.executeWithdrawal(withdrawalId);

        assertEq(token.balanceOf(alice), aliceBalanceBefore + withdrawAmount);

        ITAGITTreasury.PendingWithdrawal memory withdrawal = treasury.getWithdrawal(withdrawalId);
        assertEq(uint256(withdrawal.status), uint256(ITAGITTreasury.WithdrawalStatus.EXECUTED));
    }

    function test_executeWithdrawal_revert_beforeTimelock() public {
        uint256 allocAmount = 40_000e18;
        uint256 withdrawAmount = 10_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), withdrawAmount, alice);

        // Try to execute before timelock
        vm.expectRevert(
            abi.encodeWithSelector(
                ITAGITTreasury.TimelockNotPassed.selector,
                withdrawalId,
                uint48(block.timestamp + 48 hours),
                uint48(block.timestamp)
            )
        );
        treasury.executeWithdrawal(withdrawalId);
    }

    function test_cancelWithdrawal_byRecipient() public {
        uint256 allocAmount = 100_000e18;
        uint256 withdrawAmount = 10_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), withdrawAmount, alice);

        vm.prank(recipient1);
        vm.expectEmit(true, true, false, false);
        emit WithdrawalCanceled(withdrawalId, recipient1);
        treasury.cancelWithdrawal(withdrawalId);

        ITAGITTreasury.PendingWithdrawal memory withdrawal = treasury.getWithdrawal(withdrawalId);
        assertEq(uint256(withdrawal.status), uint256(ITAGITTreasury.WithdrawalStatus.CANCELED));

        // Check allocation spent restored
        ITAGITTreasury.Allocation memory alloc = treasury.getAllocation(allocationId);
        assertEq(alloc.spent, 0);
    }

    function test_cancelWithdrawal_byGovernor() public {
        uint256 allocAmount = 100_000e18;
        uint256 withdrawAmount = 10_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), withdrawAmount, alice);

        vm.prank(governor);
        treasury.cancelWithdrawal(withdrawalId);

        ITAGITTreasury.PendingWithdrawal memory withdrawal = treasury.getWithdrawal(withdrawalId);
        assertEq(uint256(withdrawal.status), uint256(ITAGITTreasury.WithdrawalStatus.CANCELED));
    }

    // ============================================
    // TIMELOCK TIER TESTS
    // ============================================

    function test_timelockTiers_small() public view {
        (uint48 timelock, bool multisig) = treasury.getTimelockForAmount(49_999e18);
        assertEq(timelock, 48 hours);
        assertFalse(multisig);
    }

    function test_timelockTiers_medium() public view {
        (uint48 timelock, bool multisig) = treasury.getTimelockForAmount(50_000e18);
        assertEq(timelock, 72 hours);
        assertFalse(multisig);

        (timelock, multisig) = treasury.getTimelockForAmount(249_999e18);
        assertEq(timelock, 72 hours);
        assertFalse(multisig);
    }

    function test_timelockTiers_large() public view {
        (uint48 timelock, bool multisig) = treasury.getTimelockForAmount(250_000e18);
        assertEq(timelock, 7 days);
        assertTrue(multisig);
    }

    // ============================================
    // EMERGENCY SWEEP TESTS
    // ============================================

    function test_emergencySweep() public {
        // Fund treasury with ETH
        vm.deal(address(treasury), 100 ether);

        // Create message hash
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "TAGIT_EMERGENCY_SWEEP",
                block.chainid,
                address(treasury),
                address(0), // ETH
                alice,
                uint256(0) // PATCH-08: counter-based nonce (starts at 0)
            )
        );
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        // Sign with 6 signers
        bytes[] memory sigs = new bytes[](6);
        for (uint256 i = 0; i < 6; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], ethSignedHash);
            sigs[i] = abi.encodePacked(r, s, v);
        }

        uint256 aliceBalanceBefore = alice.balance;

        vm.expectEmit(true, true, false, true);
        emit EmergencySweep(address(0), alice, 100 ether, 6);

        treasury.emergencySweep(address(0), alice, sigs);

        assertEq(alice.balance, aliceBalanceBefore + 100 ether);
    }

    function test_emergencySweep_revert_insufficientSigners() public {
        bytes[] memory sigs = new bytes[](5); // Only 5 signers

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "TAGIT_EMERGENCY_SWEEP",
                block.chainid,
                address(treasury),
                address(0),
                alice,
                uint256(0) // PATCH-08: counter-based nonce (starts at 0)
            )
        );
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        for (uint256 i = 0; i < 5; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], ethSignedHash);
            sigs[i] = abi.encodePacked(r, s, v);
        }

        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.InsufficientSigners.selector, 6, 5));
        treasury.emergencySweep(address(0), alice, sigs);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_getBalance() public view {
        (uint256 eth, uint256 tagit) = treasury.getBalance();
        assertEq(eth, 0);
        assertEq(tagit, INITIAL_BALANCE);
    }

    function test_totalAllocated_afterAllocations() public {
        vm.startPrank(governor);
        treasury.createAllocation(ECOSYSTEM_GRANTS, 100_000e18, recipient1, 30 days);
        treasury.createAllocation(LIQUIDITY, 200_000e18, recipient2, 60 days);
        vm.stopPrank();

        assertEq(treasury.totalAllocated(), 300_000e18);
        assertEq(treasury.totalUnallocated(), INITIAL_BALANCE - 300_000e18);
    }

    function test_remainingAllocation() public {
        uint256 allocAmount = 100_000e18;
        uint256 withdrawAmount = 30_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, 30 days);

        vm.prank(recipient1);
        treasury.queueWithdrawal(allocationId, address(token), withdrawAmount, alice);

        assertEq(treasury.remainingAllocation(allocationId), allocAmount - withdrawAmount);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_deposit() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);

        uint256 gasBefore = gasleft();
        treasury.deposit{value: 1 ether}();
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 50_000, "deposit() gas too high");
    }

    function test_gas_createAllocation() public {
        vm.prank(governor);

        uint256 gasBefore = gasleft();
        treasury.createAllocation(ECOSYSTEM_GRANTS, 100_000e18, recipient1, 30 days);
        uint256 gasUsed = gasBefore - gasleft();

        // Actual: ~155k (multiple storage writes + event)
        assertLt(gasUsed, 200_000, "createAllocation() gas too high");
    }

    function test_gas_queueWithdrawal() public {
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, 100_000e18, recipient1, 30 days);

        vm.prank(recipient1);

        uint256 gasBefore = gasleft();
        treasury.queueWithdrawal(allocationId, address(token), 10_000e18, alice);
        uint256 gasUsed = gasBefore - gasleft();

        // Actual: ~132k (storage writes + event + allocation update)
        assertLt(gasUsed, 150_000, "queueWithdrawal() gas too high");
    }

    function test_gas_executeWithdrawal() public {
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, 40_000e18, recipient1, 30 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), 10_000e18, alice);

        vm.warp(block.timestamp + 48 hours + 1);

        uint256 gasBefore = gasleft();
        treasury.executeWithdrawal(withdrawalId);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 100_000, "executeWithdrawal() gas too high");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_withdrawalAmounts(uint256 amount) public {
        // Bound to reasonable amounts (not exceeding initial balance, not zero)
        amount = bound(amount, 1e18, 40_000e18); // Small tier to avoid multisig requirement

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, amount, recipient1, 30 days);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), amount, alice);

        vm.warp(block.timestamp + 48 hours + 1);

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        treasury.executeWithdrawal(withdrawalId);

        assertEq(token.balanceOf(alice), aliceBalanceBefore + amount);
    }

    // ============================================
    // INVARIANT HELPERS
    // ============================================

    function test_invariant_balanceEqualsAllocatedPlusUnallocated() public {
        vm.startPrank(governor);
        treasury.createAllocation(ECOSYSTEM_GRANTS, 100_000e18, recipient1, 30 days);
        treasury.createAllocation(LIQUIDITY, 200_000e18, recipient2, 60 days);
        vm.stopPrank();

        (, uint256 tagitBalance) = treasury.getBalance();
        uint256 allocated = treasury.totalAllocated();
        uint256 unallocated = treasury.totalUnallocated();

        assertEq(tagitBalance, allocated + unallocated);
    }
}
