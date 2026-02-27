// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITPrograms
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for incentive programs and user reputation
 * @dev Manages scan rewards, reputation scoring, and customs/recall hooks
 */
interface ITAGITPrograms {
    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice Reputation tier levels
     */
    enum ReputationTier {
        BRONZE,     // 0-2500: 1x rewards
        SILVER,     // 2501-5000: 1.25x rewards
        GOLD,       // 5001-7500: 1.5x rewards
        PLATINUM    // 7501-10000: 2x rewards
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Reward program configuration
     */
    struct Program {
        bytes32 id;             // e.g., keccak256("SCAN_REWARDS")
        uint256 rewardAmount;   // TAGIT per action
        uint256 budget;         // Total allocated
        uint256 spent;          // Total distributed
        uint256 dailyCap;       // Max claims per user per day (0 = unlimited)
        uint48 startsAt;        // Program start time
        uint48 endsAt;          // Program end time
        bool active;            // Is program active
    }

    /**
     * @notice User reputation data
     */
    struct UserReputation {
        uint16 score;           // 0-10000 (2 decimal precision)
        uint32 lastUpdated;     // Epoch timestamp
        uint32 slashedAt;       // When slashing occurred (0 = not slashed)
        uint16 slashPenalty;    // Penalty amount from slashing
        bytes32 historyRoot;    // Merkle root of off-chain history
    }

    /**
     * @notice Batch reward claim data
     */
    struct RewardClaim {
        address user;
        bytes32 programId;
        uint256 amount;
        bytes32 actionProof;    // Proof of eligible action
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Caller is not the governor
    error NotGovernor(address caller);

    /// @notice Caller is not TAGITCore
    error NotCore(address caller);

    /// @notice Caller is not authorized updater
    error NotAuthorizedUpdater(address caller);

    /// @notice Caller is not authorized for slashing
    error NotAuthorizedSlasher(address caller);

    /// @notice Caller doesn't have manufacturer badge
    error NotManufacturer(address caller);

    /// @notice Program does not exist
    error ProgramNotFound(bytes32 programId);

    /// @notice Program already exists
    error ProgramAlreadyExists(bytes32 programId);

    /// @notice Program is not active
    error ProgramNotActive(bytes32 programId);

    /// @notice Program has expired
    error ProgramExpired(bytes32 programId, uint48 endsAt);

    /// @notice Program has not started
    error ProgramNotStarted(bytes32 programId, uint48 startsAt);

    /// @notice Exceeds program budget
    error ExceedsBudget(bytes32 programId, uint256 requested, uint256 remaining);

    /// @notice Daily claim cap exceeded
    error DailyCapExceeded(bytes32 programId, address user, uint256 cap);

    /// @notice Batch size exceeds maximum
    error BatchTooLarge(uint256 size, uint256 maxSize);

    /// @notice Invalid proof provided
    error InvalidProof(bytes32 programId, address user);

    /// @notice Reputation score exceeds maximum
    error ScoreExceedsMax(uint16 score, uint16 maxScore);

    /// @notice Slash penalty exceeds score
    error PenaltyExceedsScore(uint16 penalty, uint16 currentScore);

    /// @notice Invalid duration (zero or too long)
    error InvalidDuration(uint48 duration);

    /// @notice Token transfer failed
    error TransferFailed(address token, address to, uint256 amount);

    /// @notice Already claimed for this action
    error AlreadyClaimed(bytes32 programId, address user, bytes32 actionProof);

    /// @notice PATCH-14: action proof not verified
    error ActionProofNotVerified(bytes32 programId, address user, bytes32 actionProof);

    /// @notice User not found
    error UserNotFound(address user);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when program is created
    event ProgramCreated(
        bytes32 indexed programId,
        uint256 rewardAmount,
        uint256 budget,
        uint256 dailyCap,
        uint48 startsAt,
        uint48 endsAt
    );

    /// @notice Emitted when program is updated
    event ProgramUpdated(
        bytes32 indexed programId,
        uint256 newRewardAmount,
        bool active
    );

    /// @notice Emitted when program is funded
    event ProgramFunded(
        bytes32 indexed programId,
        uint256 amount,
        uint256 newBudget
    );

    /// @notice Emitted when reward is claimed
    event RewardClaimed(
        bytes32 indexed programId,
        address indexed user,
        uint256 amount,
        bytes32 actionProof
    );

    /// @notice Emitted when verification triggers reward
    event VerificationRewarded(
        address indexed user,
        uint256 indexed tokenId,
        uint256 reward
    );

    /// @notice Emitted when reputation is updated
    event ReputationUpdated(
        address indexed user,
        uint16 oldScore,
        uint16 newScore,
        bytes32 historyRoot
    );

    /// @notice Emitted when reputation is slashed
    event ReputationSlashed(
        address indexed user,
        uint16 penalty,
        uint16 newScore,
        bytes32 evidenceHash
    );

    /// @notice Emitted when user stakes for reputation
    event StakedForReputation(
        address indexed user,
        uint256 amount,
        uint256 newWeight
    );

    /// @notice Emitted when recall is registered
    event RecallRegistered(
        uint256[] tokenIds,
        string reason,
        address indexed manufacturer
    );

    /// @notice Emitted when customs event occurs
    event CustomsEvent(
        uint256 indexed tokenId,
        bytes32 indexed eventType,
        address indexed reporter
    );

    /// @notice Emitted when governor is updated
    event GovernorUpdated(
        address indexed oldGovernor,
        address indexed newGovernor
    );

    /// @notice Emitted when core contract is updated
    event CoreUpdated(
        address indexed oldCore,
        address indexed newCore
    );

