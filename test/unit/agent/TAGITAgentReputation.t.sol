// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITAgentIdentity} from "../../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAgentReputation} from "../../../src/agent/TAGITAgentReputation.sol";
import {TAGITAccess} from "../../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../../src/access/CapabilityBadge.sol";

/**
 * @title TAGITAgentReputationTest
 * @notice Unit tests for TAGITAgentReputation contract
 * @dev Tests cover feedback, revocation, responses, scoring, and anti-self-review
 */
contract TAGITAgentReputationTest is Test {
    TAGITAgentIdentity public agentIdentity;
    TAGITAgentReputation public reputation;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public registrant1;
    address public reviewer1;
    address public reviewer2;
    address public reviewer3;
    address public agentWallet1;
    address public noKycUser;

    uint256 public agentId;

    // Events
    event FeedbackGiven(uint256 indexed feedbackId, uint256 indexed agentId, address indexed reviewer, uint8 rating);
    event FeedbackRevoked(uint256 indexed feedbackId, uint256 indexed agentId);
    event ResponseAppended(uint256 indexed feedbackId, uint256 indexed agentId);

    function setUp() public {
        owner = makeAddr("owner");
        registrant1 = makeAddr("registrant1");
        reviewer1 = makeAddr("reviewer1");
        reviewer2 = makeAddr("reviewer2");
        reviewer3 = makeAddr("reviewer3");
        agentWallet1 = makeAddr("agentWallet1");
        noKycUser = makeAddr("noKycUser");

        // Deploy BIDGES
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Grant KYC
        identityBadge.grantIdentity(registrant1, 1);
        identityBadge.grantIdentity(reviewer1, 1);
        identityBadge.grantIdentity(reviewer2, 1);
        identityBadge.grantIdentity(reviewer3, 1);

        // Deploy AgentIdentity + register an agent
        vm.prank(owner);
        agentIdentity = new TAGITAgentIdentity();
        vm.prank(owner);
        agentIdentity.setAccessController(address(tagitAccess));

        vm.prank(registrant1);
        agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        // Deploy Reputation
        vm.prank(owner);
        reputation = new TAGITAgentReputation();
        vm.prank(owner);
        reputation.setAccessController(address(tagitAccess));
        vm.prank(owner);
        reputation.setIdentityRegistry(address(agentIdentity));
    }

    // ============================================
    // FEEDBACK TESTS
    // ============================================

    function test_giveFeedback_success() public {
        vm.prank(reviewer1);
        uint256 feedbackId = reputation.giveFeedback(agentId, 5, "Excellent agent!");

        assertEq(feedbackId, 1);

        TAGITAgentReputation.Feedback memory fb = reputation.getFeedback(feedbackId);
        assertEq(fb.reviewer, reviewer1);
        assertEq(fb.agentId, agentId);
        assertEq(fb.rating, 5);
        assertEq(fb.comment, "Excellent agent!");
        assertFalse(fb.revoked);
    }

    function test_giveFeedback_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit FeedbackGiven(1, agentId, reviewer1, 4);

        vm.prank(reviewer1);
        reputation.giveFeedback(agentId, 4, "Good agent");
    }

    function test_giveFeedback_multipleFeedback() public {
        vm.prank(reviewer1);
        reputation.giveFeedback(agentId, 5, "Great!");

        vm.prank(reviewer2);
        reputation.giveFeedback(agentId, 3, "Average");

        uint256[] memory feedbackIds = reputation.getAgentFeedbackIds(agentId);
        assertEq(feedbackIds.length, 2);
    }

    function test_giveFeedback_revertInvalidRating() public {
        vm.prank(reviewer1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.InvalidRating.selector, 0));
        reputation.giveFeedback(agentId, 0, "Bad rating");

        vm.prank(reviewer1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.InvalidRating.selector, 6));
        reputation.giveFeedback(agentId, 6, "Bad rating");
    }

    function test_giveFeedback_revertSelfReview() public {
        // Registrant cannot review own agent
        vm.prank(registrant1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.SelfReviewBlocked.selector, registrant1, agentId));
        reputation.giveFeedback(agentId, 5, "Self review");
    }

    function test_giveFeedback_revertSelfReviewWallet() public {
        // Agent wallet cannot review itself
        identityBadge.grantIdentity(agentWallet1, 1);
        vm.prank(agentWallet1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.SelfReviewBlocked.selector, agentWallet1, agentId));
        reputation.giveFeedback(agentId, 5, "Wallet self review");
    }

    function test_giveFeedback_revertNoKYC() public {
        vm.prank(noKycUser);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.MissingKYCIdentity.selector, noKycUser));
        reputation.giveFeedback(agentId, 5, "No KYC");
    }

    function test_giveFeedback_revertDuplicateReview() public {
        vm.prank(reviewer1);
        reputation.giveFeedback(agentId, 5, "First review");

        vm.prank(reviewer1);
        vm.expectRevert(); // SelfReviewBlocked reused for duplicate
        reputation.giveFeedback(agentId, 4, "Second review");
    }

    function test_giveFeedback_revertCommentTooLong() public {
        // Create a string > 1024 bytes
        bytes memory longComment = new bytes(1025);
        for (uint256 i = 0; i < 1025; i++) {
            longComment[i] = "a";
        }

        vm.prank(reviewer1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.CommentTooLong.selector, 1025));
        reputation.giveFeedback(agentId, 5, string(longComment));
    }

    // ============================================
    // REVOKE TESTS
    // ============================================

    function test_revokeFeedback_success() public {
        vm.prank(reviewer1);
        uint256 feedbackId = reputation.giveFeedback(agentId, 5, "Great!");

        vm.expectEmit(true, true, false, false);
        emit FeedbackRevoked(feedbackId, agentId);

        vm.prank(reviewer1);
        reputation.revokeFeedback(feedbackId);

        TAGITAgentReputation.Feedback memory fb = reputation.getFeedback(feedbackId);
        assertTrue(fb.revoked);
    }

    function test_revokeFeedback_revertNotReviewer() public {
        vm.prank(reviewer1);
        uint256 feedbackId = reputation.giveFeedback(agentId, 5, "Great!");

        vm.prank(reviewer2);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.NotReviewer.selector, reviewer2, feedbackId));
        reputation.revokeFeedback(feedbackId);
    }

    function test_revokeFeedback_revertAlreadyRevoked() public {
        vm.prank(reviewer1);
        uint256 feedbackId = reputation.giveFeedback(agentId, 5, "Great!");

        vm.prank(reviewer1);
        reputation.revokeFeedback(feedbackId);

        vm.prank(reviewer1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.FeedbackAlreadyRevoked.selector, feedbackId));
        reputation.revokeFeedback(feedbackId);
    }

    function test_giveFeedback_afterRevoke() public {
        vm.prank(reviewer1);
        uint256 feedbackId1 = reputation.giveFeedback(agentId, 5, "Great!");

        vm.prank(reviewer1);
        reputation.revokeFeedback(feedbackId1);

        // Should be able to submit new feedback after revoking
        vm.prank(reviewer1);
        uint256 feedbackId2 = reputation.giveFeedback(agentId, 3, "Changed my mind");
        assertEq(feedbackId2, 2);
    }

    // ============================================
    // RESPONSE TESTS
    // ============================================

    function test_appendResponse_success() public {
        vm.prank(reviewer1);
        uint256 feedbackId = reputation.giveFeedback(agentId, 3, "Could be better");

        vm.expectEmit(true, true, false, false);
        emit ResponseAppended(feedbackId, agentId);

        vm.prank(registrant1);
        reputation.appendResponse(feedbackId, "Thank you for the feedback!");

        TAGITAgentReputation.Feedback memory fb = reputation.getFeedback(feedbackId);
        assertEq(fb.response, "Thank you for the feedback!");
    }

    function test_appendResponse_revertNotRegistrant() public {
        vm.prank(reviewer1);
        uint256 feedbackId = reputation.giveFeedback(agentId, 3, "Could be better");

        vm.prank(reviewer2);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.NotAgentRegistrant.selector, reviewer2, agentId));
        reputation.appendResponse(feedbackId, "Not my agent");
    }

    function test_appendResponse_revertAlreadyExists() public {
        vm.prank(reviewer1);
        uint256 feedbackId = reputation.giveFeedback(agentId, 3, "Could be better");

        vm.prank(registrant1);
        reputation.appendResponse(feedbackId, "First response");

        vm.prank(registrant1);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentReputation.ResponseAlreadyExists.selector, feedbackId));
        reputation.appendResponse(feedbackId, "Second response");
    }

    // ============================================
    // SCORING TESTS
    // ============================================

    function test_getSummary_noFeedback() public view {
        TAGITAgentReputation.ReputationSummary memory summary = reputation.getSummary(agentId);
        assertEq(summary.totalFeedback, 0);
        assertEq(summary.activeFeedback, 0);
        assertEq(summary.averageRating, 0);
        assertEq(summary.weightedScore, 0);
    }

    function test_getSummary_singleFeedback() public {
        vm.prank(reviewer1);
        reputation.giveFeedback(agentId, 5, "Perfect!");

        TAGITAgentReputation.ReputationSummary memory summary = reputation.getSummary(agentId);
        assertEq(summary.totalFeedback, 1);
        assertEq(summary.activeFeedback, 1);
        assertEq(summary.averageRating, 500); // 5.00 * 100
    }

    function test_getSummary_multipleFeedback() public {
        vm.prank(reviewer1);
        reputation.giveFeedback(agentId, 5, "Great!");

        vm.prank(reviewer2);
        reputation.giveFeedback(agentId, 3, "Average");

        TAGITAgentReputation.ReputationSummary memory summary = reputation.getSummary(agentId);
        assertEq(summary.totalFeedback, 2);
        assertEq(summary.activeFeedback, 2);
        assertEq(summary.averageRating, 400); // (5+3)/2 = 4.00 * 100
    }

    function test_getSummary_excludesRevoked() public {
        vm.prank(reviewer1);
        uint256 fbId = reputation.giveFeedback(agentId, 1, "Bad!");

        vm.prank(reviewer2);
        reputation.giveFeedback(agentId, 5, "Great!");

        // Revoke the bad review
        vm.prank(reviewer1);
        reputation.revokeFeedback(fbId);

        TAGITAgentReputation.ReputationSummary memory summary = reputation.getSummary(agentId);
        assertEq(summary.totalFeedback, 2); // Total includes revoked
        assertEq(summary.activeFeedback, 1); // Active excludes revoked
        assertEq(summary.averageRating, 500); // Only the 5-star review counts
    }

    function test_getSummary_timeWeightedScoring() public {
        // Old feedback (180 days ago)
        vm.warp(block.timestamp + 1);
        vm.prank(reviewer1);
        reputation.giveFeedback(agentId, 1, "Bad!");

        // Recent feedback (now + 180 days later)
        vm.warp(block.timestamp + 180 days);
        vm.prank(reviewer2);
        reputation.giveFeedback(agentId, 5, "Great!");

        TAGITAgentReputation.ReputationSummary memory summary = reputation.getSummary(agentId);

        // Simple average = (1+5)/2 = 3.00 = 300
        // Weighted should favor the recent 5-star review
        // Old review weight: 90*100/(90+180) = 33
        // New review weight: 90*100/(90+0) = 100
        // Weighted = (1*33 + 5*100) / (33+100) = 533/133 ≈ 4.00 = ~400
        assertTrue(summary.weightedScore > summary.averageRating, "Weighted score should favor recent feedback");
    }

    // ============================================
    // READ ALL FEEDBACK TEST
    // ============================================

    function test_readAllFeedback() public {
        vm.prank(reviewer1);
        reputation.giveFeedback(agentId, 5, "Great!");

        vm.prank(reviewer2);
        reputation.giveFeedback(agentId, 4, "Good!");

        TAGITAgentReputation.Feedback[] memory allFeedback = reputation.readAllFeedback(agentId);
        assertEq(allFeedback.length, 2);
        assertEq(allFeedback[0].rating, 5);
        assertEq(allFeedback[1].rating, 4);
    }
}
