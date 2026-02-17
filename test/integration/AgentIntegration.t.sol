// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITAgentIdentity} from "../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAgentReputation} from "../../src/agent/TAGITAgentReputation.sol";
import {TAGITAgentValidation} from "../../src/agent/TAGITAgentValidation.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";

/**
 * @title AgentIntegrationTest
 * @notice End-to-end integration tests for the ERC-8004 agent system
 * @dev Tests full lifecycle: registration → feedback → validation across all three contracts
 */
contract AgentIntegrationTest is Test {
    TAGITAgentIdentity public identity;
    TAGITAgentReputation public reputation;
    TAGITAgentValidation public validation;
    TAGITAccess public access;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public operator1;  // Agent registrant
    address public operator2;  // Second registrant
    address public user1;      // Feedback reviewer
    address public user2;      // Another reviewer
    address public validator1;
    address public validator2;
    address public validator3;
    address public agentWallet1;
    address public agentWallet2;

    bytes32 constant VALIDATOR_CAPABILITY = keccak256("AGENT_VALIDATOR");

    function setUp() public {
        owner = makeAddr("owner");
        operator1 = makeAddr("operator1");
        operator2 = makeAddr("operator2");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        validator1 = makeAddr("validator1");
        validator2 = makeAddr("validator2");
        validator3 = makeAddr("validator3");
        agentWallet1 = makeAddr("agentWallet1");
        agentWallet2 = makeAddr("agentWallet2");

        // Deploy BIDGES
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        access = new TAGITAccess();
        access.setIdentityBadge(address(identityBadge));
        access.setCapabilityBadge(address(capabilityBadge));

        // Grant KYC to all actors
        identityBadge.grantIdentity(operator1, 1);
        identityBadge.grantIdentity(operator2, 1);
        identityBadge.grantIdentity(user1, 1);
        identityBadge.grantIdentity(user2, 1);

        // Grant validator capability
        capabilityBadge.grantCapability(validator1, uint256(VALIDATOR_CAPABILITY));
        capabilityBadge.grantCapability(validator2, uint256(VALIDATOR_CAPABILITY));
        capabilityBadge.grantCapability(validator3, uint256(VALIDATOR_CAPABILITY));

        // Deploy agent contracts
        vm.startPrank(owner);
        identity = new TAGITAgentIdentity();
        identity.setAccessController(address(access));

        reputation = new TAGITAgentReputation();
        reputation.setAccessController(address(access));
        reputation.setIdentityRegistry(address(identity));

        validation = new TAGITAgentValidation();
        validation.setAccessController(address(access));
        validation.setIdentityRegistry(address(identity));
        vm.stopPrank();
    }

    // ============================================
    // E2E LIFECYCLE: Register → Feedback → Validate
    // ============================================

    function test_e2e_fullAgentLifecycle() public {
        // Step 1: Register agent
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmSageAgent");
        assertEq(agentId, 1);
        assertTrue(identity.isActiveAgent(agentId));

        // Step 2: Set metadata
        vm.startPrank(operator1);
        identity.setMetadata(agentId, "model", "claude-opus-4-6");
        identity.setMetadata(agentId, "type", "analysis");
        identity.setMetadata(agentId, "version", "1.0.0");
        vm.stopPrank();

        assertEq(identity.getMetadata(agentId, "model"), "claude-opus-4-6");

        // Step 3: Users give feedback
        vm.prank(user1);
        uint256 fb1 = reputation.giveFeedback(agentId, 5, "Excellent analysis capabilities!");

        vm.prank(user2);
        uint256 fb2 = reputation.giveFeedback(agentId, 4, "Very good, but can improve speed");

        // Step 4: Agent responds to feedback
        vm.prank(operator1);
        reputation.appendResponse(fb2, "Speed improvements coming in v1.1!");

        // Step 5: Check reputation summary
        TAGITAgentReputation.ReputationSummary memory repSummary = reputation.getSummary(agentId);
        assertEq(repSummary.activeFeedback, 2);
        assertEq(repSummary.averageRating, 450); // (5+4)/2 * 100

        // Step 6: Request validation
        vm.prank(operator1);
        uint256 requestId = validation.validationRequest(agentId, false);

        // Step 7: Validator approves
        vm.prank(validator1);
        validation.validationResponse(requestId, 85, "Well-built agent with good reputation");

        // Step 8: Check validation status
        (bool isValidated, uint256 score,) = validation.getValidationStatus(agentId);
        assertTrue(isValidated);
        assertEq(score, 85);

        console2.log("=== Agent Lifecycle Complete ===");
        console2.log("Agent ID:", agentId);
        console2.log("Reputation:", repSummary.averageRating);
        console2.log("Validated:", isValidated);
        console2.log("Validation Score:", score);
    }

    function test_e2e_defenseValidation_3of5() public {
        // Register agent
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmDefenseAgent");

        // Request defense-grade validation (3-of-5 quorum)
        vm.prank(operator1);
        uint256 requestId = validation.validationRequest(agentId, true);

        // Three validators respond
        vm.prank(validator1);
        validation.validationResponse(requestId, 90, "Excellent security posture");

        vm.prank(validator2);
        validation.validationResponse(requestId, 75, "Good but needs some improvements");

        vm.prank(validator3);
        validation.validationResponse(requestId, 80, "Solid agent");

        // Should be validated (avg = 81.67 → 81)
        (bool isValidated, uint256 score,) = validation.getValidationStatus(agentId);
        assertTrue(isValidated);
        assertEq(score, 81); // (90+75+80)/3

        // Verify validator stats
        TAGITAgentValidation.ValidatorStats memory stats = validation.getValidatorStats(validator1);
        assertEq(stats.totalResponses, 1);
        assertEq(stats.accurateResponses, 1);
    }

    function test_e2e_multipleAgentsFromDifferentOperators() public {
        // Operator 1 registers Agent A
        vm.prank(operator1);
        uint256 agentA = identity.register(agentWallet1, "ipfs://QmAgentA");

        // Operator 2 registers Agent B
        vm.prank(operator2);
        uint256 agentB = identity.register(agentWallet2, "ipfs://QmAgentB");

        assertEq(agentA, 1);
        assertEq(agentB, 2);

        // User gives different feedback to each
        vm.prank(user1);
        reputation.giveFeedback(agentA, 5, "Agent A is great!");

        vm.prank(user1);
        reputation.giveFeedback(agentB, 2, "Agent B needs work");

        // Validate both
        vm.prank(operator1);
        uint256 reqA = validation.validationRequest(agentA, false);
        vm.prank(validator1);
        validation.validationResponse(reqA, 90, "Excellent");

        vm.prank(operator2);
        uint256 reqB = validation.validationRequest(agentB, false);
        vm.prank(validator1);
        validation.validationResponse(reqB, 30, "Poor quality");

        // Agent A validated, Agent B rejected
        (bool validA,,) = validation.getValidationStatus(agentA);
        (bool validB,,) = validation.getValidationStatus(agentB);
        assertTrue(validA);
        assertFalse(validB);
    }

    // ============================================
    // CROSS-CONTRACT ACCESS CONTROL
    // ============================================

    function test_crossContract_feedbackRequiresActiveAgent() public {
        // Register and then suspend agent
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(owner);
        identity.suspendAgent(agentId);

        // Feedback should fail on suspended agent
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.AgentNotActive.selector, agentId));
        reputation.giveFeedback(agentId, 5, "Can't review suspended agent");
    }

    function test_crossContract_validationRequiresActiveAgent() public {
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(owner);
        identity.suspendAgent(agentId);

        vm.prank(operator1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.AgentNotActive.selector, agentId));
        validation.validationRequest(agentId, false);
    }

    function test_crossContract_feedbackOnDecommissionedAgent() public {
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(operator1);
        identity.decommissionAgent(agentId);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.AgentNotActive.selector, agentId));
        reputation.giveFeedback(agentId, 5, "Can't review decommissioned agent");
    }

    // ============================================
    // EMERGENCY PAUSE ACROSS CONTRACTS
    // ============================================

    function test_emergencyPause_allContracts() public {
        // Pause all three contracts
        vm.startPrank(owner);
        identity.pause();
        reputation.pause();
        validation.pause();
        vm.stopPrank();

        // All operations should fail
        vm.prank(operator1);
        vm.expectRevert();
        identity.register(agentWallet1, "ipfs://QmAgent1");

        // Unpause and verify operations resume
        vm.startPrank(owner);
        identity.unpause();
        reputation.unpause();
        validation.unpause();
        vm.stopPrank();

        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmAgent1");
        assertEq(agentId, 1);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_agentRegistration() public {
        vm.prank(operator1);
        uint256 gasBefore = gasleft();
        identity.register(agentWallet1, "ipfs://QmAgent1");
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas for agent registration:", gasUsed);
    }

    function test_gas_giveFeedback() public {
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(user1);
        uint256 gasBefore = gasleft();
        reputation.giveFeedback(agentId, 5, "Great agent!");
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas for giving feedback:", gasUsed);
    }

    function test_gas_validationResponse() public {
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(operator1);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(validator1);
        uint256 gasBefore = gasleft();
        validation.validationResponse(requestId, 80, "Good agent");
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas for validation response (with finalize):", gasUsed);
    }
}
