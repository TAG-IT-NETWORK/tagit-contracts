// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {TAGITAgentIdentity} from "./TAGITAgentIdentity.sol";

/**
 * @title TAGITAgentReputation
 * @author TAG IT Network <dev@tagit.network>
 * @notice ERC-8004 Agent Reputation Registry — feedback and scoring system for AI agents
 * @dev Implements a time-weighted reputation scoring system with on-chain feedback.
 *
 * Features:
 * - Give/revoke feedback on registered agents (1-5 star rating + comment)
 * - Time-weighted scoring: recent feedback matters more
 * - Anti-self-review: agents cannot review themselves
 * - Append responses: agents can respond to feedback
 * - BIDGES KYC_L1 gated: only verified users can give feedback
 *
 * Scoring Algorithm:
 * - Each feedback has a weight = 1 / (1 + age_in_days / DECAY_PERIOD)
 * - Weighted average of all active feedback ratings
 * - Summary includes: totalFeedback, averageRating, weightedScore
 *
 * @custom:security Anti-self-review prevents agents from boosting own score
 * @custom:security KYC_L1 prevents Sybil feedback attacks
 * @custom:security All state-changing functions follow CEI pattern with ReentrancyGuard
 */
contract TAGITAgentReputation is Ownable, Pausable, ReentrancyGuard {
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice KYC_L1 identity level required for feedback
    uint256 public constant KYC_L1_IDENTITY = 1;

    /// @notice Time decay period for weighted scoring (90 days)
    uint256 public constant DECAY_PERIOD = 90 days;

    /// @notice Maximum rating value
    uint8 public constant MAX_RATING = 5;

    /// @notice Minimum rating value
    uint8 public constant MIN_RATING = 1;

    /// @notice Maximum comment length in bytes
    uint256 public constant MAX_COMMENT_LENGTH = 1024;

    /// @notice Maximum response length in bytes
    uint256 public constant MAX_RESPONSE_LENGTH = 512;

    // ============================================
    // DATA STRUCTURES
    // ============================================

    /**
     * @notice Feedback record
     * @dev Stores a single feedback entry for an agent
     */
    struct Feedback {
        address reviewer;       // Address that gave the feedback
        uint256 agentId;        // Agent being reviewed
        uint8 rating;           // 1-5 star rating
        string comment;         // Feedback text
        string response;        // Agent's response (if any)
        uint64 timestamp;       // When feedback was given
        bool revoked;           // Whether feedback has been revoked
    }

    /**
     * @notice Reputation summary for an agent
     * @dev Computed on-chain for gas-efficient reads
     */
    struct ReputationSummary {
        uint256 totalFeedback;      // Total feedback received (including revoked)
        uint256 activeFeedback;     // Non-revoked feedback count
        uint256 averageRating;      // Simple average (scaled by 100 for precision)
        uint256 weightedScore;      // Time-weighted score (scaled by 100)
        uint64 lastFeedbackAt;      // Timestamp of most recent feedback
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Rating out of valid range
    error InvalidRating(uint8 rating);

    /// @notice Comment too long
    error CommentTooLong(uint256 length);

    /// @notice Response too long
    error ResponseTooLong(uint256 length);

    /// @notice Self-review attempt blocked
    error SelfReviewBlocked(address reviewer, uint256 agentId);

    /// @notice Feedback not found
    error FeedbackNotFound(uint256 feedbackId);

    /// @notice Not the feedback reviewer
    error NotReviewer(address caller, uint256 feedbackId);

    /// @notice Feedback already revoked
    error FeedbackAlreadyRevoked(uint256 feedbackId);

    /// @notice Agent does not exist
    error AgentNotFound(uint256 agentId);

    /// @notice Agent is not active
    error AgentNotActive(uint256 agentId);

    /// @notice Caller lacks KYC identity
    error MissingKYCIdentity(address caller);

    /// @notice Access controller not set
    error AccessControllerNotSet();

    /// @notice Not the agent registrant (for responses)
    error NotAgentRegistrant(address caller, uint256 agentId);

    /// @notice Response already exists
    error ResponseAlreadyExists(uint256 feedbackId);

    /// @notice Identity registry not set
    error IdentityRegistryNotSet();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when feedback is given
    event FeedbackGiven(
        uint256 indexed feedbackId,
        uint256 indexed agentId,
        address indexed reviewer,
        uint8 rating
    );

    /// @notice Emitted when feedback is revoked
    event FeedbackRevoked(uint256 indexed feedbackId, uint256 indexed agentId);

    /// @notice Emitted when a response is appended to feedback
    event ResponseAppended(uint256 indexed feedbackId, uint256 indexed agentId);

    /// @notice Emitted when access controller is updated
    event AccessControllerUpdated(address indexed previousController, address indexed newController);

    /// @notice Emitted when identity registry is updated
    event IdentityRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);

    // ============================================
    // STORAGE
    // ============================================

    /// @notice TAGITAccess controller for BIDGES checks
    ITAGITAccess public accessController;

    /// @notice TAGITAgentIdentity registry
    TAGITAgentIdentity public identityRegistry;

    /// @notice Counter for next feedback ID (starts at 1)
    uint256 private _nextFeedbackId;

    /// @notice Mapping from feedback ID to Feedback record
    mapping(uint256 => Feedback) private _feedbacks;

    /// @notice Mapping from agent ID to array of feedback IDs
    mapping(uint256 => uint256[]) private _agentFeedbacks;

    /// @notice Mapping from reviewer => agentId => feedbackId (one feedback per reviewer per agent)
    mapping(address => mapping(uint256 => uint256)) private _reviewerFeedback;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor() Ownable(msg.sender) {
        _nextFeedbackId = 1;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Set the TAGITAccess controller
     * @param controller Address of the TAGITAccess controller
     * @custom:security Only owner
     * @custom:emits AccessControllerUpdated
     */
    function setAccessController(address controller) external onlyOwner {
        address prev = address(accessController);
        accessController = ITAGITAccess(controller);
        emit AccessControllerUpdated(prev, controller);
    }

    /**
     * @notice Set the TAGITAgentIdentity registry
     * @param registry Address of the identity registry
     * @custom:security Only owner
     * @custom:emits IdentityRegistryUpdated
     */
    function setIdentityRegistry(address registry) external onlyOwner {
        address prev = address(identityRegistry);
        identityRegistry = TAGITAgentIdentity(registry);
        emit IdentityRegistryUpdated(prev, registry);
    }

    /// @notice Pause contract (emergency stop)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause contract
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // ACCESS CONTROL
    // ============================================

    /**
     * @notice Modifier requiring KYC_L1 identity
     */
    modifier requiresKYC() {
        if (address(accessController) == address(0)) revert AccessControllerNotSet();
        if (!accessController.hasIdentity(msg.sender, KYC_L1_IDENTITY)) {
            revert MissingKYCIdentity(msg.sender);
        }
        _;
    }

    /**
     * @notice Modifier requiring agent to exist and be active
     */
    modifier requiresActiveAgent(uint256 agentId) {
        if (address(identityRegistry) == address(0)) revert IdentityRegistryNotSet();
        (address registrant,,,) = identityRegistry.getAgent(agentId);
        if (registrant == address(0)) revert AgentNotFound(agentId);
        if (!identityRegistry.isActiveAgent(agentId)) revert AgentNotActive(agentId);
        _;
    }

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Give feedback on an agent
     * @dev One feedback per reviewer per agent. KYC_L1 required.
     *      Anti-self-review: reviewer cannot be the agent's registrant or wallet.
     *      Follows Checks-Effects-Interactions pattern.
     * @param agentId The agent to review
     * @param rating Star rating (1-5)
     * @param comment Feedback text
     * @return feedbackId The ID of the new feedback
     * @custom:security Anti-self-review, KYC_L1, ReentrancyGuard, Pausable
     * @custom:emits FeedbackGiven
     */
    function giveFeedback(uint256 agentId, uint8 rating, string calldata comment)
        external
        nonReentrant
        whenNotPaused
        requiresKYC
        requiresActiveAgent(agentId)
        returns (uint256 feedbackId)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (rating < MIN_RATING || rating > MAX_RATING) revert InvalidRating(rating);
        if (bytes(comment).length > MAX_COMMENT_LENGTH) revert CommentTooLong(bytes(comment).length);

        // Anti-self-review: check registrant and wallet
        (address registrant, address wallet,,) = identityRegistry.getAgent(agentId);
        if (msg.sender == registrant || msg.sender == wallet) {
            revert SelfReviewBlocked(msg.sender, agentId);
        }

        // One feedback per reviewer per agent (revoke first to re-submit)
        if (_reviewerFeedback[msg.sender][agentId] != 0) {
            uint256 existingId = _reviewerFeedback[msg.sender][agentId];
            if (!_feedbacks[existingId].revoked) {
                revert SelfReviewBlocked(msg.sender, agentId); // Reuse error — already reviewed
            }
        }

        // ============================================
        // EFFECTS
        // ============================================
        feedbackId = _nextFeedbackId++;

        _feedbacks[feedbackId] = Feedback({
            reviewer: msg.sender,
            agentId: agentId,
            rating: rating,
            comment: comment,
            response: "",
            timestamp: uint64(block.timestamp),
            revoked: false
        });

        _agentFeedbacks[agentId].push(feedbackId);
        _reviewerFeedback[msg.sender][agentId] = feedbackId;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit FeedbackGiven(feedbackId, agentId, msg.sender, rating);
    }

    /**
     * @notice Revoke previously given feedback
     * @dev Only the original reviewer can revoke. Follows CEI pattern.
     * @param feedbackId The feedback ID to revoke
     * @custom:security Only reviewer, ReentrancyGuard
     * @custom:emits FeedbackRevoked
     */
    function revokeFeedback(uint256 feedbackId)
        external
        nonReentrant
        whenNotPaused
    {
        // ============================================
        // CHECKS
        // ============================================
        Feedback storage fb = _feedbacks[feedbackId];
        if (fb.reviewer == address(0)) revert FeedbackNotFound(feedbackId);
        if (fb.reviewer != msg.sender) revert NotReviewer(msg.sender, feedbackId);
        if (fb.revoked) revert FeedbackAlreadyRevoked(feedbackId);

        // ============================================
        // EFFECTS
        // ============================================
        fb.revoked = true;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit FeedbackRevoked(feedbackId, fb.agentId);
    }

    /**
     * @notice Append a response to feedback (agent registrant only)
     * @dev Only the agent's registrant can respond. One response per feedback.
     *      Follows Checks-Effects-Interactions pattern.
     * @param feedbackId The feedback ID to respond to
     * @param responseText Response text
     * @custom:security Only agent registrant, ReentrancyGuard, Pausable
     * @custom:emits ResponseAppended
     */
    function appendResponse(uint256 feedbackId, string calldata responseText)
        external
        nonReentrant
        whenNotPaused
    {
        // ============================================
        // CHECKS
        // ============================================
        Feedback storage fb = _feedbacks[feedbackId];
        if (fb.reviewer == address(0)) revert FeedbackNotFound(feedbackId);
        if (bytes(responseText).length > MAX_RESPONSE_LENGTH) revert ResponseTooLong(bytes(responseText).length);
        if (bytes(fb.response).length > 0) revert ResponseAlreadyExists(feedbackId);

        // Verify caller is the agent's registrant
        if (address(identityRegistry) == address(0)) revert IdentityRegistryNotSet();
        (address registrant,,,) = identityRegistry.getAgent(fb.agentId);
        if (msg.sender != registrant) revert NotAgentRegistrant(msg.sender, fb.agentId);

        // ============================================
        // EFFECTS
        // ============================================
        fb.response = responseText;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit ResponseAppended(feedbackId, fb.agentId);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get a specific feedback entry
     * @param feedbackId The feedback ID
     * @return The feedback record
     */
    function getFeedback(uint256 feedbackId) external view returns (Feedback memory) {
        return _feedbacks[feedbackId];
    }

    /**
     * @notice Get all feedback IDs for an agent
     * @param agentId The agent ID
     * @return Array of feedback IDs
     */
    function getAgentFeedbackIds(uint256 agentId) external view returns (uint256[] memory) {
        return _agentFeedbacks[agentId];
    }

    /**
     * @notice Read all feedback for an agent
     * @param agentId The agent ID
     * @return Array of Feedback records
     */
    function readAllFeedback(uint256 agentId) external view returns (Feedback[] memory) {
        uint256[] memory ids = _agentFeedbacks[agentId];
        Feedback[] memory result = new Feedback[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            result[i] = _feedbacks[ids[i]];
        }
        return result;
    }

    /**
     * @notice Get reputation summary for an agent with time-weighted scoring
     * @dev Computes weighted average using exponential decay.
     *      Weight = DECAY_PERIOD / (DECAY_PERIOD + age)
     *      All scores scaled by 100 for precision (e.g., 450 = 4.50)
     * @param agentId The agent ID
     * @return summary The computed reputation summary
     */
    function getSummary(uint256 agentId) external view returns (ReputationSummary memory summary) {
        uint256[] memory ids = _agentFeedbacks[agentId];

        uint256 activeCount;
        uint256 ratingSum;
        uint256 weightedRatingSum;
        uint256 totalWeight;
        uint64 lastTimestamp;

        for (uint256 i = 0; i < ids.length; i++) {
            Feedback memory fb = _feedbacks[ids[i]];

            if (fb.revoked) continue;

            activeCount++;
            ratingSum += fb.rating;

            // Time-weighted scoring
            uint256 age = block.timestamp - fb.timestamp;
            // Weight = DECAY_PERIOD * 100 / (DECAY_PERIOD + age)
            // Scaled by 100 for precision
            uint256 weight = (DECAY_PERIOD * 100) / (DECAY_PERIOD + age);
            weightedRatingSum += uint256(fb.rating) * weight;
            totalWeight += weight;

            if (fb.timestamp > lastTimestamp) {
                lastTimestamp = fb.timestamp;
            }
        }

        summary.totalFeedback = ids.length;
        summary.activeFeedback = activeCount;
        summary.lastFeedbackAt = lastTimestamp;

        if (activeCount > 0) {
            // Simple average scaled by 100 (e.g., 450 = 4.50 stars)
            summary.averageRating = (ratingSum * 100) / activeCount;
            // Weighted average scaled by 100
            // weightedRatingSum already has one factor of 100 from weight, so multiply by 100
            // and divide by totalWeight to get consistent scale with averageRating
            summary.weightedScore = totalWeight > 0 ? (weightedRatingSum * 100 / totalWeight) : 0;
        }
    }

    /**
     * @notice Get the feedback ID for a specific reviewer-agent pair
     * @param reviewer The reviewer address
     * @param agentId The agent ID
     * @return feedbackId (0 if none)
     */
    function getReviewerFeedback(address reviewer, uint256 agentId) external view returns (uint256) {
        return _reviewerFeedback[reviewer][agentId];
    }
}
