// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IRecovery} from "../interfaces/IRecovery.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {CircuitBreaker} from "../libraries/CircuitBreaker.sol";
import {RateLimiter} from "../libraries/RateLimiter.sol";

/**
 * @title TAGITRecovery
 * @author TAG IT Network <dev@tagit.network>
 * @notice AIRP (AI Recovery Protocol) for asset dispute resolution
 * @dev Implements badge-gated voting, quarantine, and stake-based dispute resolution
 *
 * Key Features:
 * - Stake bond required to initiate recovery claims (anti-spam)
 * - Badge-weighted voting (Verifier, Manufacturer, Governance)
 * - 7-day voting period with 66% approval threshold
 * - 50% stake slashing on fraudulent claims
 * - Appeal system with 2x bond requirement
 *
 * Security:
 * - UUPS upgradeable with owner-only upgrade auth
 * - ReentrancyGuard on all state-changing functions
 * - Checks-Effects-Interactions pattern throughout
 * - Custom errors for gas efficiency
 */
contract TAGITRecovery is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    IRecovery
{
    using SafeERC20 for IERC20;
    using CircuitBreaker for CircuitBreaker.Config;
    using RateLimiter for RateLimiter.Config;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Minimum stake bond required (100 TAGIT)
    uint256 public constant MINIMUM_STAKE_DEFAULT = 100e18;

    /// @notice Default voting duration (7 days)
    uint256 public constant VOTING_DURATION_DEFAULT = 7 days;

    /// @notice Approval threshold in basis points (66%)
    uint256 public constant APPROVAL_THRESHOLD = 6600;

    /// @notice Slash rate on rejection in basis points (50%)
    uint256 public constant SLASH_RATE = 5000;

    /// @notice Appeal bond multiplier (2x original)
    uint256 public constant APPEAL_MULTIPLIER = 2;

    /// @notice Minimum votes required for quorum
    uint256 public constant MINIMUM_VOTES = 3;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    // ============================================
    // BADGE IDS (BIDGES System)
    // ============================================

    /// @notice Verifier badge ID (1x weight)
    uint256 public constant BADGE_VERIFIER = 1;

    /// @notice Certified Verifier badge ID (2x weight)
    uint256 public constant BADGE_CERTIFIED_VERIFIER = 2;

    /// @notice Manufacturer badge ID (3x weight)
    uint256 public constant BADGE_MANUFACTURER = 10;

    /// @notice Governance badge ID (4x weight)
    uint256 public constant BADGE_GOVERNANCE = 20;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice TAGITCore contract for NFT operations
    address public core;

    /// @notice TAGITAccess contract for badge checks
    ITAGITAccess public access;

    /// @notice TAGITToken contract for stake bonds
    IERC20 public token;

    /// @notice Governor address (can update parameters)
    address public governor;

    /// @notice Treasury address (receives slashed stakes)
    address public treasury;

    /// @notice Current minimum stake requirement
    uint256 public minimumStake;

    /// @notice Current voting duration
    uint256 public votingDuration;

    /// @notice Counter for case IDs (starts at 1)
    uint256 private _nextCaseId;

    /// @notice Mapping from case ID to RecoveryCase
    mapping(uint256 => RecoveryCase) private _cases;

    /// @notice Mapping from token ID to active case ID (0 = no active case)
    mapping(uint256 => uint256) private _tokenToCase;

    /// @notice Mapping from case ID to voter to Vote
    mapping(uint256 => mapping(address => Vote)) private _votes;

    /// @notice Mapping from case ID to voter to hasVoted
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @notice Mapping from token ID to quarantine status
    mapping(uint256 => bool) private _quarantined;

    /// @notice Total stake bonds held in contract
    uint256 public totalStakesHeld;

    // ============================================
    // NIST SECURITY CONTROLS (IR-4, AC-7)
    // ============================================

    /// @notice Circuit breaker for recovery spam protection
    CircuitBreaker.Config private _recoveryCircuit;

    /// @notice Rate limiter config for per-user limits
    RateLimiter.Config private _rateLimitConfig;

    /// @notice Per-user rate limit states
    mapping(address => RateLimiter.UserState) private _rateLimitStates;

    /// @notice Storage gap for future upgrades
    uint256[37] private __gap;

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Restricts function to governor only
     */
    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotAuthorized(msg.sender);
        _;
    }

    // ============================================
    // INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the recovery contract
     * @param _core TAGITCore contract address
     * @param _access TAGITAccess contract address
     * @param _token TAGITToken contract address
     * @param _governor Governor address
     * @param _treasury Treasury address
     * @param initialOwner Initial owner address
     */
    function initialize(
        address _core,
        address _access,
        address _token,
        address _governor,
        address _treasury,
        address initialOwner
    ) external initializer {
        // ============================================
        // CHECKS
        // ============================================
        if (_core == address(0)) revert ZeroAddress();
        if (_access == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        if (_governor == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        // ============================================
        // EFFECTS
        // ============================================
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __Pausable_init();

        core = _core;
        access = ITAGITAccess(_access);
        token = IERC20(_token);
        governor = _governor;
        treasury = _treasury;

        minimumStake = MINIMUM_STAKE_DEFAULT;
        votingDuration = VOTING_DURATION_DEFAULT;
        _nextCaseId = 1;

        // Initialize NIST security controls (IR-4, AC-7)
        // Circuit breaker: 50 recoveries/hour, 1hr window, 4hr cooldown
        _recoveryCircuit.initialize(50, 1 hours, 4 hours);
        // Rate limiter: 3 per user/hour, 1hr window, 2hr cooldown, 100 global/hour
        _rateLimitConfig.initialize(3, 1 hours, 2 hours, 100);
    }

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Initiate a recovery claim for a disputed asset
     * @dev Creates case, locks stake bond, quarantines asset, and flags in TAGITCore
     * @param tokenId The asset token ID to recover
     * @param evidenceHash IPFS hash of supporting evidence
     * @return caseId The ID of the created recovery case
     * @custom:security ReentrancyGuard prevents reentrancy
     * @custom:security Stake transferred before state changes (CEI)
     * @custom:emits RecoveryInitiated, AssetQuarantined
     */
    function initiateRecovery(
        uint256 tokenId,
        bytes32 evidenceHash
    ) external nonReentrant whenNotPaused returns (uint256 caseId) {
        // ============================================
        // NIST SECURITY CHECKS (IR-4, AC-7)
        // ============================================
        // Check circuit breaker first - trips on volume anomaly
        // Note: If circuit trips, this call will succeed but contract pauses
        // Future calls will fail due to whenNotPaused
        if (_recoveryCircuit.check()) {
            _pause();
        }

        // Check per-user rate limits
        _rateLimitConfig.check(_rateLimitStates, msg.sender);

        // ============================================
        // CHECKS
        // ============================================
        if (tokenId == 0) revert InvalidTokenId(tokenId);
        if (evidenceHash == bytes32(0)) revert InvalidEvidenceHash();

        // Check no active case exists for this token
        uint256 existingCase = _tokenToCase[tokenId];
        if (existingCase != 0) {
            CaseStatus existingStatus = _cases[existingCase].status;
            if (existingStatus == CaseStatus.PENDING || existingStatus == CaseStatus.VOTING) {
                revert ActiveCaseExists(tokenId, existingCase);
            }
        }

        // Get current NFT owner from TAGITCore
        address currentHolder = IERC721(core).ownerOf(tokenId);
        if (currentHolder == address(0)) revert InvalidTokenId(tokenId);

        // Claimant cannot be the current holder
        if (msg.sender == currentHolder) revert NotAuthorized(msg.sender);

        // ============================================
        // EFFECTS
        // ============================================
        caseId = _nextCaseId++;

        // Create recovery case
        _cases[caseId] = RecoveryCase({
            tokenId: tokenId,
            claimant: msg.sender,
            currentHolder: currentHolder,
            evidenceHash: evidenceHash,
            createdAt: uint48(block.timestamp),
            votingEndsAt: uint48(block.timestamp + votingDuration),
            status: CaseStatus.VOTING,
            stakeBond: minimumStake,
            votesFor: 0,
            votesAgainst: 0,
            voteCount: 0
        });

        // Link token to active case
        _tokenToCase[tokenId] = caseId;

        // Quarantine the asset
        _quarantined[tokenId] = true;

        // Track total stakes
        totalStakesHeld += minimumStake;

        // ============================================
        // INTERACTIONS
        // ============================================
        // Transfer stake bond from claimant to this contract
        token.safeTransferFrom(msg.sender, address(this), minimumStake);

        emit RecoveryInitiated(caseId, tokenId, msg.sender, currentHolder, minimumStake, evidenceHash);
        emit AssetQuarantined(tokenId, caseId);
    }

    /**
     * @notice Submit additional evidence to an active case
     * @dev Only claimant or current holder can submit
     * @param caseId The recovery case ID
     * @param evidenceHash IPFS hash of additional evidence
     * @custom:security Only parties to the case can submit
     * @custom:emits EvidenceSubmitted
     */
    function submitEvidence(
        uint256 caseId,
        bytes32 evidenceHash
    ) external nonReentrant whenNotPaused {
        // ============================================
        // CHECKS
        // ============================================
        RecoveryCase storage recoveryCase = _cases[caseId];
        if (recoveryCase.status == CaseStatus.NONE) revert CaseNotFound(caseId);
        if (evidenceHash == bytes32(0)) revert InvalidEvidenceHash();

        // Only claimant or holder can submit evidence
        if (msg.sender != recoveryCase.claimant && msg.sender != recoveryCase.currentHolder) {
            revert NotAuthorized(msg.sender);
        }

        // Case must be in voting status
        if (recoveryCase.status != CaseStatus.VOTING) {
            revert InvalidCaseStatus(caseId, recoveryCase.status, CaseStatus.VOTING);
        }

        // ============================================
        // INTERACTIONS
        // ============================================
        emit EvidenceSubmitted(caseId, msg.sender, evidenceHash);
    }

    /**
     * @notice Cast a vote on a recovery case
     * @dev Only badge holders can vote, weighted by badge level
     * @param caseId The recovery case ID
     * @param approve True to approve return to claimant, false to reject
     * @param reasonHash Optional IPFS hash of vote rationale
     * @custom:security Badge-gated voting
     * @custom:security Double-vote prevention
     * @custom:emits VoteCast
     */
    function vote(
        uint256 caseId,
        bool approve,
        bytes32 reasonHash
    ) external nonReentrant whenNotPaused {
        // ============================================
        // CHECKS
        // ============================================
        RecoveryCase storage recoveryCase = _cases[caseId];
        if (recoveryCase.status == CaseStatus.NONE) revert CaseNotFound(caseId);

        // Case must be in voting status
        if (recoveryCase.status != CaseStatus.VOTING) {
            revert InvalidCaseStatus(caseId, recoveryCase.status, CaseStatus.VOTING);
        }

        // Voting period must not have ended
        if (block.timestamp > recoveryCase.votingEndsAt) {
            revert VotingStillActive(caseId, recoveryCase.votingEndsAt);
        }

        // Cannot vote twice
        if (_hasVoted[caseId][msg.sender]) {
            revert AlreadyVoted(caseId, msg.sender);
        }

        // Get vote weight (reverts if no badge)
        uint256 weight = _getVoteWeight(msg.sender);
        if (weight == 0) revert NotBadgeHolder(msg.sender);

        // ============================================
        // EFFECTS
        // ============================================
        _hasVoted[caseId][msg.sender] = true;
        _votes[caseId][msg.sender] = Vote({
            approve: approve,
            weight: weight,
            reasonHash: reasonHash
        });

        if (approve) {
            recoveryCase.votesFor += weight;
        } else {
            recoveryCase.votesAgainst += weight;
        }
        recoveryCase.voteCount++;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit VoteCast(caseId, msg.sender, approve, weight, reasonHash);
    }

    /**
     * @notice Execute resolution after voting period ends
     * @dev Transfers asset or slashes stake based on outcome
     * @param caseId The recovery case ID
     * @custom:security ReentrancyGuard prevents reentrancy
     * @custom:security Checks-Effects-Interactions pattern
     * @custom:emits CaseResolved, StakeSlashed or StakeReturned
     */
    function executeResolution(uint256 caseId) external nonReentrant {
        // ============================================
        // CHECKS
        // ============================================
        RecoveryCase storage recoveryCase = _cases[caseId];
        if (recoveryCase.status == CaseStatus.NONE) revert CaseNotFound(caseId);

        // Case must be in voting status
        if (recoveryCase.status != CaseStatus.VOTING) {
            revert InvalidCaseStatus(caseId, recoveryCase.status, CaseStatus.VOTING);
        }

        // Voting period must have ended
        if (block.timestamp <= recoveryCase.votingEndsAt) {
            revert VotingStillActive(caseId, recoveryCase.votingEndsAt);
        }

        // Quorum must be reached
        if (recoveryCase.voteCount < MINIMUM_VOTES) {
            revert QuorumNotReached(caseId, recoveryCase.voteCount, MINIMUM_VOTES);
        }

        // ============================================
        // EFFECTS
        // ============================================
        uint256 tokenId = recoveryCase.tokenId;
        uint256 stakeBond = recoveryCase.stakeBond;
        address claimant = recoveryCase.claimant;
        uint256 totalVotes = recoveryCase.votesFor + recoveryCase.votesAgainst;

        // Calculate approval percentage
        bool approved = false;
        if (totalVotes > 0) {
            uint256 approvalRate = (recoveryCase.votesFor * BASIS_POINTS) / totalVotes;
            approved = approvalRate >= APPROVAL_THRESHOLD;
        }

        // Update case status
        if (approved) {
            recoveryCase.status = CaseStatus.RESOLVED;
        } else {
            recoveryCase.status = CaseStatus.REJECTED;
        }

        // Release quarantine
        _quarantined[tokenId] = false;
        _tokenToCase[tokenId] = 0;

        // Update total stakes held
        totalStakesHeld -= stakeBond;

        // ============================================
        // INTERACTIONS
        // ============================================
        address winner;
        if (approved) {
            // Return stake to claimant
            token.safeTransfer(claimant, stakeBond);
            emit StakeReturned(caseId, claimant, stakeBond);

            // Note: In production, this would call TAGITCore.resolve()
            // to transfer the NFT to the claimant
            winner = claimant;
        } else {
            // Slash stake - 50% to treasury, 50% burned (sent to treasury for now)
            uint256 slashAmount = (stakeBond * SLASH_RATE) / BASIS_POINTS;
            uint256 returnAmount = stakeBond - slashAmount;

            if (slashAmount > 0) {
                token.safeTransfer(treasury, slashAmount);
                emit StakeSlashed(caseId, claimant, slashAmount, treasury);
            }
            if (returnAmount > 0) {
                token.safeTransfer(claimant, returnAmount);
                emit StakeReturned(caseId, claimant, returnAmount);
            }

            winner = recoveryCase.currentHolder;
        }

        emit QuarantineReleased(tokenId);
        emit CaseResolved(caseId, recoveryCase.status, winner, recoveryCase.votesFor, recoveryCase.votesAgainst);
    }

    /**
     * @notice Appeal a rejected case with higher bond
     * @dev Requires 2x original stake, resets voting
     * @param caseId The recovery case ID
     * @param newEvidenceHash IPFS hash of appeal evidence
     * @custom:security Requires 2x bond
     * @custom:emits AppealFiled
     */
    function appeal(
        uint256 caseId,
        bytes32 newEvidenceHash
    ) external nonReentrant whenNotPaused {
        // ============================================
        // NIST SECURITY CHECKS (IR-4, AC-7)
        // ============================================
        // Check circuit breaker first - trips on volume anomaly
        // Note: If circuit trips, this call will succeed but contract pauses
        // Future calls will fail due to whenNotPaused
        if (_recoveryCircuit.check()) {
            _pause();
        }

        // Check per-user rate limits
        _rateLimitConfig.check(_rateLimitStates, msg.sender);

        // ============================================
        // CHECKS
        // ============================================
        RecoveryCase storage recoveryCase = _cases[caseId];
        if (recoveryCase.status == CaseStatus.NONE) revert CaseNotFound(caseId);
        if (newEvidenceHash == bytes32(0)) revert InvalidEvidenceHash();

        // Only claimant can appeal
        if (msg.sender != recoveryCase.claimant) revert NotAuthorized(msg.sender);

        // Can only appeal rejected cases
        if (recoveryCase.status != CaseStatus.REJECTED) {
            revert CannotAppeal(caseId, recoveryCase.status);
        }

        uint256 appealBond = recoveryCase.stakeBond * APPEAL_MULTIPLIER;

        // ============================================
        // EFFECTS
        // ============================================
        recoveryCase.status = CaseStatus.APPEALED;
        recoveryCase.evidenceHash = newEvidenceHash;
        recoveryCase.votingEndsAt = uint48(block.timestamp + votingDuration);
        recoveryCase.stakeBond += appealBond;
        recoveryCase.votesFor = 0;
        recoveryCase.votesAgainst = 0;
        recoveryCase.voteCount = 0;

        // Re-quarantine the asset
        _quarantined[recoveryCase.tokenId] = true;
        _tokenToCase[recoveryCase.tokenId] = caseId;

        // Update status to voting for appeal
        recoveryCase.status = CaseStatus.VOTING;

        totalStakesHeld += appealBond;

        // ============================================
        // INTERACTIONS
        // ============================================
        token.safeTransferFrom(msg.sender, address(this), appealBond);

        emit AppealFiled(caseId, msg.sender, appealBond, newEvidenceHash);
        emit AssetQuarantined(recoveryCase.tokenId, caseId);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get recovery case details
     * @param caseId The recovery case ID
     * @return The RecoveryCase struct
     */
    function getCase(uint256 caseId) external view returns (RecoveryCase memory) {
        return _cases[caseId];
    }

    /**
     * @notice Check if asset is quarantined
     * @param tokenId The asset token ID
     * @return True if asset is quarantined
     */
    function isQuarantined(uint256 tokenId) external view returns (bool) {
        return _quarantined[tokenId];
    }

    /**
     * @notice Get active case ID for an asset
     * @param tokenId The asset token ID
     * @return caseId The active case ID (0 if none)
     */
    function getActiveCaseForToken(uint256 tokenId) external view returns (uint256) {
        return _tokenToCase[tokenId];
    }

    /**
     * @notice Check if address has voted on a case
     * @param caseId The recovery case ID
     * @param voter The address to check
     * @return True if voter has already voted
     */
    function hasVoted(uint256 caseId, address voter) external view returns (bool) {
        return _hasVoted[caseId][voter];
    }

    /**
     * @notice Get vote details for a voter on a case
     * @param caseId The recovery case ID
     * @param voter The voter address
     * @return The Vote struct
     */
    function getVote(uint256 caseId, address voter) external view returns (Vote memory) {
        return _votes[caseId][voter];
    }

    /**
     * @notice Calculate vote weight for an address
     * @param voter The address to check
     * @return weight The calculated vote weight
     */
    function getVoteWeight(address voter) external view returns (uint256 weight) {
        return _getVoteWeight(voter);
    }

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Get next case ID
     * @return The next case ID to be assigned
     */
    function nextCaseId() external view returns (uint256) {
        return _nextCaseId;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Update governor address
     * @param newGovernor New governor address
     * @custom:security Only owner can call
     * @custom:emits GovernorUpdated
     */
    function setGovernor(address newGovernor) external onlyOwner {
        if (newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = governor;
        governor = newGovernor;
        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     * @custom:security Only owner can call
     * @custom:emits TreasuryUpdated
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Update voting duration
     * @param newDuration New voting duration in seconds
     * @custom:security Only governor can call
     * @custom:emits VotingDurationUpdated
     */
    function setVotingDuration(uint256 newDuration) external onlyGovernor {
        if (newDuration == 0) revert InvalidTokenId(0); // Reuse error for zero value
        uint256 oldDuration = votingDuration;
        votingDuration = newDuration;
        emit VotingDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Update minimum stake requirement
     * @param newMinimumStake New minimum stake amount
     * @custom:security Only governor can call
     * @custom:emits MinimumStakeUpdated
     */
    function setMinimumStake(uint256 newMinimumStake) external onlyGovernor {
        if (newMinimumStake == 0) revert InvalidTokenId(0); // Reuse error for zero value
        uint256 oldStake = minimumStake;
        minimumStake = newMinimumStake;
        emit MinimumStakeUpdated(oldStake, newMinimumStake);
    }

    /**
     * @notice Pause the contract
     * @custom:security Only owner can call
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     * @custom:security Only owner can call
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // NIST SECURITY ADMIN FUNCTIONS (IR-4, AC-7)
    // ============================================

    /**
     * @notice Reset the circuit breaker after cooldown
     * @dev Only governor can call. Circuit must be past cooldown period.
     * @custom:security Governor-gated
     * @custom:emits CircuitReset
     */
    function resetCircuitBreaker() external onlyGovernor {
        // forceReset checks cooldown internally and emits events
        _recoveryCircuit.forceReset(msg.sender);
    }

    /**
     * @notice Force reset circuit breaker (emergency only)
     * @dev Only owner can call. Bypasses cooldown check.
     * @custom:security Owner-only emergency function
     * @custom:emits CircuitReset
     */
    function forceResetCircuitBreaker() external onlyOwner {
        _recoveryCircuit.forceReset(msg.sender);
    }

    /**
     * @notice Reset rate limit for a specific user
     * @param user User address to reset
     * @custom:security Governor-gated
     */
    function resetUserRateLimit(address user) external onlyGovernor {
        RateLimiter.forceUnlock(_rateLimitStates, user);
    }

    /**
     * @notice Update rate limit configuration
     * @param maxPerWindow Max actions per user per window
     * @param windowDuration Duration of rate limit window
     * @param cooldownDuration Lockout duration after hitting limit
     * @param globalMax Max global actions per window (0 = no global limit)
     * @custom:security Governor-gated
     */
    function setRateLimitConfig(
        uint64 maxPerWindow,
        uint64 windowDuration,
        uint64 cooldownDuration,
        uint64 globalMax
    ) external onlyGovernor {
        RateLimiter.updateConfig(
            _rateLimitConfig,
            maxPerWindow,
            windowDuration,
            cooldownDuration,
            globalMax
        );
    }

    /**
     * @notice Enable or disable rate limiting
     * @param enabled Whether rate limiting should be enabled
     * @custom:security Governor-gated
     */
    function setRateLimitEnabled(bool enabled) external onlyGovernor {
        _rateLimitConfig.setEnabled(enabled);
    }

    /**
     * @notice Get circuit breaker state
     * @return count Current action count in window
     * @return windowStart Window start timestamp
     * @return tripped Whether circuit is tripped
     * @return cooldownEnds Cooldown end timestamp
     */
    function getCircuitBreakerState() external view returns (
        uint64 count,
        uint64 windowStart,
        bool tripped,
        uint64 cooldownEnds
    ) {
        return (
            _recoveryCircuit.count,
            _recoveryCircuit.windowStart,
            _recoveryCircuit.tripped,
            _recoveryCircuit.cooldownEnds
        );
    }

    /**
     * @notice Get rate limit state for a user
     * @param user User address to query
     * @return count Actions in current window
     * @return windowStart Window start timestamp
     * @return lockedUntil Lockout end timestamp (0 = not locked)
     */
    function getUserRateLimitState(address user) external view returns (
        uint64 count,
        uint64 windowStart,
        uint64 lockedUntil
    ) {
        return RateLimiter.getUserState(_rateLimitStates, user);
    }

    /**
     * @notice Check remaining actions before rate limit
     * @param user User address to query
     * @return canAct_ Whether user can perform action
     * @return remaining Actions remaining in current window
     * @return lockedUntil Lockout end timestamp (0 = not locked)
     */
    function getRemainingActions(address user) external view returns (
        bool canAct_,
        uint256 remaining,
        uint256 lockedUntil
    ) {
        return _rateLimitConfig.canAct(_rateLimitStates, user);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Calculate vote weight based on badges
     * @dev Checks badges in order of weight (highest first)
     * @param voter Address to check
     * @return weight Vote weight (0 if no badge)
     */
    function _getVoteWeight(address voter) internal view returns (uint256 weight) {
        // Check badges in order of weight (highest first)
        // Governance = 4x
        if (access.hasCapability(voter, BADGE_GOVERNANCE)) {
            return 4;
        }
        // Manufacturer = 3x
        if (access.hasCapability(voter, BADGE_MANUFACTURER)) {
            return 3;
        }
        // Certified Verifier = 2x
        if (access.hasCapability(voter, BADGE_CERTIFIED_VERIFIER)) {
            return 2;
        }
        // Basic Verifier = 1x
        if (access.hasCapability(voter, BADGE_VERIFIER)) {
            return 1;
        }
        // No badge = 0 (cannot vote)
        return 0;
    }

    /**
     * @notice Authorize upgrade (owner only)
     * @param newImplementation New implementation address
     * @custom:security Only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
