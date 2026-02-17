// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {TAGITAgentIdentity} from "./TAGITAgentIdentity.sol";

/**
 * @title TAGITAgentValidation
 * @author TAG IT Network <dev@tagit.network>
 * @notice ERC-8004 Agent Validation Registry — proof verification for AI agents
 * @dev Implements multi-party validation with 3-of-5 consensus for defense agents.
 *
 * Features:
 * - Validation requests: any registered agent can request validation
 * - Validation responses: validators score 0-100 with justification
 * - 3-of-5 multi-party consensus for defense-grade agents
 * - Validator reputation tracking (accuracy over time)
 * - Per-agent validation summary
 *
 * Validation Flow:
 * 1. Agent (or registrant) creates a validation request
 * 2. Approved validators submit responses (0-100 score)
 * 3. Once quorum is met, final score is computed
 * 4. Agent is marked validated (or rejected)
 *
 * @custom:security Multi-party consensus prevents single-validator manipulation
 * @custom:security Validator reputation tracks accuracy for future selection
 * @custom:security All state-changing functions follow CEI pattern with ReentrancyGuard
 */
contract TAGITAgentValidation is Ownable, Pausable, ReentrancyGuard {
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice KYC_L1 identity level required
    uint256 public constant KYC_L1_IDENTITY = 1;

    /// @notice Validator capability for BIDGES access control
    bytes32 public constant VALIDATOR_CAPABILITY = keccak256("AGENT_VALIDATOR");

    /// @notice Default quorum for standard validation (1-of-1)
    uint8 public constant DEFAULT_QUORUM = 1;

    /// @notice Defense quorum (3-of-5)
    uint8 public constant DEFENSE_QUORUM = 3;

    /// @notice Maximum validators per request
    uint8 public constant MAX_VALIDATORS = 5;

    /// @notice Maximum score value
    uint8 public constant MAX_SCORE = 100;

    /// @notice Passing threshold for validation
    uint8 public constant PASSING_THRESHOLD = 60;

    /// @notice Maximum justification length
    uint256 public constant MAX_JUSTIFICATION_LENGTH = 2048;

    /// @notice Validation request expiry (30 days)
    uint256 public constant REQUEST_EXPIRY = 30 days;

    // ============================================
    // DATA STRUCTURES
    // ============================================

    /**
     * @notice Validation request status
     */
    enum RequestStatus {
        PENDING,
        IN_PROGRESS,
        VALIDATED,
        REJECTED,
        EXPIRED
    }

    /**
     * @notice Validation request
     */
    struct ValidationRequest {
        uint256 agentId;            // Agent being validated
        address requester;          // Who requested validation
        uint8 quorum;               // Required number of responses
        uint8 responseCount;        // Number of responses received
        uint64 createdAt;           // Request creation timestamp
        RequestStatus status;       // Current status
        bool isDefense;             // Whether this is a defense-grade validation
    }

    /**
     * @notice Validator response to a request
     */
    struct ValidatorResponse {
        address validator;          // Validator address
        uint8 score;                // 0-100 score
        string justification;       // Reasoning
        uint64 timestamp;           // Response timestamp
    }

    /**
     * @notice Per-agent validation summary
     */
    struct ValidationSummary {
        uint256 totalRequests;      // Total validation requests
        uint256 passedCount;        // Number of passed validations
        uint256 failedCount;        // Number of failed validations
        uint256 latestScore;        // Most recent validation score
        uint64 lastValidatedAt;     // Last successful validation timestamp
        bool isValidated;           // Currently validated
    }

    /**
     * @notice Validator reputation tracking
     */
    struct ValidatorStats {
        uint256 totalResponses;     // Total responses given
        uint256 accurateResponses;  // Responses aligned with final outcome
        uint64 lastResponseAt;      // Last response timestamp
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Invalid score value
    error InvalidScore(uint8 score);

    /// @notice Request not found
    error RequestNotFound(uint256 requestId);

    /// @notice Request not in expected status
    error InvalidRequestStatus(uint256 requestId, RequestStatus current, RequestStatus expected);

    /// @notice Caller is not an approved validator
    error NotValidator(address caller);

    /// @notice Validator already responded to this request
    error AlreadyResponded(address validator, uint256 requestId);

    /// @notice Agent not found
    error AgentNotFound(uint256 agentId);

    /// @notice Agent not active
    error AgentNotActive(uint256 agentId);

    /// @notice Justification too long
    error JustificationTooLong(uint256 length);

    /// @notice Request has expired
    error RequestExpired(uint256 requestId);

    /// @notice Access controller not set
    error AccessControllerNotSet();

    /// @notice Identity registry not set
    error IdentityRegistryNotSet();

    /// @notice Caller lacks KYC identity
    error MissingKYCIdentity(address caller);

    /// @notice Not the request requester or agent registrant
    error NotRequester(address caller, uint256 requestId);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a validation request is created
    event ValidationRequested(
        uint256 indexed requestId,
        uint256 indexed agentId,
        address indexed requester,
        bool isDefense
    );

    /// @notice Emitted when a validator responds
    event ValidationResponseSubmitted(
        uint256 indexed requestId,
        uint256 indexed agentId,
        address indexed validator,
        uint8 score
    );

    /// @notice Emitted when validation is finalized
    event ValidationFinalized(
        uint256 indexed requestId,
        uint256 indexed agentId,
        bool passed,
        uint256 finalScore
    );

    /// @notice Emitted when access controller is updated
    event AccessControllerUpdated(address indexed previousController, address indexed newController);

    /// @notice Emitted when identity registry is updated
    event IdentityRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);

    // ============================================
    // STORAGE
    // ============================================

    /// @notice TAGITAccess controller
    ITAGITAccess public accessController;

    /// @notice TAGITAgentIdentity registry
    TAGITAgentIdentity public identityRegistry;

    /// @notice Counter for next request ID (starts at 1)
    uint256 private _nextRequestId;

    /// @notice Mapping from request ID to ValidationRequest
    mapping(uint256 => ValidationRequest) private _requests;

    /// @notice Mapping from request ID to validator responses
    mapping(uint256 => ValidatorResponse[]) private _responses;

    /// @notice Mapping from request ID => validator address => has responded
    mapping(uint256 => mapping(address => bool)) private _hasResponded;

    /// @notice Mapping from agent ID to their request IDs
    mapping(uint256 => uint256[]) private _agentRequests;

    /// @notice Mapping from agent ID to validation summary
    mapping(uint256 => ValidationSummary) private _summaries;

    /// @notice Mapping from validator address to stats
    mapping(address => ValidatorStats) private _validatorStats;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor() Ownable(msg.sender) {
        _nextRequestId = 1;
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
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Create a validation request for an agent
     * @dev Anyone with KYC_L1 can request validation. Defense requests require 3-of-5.
     *      Follows Checks-Effects-Interactions pattern.
     * @param agentId The agent to validate
     * @param isDefense Whether this is defense-grade validation (3-of-5 quorum)
     * @return requestId The ID of the new request
     * @custom:security KYC_L1 required, ReentrancyGuard, Pausable
     * @custom:emits ValidationRequested
     */
    function validationRequest(uint256 agentId, bool isDefense)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (address(accessController) == address(0)) revert AccessControllerNotSet();
        if (!accessController.hasIdentity(msg.sender, KYC_L1_IDENTITY)) {
            revert MissingKYCIdentity(msg.sender);
        }
        if (address(identityRegistry) == address(0)) revert IdentityRegistryNotSet();

        (address registrant,,,) = identityRegistry.getAgent(agentId);
        if (registrant == address(0)) revert AgentNotFound(agentId);
        if (!identityRegistry.isActiveAgent(agentId)) revert AgentNotActive(agentId);

        // ============================================
        // EFFECTS
        // ============================================
        requestId = _nextRequestId++;

        uint8 quorum = isDefense ? DEFENSE_QUORUM : DEFAULT_QUORUM;

        _requests[requestId] = ValidationRequest({
            agentId: agentId,
            requester: msg.sender,
            quorum: quorum,
            responseCount: 0,
            createdAt: uint64(block.timestamp),
            status: RequestStatus.PENDING,
            isDefense: isDefense
        });

        _agentRequests[agentId].push(requestId);
        _summaries[agentId].totalRequests++;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit ValidationRequested(requestId, agentId, msg.sender, isDefense);
    }

    /**
     * @notice Submit a validation response
     * @dev Only approved validators (AGENT_VALIDATOR capability) can respond.
     *      When quorum is met, validation is automatically finalized.
     *      Follows Checks-Effects-Interactions pattern.
     * @param requestId The request ID to respond to
     * @param score Validation score (0-100)
     * @param justification Reasoning for the score
     * @custom:security Validator capability required, ReentrancyGuard, Pausable
     * @custom:emits ValidationResponseSubmitted, ValidationFinalized (if quorum met)
     */
    function validationResponse(uint256 requestId, uint8 score, string calldata justification)
        external
        nonReentrant
        whenNotPaused
    {
        // ============================================
        // CHECKS
        // ============================================
        if (address(accessController) == address(0)) revert AccessControllerNotSet();
        if (!accessController.hasCapability(msg.sender, uint256(VALIDATOR_CAPABILITY))) {
            revert NotValidator(msg.sender);
        }

        ValidationRequest storage req = _requests[requestId];
        if (req.requester == address(0)) revert RequestNotFound(requestId);
        if (req.status != RequestStatus.PENDING && req.status != RequestStatus.IN_PROGRESS) {
            revert InvalidRequestStatus(requestId, req.status, RequestStatus.PENDING);
        }
        if (block.timestamp > req.createdAt + REQUEST_EXPIRY) revert RequestExpired(requestId);
        if (score > MAX_SCORE) revert InvalidScore(score);
        if (bytes(justification).length > MAX_JUSTIFICATION_LENGTH) {
            revert JustificationTooLong(bytes(justification).length);
        }
        if (_hasResponded[requestId][msg.sender]) revert AlreadyResponded(msg.sender, requestId);

        // ============================================
        // EFFECTS
        // ============================================
        _responses[requestId].push(ValidatorResponse({
            validator: msg.sender,
            score: score,
            justification: justification,
            timestamp: uint64(block.timestamp)
        }));

        _hasResponded[requestId][msg.sender] = true;
        req.responseCount++;

        if (req.status == RequestStatus.PENDING) {
            req.status = RequestStatus.IN_PROGRESS;
        }

        // Update validator stats
        _validatorStats[msg.sender].totalResponses++;
        _validatorStats[msg.sender].lastResponseAt = uint64(block.timestamp);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit ValidationResponseSubmitted(requestId, req.agentId, msg.sender, score);

        // Check if quorum is met
        if (req.responseCount >= req.quorum) {
            _finalize(requestId);
        }
    }

    /**
     * @notice Finalize a validation request (internal)
     * @dev Computes average score and determines pass/fail
     */
    function _finalize(uint256 requestId) internal {
        ValidationRequest storage req = _requests[requestId];
        ValidatorResponse[] storage responses = _responses[requestId];

        // Compute average score
        uint256 totalScore;
        for (uint256 i = 0; i < responses.length; i++) {
            totalScore += responses[i].score;
        }
        uint256 avgScore = totalScore / responses.length;

        bool passed = avgScore >= PASSING_THRESHOLD;

        // Update request status
        req.status = passed ? RequestStatus.VALIDATED : RequestStatus.REJECTED;

        // Update agent summary
        ValidationSummary storage summary = _summaries[req.agentId];
        summary.latestScore = avgScore;

        if (passed) {
            summary.passedCount++;
            summary.lastValidatedAt = uint64(block.timestamp);
            summary.isValidated = true;
        } else {
            summary.failedCount++;
            summary.isValidated = false;
        }

        // Update validator accuracy
        for (uint256 i = 0; i < responses.length; i++) {
            bool validatorAgreed = (responses[i].score >= PASSING_THRESHOLD) == passed;
            if (validatorAgreed) {
                _validatorStats[responses[i].validator].accurateResponses++;
            }
        }

        emit ValidationFinalized(requestId, req.agentId, passed, avgScore);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get a validation request
     * @param requestId The request ID
     * @return The validation request
     */
    function getRequest(uint256 requestId) external view returns (ValidationRequest memory) {
        return _requests[requestId];
    }

    /**
     * @notice Get all responses for a request
     * @param requestId The request ID
     * @return Array of validator responses
     */
    function getResponses(uint256 requestId) external view returns (ValidatorResponse[] memory) {
        return _responses[requestId];
    }

    /**
     * @notice Get validation summary for an agent
     * @param agentId The agent ID
     * @return The validation summary
     */
    function getSummary(uint256 agentId) external view returns (ValidationSummary memory) {
        return _summaries[agentId];
    }

    /**
     * @notice Get validation status for an agent
     * @param agentId The agent ID
     * @return isValidated Whether agent is currently validated
     * @return latestScore Most recent validation score
     * @return lastValidatedAt Timestamp of last successful validation
     */
    function getValidationStatus(uint256 agentId)
        external
        view
        returns (bool isValidated, uint256 latestScore, uint64 lastValidatedAt)
    {
        ValidationSummary memory summary = _summaries[agentId];
        return (summary.isValidated, summary.latestScore, summary.lastValidatedAt);
    }

    /**
     * @notice Get all request IDs for an agent
     * @param agentId The agent ID
     * @return Array of request IDs
     */
    function getAgentRequests(uint256 agentId) external view returns (uint256[] memory) {
        return _agentRequests[agentId];
    }

    /**
     * @notice Get validator stats
     * @param validator The validator address
     * @return The validator stats
     */
    function getValidatorStats(address validator) external view returns (ValidatorStats memory) {
        return _validatorStats[validator];
    }

    /**
     * @notice Check if a validator has responded to a request
     * @param requestId The request ID
     * @param validator The validator address
     * @return True if already responded
     */
    function hasValidatorResponded(uint256 requestId, address validator) external view returns (bool) {
        return _hasResponded[requestId][validator];
    }
}
