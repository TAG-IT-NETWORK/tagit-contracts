// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITAgentIdentity} from "../../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAgentValidation} from "../../../src/agent/TAGITAgentValidation.sol";
import {TAGITAccess} from "../../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../../src/access/CapabilityBadge.sol";

/**
 * @title TAGITAgentValidationTest
 * @notice Unit tests for TAGITAgentValidation contract
 * @dev Tests cover validation requests, responses, quorum, scoring, and multi-party consensus
 */
contract TAGITAgentValidationTest is Test {
    TAGITAgentIdentity public agentIdentity;
    TAGITAgentValidation public validation;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public registrant1;
    address public requester;
    address public validator1;
    address public validator2;
    address public validator3;
    address public validator4;
    address public validator5;
    address public agentWallet1;
    address public noKycUser;
    address public notValidator;

    uint256 public agentId;

    bytes32 constant VALIDATOR_CAPABILITY = keccak256("AGENT_VALIDATOR");

    // Events
    event ValidationRequested(
        uint256 indexed requestId, uint256 indexed agentId, address indexed requester, bool isDefense
    );
    event ValidationResponseSubmitted(
        uint256 indexed requestId, uint256 indexed agentId, address indexed validator, uint8 score
    );
    event ValidationFinalized(uint256 indexed requestId, uint256 indexed agentId, bool passed, uint256 finalScore);

    function setUp() public {
        owner = makeAddr("owner");
        registrant1 = makeAddr("registrant1");
        requester = makeAddr("requester");
        validator1 = makeAddr("validator1");
        validator2 = makeAddr("validator2");
        validator3 = makeAddr("validator3");
        validator4 = makeAddr("validator4");
        validator5 = makeAddr("validator5");
        agentWallet1 = makeAddr("agentWallet1");
        noKycUser = makeAddr("noKycUser");
        notValidator = makeAddr("notValidator");

        // Deploy BIDGES
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Grant KYC
        identityBadge.grantIdentity(registrant1, 1);
        identityBadge.grantIdentity(requester, 1);
        identityBadge.grantIdentity(notValidator, 1);

        // Grant VALIDATOR capability
        capabilityBadge.grantCapability(validator1, uint256(VALIDATOR_CAPABILITY));
        capabilityBadge.grantCapability(validator2, uint256(VALIDATOR_CAPABILITY));
        capabilityBadge.grantCapability(validator3, uint256(VALIDATOR_CAPABILITY));
        capabilityBadge.grantCapability(validator4, uint256(VALIDATOR_CAPABILITY));
        capabilityBadge.grantCapability(validator5, uint256(VALIDATOR_CAPABILITY));

        // Deploy AgentIdentity + register agent
        vm.prank(owner);
        agentIdentity = new TAGITAgentIdentity();
        vm.prank(owner);
        agentIdentity.setAccessController(address(tagitAccess));

        vm.prank(registrant1);
        agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        // Deploy Validation
        vm.prank(owner);
        validation = new TAGITAgentValidation();
        vm.prank(owner);
        validation.setAccessController(address(tagitAccess));
        vm.prank(owner);
        validation.setIdentityRegistry(address(agentIdentity));
    }

    // ============================================
    // VALIDATION REQUEST TESTS
    // ============================================

    function test_validationRequest_standard() public {
        vm.expectEmit(true, true, true, true);
        emit ValidationRequested(1, agentId, requester, false);

        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        assertEq(requestId, 1);

        TAGITAgentValidation.ValidationRequest memory req = validation.getRequest(requestId);
        assertEq(req.agentId, agentId);
        assertEq(req.requester, requester);
        assertEq(req.quorum, 1); // DEFAULT_QUORUM
        assertEq(req.responseCount, 0);
        assertFalse(req.isDefense);
        assertEq(uint8(req.status), uint8(TAGITAgentValidation.RequestStatus.PENDING));
    }

    function test_validationRequest_defense() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, true);

        TAGITAgentValidation.ValidationRequest memory req = validation.getRequest(requestId);
        assertEq(req.quorum, 3); // DEFENSE_QUORUM (3-of-5)
        assertTrue(req.isDefense);
    }

    function test_validationRequest_revertNoKYC() public {
        vm.prank(noKycUser);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.MissingKYCIdentity.selector, noKycUser));
        validation.validationRequest(agentId, false);
    }

    function test_validationRequest_revertAgentNotFound() public {
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.AgentNotFound.selector, 999));
        validation.validationRequest(999, false);
    }

    // ============================================
    // VALIDATION RESPONSE TESTS
    // ============================================

    function test_validationResponse_standard_pass() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.expectEmit(true, true, true, true);
        emit ValidationResponseSubmitted(requestId, agentId, validator1, 80);

        vm.expectEmit(true, true, false, true);
        emit ValidationFinalized(requestId, agentId, true, 80);

        vm.prank(validator1);
        validation.validationResponse(requestId, 80, "Looks good");

        // Standard quorum = 1, so should be finalized
        TAGITAgentValidation.ValidationRequest memory req = validation.getRequest(requestId);
        assertEq(uint8(req.status), uint8(TAGITAgentValidation.RequestStatus.VALIDATED));

        // Check summary
        TAGITAgentValidation.ValidationSummary memory summary = validation.getSummary(agentId);
        assertTrue(summary.isValidated);
        assertEq(summary.latestScore, 80);
        assertEq(summary.passedCount, 1);
    }

    function test_validationResponse_standard_fail() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(validator1);
        validation.validationResponse(requestId, 40, "Below threshold");

        TAGITAgentValidation.ValidationRequest memory req = validation.getRequest(requestId);
        assertEq(uint8(req.status), uint8(TAGITAgentValidation.RequestStatus.REJECTED));

        TAGITAgentValidation.ValidationSummary memory summary = validation.getSummary(agentId);
        assertFalse(summary.isValidated);
        assertEq(summary.failedCount, 1);
    }

    function test_validationResponse_defense_3of5_pass() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, true);

        // First response — should move to IN_PROGRESS
        vm.prank(validator1);
        validation.validationResponse(requestId, 80, "Good");

        TAGITAgentValidation.ValidationRequest memory req = validation.getRequest(requestId);
        assertEq(uint8(req.status), uint8(TAGITAgentValidation.RequestStatus.IN_PROGRESS));

        // Second response
        vm.prank(validator2);
        validation.validationResponse(requestId, 70, "OK");

        // Third response — quorum met, should finalize
        vm.prank(validator3);
        validation.validationResponse(requestId, 90, "Excellent");

        req = validation.getRequest(requestId);
        assertEq(uint8(req.status), uint8(TAGITAgentValidation.RequestStatus.VALIDATED));
        assertEq(req.responseCount, 3);

        // Average should be (80+70+90)/3 = 80
        TAGITAgentValidation.ValidationSummary memory summary = validation.getSummary(agentId);
        assertEq(summary.latestScore, 80);
        assertTrue(summary.isValidated);
    }

    function test_validationResponse_defense_3of5_fail() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, true);

        vm.prank(validator1);
        validation.validationResponse(requestId, 30, "Bad");

        vm.prank(validator2);
        validation.validationResponse(requestId, 20, "Very bad");

        vm.prank(validator3);
        validation.validationResponse(requestId, 50, "Below threshold");

        TAGITAgentValidation.ValidationRequest memory req = validation.getRequest(requestId);
        assertEq(uint8(req.status), uint8(TAGITAgentValidation.RequestStatus.REJECTED));

        // Average = (30+20+50)/3 = 33
        TAGITAgentValidation.ValidationSummary memory summary = validation.getSummary(agentId);
        assertEq(summary.latestScore, 33);
    }

    function test_validationResponse_revertNotValidator() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(notValidator);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.NotValidator.selector, notValidator));
        validation.validationResponse(requestId, 80, "Not authorized");
    }

    function test_validationResponse_revertAlreadyResponded() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, true);

        vm.prank(validator1);
        validation.validationResponse(requestId, 80, "First");

        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.AlreadyResponded.selector, validator1, requestId));
        validation.validationResponse(requestId, 90, "Duplicate");
    }

    function test_validationResponse_revertInvalidScore() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.InvalidScore.selector, 101));
        validation.validationResponse(requestId, 101, "Too high");
    }

    function test_validationResponse_revertRequestNotFound() public {
        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.RequestNotFound.selector, 999));
        validation.validationResponse(999, 80, "Does not exist");
    }

    function test_validationResponse_revertExpired() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        // Warp past expiry (30 days + 1)
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.RequestExpired.selector, requestId));
        validation.validationResponse(requestId, 80, "Too late");
    }

    // ============================================
    // VALIDATOR STATS TESTS
    // ============================================

    function test_validatorStats_tracking() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(validator1);
        validation.validationResponse(requestId, 80, "Good");

        TAGITAgentValidation.ValidatorStats memory stats = validation.getValidatorStats(validator1);
        assertEq(stats.totalResponses, 1);
        assertEq(stats.accurateResponses, 1); // Agreed with pass outcome
        assertGt(stats.lastResponseAt, 0);
    }

    function test_validatorStats_accuracyTracking() public {
        // Defense validation with mixed responses
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, true);

        // Two validators say pass (>= 60), one says fail (< 60)
        vm.prank(validator1);
        validation.validationResponse(requestId, 80, "Pass");

        vm.prank(validator2);
        validation.validationResponse(requestId, 70, "Pass");

        vm.prank(validator3);
        validation.validationResponse(requestId, 30, "Fail"); // Disagrees

        // Final: (80+70+30)/3 = 60 → PASS (>= 60)
        TAGITAgentValidation.ValidatorStats memory stats1 = validation.getValidatorStats(validator1);
        assertEq(stats1.accurateResponses, 1); // Agreed (score >= 60, outcome pass)

        TAGITAgentValidation.ValidatorStats memory stats3 = validation.getValidatorStats(validator3);
        assertEq(stats3.accurateResponses, 0); // Disagreed (score < 60, outcome pass)
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_getValidationStatus() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(validator1);
        validation.validationResponse(requestId, 80, "Good");

        (bool isValidated, uint256 latestScore, uint64 lastValidatedAt) = validation.getValidationStatus(agentId);
        assertTrue(isValidated);
        assertEq(latestScore, 80);
        assertGt(lastValidatedAt, 0);
    }

    function test_getAgentRequests() public {
        vm.prank(requester);
        validation.validationRequest(agentId, false);

        vm.prank(requester);
        validation.validationRequest(agentId, true);

        uint256[] memory requests = validation.getAgentRequests(agentId);
        assertEq(requests.length, 2);
    }

    function test_hasValidatorResponded() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, true);

        assertFalse(validation.hasValidatorResponded(requestId, validator1));

        vm.prank(validator1);
        validation.validationResponse(requestId, 80, "Good");

        assertTrue(validation.hasValidatorResponded(requestId, validator1));
        assertFalse(validation.hasValidatorResponded(requestId, validator2));
    }

    function test_getResponses() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, true);

        vm.prank(validator1);
        validation.validationResponse(requestId, 80, "Good");

        vm.prank(validator2);
        validation.validationResponse(requestId, 70, "OK");

        TAGITAgentValidation.ValidatorResponse[] memory responses = validation.getResponses(requestId);
        assertEq(responses.length, 2);
        assertEq(responses[0].score, 80);
        assertEq(responses[1].score, 70);
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function test_pause_blocksRequests() public {
        vm.prank(owner);
        validation.pause();

        vm.prank(requester);
        vm.expectRevert();
        validation.validationRequest(agentId, false);
    }

    function test_pause_blocksResponses() public {
        vm.prank(requester);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(owner);
        validation.pause();

        vm.prank(validator1);
        vm.expectRevert();
        validation.validationResponse(requestId, 80, "Good");
    }
}
