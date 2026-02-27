// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITAGITPrograms} from "../interfaces/ITAGITPrograms.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {ITAGITStaking} from "../interfaces/ITAGITStaking.sol";
import {DrainDetector} from "../libraries/DrainDetector.sol";

/**
 * @title TAGITPrograms
 * @author TAG IT Network <dev@tagit.network>
 * @notice Incentive programs with rewards and reputation scoring
 * @dev Manages scan rewards, user reputation, and customs/recall hooks
 *
 * Features:
 * - Program-based rewards with daily caps
 * - Integration with TAGITCore for scan rewards
 * - User reputation with badge-weighted scoring
 * - Slashing with 90-day linear recovery
 * - Recall and customs event tracking
 */
contract TAGITPrograms is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable,
    OwnableUpgradeable,
    ITAGITPrograms
{
    using SafeERC20 for IERC20;
    using DrainDetector for DrainDetector.Config;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Maximum reputation score
    uint16 public constant MAX_SCORE = 10000;

    /// @notice Maximum batch claim size
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice Slash recovery period (90 days)
    uint256 public constant SLASH_RECOVERY_PERIOD = 90 days;

    /// @notice Maximum program duration (2 years)
    uint48 public constant MAX_DURATION = 730 days;

    /// @notice Badge ID for manufacturer
    uint256 public constant BADGE_MANUFACTURER = 10;

    /// @notice Badge ID for basic verifier
    uint256 public constant BADGE_BASIC_VERIFIER = 50;

    /// @notice Badge ID for certified verifier
    uint256 public constant BADGE_CERTIFIED_VERIFIER = 51;

    /// @notice Badge ID for governance
    uint256 public constant BADGE_GOVERNANCE = 60;

    /// @notice Tier score thresholds
    uint16 public constant TIER_SILVER = 2501;
    uint16 public constant TIER_GOLD = 5001;
    uint16 public constant TIER_PLATINUM = 7501;

    /// @notice Tier multipliers (10000 = 1x)
    uint256 public constant MULTIPLIER_BRONZE = 10000;
    uint256 public constant MULTIPLIER_SILVER = 12500;
    uint256 public constant MULTIPLIER_GOLD = 15000;
    uint256 public constant MULTIPLIER_PLATINUM = 20000;

    /// @notice Program IDs
    bytes32 public constant PROGRAM_SCAN_REWARDS = keccak256("SCAN_REWARDS");
    bytes32 public constant PROGRAM_FIRST_SCAN = keccak256("FIRST_SCAN");

    // ============================================
    // STORAGE
    // ============================================

    /// @notice Governor address
    address private _governor;

    /// @notice TAGITCore contract
    address private _coreContract;

    /// @notice TAGITToken contract
    address private _tokenContract;

    /// @notice TAGITAccess contract
    ITAGITAccess private _accessContract;

    /// @notice TAGITStaking contract
    ITAGITStaking private _stakingContract;

    /// @notice TAGITRecovery contract (for slashing authorization)
    address private _recoveryContract;

    /// @notice Programs by ID
    mapping(bytes32 => Program) private _programs;

    /// @notice User reputation data
    mapping(address => UserReputation) private _reputation;

    /// @notice Daily claims: programId => user => day => count
    mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) private _dailyClaims;

    /// @notice Claimed actions: programId => user => actionProof => claimed
    mapping(bytes32 => mapping(address => mapping(bytes32 => bool))) private _claimedActions;

    /// @notice First scan per token: tokenId => claimed
    mapping(uint256 => bool) private _firstScanClaimed;

    /// @notice Authorized reputation updaters
    mapping(address => bool) private _authorizedUpdaters;

    /// @notice Authorized customs reporters
    mapping(address => bool) private _authorizedReporters;

    /// @notice User staked amounts for reputation boost
    mapping(address => uint256) private _reputationStakes;

    // PATCH-14: action proof verification
    /// @notice Authorized action verifier (signs/approves action proofs)
    address private _actionVerifier;

    /// @notice Pre-approved action proofs: keccak256(programId, user, actionProof) => approved
    mapping(bytes32 => bool) private _approvedActions;

    // ============================================
    // NIST SECURITY CONTROLS (SI-4)
    // ============================================

    /// @notice Drain detector for reward pool anomaly detection
    DrainDetector.Config private _rewardDrainDetector;

    // ============================================
    // EVENTS (NIST SI-4 Monitoring)
    // ============================================

    /// @notice Emitted when drain detector trips
    event RewardPoolDrainDetected(uint256 indexed timestamp, uint8 reason, string details);

    // ============================================
    // INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the programs contract
     * @param governorAddress Governor contract address
     * @param coreAddress TAGITCore contract address
     * @param tokenAddress TAGITToken contract address
     * @param accessAddress TAGITAccess contract address
     * @param stakingAddress TAGITStaking contract address
     * @param initialOwner Initial owner address
     */
    function initialize(
        address governorAddress,
        address coreAddress,
        address tokenAddress,
        address accessAddress,
        address stakingAddress,
        address initialOwner
    ) external initializer {
        if (governorAddress == address(0)) revert ZeroAddress();
        if (coreAddress == address(0)) revert ZeroAddress();
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (accessAddress == address(0)) revert ZeroAddress();
        if (stakingAddress == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        __UUPSUpgradeable_init();
        __Pausable_init();
        __Ownable_init(initialOwner);

        _governor = governorAddress;
        _coreContract = coreAddress;
        _tokenContract = tokenAddress;
        _accessContract = ITAGITAccess(accessAddress);
        _stakingContract = ITAGITStaking(stakingAddress);

        // Initialize NIST security controls (SI-4)
        // Drain detector: 1hr window, 5% spike, 20% velocity, 500 tx/window, 2hr cooldown, 0 initial balance
        _rewardDrainDetector.initialize(1 hours, 500, 2000, 500, 2 hours, 0);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyGovernor() {
        if (msg.sender != _governor) {
            revert NotGovernor(msg.sender);
        }
        _;
    }

    modifier onlyCore() {
        if (msg.sender != _coreContract) {
            revert NotCore(msg.sender);
        }
        _;
    }

    modifier onlyAuthorizedUpdater() {
        if (!_authorizedUpdaters[msg.sender] && msg.sender != _governor) {
            revert NotAuthorizedUpdater(msg.sender);
        }
        _;
    }

    modifier onlyAuthorizedSlasher() {
        if (msg.sender != _governor && msg.sender != _recoveryContract) {
            revert NotAuthorizedSlasher(msg.sender);
        }
        _;
    }

    // ============================================
    // PROGRAM MANAGEMENT
    // ============================================

    /**
     * @inheritdoc ITAGITPrograms
     */
    function createProgram(bytes32 id, uint256 rewardAmount, uint256 budget, uint256 dailyCap, uint48 duration)
        external
        override
        onlyGovernor
        returns (bool)
    {
        if (_programs[id].id != bytes32(0)) revert ProgramAlreadyExists(id);
        if (rewardAmount == 0) revert ZeroAmount();
        if (budget == 0) revert ZeroAmount();
        if (duration == 0 || duration > MAX_DURATION) revert InvalidDuration(duration);

        _programs[id] = Program({
            id: id,
            rewardAmount: rewardAmount,
            budget: budget,
            spent: 0,
            dailyCap: dailyCap,
            startsAt: uint48(block.timestamp),
            endsAt: uint48(block.timestamp) + duration,
            active: true
        });

        emit ProgramCreated(
            id, rewardAmount, budget, dailyCap, uint48(block.timestamp), uint48(block.timestamp) + duration
        );
        return true;
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function updateProgram(bytes32 id, uint256 newRewardAmount, bool active) external override onlyGovernor {
        Program storage program = _programs[id];
        if (program.id == bytes32(0)) revert ProgramNotFound(id);

        program.rewardAmount = newRewardAmount;
        program.active = active;

        emit ProgramUpdated(id, newRewardAmount, active);
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function fundProgram(bytes32 id, uint256 amount) external override onlyGovernor {
        Program storage program = _programs[id];
        if (program.id == bytes32(0)) revert ProgramNotFound(id);
        if (amount == 0) revert ZeroAmount();

        // EFFECTS
        program.budget += amount;
        emit ProgramFunded(id, amount, program.budget);

        // NIST SI-4: Track deposit in drain detector
        _rewardDrainDetector.recordDeposit(amount);

        // INTERACTIONS
        IERC20(_tokenContract).safeTransferFrom(msg.sender, address(this), amount);
    }

    // ============================================
    // REWARDS
    // ============================================

    /**
     * @inheritdoc ITAGITPrograms
     */
    function claimReward(bytes32 programId, bytes32 actionProof) external override nonReentrant whenNotPaused {
        _claimReward(msg.sender, programId, actionProof);
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function batchClaimRewards(RewardClaim[] calldata claims) external override nonReentrant whenNotPaused {
        if (claims.length > MAX_BATCH_SIZE) revert BatchTooLarge(claims.length, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < claims.length; i++) {
            // Only allow self-claims in batch
            if (claims[i].user != msg.sender) continue;
            _claimReward(claims[i].user, claims[i].programId, claims[i].actionProof);
        }
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function onVerification(address user, uint256 tokenId) external override onlyCore nonReentrant {
        // CHECKS & EFFECTS first, INTERACTIONS last (CEI pattern)
        uint256 scanReward = 0;
        uint256 firstScanReward = 0;

        // Check scan rewards program
        Program storage program = _programs[PROGRAM_SCAN_REWARDS];
        if (program.id != bytes32(0) && program.active && block.timestamp <= program.endsAt) {
            uint256 currentDay = block.timestamp / 1 days;
            uint256 dailyCount = _dailyClaims[PROGRAM_SCAN_REWARDS][user][currentDay];

            // Check daily cap (0 = unlimited)
            if (program.dailyCap == 0 || dailyCount < program.dailyCap) {
                uint256 remaining = program.budget - program.spent;
                if (remaining >= program.rewardAmount) {
                    // Apply tier multiplier
                    scanReward = _applyTierMultiplier(user, program.rewardAmount);
                    if (scanReward <= remaining) {
                        // EFFECTS: Update state before external calls
                        program.spent += scanReward;
                        _dailyClaims[PROGRAM_SCAN_REWARDS][user][currentDay]++;
                    } else {
                        scanReward = 0;
                    }
                }
            }
        }

        // Check first scan bonus
        if (!_firstScanClaimed[tokenId]) {
            Program storage firstScan = _programs[PROGRAM_FIRST_SCAN];
            if (firstScan.id != bytes32(0) && firstScan.active && block.timestamp <= firstScan.endsAt) {
                uint256 remaining = firstScan.budget - firstScan.spent;
                if (remaining >= firstScan.rewardAmount) {
                    firstScanReward = firstScan.rewardAmount;
                    // EFFECTS: Update state before external calls
                    _firstScanClaimed[tokenId] = true;
                    firstScan.spent += firstScanReward;
                }
            }
        }

        // NIST SI-4: Check drain detection for combined reward
        uint256 totalReward = scanReward + firstScanReward;
        if (totalReward > 0) {
            uint8 drainReason = _rewardDrainDetector.checkWithdrawal(totalReward);
            if (drainReason > 0) {
                _pause();
                emit RewardPoolDrainDetected(block.timestamp, drainReason, "verification_reward");
            }
            _rewardDrainDetector.recordWithdrawal(totalReward);
        }

        // INTERACTIONS: All external calls at the end
        if (scanReward > 0) {
            IERC20(_tokenContract).safeTransfer(user, scanReward);
            emit VerificationRewarded(user, tokenId, scanReward);
        }

        if (firstScanReward > 0) {
            IERC20(_tokenContract).safeTransfer(user, firstScanReward);
            emit RewardClaimed(PROGRAM_FIRST_SCAN, user, firstScanReward, bytes32(tokenId));
        }
    }

    /**
     * @dev Internal claim logic
     */
    function _claimReward(address user, bytes32 programId, bytes32 actionProof) internal {
        Program storage program = _programs[programId];

        if (program.id == bytes32(0)) revert ProgramNotFound(programId);
        if (!program.active) revert ProgramNotActive(programId);
        if (block.timestamp < program.startsAt) revert ProgramNotStarted(programId, program.startsAt);
        if (block.timestamp > program.endsAt) revert ProgramExpired(programId, program.endsAt);

        // PATCH-14: verify action proof was pre-approved by verifier
        bytes32 proofKey = keccak256(abi.encodePacked(programId, user, actionProof));
        if (!_approvedActions[proofKey]) {
            revert ActionProofNotVerified(programId, user, actionProof);
        }
        // Consume approval (prevents double-use even though _claimedActions also checks)
        _approvedActions[proofKey] = false;

        // Check if already claimed
        if (_claimedActions[programId][user][actionProof]) {
            revert AlreadyClaimed(programId, user, actionProof);
        }

        // Check daily cap
        uint256 currentDay = block.timestamp / 1 days;
        if (program.dailyCap > 0 && _dailyClaims[programId][user][currentDay] >= program.dailyCap) {
            revert DailyCapExceeded(programId, user, program.dailyCap);
        }

        // Check budget
        uint256 remaining = program.budget - program.spent;
        uint256 reward = _applyTierMultiplier(user, program.rewardAmount);
        if (reward > remaining) {
            revert ExceedsBudget(programId, reward, remaining);
        }

        // Mark as claimed
        _claimedActions[programId][user][actionProof] = true;
        _dailyClaims[programId][user][currentDay]++;
        program.spent += reward;

        // NIST SI-4: Check drain detection before transfer
        uint8 drainReason = _rewardDrainDetector.checkWithdrawal(reward);
        if (drainReason > 0) {
            _pause();
            emit RewardPoolDrainDetected(block.timestamp, drainReason, "claim_reward");
        }
        _rewardDrainDetector.recordWithdrawal(reward);

        // Transfer reward
        IERC20(_tokenContract).safeTransfer(user, reward);

        emit RewardClaimed(programId, user, reward, actionProof);
    }

    /**
     * @dev Apply tier multiplier to reward
     */
    function _applyTierMultiplier(address user, uint256 baseReward) internal view returns (uint256) {
        ReputationTier tier = getReputationTier(user);
        uint256 multiplier = getTierMultiplier(tier);
        return (baseReward * multiplier) / 10000;
    }

    // ============================================
    // USER REPUTATION
    // ============================================

    /**
     * @inheritdoc ITAGITPrograms
     */
    function updateReputation(address user, uint16 newScore, bytes32 newHistoryRoot)
        external
        override
        onlyAuthorizedUpdater
    {
        if (user == address(0)) revert ZeroAddress();
        if (newScore > MAX_SCORE) revert ScoreExceedsMax(newScore, MAX_SCORE);

        UserReputation storage rep = _reputation[user];
        uint16 oldScore = rep.score;

        rep.score = newScore;
        rep.lastUpdated = uint32(block.timestamp);
        rep.historyRoot = newHistoryRoot;

        emit ReputationUpdated(user, oldScore, newScore, newHistoryRoot);
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function stakeForReputation(uint256 amount) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        _reputationStakes[msg.sender] += amount;

        IERC20(_tokenContract).safeTransferFrom(msg.sender, address(this), amount);

        uint256 newWeight = getWeightedScore(msg.sender);
        emit StakedForReputation(msg.sender, amount, newWeight);
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function slashReputation(address user, uint16 penalty, bytes32 evidenceHash)
        external
        override
        onlyAuthorizedSlasher
    {
        if (user == address(0)) revert ZeroAddress();

        UserReputation storage rep = _reputation[user];
        if (penalty > rep.score) revert PenaltyExceedsScore(penalty, rep.score);

        rep.score -= penalty;
        rep.slashedAt = uint32(block.timestamp);
        rep.slashPenalty = penalty;

        emit ReputationSlashed(user, penalty, rep.score, evidenceHash);
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function getWeightedScore(address user) public view override returns (uint256 weightedScore) {
        uint256 baseScore = _getRecoveredScore(user);

        // Badge multiplier
        uint256 multiplier = 10000; // 1x default

        if (_accessContract.hasIdentity(user, BADGE_GOVERNANCE)) {
            multiplier = 40000; // 4x
        } else if (_accessContract.hasIdentity(user, BADGE_CERTIFIED_VERIFIER)) {
            multiplier = 30000; // 3x
        } else if (_accessContract.hasIdentity(user, BADGE_MANUFACTURER)) {
            multiplier = 20000; // 2x
        } else if (_accessContract.hasIdentity(user, BADGE_BASIC_VERIFIER)) {
            multiplier = 20000; // 2x
        }

        // Stake boost (1% per 1000 staked, max 50%)
        uint256 stakeBoost = 0;
        uint256 staked = _reputationStakes[user];
        if (staked > 0) {
            stakeBoost = (staked * 100) / 1000e18; // 1% per 1000 tokens
            if (stakeBoost > 5000) stakeBoost = 5000; // Cap at 50%
        }

        weightedScore = (baseScore * (multiplier + stakeBoost)) / 10000;
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function getReputationTier(address user) public view override returns (ReputationTier) {
        uint256 score = _getRecoveredScore(user);

        if (score >= TIER_PLATINUM) return ReputationTier.PLATINUM;
        if (score >= TIER_GOLD) return ReputationTier.GOLD;
        if (score >= TIER_SILVER) return ReputationTier.SILVER;
        return ReputationTier.BRONZE;
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function getTierMultiplier(ReputationTier tier) public pure override returns (uint256) {
        if (tier == ReputationTier.PLATINUM) return MULTIPLIER_PLATINUM;
        if (tier == ReputationTier.GOLD) return MULTIPLIER_GOLD;
        if (tier == ReputationTier.SILVER) return MULTIPLIER_SILVER;
        return MULTIPLIER_BRONZE;
    }

    /**
     * @dev Get score with linear slash recovery
     */
    function _getRecoveredScore(address user) internal view returns (uint256) {
        UserReputation storage rep = _reputation[user];

        if (rep.slashedAt == 0 || rep.slashPenalty == 0) {
            return rep.score;
        }

        uint256 elapsed = block.timestamp - rep.slashedAt;
        if (elapsed >= SLASH_RECOVERY_PERIOD) {
            // Fully recovered
            return rep.score + rep.slashPenalty;
        }

        // Linear recovery
        uint256 recovered = (rep.slashPenalty * elapsed) / SLASH_RECOVERY_PERIOD;
        return rep.score + recovered;
    }

    // ============================================
    // RECALLS & CUSTOMS
    // ============================================

    /**
     * @inheritdoc ITAGITPrograms
     */
    function registerRecall(uint256[] calldata tokenIds, string calldata reason) external override {
        if (!_accessContract.hasIdentity(msg.sender, BADGE_MANUFACTURER)) {
            revert NotManufacturer(msg.sender);
        }

        emit RecallRegistered(tokenIds, reason, msg.sender);
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function notifyCustomsEvent(uint256 tokenId, bytes32 eventType) external override {
        if (!_authorizedReporters[msg.sender] && msg.sender != _governor) {
            revert NotAuthorizedUpdater(msg.sender);
        }

        emit CustomsEvent(tokenId, eventType, msg.sender);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Set governor address
     * @param newGovernor New governor address
     */
    function setGovernor(address newGovernor) external onlyOwner {
        if (newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = _governor;
        _governor = newGovernor;
        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    /**
     * @notice Set core contract address
     * @param newCore New core address
     */
    function setCore(address newCore) external onlyGovernor {
        if (newCore == address(0)) revert ZeroAddress();
        address oldCore = _coreContract;
        _coreContract = newCore;
        emit CoreUpdated(oldCore, newCore);
    }

    /**
     * @notice Set token contract address
     * @param newToken New TAGITToken address
     */
    function setToken(address newToken) external onlyOwner {
        if (newToken == address(0)) revert ZeroAddress();
        address oldToken = _tokenContract;
        _tokenContract = newToken;
        emit TokenUpdated(oldToken, newToken);
    }

    /**
     * @notice Set recovery contract for slashing authorization
     * @param recoveryAddress Recovery contract address
     */
    function setRecoveryContract(address recoveryAddress) external onlyGovernor {
        if (recoveryAddress == address(0)) revert ZeroAddress();
        address oldRecovery = _recoveryContract;
        _recoveryContract = recoveryAddress;
        emit RecoveryContractUpdated(oldRecovery, recoveryAddress);
    }

    /**
     * @notice Set authorized updater
     * @param updater Updater address
     * @param authorized Whether authorized
     */
    function setUpdater(address updater, bool authorized) external onlyGovernor {
        if (updater == address(0)) revert ZeroAddress();
        _authorizedUpdaters[updater] = authorized;
        emit UpdaterSet(updater, authorized);
    }

    // ============================================
    // PATCH-14: ACTION PROOF VERIFICATION
    // ============================================

    /**
     * @notice Set the action verifier address
     * @param newVerifier New action verifier address
     */
    function setActionVerifier(address newVerifier) external onlyGovernor {
        address oldVerifier = _actionVerifier;
        _actionVerifier = newVerifier;
        emit ActionVerifierUpdated(oldVerifier, newVerifier);
    }

    /**
     * @notice Pre-approve an action proof for a user
     * @dev Only governor or action verifier can call.
     *      Off-chain service validates action then approves the proof.
     * @param programId Program the claim is for
     * @param user User who will claim
     * @param actionProof The action proof hash
     */
    function approveAction(bytes32 programId, address user, bytes32 actionProof) external {
        if (msg.sender != _governor && msg.sender != _actionVerifier) {
            revert NotAuthorizedUpdater(msg.sender);
        }
        bytes32 proofKey = keccak256(abi.encodePacked(programId, user, actionProof));
        _approvedActions[proofKey] = true;
        emit ActionProofApproved(proofKey, programId, user);
    }

    /**
     * @notice Batch approve action proofs
     * @param programIds Program IDs
     * @param users User addresses
     * @param actionProofs Action proof hashes
     */
    function batchApproveActions(
        bytes32[] calldata programIds,
        address[] calldata users,
        bytes32[] calldata actionProofs
    ) external {
        if (msg.sender != _governor && msg.sender != _actionVerifier) {
            revert NotAuthorizedUpdater(msg.sender);
        }
        if (programIds.length != users.length || users.length != actionProofs.length) {
            revert BatchTooLarge(programIds.length, MAX_BATCH_SIZE);
        }
        for (uint256 i = 0; i < programIds.length; i++) {
            bytes32 proofKey = keccak256(abi.encodePacked(programIds[i], users[i], actionProofs[i]));
            _approvedActions[proofKey] = true;
            emit ActionProofApproved(proofKey, programIds[i], users[i]);
        }
    }

    /**
     * @notice Check if an action proof is approved
     * @param programId Program ID
     * @param user User address
     * @param actionProof Action proof hash
     * @return approved True if approved
     */
    function isActionApproved(bytes32 programId, address user, bytes32 actionProof) external view returns (bool) {
        bytes32 proofKey = keccak256(abi.encodePacked(programId, user, actionProof));
        return _approvedActions[proofKey];
    }

    /**
     * @notice Get the action verifier address
     */
    function actionVerifier() external view returns (address) {
        return _actionVerifier;
    }

    /**
     * @notice Set authorized customs reporter
     * @param reporter Reporter address
     * @param authorized Whether authorized
     */
    function setReporter(address reporter, bool authorized) external onlyGovernor {
        if (reporter == address(0)) revert ZeroAddress();
        _authorizedReporters[reporter] = authorized;
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyGovernor {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyGovernor {
        _unpause();
    }

    // ============================================
    // NIST SECURITY ADMIN FUNCTIONS (SI-4)
    // ============================================

    /**
     * @notice Update drain detector tracked balance
     * @param newBalance New balance to track
     */
    function updateDrainBalance(uint128 newBalance) external onlyGovernor {
        _rewardDrainDetector.setBalance(newBalance);
    }

    /**
     * @notice Sync drain detector balance with actual token balance
     */
    function syncDrainBalance() external onlyGovernor {
        uint256 balance = IERC20(_tokenContract).balanceOf(address(this));
        uint128 capped = balance > type(uint128).max ? type(uint128).max : uint128(balance);
        _rewardDrainDetector.setBalance(capped);
    }

    /**
     * @notice Force reset drain detector after incident investigation
     */
    function resetDrainDetector() external onlyOwner {
        _rewardDrainDetector.forceReset(msg.sender);
    }

    /**
     * @notice Get drain detector state
     */
    function getDrainDetectorState()
        external
        view
        returns (
            uint128 trackedBalance,
            uint16 spikeThresholdBps,
            uint16 velocityThresholdBps,
            uint32 maxTxPerWindow,
            bool tripped,
            uint64 cooldownEnds
        )
    {
        return (
            _rewardDrainDetector.trackedBalance,
            _rewardDrainDetector.spikeThresholdBps,
            _rewardDrainDetector.velocityThresholdBps,
            _rewardDrainDetector.maxTxPerWindow,
            _rewardDrainDetector.tripped,
            _rewardDrainDetector.cooldownEnds
        );
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITPrograms
     */
    function getProgram(bytes32 programId) external view override returns (Program memory) {
        return _programs[programId];
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function getReputation(address user) external view override returns (UserReputation memory) {
        return _reputation[user];
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function getDailyClaims(bytes32 programId, address user) external view override returns (uint256) {
        uint256 currentDay = block.timestamp / 1 days;
        return _dailyClaims[programId][user][currentDay];
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function getRemainingBudget(bytes32 programId) external view override returns (uint256) {
        Program storage program = _programs[programId];
        return program.budget - program.spent;
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function governor() external view override returns (address) {
        return _governor;
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function coreContract() external view override returns (address) {
        return _coreContract;
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function isAuthorizedUpdater(address updater) external view override returns (bool) {
        return _authorizedUpdaters[updater] || updater == _governor;
    }

    /**
     * @inheritdoc ITAGITPrograms
     */
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    // ============================================
    // UUPS
    // ============================================

    /**
     * @dev Required override for UUPS
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