    /// @notice Emitted when token contract is updated
    event TokenUpdated(
        address indexed oldToken,
        address indexed newToken
    );

    /// @notice Emitted when recovery contract is updated
    event RecoveryContractUpdated(
        address indexed oldRecovery,
        address indexed newRecovery
    );

    /// @notice Emitted when updater is set
    event UpdaterSet(
        address indexed updater,
        bool authorized
    );

    /// @notice PATCH-14: Emitted when action proof is approved
    event ActionProofApproved(
        bytes32 indexed proofKey,
        bytes32 indexed programId,
        address indexed user
    );

    /// @notice PATCH-14: Emitted when action verifier is updated
    event ActionVerifierUpdated(
        address indexed oldVerifier,
        address indexed newVerifier
    );

    // ============================================
    // PROGRAM MANAGEMENT
    // ============================================

    /**
     * @notice Create a new reward program (Governor only)
     * @param id Program identifier (e.g., keccak256("SCAN_REWARDS"))
     * @param rewardAmount TAGIT reward per action
     * @param budget Total program budget
     * @param dailyCap Max claims per user per day (0 = unlimited)
     * @param duration Program duration in seconds
     * @return success True if created
     */
    function createProgram(
        bytes32 id,
        uint256 rewardAmount,
        uint256 budget,
        uint256 dailyCap,
        uint48 duration
    ) external returns (bool success);

    /**
     * @notice Update an existing program (Governor only)
     * @param id Program identifier
     * @param newRewardAmount New reward amount
     * @param active Whether program is active
     */
    function updateProgram(
        bytes32 id,
        uint256 newRewardAmount,
        bool active
    ) external;

    /**
     * @notice Add funds to a program (Governor only)
     * @param id Program identifier
     * @param amount Amount to add to budget
     */
    function fundProgram(bytes32 id, uint256 amount) external;

    // ============================================
    // REWARDS
    // ============================================

    /**
     * @notice Claim a reward from a program
     * @param programId Program identifier
     * @param actionProof Proof of eligible action
     */
    function claimReward(bytes32 programId, bytes32 actionProof) external;

    /**
     * @notice Batch claim rewards (max 100)
     * @param claims Array of reward claims
     */
    function batchClaimRewards(RewardClaim[] calldata claims) external;

    /**
     * @notice Called by TAGITCore when verify() is successful
     * @param user User who performed verification
     * @param tokenId Token that was verified
     */
    function onVerification(address user, uint256 tokenId) external;

    // ============================================
    // USER REPUTATION
    // ============================================

    /**
     * @notice Update user reputation (authorized updater only)
     * @param user User address
     * @param newScore New reputation score (0-10000)
     * @param newHistoryRoot New merkle root of history
     */
    function updateReputation(
        address user,
        uint16 newScore,
        bytes32 newHistoryRoot
    ) external;

    /**
     * @notice Stake tokens to boost reputation weight
     * @param amount Amount to stake
     */
    function stakeForReputation(uint256 amount) external;

    /**
     * @notice Slash user reputation (Governor or Recovery only)
     * @param user User to slash
     * @param penalty Penalty amount (subtracted from score)
     * @param evidenceHash IPFS hash of evidence
     */
    function slashReputation(
        address user,
        uint16 penalty,
        bytes32 evidenceHash
    ) external;

    // ============================================
    // RECALLS & CUSTOMS
    // ============================================

    /**
     * @notice Register a recall for tokens (manufacturer only)
     * @param tokenIds Array of token IDs to recall
     * @param reason Reason for recall
     */
    function registerRecall(
        uint256[] calldata tokenIds,
        string calldata reason
    ) external;

    /**
     * @notice Notify customs event (authorized only)
     * @param tokenId Token involved
     * @param eventType Type of customs event
     */
    function notifyCustomsEvent(
        uint256 tokenId,
        bytes32 eventType
    ) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get program details
     * @param programId Program identifier
     * @return program Program data
     */
    function getProgram(bytes32 programId) external view returns (Program memory program);

    /**
     * @notice Get user reputation
     * @param user User address
     * @return reputation User reputation data
     */
    function getReputation(address user) external view returns (UserReputation memory reputation);

    /**
     * @notice Get weighted reputation score with badge multiplier
     * @param user User address
     * @return weightedScore Score with multiplier applied
     */
    function getWeightedScore(address user) external view returns (uint256 weightedScore);

    /**
     * @notice Get user's reputation tier
     * @param user User address
     * @return tier Reputation tier
     */
    function getReputationTier(address user) external view returns (ReputationTier tier);

    /**
     * @notice Get reward multiplier for a tier
     * @param tier Reputation tier
     * @return multiplier Reward multiplier (10000 = 1x)
     */
    function getTierMultiplier(ReputationTier tier) external pure returns (uint256 multiplier);

    /**
     * @notice Get daily claims count for a user on a program
     * @param programId Program identifier
     * @param user User address
     * @return claims Number of claims today
     */
    function getDailyClaims(bytes32 programId, address user) external view returns (uint256 claims);

    /**
     * @notice Get remaining budget for a program
     * @param programId Program identifier
     * @return remaining Remaining budget
     */
    function getRemainingBudget(bytes32 programId) external view returns (uint256 remaining);

    /**
     * @notice Get governor address
     * @return Governor address
     */
    function governor() external view returns (address);

    /**
     * @notice Get core contract address
     * @return Core contract address
     */
    function coreContract() external view returns (address);

    /**
     * @notice Check if address is authorized updater
     * @param updater Address to check
     * @return True if authorized
     */
    function isAuthorizedUpdater(address updater) external view returns (bool);

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory);
}
