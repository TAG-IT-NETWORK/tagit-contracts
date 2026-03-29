// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "@forge-std/Test.sol";
import {TAGITAgentIdentity} from "../../src/agent/TAGITAgentIdentity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentIdentityMultiSigTest
 * @author TAG IT Network <dev@tagit.network>
 * @notice Tests for multi-sig ownership of TAGITAgentIdentity
 * @dev Validates that ownership transfer to a multi-sig (simulated) works correctly,
 *      and that the old EOA cannot call onlyOwner functions after transfer.
 *
 * Test Coverage:
 * - Ownership transfer to Safe address
 * - Old EOA loses onlyOwner access after transfer
 * - New owner (Safe) can call all onlyOwner functions
 * - Zero address ownership transfer blocked
 * - Double transfer scenario
 * - Emergency pause/unpause via multi-sig owner
 */
contract AgentIdentityMultiSigTest is Test {
    TAGITAgentIdentity public agentIdentity;

    address public deployer = makeAddr("deployer");
    address public safeAddress = makeAddr("safe-multisig");
    address public randomUser = makeAddr("random-user");
    address public newController = makeAddr("new-access-controller");

    /// @notice Deploy a fresh TAGITAgentIdentity for each test
    function setUp() public {
        vm.prank(deployer);
        agentIdentity = new TAGITAgentIdentity(deployer);
    }

    // ============================================
    // OWNERSHIP TRANSFER TESTS
    // ============================================

    /**
     * @notice Test that ownership can be transferred to a Safe address
     * @dev Simulates the transferOwnership call from the deployer EOA
     */
    function test_transferOwnershipToSafe() public {
        // Pre-condition: deployer is owner
        assertEq(agentIdentity.owner(), deployer, "deployer should be initial owner");

        // Transfer
        vm.prank(deployer);
        agentIdentity.transferOwnership(safeAddress);

        // Post-condition: safe is owner
        assertEq(agentIdentity.owner(), safeAddress, "safe should be new owner");
    }

    /**
     * @notice Test that old EOA cannot call onlyOwner functions after transfer
     * @dev Verifies all onlyOwner functions revert with OwnableUnauthorizedAccount
     */
    function test_oldEOACannotCallOnlyOwnerAfterTransfer() public {
        // Transfer ownership
        vm.prank(deployer);
        agentIdentity.transferOwnership(safeAddress);

        // Old EOA tries to pause — should revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.pause();

        // Old EOA tries to unpause — should revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.unpause();

        // Old EOA tries to setAccessController — should revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.setAccessController(newController);

        // Old EOA tries to setRegistrationFee — should revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.setRegistrationFee(1 ether);

        // Old EOA tries to withdrawFees — should revert
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.withdrawFees(deployer);
    }

    /**
     * @notice Test that new owner (Safe) can call all onlyOwner functions
     * @dev Simulates multi-sig executing onlyOwner calls
     */
    function test_safeCanCallOnlyOwnerFunctions() public {
        // Transfer ownership
        vm.prank(deployer);
        agentIdentity.transferOwnership(safeAddress);

        // Safe can pause
        vm.prank(safeAddress);
        agentIdentity.pause();
        assertTrue(agentIdentity.paused(), "contract should be paused");

        // Safe can unpause
        vm.prank(safeAddress);
        agentIdentity.unpause();
        assertFalse(agentIdentity.paused(), "contract should be unpaused");

        // Safe can setAccessController
        vm.prank(safeAddress);
        agentIdentity.setAccessController(newController);
        assertEq(address(agentIdentity.accessController()), newController, "access controller should be updated");

        // Safe can setRegistrationFee
        vm.prank(safeAddress);
        agentIdentity.setRegistrationFee(0.01 ether);
        assertEq(agentIdentity.registrationFee(), 0.01 ether, "registration fee should be updated");

        // Safe can withdrawFees (no balance, but should not revert on access check)
        // Note: will revert on the actual transfer because balance is 0, but that's expected
        // We just verify access control passes by checking it doesn't revert with OwnableUnauthorizedAccount
        vm.prank(safeAddress);
        agentIdentity.withdrawFees(safeAddress);
    }

    /**
     * @notice Test that random user cannot call onlyOwner functions
     * @dev Ensures non-owners are always blocked
     */
    function test_randomUserCannotCallOnlyOwner() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        agentIdentity.pause();
    }

    /**
     * @notice Test that non-owner cannot transfer ownership
     */
    function test_nonOwnerCannotTransferOwnership() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, randomUser));
        agentIdentity.transferOwnership(randomUser);
    }

    /**
     * @notice Test ownership transfer to zero address is blocked
     * @dev OpenZeppelin Ownable reverts on zero address
     */
    function test_cannotTransferToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        agentIdentity.transferOwnership(address(0));
    }

    /**
     * @notice Test double ownership transfer (Safe transfers to new Safe)
     * @dev Validates that the new owner can further transfer ownership
     */
    function test_doubleTransfer() public {
        address newSafe = makeAddr("new-safe");

        // Transfer to first Safe
        vm.prank(deployer);
        agentIdentity.transferOwnership(safeAddress);
        assertEq(agentIdentity.owner(), safeAddress);

        // First Safe transfers to new Safe
        vm.prank(safeAddress);
        agentIdentity.transferOwnership(newSafe);
        assertEq(agentIdentity.owner(), newSafe);

        // First Safe can no longer call onlyOwner
        vm.prank(safeAddress);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safeAddress));
        agentIdentity.pause();
    }

    // ============================================
    // EMERGENCY OPERATIONS TESTS
    // ============================================

    /**
     * @notice Test emergency pause via new multi-sig owner
     * @dev Simulates Safe executing pause in emergency
     */
    function test_emergencyPauseViaSafe() public {
        // Transfer to Safe
        vm.prank(deployer);
        agentIdentity.transferOwnership(safeAddress);

        // Safe pauses in emergency
        vm.prank(safeAddress);
        agentIdentity.pause();
        assertTrue(agentIdentity.paused());

        // Verify deployer cannot unpause
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.unpause();

        // Only Safe can unpause
        vm.prank(safeAddress);
        agentIdentity.unpause();
        assertFalse(agentIdentity.paused());
    }

    /**
     * @notice Test suspendAgent requires new owner
     * @dev After transfer, only Safe can suspend agents (not deployer)
     */
    function test_suspendAgentRequiresNewOwner() public {
        // Transfer to Safe
        vm.prank(deployer);
        agentIdentity.transferOwnership(safeAddress);

        // Deployer cannot suspend (agent ID 1 doesn't exist, but access check comes first)
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.suspendAgent(1);
    }

    /**
     * @notice Test reactivateAgent requires new owner
     */
    function test_reactivateAgentRequiresNewOwner() public {
        // Transfer to Safe
        vm.prank(deployer);
        agentIdentity.transferOwnership(safeAddress);

        // Deployer cannot reactivate
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.reactivateAgent(1);
    }

    // ============================================
    // CONSTRUCTOR OWNERSHIP TESTS
    // ============================================

    /**
     * @notice Test that constructor sets owner correctly
     */
    function test_constructorSetsOwner() public view {
        assertEq(agentIdentity.owner(), deployer);
    }

    /**
     * @notice Test that constructor with Safe address directly sets Safe as owner
     * @dev For new deployments, Safe can be set as initial owner
     */
    function test_constructorWithSafeAsOwner() public {
        TAGITAgentIdentity directSafeOwned = new TAGITAgentIdentity(safeAddress);
        assertEq(directSafeOwned.owner(), safeAddress);

        // Deployer (this test contract) cannot call onlyOwner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        directSafeOwned.pause();

        // Safe can call onlyOwner
        vm.prank(safeAddress);
        directSafeOwned.pause();
        assertTrue(directSafeOwned.paused());
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    /**
     * @notice Fuzz test: any non-owner address is blocked from onlyOwner functions
     * @param caller Random address to test
     */
    function testFuzz_nonOwnerBlocked(address caller) public {
        vm.assume(caller != deployer);
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        agentIdentity.pause();
    }

    /**
     * @notice Fuzz test: ownership transfer to any non-zero address succeeds
     * @param newOwner Random address to transfer to
     */
    function testFuzz_transferToAnyAddress(address newOwner) public {
        vm.assume(newOwner != address(0));

        vm.prank(deployer);
        agentIdentity.transferOwnership(newOwner);
        assertEq(agentIdentity.owner(), newOwner);
    }

    // ============================================
    // EVENT TESTS
    // ============================================

    /**
     * @notice Test that OwnershipTransferred event is emitted
     */
    function test_emitsOwnershipTransferredEvent() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, false, false);
        emit Ownable.OwnershipTransferred(deployer, safeAddress);
        agentIdentity.transferOwnership(safeAddress);
    }

    /**
     * @notice Test renounceOwnership is available but dangerous
     * @dev OZ Ownable allows renouncing; after renounce, no one can call onlyOwner
     */
    function test_renounceOwnershipLocks() public {
        vm.prank(deployer);
        agentIdentity.renounceOwnership();
        assertEq(agentIdentity.owner(), address(0));

        // Nobody can call onlyOwner now
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        agentIdentity.pause();
    }
}
