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
 * @title AgentSecurityTest
 * @notice Security-focused tests for the ERC-8004 agent system
 * @dev Tests anti-Sybil, anti-self-review, defense guard rejection, and edge cases
 */
contract AgentSecurityTest is Test {
    TAGITAgentIdentity public identity;
    TAGITAgentReputation public reputation;
    TAGITAgentValidation public validation;
    TAGITAccess public access;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public operator;
    address public agentWallet;
    address public attacker;
    address public govMilUser;

    bytes32 constant VALIDATOR_CAPABILITY = keccak256("AGENT_VALIDATOR");
    bytes32 constant GOV_MIL_CAPABILITY = keccak256("GOV_MIL");

    function setUp() public {
        owner = makeAddr("owner");
        operator = makeAddr("operator");
        agentWallet = makeAddr("agentWallet");
        attacker = makeAddr("attacker");
        govMilUser = makeAddr("govMilUser");

        // Deploy BIDGES
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        access = new TAGITAccess();
        access.setIdentityBadge(address(identityBadge));
        access.setCapabilityBadge(address(capabilityBadge));

        // Grant KYC
        identityBadge.grantIdentity(operator, 1);
        identityBadge.grantIdentity(attacker, 1);
        identityBadge.grantIdentity(govMilUser, 1);

        // GOV_MIL block
        capabilityBadge.grantCapability(govMilUser, uint256(GOV_MIL_CAPABILITY));

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
    // HELPERS
    // ============================================

    function _registerAndActivateAgent(address op, address wallet, string memory uri) internal returns (uint256) {
        vm.prank(op);
        uint256 agentId = identity.register(wallet, uri);
        vm.prank(op);
        identity.activate(agentId);
        return agentId;
    }

    // ============================================
    // DEFENSE GUARD REJECTION
    // ============================================

    function test_security_govMilCannotRegister() public {
        vm.prank(govMilUser);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.DefenseGuardBlocked.selector, govMilUser));
        identity.register(agentWallet, "ipfs://QmGovAgent");
    }

    // ============================================
    // ANTI-SYBIL (KYC ENFORCEMENT)
    // ============================================

    function test_security_noKycCannotRegister() public {
        address noKyc = makeAddr("noKyc");
        vm.prank(noKyc);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.MissingKYCIdentity.selector, noKyc));
        identity.register(agentWallet, "ipfs://QmAgent");
    }

    function test_security_noKycCannotGiveFeedback() public {
        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        address noKyc = makeAddr("noKycReviewer");
        vm.prank(noKyc);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.MissingKYCIdentity.selector, noKyc));
        reputation.giveFeedback(agentId, 5, "Sybil attempt");
    }

    function test_security_noKycCannotRequestValidation() public {
        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        address noKyc = makeAddr("noKycRequester");
        vm.prank(noKyc);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.MissingKYCIdentity.selector, noKyc));
        validation.validationRequest(agentId, false);
    }

    // ============================================
    // ANTI-SELF-REVIEW
    // ============================================

    function test_security_registrantCannotSelfReview() public {
        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.SelfReviewBlocked.selector, operator, agentId));
        reputation.giveFeedback(agentId, 5, "I'm the best!");
    }

    function test_security_agentWalletCannotSelfReview() public {
        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        identityBadge.grantIdentity(agentWallet, 1);
        vm.prank(agentWallet);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.SelfReviewBlocked.selector, agentWallet, agentId));
        reputation.giveFeedback(agentId, 5, "Self-review via wallet");
    }

    function test_security_cannotDuplicateFeedback() public {
        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        vm.prank(attacker);
        reputation.giveFeedback(agentId, 5, "First review");

        vm.prank(attacker);
        vm.expectRevert(); // Duplicate review blocked
        reputation.giveFeedback(agentId, 5, "Boosting review");
    }

    // ============================================
    // SOULBOUND ENFORCEMENT
    // ============================================

    function test_security_cannotTransferAgentToken() public {
        vm.prank(operator);
        uint256 agentId = identity.register(agentWallet, "ipfs://QmAgent");

        vm.prank(operator);
        vm.expectRevert(TAGITAgentIdentity.SoulboundTransferDisabled.selector);
        identity.transferFrom(operator, attacker, agentId);
    }

    function test_security_cannotSafeTransferAgentToken() public {
        vm.prank(operator);
        uint256 agentId = identity.register(agentWallet, "ipfs://QmAgent");

        vm.prank(operator);
        vm.expectRevert(TAGITAgentIdentity.SoulboundTransferDisabled.selector);
        identity.safeTransferFrom(operator, attacker, agentId);
    }

    // ============================================
    // WALLET UNIQUENESS
    // ============================================

    function test_security_cannotReuseBoundWallet() public {
        vm.prank(operator);
        identity.register(agentWallet, "ipfs://QmAgent1");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.WalletAlreadyRegistered.selector, agentWallet));
        identity.register(agentWallet, "ipfs://QmAgent2");
    }

    // ============================================
    // VALIDATOR ACCESS CONTROL
    // ============================================

    function test_security_nonValidatorCannotRespond() public {
        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        vm.prank(operator);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.NotValidator.selector, attacker));
        validation.validationResponse(requestId, 80, "Unauthorized validation");
    }

    function test_security_validatorCannotDoubleRespond() public {
        capabilityBadge.grantCapability(attacker, uint256(VALIDATOR_CAPABILITY));

        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        vm.prank(operator);
        uint256 requestId = validation.validationRequest(agentId, true); // Defense quorum = 3

        vm.prank(attacker);
        validation.validationResponse(requestId, 100, "First vote");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.AlreadyResponded.selector, attacker, requestId));
        validation.validationResponse(requestId, 100, "Vote stuffing");
    }

    // ============================================
    // EXPIRED REQUEST PROTECTION
    // ============================================

    function test_security_cannotRespondToExpiredRequest() public {
        capabilityBadge.grantCapability(attacker, uint256(VALIDATOR_CAPABILITY));

        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        vm.prank(operator);
        uint256 requestId = validation.validationRequest(agentId, false);

        // Fast-forward past 30-day expiry
        vm.warp(block.timestamp + 31 days);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.RequestExpired.selector, requestId));
        validation.validationResponse(requestId, 100, "Late response");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function test_fuzz_feedbackRating(uint8 rating) public {
        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        vm.prank(attacker);
        if (rating >= 1 && rating <= 5) {
            // Valid rating should succeed
            reputation.giveFeedback(agentId, rating, "Fuzz test");
            TAGITAgentReputation.Feedback memory fb = reputation.getFeedback(1);
            assertEq(fb.rating, rating);
        } else {
            // Invalid rating should revert
            vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.InvalidRating.selector, rating));
            reputation.giveFeedback(agentId, rating, "Fuzz test");
        }
    }

    function test_fuzz_validationScore(uint8 score) public {
        capabilityBadge.grantCapability(attacker, uint256(VALIDATOR_CAPABILITY));

        uint256 agentId = _registerAndActivateAgent(operator, agentWallet, "ipfs://QmAgent");

        vm.prank(operator);
        uint256 requestId = validation.validationRequest(agentId, false);

        vm.prank(attacker);
        if (score <= 100) {
            validation.validationResponse(requestId, score, "Fuzz test");
            (bool isValidated, uint256 latestScore,) = validation.getValidationStatus(agentId);
            assertEq(latestScore, score);
            assertEq(isValidated, score >= 60);
        } else {
            vm.expectRevert(abi.encodeWithSelector(TAGITAgentValidation.InvalidScore.selector, score));
            validation.validationResponse(requestId, score, "Fuzz test");
        }
    }

    function test_fuzz_registrationURI(string calldata uri) public {
        vm.prank(operator);
        if (bytes(uri).length == 0) {
            vm.expectRevert(TAGITAgentIdentity.InvalidURI.selector);
            identity.register(agentWallet, uri);
        } else {
            uint256 agentId = identity.register(agentWallet, uri);
            assertEq(identity.tokenURI(agentId), uri);
        }
    }
}
