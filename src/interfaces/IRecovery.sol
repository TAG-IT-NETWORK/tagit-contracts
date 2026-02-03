// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRecovery
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for AIRP (AI Recovery Protocol) dispute resolution system
 * @dev Handles stolen/counterfeit claims, evidence collection, badge-gated voting, and resolution
 */
interface IRecovery {
    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice Status of a recovery case
     * @dev NONE is default (case doesn't exist), others represent case lifecycle
     */
    enum CaseStatus {
        NONE,       // 0 - Case doesn't exist
        PENDING,    // 1 - Case created, awaiting votes
        VOTING,     // 2 - Voting period active
        RESOLVED,   // 3 - Approved - asset returned to claimant
        REJECTED,   // 4 - Rejected - asset stays with holder
        APPEALED    // 5 - Under appeal with higher bond
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Recovery case data structure
     * @dev Packed for gas efficiency where possible
     */
    struct RecoveryCase {
        uint256 tokenId;           // Asset in dispute
        address claimant;          // Who initiated recovery
        address currentHolder;     // Current NFT owner at initiation
        bytes32 evidenceHash;      // Initial evidence IPFS hash
        uint48 createdAt;          // Case creation timestamp
        uint48 votingEndsAt;       // Voting deadline
        CaseStatus status;         // Current case status
        uint256 stakeBond;         // Claimant's staked collateral
        uint256 votesFor;          // Weighted votes approving return to claimant
        uint256 votesAgainst;      // Weighted votes rejecting claim
        uint256 voteCount;         // Total number of votes cast
    }

    /**
     * @notice Individual vote record
     */
    struct Vote {
        bool approve;              // true = return to claimant
        uint256 weight;            // Badge-weighted vote power
        bytes32 reasonHash;        // Optional rationale (IPFS hash)
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Case ID does not exist
    error CaseNotFound(uint256 caseId);

    /// @notice Token ID is invalid (zero or doesn't exist)
    error InvalidTokenId(uint256 tokenId);

    /// @notice Evidence hash is invalid (zero)
    error InvalidEvidenceHash();

    /// @notice Stake bond is insufficient
    error InsufficientStake(uint256 required, uint256 provided);

    /// @notice Voting period has not started
    error VotingNotOpen(uint256 caseId);

    /// @notice Voting period is still active
    error VotingStillActive(uint256 caseId, uint256 endsAt);

    /// @notice Caller has already voted on this case
    error AlreadyVoted(uint256 caseId, address voter);

    /// @notice Caller does not hold required badge for voting
    error NotBadgeHolder(address caller);

    /// @notice Asset is not quarantined
    error AssetNotQuarantined(uint256 tokenId);

    /// @notice Asset is already quarantined
    error AssetAlreadyQuarantined(uint256 tokenId);

    /// @notice Cannot transfer quarantined asset
    error CannotTransferQuarantined(uint256 tokenId);

    /// @notice Case is not in expected status
    error InvalidCaseStatus(uint256 caseId, CaseStatus current, CaseStatus required);

    /// @notice Caller is not authorized for this action
    error NotAuthorized(address caller);

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Asset already has active recovery case
    error ActiveCaseExists(uint256 tokenId, uint256 existingCaseId);

    /// @notice Quorum not reached
    error QuorumNotReached(uint256 caseId, uint256 votes, uint256 required);

    /// @notice Appeal bond insufficient (must be 2x original)
    error InsufficientAppealBond(uint256 required, uint256 provided);

    /// @notice Case cannot be appealed (wrong status)
    error CannotAppeal(uint256 caseId, CaseStatus status);

    /// @notice Circuit breaker has tripped due to volume anomaly
    error CircuitBreakerTripped();

    /// @notice Rate limit exceeded for user
    error RateLimitExceeded(address user, uint256 count, uint256 limit);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when new recovery case is initiated
    event RecoveryInitiated(
        uint256 indexed caseId,
        uint256 indexed tokenId,
        address indexed claimant,
        address currentHolder,
        uint256 stakeBond,
        bytes32 evidenceHash
    );

    /// @notice Emitted when additional evidence is submitted
    event EvidenceSubmitted(
        uint256 indexed caseId,
        address indexed submitter,
        bytes32 evidenceHash
    );

    /// @notice Emitted when vote is cast
    event VoteCast(
        uint256 indexed caseId,
        address indexed voter,
        bool approve,
        uint256 weight,
        bytes32 reasonHash
    );

    /// @notice Emitted when case is resolved
    event CaseResolved(
        uint256 indexed caseId,
        CaseStatus outcome,
        address winner,
        uint256 votesFor,
        uint256 votesAgainst
    );

    /// @notice Emitted when asset is quarantined
    event AssetQuarantined(
        uint256 indexed tokenId,
        uint256 indexed caseId
    );

    /// @notice Emitted when quarantine is released
    event QuarantineReleased(
        uint256 indexed tokenId
    );

    /// @notice Emitted when stake is slashed
    event StakeSlashed(
        uint256 indexed caseId,
        address indexed claimant,
        uint256 amount,
        address treasury
    );

    /// @notice Emitted when stake is returned
    event StakeReturned(
        uint256 indexed caseId,
        address indexed claimant,
        uint256 amount
    );

    /// @notice Emitted when appeal is filed
    event AppealFiled(
        uint256 indexed caseId,
        address indexed appellant,
        uint256 newBond,
        bytes32 newEvidenceHash
    );

    /// @notice Emitted when governor is updated
    event GovernorUpdated(
        address indexed oldGovernor,
        address indexed newGovernor
    );

    /// @notice Emitted when treasury is updated
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    /// @notice Emitted when voting duration is updated
    event VotingDurationUpdated(
        uint256 oldDuration,
        uint256 newDuration
    );

    /// @notice Emitted when minimum stake is updated
    event MinimumStakeUpdated(
        uint256 oldStake,
        uint256 newStake
    );

    /// @notice Emitted when circuit breaker trips
    event CircuitTripped(
        uint256 indexed timestamp,
        uint256 count,
        uint256 threshold,
        uint256 cooldownEnds
    );

    /// @notice Emitted when circuit breaker resets
    event CircuitReset(
        uint256 indexed timestamp,
        uint256 previousCooldownEnds
    );

    /// @notice Emitted when rate limit is hit
    event RateLimitHit(
        address indexed user,
        uint256 count,
        uint256 lockedUntil
    );

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Initiate a recovery claim for a disputed asset
     * @dev Creates case, locks stake bond, and quarantines asset
     * @param tokenId The asset token ID to recover
     * @param evidenceHash IPFS hash of supporting evidence
     * @return caseId The ID of the created recovery case
     */
    function initiateRecovery(
        uint256 tokenId,
        bytes32 evidenceHash
    ) external returns (uint256 caseId);

    /**
     * @notice Submit additional evidence to an active case
     * @dev Only claimant or current holder can submit
     * @param caseId The recovery case ID
     * @param evidenceHash IPFS hash of additional evidence
     */
    function submitEvidence(
        uint256 caseId,
        bytes32 evidenceHash
    ) external;

    /**
     * @notice Cast a vote on a recovery case
     * @dev Only badge holders can vote, weighted by badge level
     * @param caseId The recovery case ID
     * @param approve True to approve return to claimant, false to reject
     * @param reasonHash Optional IPFS hash of vote rationale
     */
    function vote(
        uint256 caseId,
        bool approve,
        bytes32 reasonHash
    ) external;

    /**
     * @notice Execute resolution after voting period ends
     * @dev Transfers asset or slashes stake based on outcome
     * @param caseId The recovery case ID
     */
    function executeResolution(uint256 caseId) external;

    /**
     * @notice Appeal a rejected case with higher bond
     * @dev Requires 2x original stake, resets voting
     * @param caseId The recovery case ID
     * @param newEvidenceHash IPFS hash of appeal evidence
     */
    function appeal(
        uint256 caseId,
        bytes32 newEvidenceHash
    ) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get recovery case details
     * @param caseId The recovery case ID
     * @return The RecoveryCase struct
     */
    function getCase(uint256 caseId) external view returns (RecoveryCase memory);

    /**
     * @notice Check if asset is quarantined
     * @param tokenId The asset token ID
     * @return True if asset is quarantined
     */
    function isQuarantined(uint256 tokenId) external view returns (bool);

    /**
     * @notice Get active case ID for an asset
     * @param tokenId The asset token ID
     * @return caseId The active case ID (0 if none)
     */
    function getActiveCaseForToken(uint256 tokenId) external view returns (uint256);

    /**
     * @notice Check if address has voted on a case
     * @param caseId The recovery case ID
     * @param voter The address to check
     * @return True if voter has already voted
     */
    function hasVoted(uint256 caseId, address voter) external view returns (bool);

    /**
     * @notice Get vote details for a voter on a case
     * @param caseId The recovery case ID
     * @param voter The voter address
     * @return The Vote struct
     */
    function getVote(uint256 caseId, address voter) external view returns (Vote memory);

    /**
     * @notice Calculate vote weight for an address
     * @param voter The address to check
     * @return weight The calculated vote weight
     */
    function getVoteWeight(address voter) external view returns (uint256 weight);

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory);
}
