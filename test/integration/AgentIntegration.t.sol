// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITAgentIdentity} from "../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAgentReputation} from "../../src/agent/TAGITAgentReputation.sol";
import {TAGITAgentValidation} from "../../src/agent/TAGITAgentValidation.sol";
import {ReputationStaking} from "../../src/agent/ReputationStaking.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockTAGITForIntegration
 * @notice Minimal ERC20 mock for ReputationStaking integration tests
 */
contract MockTAGITForIntegration is ERC20 {
    constructor() ERC20("TAG IT Token", "TAGIT") {
        _mint(msg.sender, 1_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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
    address public operator1; // Agent registrant
    address public operator2; // Second registrant
    address public user1; // Feedback reviewer
    address public user2; // Another reviewer
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

        // Activate agent (register creates INACTIVE; activate transitions to ACTIVE)
        vm.prank(operator1);
        identity.activate(agentId);
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

        // Activate agent (register creates INACTIVE; activate transitions to ACTIVE)
        vm.prank(operator1);
        identity.activate(agentId);

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
        vm.prank(operator1);
        identity.activate(agentA);

        // Operator 2 registers Agent B
        vm.prank(operator2);
        uint256 agentB = identity.register(agentWallet2, "ipfs://QmAgentB");
        vm.prank(operator2);
        identity.activate(agentB);

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
        vm.prank(operator1);
        identity.activate(agentId);

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
        identity.activate(agentId);

        vm.prank(operator1);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(validator1);
        uint256 gasBefore = gasleft();
        validation.validationResponse(requestId, 80, "Good agent");
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas for validation response (with finalize):", gasUsed);
    }

    // ============================================
    // REPUTATION STAKING INTEGRATION TESTS
    // ============================================

    function test_e2e_registerStakeActivate_happyPath() public {
        // Deploy MockTAGIT token, mint to operator1
        vm.prank(owner);
        MockTAGITForIntegration tagToken = new MockTAGITForIntegration();
        vm.prank(owner);
        tagToken.transfer(operator1, 10_000 * 1e18);

        // Deploy ReputationStaking
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        ReputationStaking staking = new ReputationStaking(address(tagToken), treasuryAddr, owner);

        // Wire contracts together
        vm.prank(owner);
        staking.setAgentIdentity(address(identity));
        vm.prank(owner);
        identity.setReputationStaking(address(staking));

        // Register agent (status: INACTIVE)
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmStakedAgent");
        assertEq(uint8(identity.getAgentStatus(agentId)), uint8(TAGITAgentIdentity.AgentStatus.INACTIVE));
        assertFalse(identity.isActiveAgent(agentId));

        // Approve staking contract and stake minBond
        vm.prank(operator1);
        tagToken.approve(address(staking), type(uint256).max);
        vm.prank(operator1);
        staking.stake(agentId, 100 * 1e18);

        // Activate agent (should succeed with bond met)
        vm.prank(operator1);
        identity.activate(agentId);

        // Verify final state
        assertTrue(identity.isActiveAgent(agentId));
        assertEq(staking.getStake(agentId), 100 * 1e18);
        assertTrue(staking.hasMinBond(agentId));
    }

    function test_e2e_activateWithoutStaking_reverts() public {
        // Deploy MockTAGIT token
        vm.prank(owner);
        MockTAGITForIntegration tagToken = new MockTAGITForIntegration();

        // Deploy ReputationStaking
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        ReputationStaking staking = new ReputationStaking(address(tagToken), treasuryAddr, owner);

        // Wire contracts together
        vm.prank(owner);
        staking.setAgentIdentity(address(identity));
        vm.prank(owner);
        identity.setReputationStaking(address(staking));

        // Register agent (status: INACTIVE)
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmUnstakedAgent");

        // Activate without staking should revert
        vm.prank(operator1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.InsufficientCredibilityBond.selector, agentId));
        identity.activate(agentId);
    }

    function test_e2e_activateBypassMode_succeeds() public {
        // Do NOT set reputationStaking (defaults to address(0) — bypass mode)
        // Register agent
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmBypassAgent");

        // Activate should succeed without staking when reputationStaking == address(0)
        vm.prank(operator1);
        identity.activate(agentId);

        assertTrue(identity.isActiveAgent(agentId));
    }

    function test_e2e_fullLifecycleWithStaking() public {
        // Deploy MockTAGIT token, mint to operator1
        vm.prank(owner);
        MockTAGITForIntegration tagToken = new MockTAGITForIntegration();
        vm.prank(owner);
        tagToken.transfer(operator1, 10_000 * 1e18);

        // Deploy ReputationStaking
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        ReputationStaking staking = new ReputationStaking(address(tagToken), treasuryAddr, owner);

        // Wire contracts together
        vm.prank(owner);
        staking.setAgentIdentity(address(identity));
        vm.prank(owner);
        identity.setReputationStaking(address(staking));

        // Step 1: Register agent (INACTIVE)
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmFullLifecycleAgent");
        assertFalse(identity.isActiveAgent(agentId));

        // Step 2: Stake credibility bond
        vm.prank(operator1);
        tagToken.approve(address(staking), type(uint256).max);
        vm.prank(operator1);
        staking.stake(agentId, 200 * 1e18);

        // Step 3: Activate
        vm.prank(operator1);
        identity.activate(agentId);
        assertTrue(identity.isActiveAgent(agentId));

        // Step 4: Give feedback
        vm.prank(user1);
        reputation.giveFeedback(agentId, 5, "Excellent staked agent!");

        TAGITAgentReputation.ReputationSummary memory repSummary = reputation.getSummary(agentId);
        assertEq(repSummary.activeFeedback, 1);

        // Step 5: Request and complete validation
        vm.prank(operator1);
        uint256 requestId = validation.validationRequest(agentId, false);
        vm.prank(validator1);
        validation.validationResponse(requestId, 85, "Well-staked agent");

        (bool isValidated, uint256 score,) = validation.getValidationStatus(agentId);
        assertTrue(isValidated);
        assertEq(score, 85);

        // Step 6: Decommission agent
        vm.prank(operator1);
        identity.decommissionAgent(agentId);
        assertFalse(identity.isActiveAgent(agentId));

        // Step 7: Unstake and verify tokens returned
        uint256 balanceBefore = tagToken.balanceOf(operator1);
        vm.prank(operator1);
        staking.unstake(agentId);

        assertEq(tagToken.balanceOf(operator1), balanceBefore + 200 * 1e18);
        assertEq(staking.getStake(agentId), 0);
    }

    function test_e2e_reactivateWithInsufficientBond_reverts() public {
        // Deploy MockTAGIT token, mint to operator1
        vm.prank(owner);
        MockTAGITForIntegration tagToken = new MockTAGITForIntegration();
        vm.prank(owner);
        tagToken.transfer(operator1, 10_000 * 1e18);

        // Deploy ReputationStaking
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        ReputationStaking staking = new ReputationStaking(address(tagToken), treasuryAddr, owner);

        // Wire contracts together
        vm.prank(owner);
        staking.setAgentIdentity(address(identity));
        vm.prank(owner);
        identity.setReputationStaking(address(staking));

        // Register + stake + activate
        vm.prank(operator1);
        uint256 agentId = identity.register(agentWallet1, "ipfs://QmSlashedAgent");
        vm.prank(operator1);
        tagToken.approve(address(staking), type(uint256).max);
        vm.prank(operator1);
        staking.stake(agentId, 100 * 1e18);
        vm.prank(operator1);
        identity.activate(agentId);

        // Owner suspends agent
        vm.prank(owner);
        identity.suspendAgent(agentId);

        // Owner slashes bond below minimum
        vm.prank(owner);
        staking.slash(agentId, 100 * 1e18);
        assertFalse(staking.hasMinBond(agentId));

        // Reactivation should revert — bond insufficient
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.InsufficientCredibilityBond.selector, agentId));
        identity.reactivateAgent(agentId);
    }
}
