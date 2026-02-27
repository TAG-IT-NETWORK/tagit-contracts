// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TAGITPrograms} from "../../src/programs/TAGITPrograms.sol";
import {ITAGITPrograms} from "../../src/interfaces/ITAGITPrograms.sol";

// Minimal mock ERC20 for reward payouts
contract MockTokenP14 is ERC20 {
    constructor() ERC20("TAGIT", "TAG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Minimal mock TAGITAccess
contract MockAccessP14 {
    function hasIdentity(address, uint256) external pure returns (bool) {
        return false;
    }
}

// Minimal mock TAGITStaking
contract MockStakingP14 {
    function getStake(address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title Patch14ActionProofTest
 * @notice Tests for PATCH-14: action proof verification in TAGITPrograms
 */
contract Patch14ActionProofTest is Test {
    TAGITPrograms public programs;
    MockTokenP14 public token;
    MockAccessP14 public access;
    MockStakingP14 public staking;

    address public owner = makeAddr("owner");
    address public governor = makeAddr("governor");
    address public verifier = makeAddr("verifier");
    address public claimant = makeAddr("claimant");
    address public attacker = makeAddr("attacker");
    address public core = makeAddr("core");

    bytes32 public constant PROGRAM_ID = keccak256("TEST_PROGRAM");
    bytes32 public constant ACTION_PROOF = keccak256("action_1");

    function setUp() public {
        token = new MockTokenP14();
        access = new MockAccessP14();
        staking = new MockStakingP14();

        // Deploy programs via proxy
        TAGITPrograms programsImpl = new TAGITPrograms();
        bytes memory initData = abi.encodeCall(
            TAGITPrograms.initialize, (governor, core, address(token), address(access), address(staking), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(programsImpl), initData);
        programs = TAGITPrograms(address(proxy));

        // Set action verifier
        vm.prank(governor);
        programs.setActionVerifier(verifier);

        // Create a test program with budget
        vm.prank(governor);
        programs.createProgram(PROGRAM_ID, 1 ether, 1000 ether, 10, uint48(365 days));

        // Fund the program
        token.mint(governor, 1000 ether);
        vm.startPrank(governor);
        token.approve(address(programs), 1000 ether);
        programs.fundProgram(PROGRAM_ID, 1000 ether);
        vm.stopPrank();
    }

    function test_claimReward_reverts_without_approved_proof() public {
        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITPrograms.ActionProofNotVerified.selector, PROGRAM_ID, claimant, ACTION_PROOF)
        );
        programs.claimReward(PROGRAM_ID, ACTION_PROOF);
    }

    function test_claimReward_succeeds_with_approved_proof() public {
        // Verifier approves the action
        vm.prank(verifier);
        programs.approveAction(PROGRAM_ID, claimant, ACTION_PROOF);

        // Claimant can now claim
        uint256 balanceBefore = token.balanceOf(claimant);
        vm.prank(claimant);
        programs.claimReward(PROGRAM_ID, ACTION_PROOF);
        assertGt(token.balanceOf(claimant), balanceBefore, "Should receive reward");
    }

    function test_attacker_cannot_claim_with_random_proof() public {
        bytes32 fakeProof = keccak256("attacker_fake_proof");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITPrograms.ActionProofNotVerified.selector, PROGRAM_ID, attacker, fakeProof)
        );
        programs.claimReward(PROGRAM_ID, fakeProof);
    }

    function test_proof_consumed_after_claim() public {
        vm.prank(verifier);
        programs.approveAction(PROGRAM_ID, claimant, ACTION_PROOF);

        // First claim succeeds
        vm.prank(claimant);
        programs.claimReward(PROGRAM_ID, ACTION_PROOF);

        // Second claim fails — proof consumed
        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITPrograms.ActionProofNotVerified.selector, PROGRAM_ID, claimant, ACTION_PROOF)
        );
        programs.claimReward(PROGRAM_ID, ACTION_PROOF);
    }

    function test_approveAction_requires_authorization() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.NotAuthorizedUpdater.selector, attacker));
        programs.approveAction(PROGRAM_ID, claimant, ACTION_PROOF);
    }

    function test_governor_can_approve_action() public {
        vm.prank(governor);
        programs.approveAction(PROGRAM_ID, claimant, ACTION_PROOF);

        assertTrue(
            programs.isActionApproved(PROGRAM_ID, claimant, ACTION_PROOF), "Governor-approved action should be valid"
        );
    }

    function test_batchApproveActions() public {
        bytes32[] memory programIds = new bytes32[](2);
        address[] memory users = new address[](2);
        bytes32[] memory proofs = new bytes32[](2);

        programIds[0] = PROGRAM_ID;
        programIds[1] = PROGRAM_ID;
        users[0] = claimant;
        users[1] = attacker;
        proofs[0] = keccak256("proof_1");
        proofs[1] = keccak256("proof_2");

        vm.prank(verifier);
        programs.batchApproveActions(programIds, users, proofs);

        assertTrue(programs.isActionApproved(PROGRAM_ID, claimant, proofs[0]));
        assertTrue(programs.isActionApproved(PROGRAM_ID, attacker, proofs[1]));
    }

    function test_proof_tied_to_specific_user() public {
        // Approve for claimant
        vm.prank(verifier);
        programs.approveAction(PROGRAM_ID, claimant, ACTION_PROOF);

        // Attacker tries to use claimant's proof — different user in proofKey
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITPrograms.ActionProofNotVerified.selector, PROGRAM_ID, attacker, ACTION_PROOF)
        );
        programs.claimReward(PROGRAM_ID, ACTION_PROOF);
    }

    function testFuzz_claimReward_random_proofs(bytes32 randomProof) public {
        vm.prank(attacker);
        vm.expectRevert();
        programs.claimReward(PROGRAM_ID, randomProof);
    }
}
