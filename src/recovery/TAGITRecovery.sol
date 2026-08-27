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
import {ITAGITCoreRecovery} from "../interfaces/ITAGITCoreRecovery.sol";
import {CircuitBreaker} from "../libraries/CircuitBreaker.sol";
import {RateLimiter} from "../libraries/RateLimiter.sol";

/**
 * @title TAGITRecovery
 * @author TAG IT Network <dev@tagit.network>
 * @notice AIRP (AI Recovery Protocol) for asset dispute resolution
 * @dev AIRP is an ADJUDICATOR, not a custodian. It decides who a disputed asset
 *      belongs to and escrows the claimant's bond until custody actually moves.
 *      It never moves the asset itself.
 *
 * Key Features:
 * - Stake bond required to initiate recovery claims (anti-spam)
 * - Soulbound IdentityBadge-weighted voting on dedicated AIRP juror seats (ids 70-73)
 * - 7-day voting period with 66% approval threshold
 * - 50% stake slashing on fraudulent claims (adverse vote only)
 * - A 10% anti-squat fee on a case that expires having drawn FEWER THAN TWO votes: opening
 *   a bonded case takes an asset's only dispute slot for the whole voting period, so a case
 *   that never drew plural engagement must not be free. A single vote is purchasable from a
 *   single juror seat and cannot be the bar. From two votes up the bond refunds in full —
 *   that is voter apathy, not claimant conduct.
 * - Appeals reopen a REJECTED case in a NEW voting round against a fresh 2x bond
 *   (the previous round's bond was already disbursed, so the record is replaced), within a
 *   bounded appeal window during which the REJECTED case keeps its token's dispute slot.
 *   That window counts UNPAUSED seconds only: appeal() is whenNotPaused, so a pause that
 *   outlasted a wall-clock window would have consumed an appeal right the claimant had
 *   already paid a 50% slash to earn
 * - Verdict-bound execution: an approved case enters ENFORCING and settles only
 *   once TAGITCore's 2-of-3 resolver quorum has actually delivered the asset
 *
 * Security:
 * - UUPS upgradeable with owner-only upgrade auth
 * - ReentrancyGuard on all eight externally-callable case functions
 *   (initiateRecovery, submitEvidence, vote, executeResolution, finalizeResolution,
 *   expireEnforcement, abandonEnforcement, appeal). submitEvidence is guarded for
 *   uniformity only — it validates and emits, and writes no state. The owner/governor-only
 *   configuration setters are deliberately NOT nonReentrant: none of them makes an
 *   external call, so there is no reentrancy surface for a guard to close.
 * - Checks-Effects-Interactions pattern throughout
 * - Custom errors for gas efficiency
 *
 * @custom:security TRUST BOUNDARY. TAGITRecovery adjudicates and escrows; it never
 *   holds custody. It holds NO CapabilityBadge in TAGITCore and makes NO
 *   state-changing call into TAGITCore — only getAsset(), preFlagState(),
 *   getResolveApprovalStatus(), RESOLVE_QUORUM() and ownerOf(), all view. Custody moves solely via
 *   TAGITCore.resolve(), which requires RESOLVER_CAPABILITY plus a 2-of-3 quorum of
 *   distinct human approvers. Granting this contract any capability would break that
 *   boundary and must be treated as a security incident.
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

    /// @notice Anti-squat fee in basis points (10%) on a case that expires with FEWER THAN
    ///         FEE_EXEMPT_MIN_VOTES votes
    /// @dev NOT a slash. SLASH_RATE is the penalty for losing a vote; this is the price of
    ///      having occupied an asset's only dispute slot for a full voting period without
    ///      drawing plural engagement. Charged whenever voteCount < FEE_EXEMPT_MIN_VOTES; a
    ///      case that drew two or more votes is still below MINIMUM_VOTES and still EXPIRES,
    ///      but that is voter apathy rather than claimant conduct and refunds in full.
    uint256 public constant SQUAT_FEE_RATE = 1000;

    /// @notice Votes a case must draw to be exempt from the anti-squat fee when it expires
    /// @dev TWO, not one. The fee used to be keyed on voteCount == 0, and vote() excludes
    ///      only the claimant and the current holder — so ONE address holding a single AIRP
    ///      juror seat (ids 70-73) that a griefer controls, rents or bribes could cast one
    ///      vote per decoy, tip the case into the apathy carve-out, and make squatting free
    ///      and infinitely repeatable again: the exact state the fee exists to prevent.
    ///      One vote is purchasable from a single seat; two requires collusion between two
    ///      independently-granted seats. MINIMUM_VOTES is 3, so this threshold still sits
    ///      STRICTLY BELOW quorum and the apathy principle — "voter apathy is not claimant
    ///      fraud" — is preserved for every case that drew real, plural engagement.
    uint256 public constant FEE_EXEMPT_MIN_VOTES = 2;

    /// @notice Appeal bond multiplier (2x original)
    uint256 public constant APPEAL_MULTIPLIER = 2;

    /// @notice Minimum votes required for quorum
    uint256 public constant MINIMUM_VOTES = 3;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Lower bound for a governor-configured minimum stake
    /// @dev BASIS_POINTS / SQUAT_FEE_RATE — the smallest bond on which the anti-squat fee is
    ///      still a non-zero number of wei. Below it (bond * SQUAT_FEE_RATE) / BASIS_POINTS
    ///      truncates to zero and the fee stops existing with no revert, no event and no
    ///      other signal, so squatting silently becomes free again while every document
    ///      still claims it costs 10%. Both window setters were already bounded; the
    ///      parameter the anti-squat economics actually rest on was not.
    uint256 public constant MINIMUM_STAKE_FLOOR = BASIS_POINTS / SQUAT_FEE_RATE;

    /// @notice Default window in which the resolver quorum may execute an approved verdict
    uint256 public constant ENFORCEMENT_WINDOW_DEFAULT = 30 days;

    /// @notice Lower bound for a governor-configured enforcement window
    uint256 public constant ENFORCEMENT_WINDOW_MIN = 7 days;

    /// @notice Upper bound for a governor-configured enforcement window
    uint256 public constant ENFORCEMENT_WINDOW_MAX = 365 days;

    /// @notice Default window in which a REJECTED case keeps the exclusive right to appeal
    uint256 public constant APPEAL_WINDOW_DEFAULT = 7 days;

    /// @notice Lower bound for a governor-configured appeal window
    uint256 public constant APPEAL_WINDOW_MIN = 1 days;

    /// @notice Upper bound for a governor-configured appeal window
    /// @dev Deliberately far below ENFORCEMENT_WINDOW_MAX. This window LOCKS an asset's only
    ///      dispute slot against every other claimant, so it is a cost borne by third
    ///      parties, not by the case that holds it.
    uint256 public constant APPEAL_WINDOW_MAX = 30 days;

    // ============================================
    // AIRP JUROR BADGE IDS (BIDGES IdentityBadge, range 70-79)
    // ============================================
    //
    // IdentityBadge ids are ONE flat protocol-wide registry. Everything below 70 is
    // already allocated to a DIFFERENT meaning and must never be reused here:
    //   1-3   KYC_L1/L2/L3      (TAGITAgentIdentity, TAGITAgentReputation, TAGITAgentValidation)
    //   10-11 MANUFACTURER/RETAILER (RobotTypes, TAGITGovernor, TAGITPrograms)
    //   20-21 GOV_MIL/LAW_ENFORCEMENT (RobotTypes, TAGITGovernor)
    //   30-35 robot classes     (RobotTypes) — 30 is also TAGITGovernor.BADGE_DEV
    //   40    REGULATORY        (TAGITGovernor)
    //   50-51 / 60 verifier + governance tiers (TAGITPrograms)
    //
    // Before this change the juror lookup pointed at 1/2/10/20. That was inert while the
    // lookup read the CapabilityBadge registry (nobody holds capability ids 1/2/10/20 —
    // documented capabilities are 100-108), but the sybil fix moved the lookup to the
    // SOULBOUND IdentityBadge registry, where id 1 is basic KYC. Every KYC'd user in the
    // protocol silently became an AIRP juror able to vote a claimant's bond away.
    //
    // 70-79 is therefore reserved protocol-wide for AIRP jury seats and is used by nothing
    // else. See src/access/IdentityBadge.sol for the registry-wide allocation table.

    /// @notice AIRP juror seat (1x weight). AIRP-SPECIFIC IdentityBadge id — NOT KYC_L1.
    uint256 public constant BADGE_AIRP_JUROR = 70;

    /// @notice AIRP senior juror seat (2x weight). AIRP-SPECIFIC id — NOT KYC_L2.
    uint256 public constant BADGE_AIRP_SENIOR_JUROR = 71;

    /// @notice AIRP arbiter seat (3x weight). AIRP-SPECIFIC id — NOT MANUFACTURER.
    uint256 public constant BADGE_AIRP_ARBITER = 72;

    /// @notice AIRP tribunal seat (4x weight). AIRP-SPECIFIC id — NOT GOV_MIL.
    uint256 public constant BADGE_AIRP_TRIBUNAL = 73;

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

    // ============================================
    // VERDICT-BOUND EXECUTION (v2 — appended)
    // ============================================

    /// @notice Raw configured enforcement window (slot 20). 0 = never configured.
    /// @dev PRIVATE on purpose. Read it through the effective getter enforcementWindow()
    ///      or _window(), never directly: a proxy upgraded from v1 has never written this
    ///      slot, so the raw value is 0 while the contract actually enforces
    ///      ENFORCEMENT_WINDOW_DEFAULT. The public auto-getter used to leak that 0 to
    ///      off-chain consumers, which reported "no enforcement window configured".
    ///      Renaming the identifier does NOT move the slot: still slot 20, still uint256.
    uint256 private _enforcementWindow;

    /// @notice caseId => enforcement deadline (0 = not in ENFORCING)
    mapping(uint256 => uint48) private _enforcementEndsAt;

    // ============================================
    // APPEAL ROUNDS (v2.1 — appended)
    // ============================================

    /// @notice caseId => current voting round (0 = the original round, 1 = first appeal, ...)
    /// @dev appeal() resets the tally but the vote RECORDS are keyed by address, so without
    ///      a round every round-1 voter stayed permanently marked as having voted and an
    ///      appealed case could never reach MINIMUM_VOTES again. See _voteKey().
    mapping(uint256 => uint256) private _caseRound;

    // ============================================
    // BOUNDED APPEAL WINDOW (v2.2 — appended)
    // ============================================

    /// @notice Raw configured appeal window (slot 23). 0 = never configured.
    /// @dev PRIVATE for exactly the reason _enforcementWindow is. Read it through
    ///      appealWindow() or _appealWindowEffective(), never directly: a proxy upgraded from
    ///      an earlier implementation has never written this slot, so the raw value is 0 while
    ///      the contract actually applies APPEAL_WINDOW_DEFAULT. A public auto-getter here
    ///      would report "no appeal window configured" about a contract enforcing 7 days —
    ///      the precise defect a reviewer caught on enforcementWindow().
    uint256 private _appealWindow;

    /// @notice caseId => the instant its exclusive appeal right lapses (0 = none recorded)
    /// @dev Written when executeResolution records REJECTED; cleared when appeal() reopens the
    ///      case. uint256 rather than the uint48 used by _enforcementEndsAt because a mapping
    ///      value occupies a whole slot either way, so narrowing buys nothing and only adds a
    ///      truncation edge to reason about.
    mapping(uint256 => uint256) private _appealDeadline;

    // ============================================
    // PAUSE-AWARE APPEAL WINDOW (v2.3 — appended)
    // ============================================
    //
    // WHY THIS EXISTS. appeal() carries whenNotPaused and _appealDeadline is an absolute
    // wall-clock instant that nothing ever extended. Before the window shipped the appeal
    // right was unbounded, so a pause merely DELAYED it; with the window a pause that
    // outlasts it CONSUMES it outright — and the claimant already paid a 50% slash to earn
    // that right. It is reachable two ways: owner pause(), and the CircuitBreaker auto-trip
    // inside initiateRecovery/appeal, which calls _pause() DIRECTLY. The breaker's 4-hour
    // cooldown does NOT clear Pausable — only unpause() (onlyOwner) does — so ordinary
    // volume can pause the contract and the owner would have to notice and unpause within
    // the window or the right is gone. That directly contradicted the rule this codebase
    // states in executeResolution and in KNOWN-ISSUES KI-25 item 6: a tripped breaker can
    // never trap a bond.
    //
    // THE FIX, in O(1) with no iteration over cases: the window counts UNPAUSED seconds.
    // The contract accrues a global pause credit, each rejection records the credit reading
    // at that instant, and the effective deadline is the recorded wall-clock deadline plus
    // whatever credit accrued afterwards. Both _pause() and _unpause() are overridden, so
    // the breaker's direct _pause() is covered along with the external pause().

    /// @notice Timestamp the current pause began (slot 25); 0 while the contract is unpaused
    /// @dev Written by the _pause()/_unpause() overrides, which is what covers BOTH pause
    ///      paths. A contract already paused by an implementation that predates this slot
    ///      reads 0 here while paused; the overrides handle that explicitly rather than
    ///      crediting the whole Unix epoch.
    uint256 private _pausedAt;

    /// @notice Cumulative seconds this contract has spent paused, all time (slot 26)
    /// @dev Monotonically non-decreasing. Only closed pauses are counted here; a pause in
    ///      progress is added on the fly by _appealDeadlineEffective().
    uint256 private _pauseCredit;

    /// @notice caseId => the _pauseCredit reading when the case was REJECTED, PLUS ONE (slot 27)
    /// @dev OFFSET BY ONE ON PURPOSE. A raw 0 would be ambiguous: it is both "rejected when no
    ///      pause had ever occurred" and "rejected by an implementation that predates this
    ///      slot and never recorded anything". Reading the second as the first would hand a
    ///      pre-upgrade case the ENTIRE pause credit accrued since the upgrade — a right it
    ///      was never granted. With the offset, 0 means unambiguously "never recorded" and
    ///      _pauseCreditSince() returns 0 credit for it, so such a case keeps exactly the
    ///      wall-clock deadline it was given. See _pauseCreditSince() for the residual that
    ///      leaves and why it is bounded.
    mapping(uint256 => uint256) private _pauseCreditAtRejection;

    /// @notice Storage gap for future upgrades
    /// @dev Reduced from 37: -2 (_enforcementWindow, _enforcementEndsAt) -1 (_caseRound)
    ///      -2 (_appealWindow, _appealDeadline) -3 (_pausedAt, _pauseCredit,
    ///      _pauseCreditAtRejection). The contract still ends at slot 56 — 57 slots, the
    ///      footprint it has always had.
    uint256[29] private __gap;

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
        _enforcementWindow = ENFORCEMENT_WINDOW_DEFAULT;
        _appealWindow = APPEAL_WINDOW_DEFAULT;
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
     * @dev Opens a bonded dispute over an asset that TAGITCore already reports as
     *      FLAGGED. This function does NOT flag the asset and cannot: TAGITRecovery
     *      holds no CapabilityBadge. Creates the case and locks the stake bond.
     * @param tokenId The asset token ID to recover
     * @param evidenceHash IPFS hash of supporting evidence
     * @return caseId The ID of the created recovery case
     * @custom:security ReentrancyGuard prevents reentrancy
     * @custom:security Stake bond is collected LAST, after every state change (CEI):
     *                  effects run in the EFFECTS block, the safeTransferFrom is the final statement
     * @custom:security Entry to quarantine is exactly as hard as exit — a FLAGGER must
     *                  freeze the asset first, so AIRP never creates a freeze it cannot release
     * @custom:emits RecoveryInitiated, AssetQuarantined
     */
    function initiateRecovery(uint256 tokenId, bytes32 evidenceHash)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 caseId)
    {
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

        // Check no active case exists for this token.
        //
        // THE RULE THIS IMPLEMENTS: every status that still OWNS _tokenToCase[tokenId] must
        // be listed here, and a status owns the link for exactly as long as the code says it
        // does. Four statuses own it unconditionally (PENDING, VOTING, ENFORCING, APPEALED)
        // and one owns it for a bounded time (REJECTED, until its appeal window lapses).
        //
        // ENFORCING is the one that mattered first: an ENFORCING case still holds an escrowed
        // bond and still owns the link. Omitting it let a second bonded case silently repoint
        // the link, and the decoy's own terminal path then erased the live case's link and
        // switched isQuarantined() off for an asset that was still FLAGGED.
        //
        // APPEALED is listed for forward-compatibility only. It is a same-transaction
        // transient: appeal() writes it and overwrites it with VOTING before returning, with
        // no external call in between, so no reader can ever observe it at rest.
        //
        // REJECTED is non-terminal — appeal() reopens it — and it now KEEPS the link for the
        // length of its appeal window. It used to release the link the instant it was
        // rejected, which handed the claimant's own appeal right to whoever front-ran the
        // freed slot: executeResolution is permissionless but appeal() is claimant-only, so an
        // EOA appellant could not atomically expire a decoy and appeal in one transaction and
        // the slot could be re-occupied indefinitely, for gas. Once the window lapses the link
        // is stale and is released HERE, lazily — nobody has to call a cleanup function, so a
        // slot can never be left locked by an absent keeper.
        uint256 existingCase = _tokenToCase[tokenId];
        if (existingCase != 0) {
            CaseStatus existingStatus = _cases[existingCase].status;
            if (
                existingStatus == CaseStatus.PENDING || existingStatus == CaseStatus.VOTING
                    || existingStatus == CaseStatus.ENFORCING || existingStatus == CaseStatus.APPEALED
            ) {
                revert ActiveCaseExists(tokenId, existingCase);
            }
            if (existingStatus == CaseStatus.REJECTED) {
                // The EFFECTIVE deadline, never the raw slot: appeal() consults the very
                // same private helper, so the guard and the appeal right are exact
                // complements at every instant. If these two ever read different numbers
                // there is an interval in which nobody may open a case and the claimant may
                // not appeal either — the asset's dispute slot would be dead.
                // A helper result of 0 means no window was ever recorded (the legacy
                // carve-out appeal() honours); such a case never held anyone's slot, so the
                // link is stale and is released here.
                uint256 appealEndsAt = _appealDeadlineEffective(existingCase);
                if (block.timestamp <= appealEndsAt) {
                    revert ActiveCaseExists(tokenId, existingCase);
                }
                _unlinkToken(existingCase, tokenId);
            }
        }

        // Read the asset from TAGITCore (view only — AIRP never writes to Core)
        (address holder,, ITAGITCoreRecovery.State st,,) = ITAGITCoreRecovery(core).getAsset(tokenId);
        if (holder == address(0)) revert InvalidTokenId(tokenId);

        // Quarantine IS TAGITCore's FLAGGED state. A case may only exist over an asset that
        // is already frozen: transferAsset() requires CLAIMED, claim() requires ACTIVATED,
        // and _update() blocks every external ERC-721 transfer. AIRP neither creates nor
        // releases the freeze — entry to quarantine stays exactly as hard as exit.
        if (st != ITAGITCoreRecovery.State.FLAGGED) revert AssetNotQuarantined(tokenId);

        // Mirror TAGITCore.resolve()'s OWN predicate exactly. resolve() computes
        //     restored = (stored == BOUND || ACTIVATED || CLAIMED) ? stored : CLAIMED
        // and only reassigns to a new owner when `restored == CLAIMED`. So the set of
        // pre-flag states AIRP can actually deliver is {CLAIMED, NONE}: a token flagged
        // BEFORE the _preFlagState upgrade shipped stores NONE, and resolve() treats NONE
        // as CLAIMED and delivers it without complaint. Rejecting NONE here would lock
        // every legacy-flagged asset out of AIRP while resolve() would have honoured it.
        // BOUND/ACTIVATED stay rejected: resolve() refuses to reassign those to anyone but
        // their current owner, so such a case could never deliver and taking a bond for it
        // would recreate the very bug this design fixes.
        ITAGITCoreRecovery.State pre = ITAGITCoreRecovery(core).preFlagState(tokenId);
        if (pre != ITAGITCoreRecovery.State.CLAIMED && pre != ITAGITCoreRecovery.State.NONE) {
            revert AssetNotRecoverable(tokenId, uint8(pre));
        }

        address currentHolder = holder;

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

        // Mirror TAGITCore's ALREADY-EXISTING freeze into the local case index. AIRP does
        // not quarantine anything and cannot: a FLAGGER froze this asset before the check
        // above would pass, and AIRP holds no capability to create or release that freeze.
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
    function submitEvidence(uint256 caseId, bytes32 evidenceHash) external nonReentrant whenNotPaused {
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
     * @notice Cast a vote in the current round of a recovery case
     * @dev Only AIRP juror-seat holders can vote, weighted by seat. Vote records are keyed
     *      by (caseId, round): one vote per address PER ROUND, so an appeal genuinely
     *      reopens the case to the same jurors instead of locking them out for good.
     * @param caseId The recovery case ID
     * @param approve True to approve return to claimant, false to reject
     * @param reasonHash Optional IPFS hash of vote rationale
     * @custom:security Seat-gated voting on the soulbound IdentityBadge (ids 70-73)
     * @custom:security Double-vote prevention within a round
     * @custom:emits VoteCast
     */
    function vote(uint256 caseId, bool approve, bytes32 reasonHash) external nonReentrant whenNotPaused {
        // ============================================
        // CHECKS
        // ============================================
        RecoveryCase storage recoveryCase = _cases[caseId];
        if (recoveryCase.status == CaseStatus.NONE) revert CaseNotFound(caseId);

        // Case must be in voting status
        if (recoveryCase.status != CaseStatus.VOTING) {
            revert InvalidCaseStatus(caseId, recoveryCase.status, CaseStatus.VOTING);
        }

        // Voting period must not have ended. The error is VotingPeriodEnded, not
        // VotingStillActive: the old name asserted the exact opposite of the condition
        // it fired on. VotingStillActive keeps its correct meaning in executeResolution().
        if (block.timestamp > recoveryCase.votingEndsAt) {
            revert VotingPeriodEnded(caseId, recoveryCase.votingEndsAt);
        }

        // Cannot vote twice IN THIS ROUND. Keying on the round is what lets an appealed
        // case reach quorum again: appeal() resets the tally, and without a round bump the
        // round-1 voters stayed marked forever and round 2 could never reach MINIMUM_VOTES.
        uint256 voteKey = _voteKey(caseId, _caseRound[caseId]);
        if (_hasVoted[voteKey][msg.sender]) {
            revert AlreadyVoted(caseId, msg.sender);
        }

        // Parties to the dispute cannot adjudicate their own dispute
        if (msg.sender == recoveryCase.claimant || msg.sender == recoveryCase.currentHolder) {
            revert NotAuthorized(msg.sender);
        }

        // Get vote weight (reverts if no badge)
        uint256 weight = _getVoteWeight(msg.sender);
        if (weight == 0) revert NotBadgeHolder(msg.sender);

        // ============================================
        // EFFECTS
        // ============================================
        _hasVoted[voteKey][msg.sender] = true;
        _votes[voteKey][msg.sender] = Vote({approve: approve, weight: weight, reasonHash: reasonHash});

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
     * @dev Tallies the vote and settles the bond.
     *
     *      This function does NOT transfer the asset and cannot. TAGITRecovery holds no
     *      capability in TAGITCore. An approved verdict is an instruction to the 2-of-3
     *      resolver quorum; custody moves only when two RESOLVER_CAPABILITY holders call
     *      approveResolve() and one calls resolve().
     *
     *      Three outcomes:
     *      - fewer than MINIMUM_VOTES cast  -> EXPIRED. Refunded in full from
     *        FEE_EXEMPT_MIN_VOTES votes up (voter apathy is not claimant fraud); refunded
     *        less SQUAT_FEE_RATE on FEWER THAN TWO, because a case that never drew plural
     *        engagement still took the asset's only dispute slot for the whole voting
     *        period. Before this change such a case could never leave VOTING and its bond
     *        was locked forever; the 100%-refund fix that replaced the lock made squatting
     *        free, and the fee is what closes that. Two, not one: a single vote is
     *        purchasable from a single juror seat, so keying the exemption on one vote left
     *        the fee dodgeable by anyone who controlled, rented or bribed one seat.
     *      - approval below APPROVAL_THRESHOLD -> REJECTED, 50% slash (the only path that
     *        ever slashes: an actual adverse vote). The token link is NOT released here —
     *        the case keeps it for the length of its appeal window.
     *      - approval at or above the threshold -> ENFORCING, bond stays escrowed.
     *
     *      All three hold for an APPEALED case too. Every branch settles exactly
     *      `stakeBond`, and appeal() REPLACES that field rather than adding to it, so the
     *      amount subtracted from totalStakesHeld is always the amount actually escrowed.
     * @param caseId The recovery case ID
     * @custom:security ReentrancyGuard prevents reentrancy
     * @custom:security Checks-Effects-Interactions pattern
     * @custom:security Deliberately NOT whenNotPaused — a tripped circuit breaker must
     *                  never trap an escrowed bond. Entry points (initiateRecovery, vote,
     *                  appeal) are paused; exit paths are not.
     * @custom:emits CaseResolved, CaseExpired, ResolutionPending, StakeSlashed, StakeReturned,
     *               AntiSquatFeeCharged, AppealWindowOpened
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

        // ============================================
        // EFFECTS
        // ============================================
        uint256 tokenId = recoveryCase.tokenId;
        uint256 stakeBond = recoveryCase.stakeBond;
        address claimant = recoveryCase.claimant;

        // ---- No-quorum branch: terminal EXPIRED, no SLASH ever ----
        // vote() is closed after votingEndsAt and appeal() only accepts REJECTED, so a
        // case that never reached MINIMUM_VOTES had no reachable exit before this branch.
        // _releaseEscrowAsExpired is the ONE settlement path for an EXPIRED case — shared
        // with expireEnforcement / abandonEnforcement — so the anti-squat fee cannot be
        // present on one expiry path and missing from another.
        if (recoveryCase.voteCount < MINIMUM_VOTES) {
            _releaseEscrowAsExpired(caseId);
            return;
        }

        // Calculate approval percentage
        uint256 totalVotes = recoveryCase.votesFor + recoveryCase.votesAgainst;
        bool approved = false;
        if (totalVotes > 0) {
            uint256 approvalRate = (recoveryCase.votesFor * BASIS_POINTS) / totalVotes;
            approved = approvalRate >= APPROVAL_THRESHOLD;
        }

        if (!approved) {
            // ---- REJECTED: 50% slash, the only path that ever slashes. NOT terminal —
            //      appeal() reopens a REJECTED case into a new voting round with a fresh
            //      2x bond, which is why this branch settles the bond COMPLETELY: appeal()
            //      starts from zero escrow, not from a remainder. The asset stays FLAGGED,
            //      exactly as AIRP found it — AIRP makes no state-changing call into
            //      TAGITCore.
            //
            //      The token link is deliberately NOT released. This branch used to call
            //      _unlinkToken, which freed the asset's only dispute slot in the same
            //      transaction that created the claimant's appeal right — and this function
            //      is permissionless while appeal() is claimant-only, so a third party could
            //      front-run the freed slot with a decoy case and keep the appeal
            //      unreachable indefinitely. The case now holds the slot for exactly
            //      _appealWindowEffective() seconds; initiateRecovery releases it lazily
            //      once that lapses.
            recoveryCase.status = CaseStatus.REJECTED;
            uint256 appealEndsAt = block.timestamp + _appealWindowEffective();
            _appealDeadline[caseId] = appealEndsAt;
            // Stamp the pause credit at this instant, offset by one so that a raw 0 can
            // only ever mean "recorded by an implementation that predates pause credit".
            // Everything the contract spends paused AFTER this point is added back to the
            // deadline, so the window measures unpaused seconds and a pause can no longer
            // eat an appeal right this branch just created.
            _pauseCreditAtRejection[caseId] = _creditNow() + 1;
            totalStakesHeld -= stakeBond;

            // ============================================
            // INTERACTIONS
            // ============================================
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

            emit AppealWindowOpened(caseId, tokenId, appealEndsAt);
            emit CaseResolved(
                caseId,
                CaseStatus.REJECTED,
                recoveryCase.currentHolder,
                recoveryCase.votesFor,
                recoveryCase.votesAgainst
            );
            return;
        }

        // ---- Approved: non-terminal ENFORCING. The bond stays escrowed and the token
        //      stays linked to the case until custody actually moves (or the window
        //      lapses). No CaseResolved here — the case is not resolved until then.
        recoveryCase.status = CaseStatus.ENFORCING;
        uint256 deadline = block.timestamp + _window();
        _enforcementEndsAt[caseId] = uint48(deadline);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit ResolutionPending(caseId, tokenId, claimant, deadline);
    }

    /**
     * @notice Settle an ENFORCING case by observing what TAGITCore actually did
     * @dev Permissionless. Reads TAGITCore through view functions only and never calls
     *      into it. If the asset is still FLAGGED the call reverts with the precise
     *      reason the quorum has not delivered yet, so a keeper can see what is missing.
     *      Once Core has acted, the bond is released 100% either way: RESOLVED when the
     *      claimant holds the asset, VOIDED when the resolvers diverged from the verdict.
     *      A machinery failure is never slashed.
     * @param caseId The recovery case ID
     * @custom:security ReentrancyGuard prevents reentrancy
     * @custom:security Not whenNotPaused — escrowed bonds must never be trapped by a breaker
     * @custom:security TAGITCore.resolve() uses _transfer (not _safeTransfer), so there is
     *                  no onERC721Received callback in the delivery path and a contract
     *                  claimant cannot deadlock its own case
     * @custom:emits ResolutionDelivered or CaseVoided, StakeReturned, CaseResolved
     */
    function finalizeResolution(uint256 caseId) external nonReentrant {
        // ============================================
        // CHECKS
        // ============================================
        RecoveryCase storage c = _cases[caseId];
        if (c.status == CaseStatus.NONE) revert CaseNotFound(caseId);
        if (c.status != CaseStatus.ENFORCING) {
            revert InvalidCaseStatus(caseId, c.status, CaseStatus.ENFORCING);
        }

        uint256 tokenId = c.tokenId;
        (,, ITAGITCoreRecovery.State st,,) = ITAGITCoreRecovery(core).getAsset(tokenId);

        if (st == ITAGITCoreRecovery.State.FLAGGED) {
            // Core has not acted yet. Surface exactly why so the caller can see what is missing.
            (uint256 n, address r,) = ITAGITCoreRecovery(core).getResolveApprovalStatus(tokenId);
            uint256 q = ITAGITCoreRecovery(core).RESOLVE_QUORUM();
            if (n < q) revert ResolverQuorumMissing(caseId, n, q);
            if (r != c.claimant) revert ResolverRecipientMismatch(caseId, c.claimant, r);
            // Quorum and recipient are both correct; resolve() has simply not been called.
            // Only claim the window is open while it actually is — past the deadline the
            // correct call is expireEnforcement, and saying "EnforcementActive" would state
            // the reverse of the truth to a keeper trying to work out why this refused.
            uint256 deadline = _enforcementEndsAt[caseId];
            if (block.timestamp > deadline) revert UseExpireEnforcement(caseId);
            revert EnforcementActive(caseId, deadline);
        }

        // Post-hoc assertion: trust the chain, not the call we asked someone else to make.
        address actual = IERC721(core).ownerOf(tokenId);

        // ============================================
        // EFFECTS (before any token transfer)
        // ============================================
        _unlinkToken(caseId, tokenId);
        _enforcementEndsAt[caseId] = 0;
        uint256 bond = c.stakeBond;
        totalStakesHeld -= bond;

        // ============================================
        // INTERACTIONS
        // ============================================
        // ACCEPTED EDGE CASE: if the claimant receives the asset and resells it via
        // transferAsset() before anyone finalizes, this records VOIDED instead of
        // RESOLVED. The money outcome is byte-identical (100% refund either way); only
        // the label differs. Ownership cannot change while FLAGGED, and initiateRecovery
        // forbids claimant == currentHolder, so no other divergence is reachable.
        if (actual == c.claimant) {
            c.status = CaseStatus.RESOLVED;
            token.safeTransfer(c.claimant, bond);
            emit StakeReturned(caseId, c.claimant, bond);
            emit ResolutionDelivered(caseId, tokenId, c.claimant);
            emit CaseResolved(caseId, CaseStatus.RESOLVED, c.claimant, c.votesFor, c.votesAgainst);
        } else {
            c.status = CaseStatus.VOIDED;
            token.safeTransfer(c.claimant, bond); // 100% — machinery failure is never slashed
            emit StakeReturned(caseId, c.claimant, bond);
            emit CaseVoided(caseId, tokenId, c.claimant, actual, uint8(st));
            emit CaseResolved(caseId, CaseStatus.VOIDED, actual, c.votesFor, c.votesAgainst);
        }
    }

    /**
     * @notice Release an ENFORCING case whose enforcement window elapsed unused
     * @dev Permissionless. If the resolver quorum never delivered within the window the
     *      claimant gets their whole bond back, unslashed. The asset remains FLAGGED —
     *      the exact state AIRP found it in.
     * @param caseId The recovery case ID
     * @custom:security ReentrancyGuard prevents reentrancy
     * @custom:security Not whenNotPaused — escrowed bonds must never be trapped by a breaker
     * @custom:emits StakeReturned, CaseExpired, CaseResolved
     */
    function expireEnforcement(uint256 caseId) external nonReentrant {
        // ============================================
        // CHECKS
        // ============================================
        RecoveryCase storage c = _cases[caseId];
        if (c.status == CaseStatus.NONE) revert CaseNotFound(caseId);
        if (c.status != CaseStatus.ENFORCING) {
            revert InvalidCaseStatus(caseId, c.status, CaseStatus.ENFORCING);
        }

        uint256 deadline = _enforcementEndsAt[caseId];
        if (block.timestamp <= deadline) revert EnforcementActive(caseId, deadline);

        // Core may have acted at the last moment — that case must be classified, not expired.
        (,, ITAGITCoreRecovery.State st,,) = ITAGITCoreRecovery(core).getAsset(c.tokenId);
        if (st != ITAGITCoreRecovery.State.FLAGGED) revert UseFinalizeResolution(caseId);

        // ============================================
        // EFFECTS + INTERACTIONS
        // ============================================
        _releaseEscrowAsExpired(caseId);
    }

    /**
     * @notice Let the claimant abandon their own ENFORCING case early
     * @dev Claimant-only, no deadline requirement. A claimant who no longer wants to wait
     *      for the resolver quorum can recover their whole bond at any time, unslashed.
     *      The asset remains FLAGGED.
     * @param caseId The recovery case ID
     * @custom:security ReentrancyGuard prevents reentrancy
     * @custom:security Not whenNotPaused — escrowed bonds must never be trapped by a breaker
     * @custom:emits StakeReturned, CaseExpired, CaseResolved
     */
    function abandonEnforcement(uint256 caseId) external nonReentrant {
        // ============================================
        // CHECKS
        // ============================================
        RecoveryCase storage c = _cases[caseId];
        if (c.status == CaseStatus.NONE) revert CaseNotFound(caseId);
        if (msg.sender != c.claimant) revert NotAuthorized(msg.sender);
        if (c.status != CaseStatus.ENFORCING) {
            revert InvalidCaseStatus(caseId, c.status, CaseStatus.ENFORCING);
        }

        // Core may already have delivered — that case must be classified, not abandoned.
        (,, ITAGITCoreRecovery.State st,,) = ITAGITCoreRecovery(core).getAsset(c.tokenId);
        if (st != ITAGITCoreRecovery.State.FLAGGED) revert UseFinalizeResolution(caseId);

        // ============================================
        // EFFECTS + INTERACTIONS
        // ============================================
        _releaseEscrowAsExpired(caseId);
    }

    /**
     * @notice Appeal a rejected case with a fresh, higher bond
     * @dev Round one has ALREADY been settled in full when this is reachable: the REJECTED
     *      branch of executeResolution() slashed 50% to the treasury, returned 50% to the
     *      claimant and subtracted the whole original bond from totalStakesHeld. Nothing of
     *      it is still escrowed. `stakeBond` is therefore REPLACED with the appeal bond,
     *      never accumulated onto the spent one: recording 3x while holding 2x made every
     *      round-two terminal path (EXPIRED, REJECTED, finalizeResolution,
     *      _releaseEscrowAsExpired) subtract more than the ledger held and revert with a
     *      checked-arithmetic panic, stranding the bond permanently — including after a WON
     *      appeal where TAGITCore had already delivered the asset.
     *
     *      Appealing also opens a NEW VOTING ROUND (_caseRound++). The tally reset alone was
     *      not enough: the per-voter records are keyed by address, so without a round bump
     *      every round-one juror stayed locked out and an appealed case could never reach
     *      MINIMUM_VOTES again — it necessarily fell into the EXPIRED branch and hit the
     *      underflow above.
     * @param caseId The recovery case ID
     * @param newEvidenceHash IPFS hash of appeal evidence
     * @custom:security Requires 2x the previous bond, paid in full up front
     * @custom:security Escrow solvency is asserted after the transfer: the contract must
     *                  hold at least what totalStakesHeld claims it holds
     * @custom:security Bounded in time, WITH ONE NAMED EXCEPTION. The case owns its token's
     *                  dispute slot from the moment it was REJECTED until
     *                  appealDeadlineEffective(caseId), and this function is callable over
     *                  exactly that interval — EXCEPT for the legacy carve-out below, where a
     *                  recorded deadline of 0 (a case rejected before the bounded window
     *                  shipped) leaves the appeal right unbounded, exactly as the code that
     *                  rejected it promised. See KNOWN-ISSUES KI-25 item 13.
     * @custom:security The deadline is PAUSE-AWARE. This function is whenNotPaused, so a
     *                  pause spanning the window would otherwise destroy an appeal right the
     *                  claimant paid a 50% slash to earn. The window counts unpaused seconds
     *                  only; the guard in initiateRecovery reads the same private helper, so
     *                  the two can never disagree about who owns the slot.
     * @custom:emits AppealFiled, AppealRoundOpened, AssetQuarantined
     */
    function appeal(uint256 caseId, bytes32 newEvidenceHash) external nonReentrant whenNotPaused {
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

        // Can only appeal rejected cases. REJECTED is the ONE non-terminal outcome that
        // reopens; this also makes RESOLVED, EXPIRED and VOIDED (terminal) and ENFORCING
        // (still in flight) un-appealable.
        if (recoveryCase.status != CaseStatus.REJECTED) {
            revert CannotAppeal(caseId, recoveryCase.status);
        }

        // The appeal right is bounded, and the token's dispute slot is held for exactly as
        // long as the right lasts. Past the deadline the slot belongs to whoever wants it
        // and this case can no longer reopen.
        //
        // LEGACY CARVE-OUT — a deadline of 0 means "no window was ever recorded". That is
        // only reachable for a case REJECTED by an implementation that predates this
        // window, which also released the token link immediately, so such a case never
        // occupied anyone's slot and closing its appeal right retroactively would be a
        // silent taking. It keeps the unbounded right the code gave it when it was
        // rejected. Every case rejected from here on gets a non-zero deadline, so this can
        // never widen the window for a new case.
        //
        // PAUSE CREDIT — the deadline consulted here is the EFFECTIVE one, extended by every
        // second the contract has spent paused since this case was rejected. This function
        // is whenNotPaused and the breaker can pause the contract by itself, so without the
        // credit an ordinary volume spike could consume the entire window while nobody was
        // able to act. initiateRecovery's active-case guard reads the SAME helper, so the
        // slot is held for exactly as long as the right lasts, to the second.
        uint256 appealEndsAt = _appealDeadlineEffective(caseId);
        if (appealEndsAt != 0 && block.timestamp > appealEndsAt) {
            revert AppealWindowClosed(caseId, appealEndsAt);
        }

        // The asset must still be frozen for a second round to be meaningful, and the
        // holder may have changed since the first round — the original appeal() carried
        // a stale currentHolder into round two.
        uint256 tokenId = recoveryCase.tokenId;
        (address nowHolder,, ITAGITCoreRecovery.State st,,) = ITAGITCoreRecovery(core).getAsset(tokenId);
        if (st != ITAGITCoreRecovery.State.FLAGGED) revert AssetNotQuarantined(tokenId);
        if (msg.sender == nowHolder) revert NotAuthorized(msg.sender);

        // Never steal the token link from a DIFFERENT live case. A case rejected under the
        // bounded window still HOLDS its own link, so within the window this is normally a
        // no-op — but it is exactly what stops the legacy carve-out above from letting an
        // old REJECTED case re-point a link that a new claimant has since taken. Two live
        // cases must never fight over one _tokenToCase entry.
        uint256 linkedCase = _tokenToCase[tokenId];
        if (linkedCase != 0 && linkedCase != caseId) revert ActiveCaseExists(tokenId, linkedCase);

        uint256 appealBond = recoveryCase.stakeBond * APPEAL_MULTIPLIER;
        uint256 newRound = _caseRound[caseId] + 1;

        // ============================================
        // EFFECTS
        // ============================================
        recoveryCase.currentHolder = nowHolder; // refresh: the original never did
        recoveryCase.status = CaseStatus.APPEALED;
        recoveryCase.evidenceHash = newEvidenceHash;
        recoveryCase.votingEndsAt = uint48(block.timestamp + votingDuration);
        // SET, never accumulate. Round one's bond has already been disbursed in full.
        recoveryCase.stakeBond = appealBond;
        recoveryCase.votesFor = 0;
        recoveryCase.votesAgainst = 0;
        recoveryCase.voteCount = 0;

        // Open a fresh voting round so round-one jurors may vote again on the new evidence.
        _caseRound[caseId] = newRound;

        // The window has served its purpose: the case is live again, not awaiting an appeal.
        // Leaving a stale deadline behind would have appealDeadline() report a pending
        // appeal right on a case that is back in VOTING. The pause-credit stamp is cleared
        // in the same breath — it is only meaningful next to a live deadline, and a stale
        // one would silently shorten the credit of a LATER rejection of this same case.
        _appealDeadline[caseId] = 0;
        _pauseCreditAtRejection[caseId] = 0;

        // Re-point the local case index at this case for round two. AIRP does not
        // re-quarantine anything: the asset was re-checked as FLAGGED above and only a
        // FLAGGER can create or release that freeze.
        _quarantined[tokenId] = true;
        _tokenToCase[tokenId] = caseId;

        // Update status to voting for appeal
        recoveryCase.status = CaseStatus.VOTING;

        totalStakesHeld += appealBond;

        // ============================================
        // INTERACTIONS
        // ============================================
        token.safeTransferFrom(msg.sender, address(this), appealBond);

        // Escrow solvency: the ledger must never claim more than the contract holds. This
        // is the invariant the 3x-recorded-vs-2x-held bug broke, asserted at the exact
        // point it was broken so it can never silently return.
        uint256 held = token.balanceOf(address(this));
        if (held < totalStakesHeld) revert EscrowUnderfunded(held, totalStakesHeld);

        emit AppealFiled(caseId, msg.sender, appealBond, newEvidenceHash);
        emit AppealRoundOpened(caseId, newRound, appealBond);
        emit AssetQuarantined(tokenId, caseId);
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
     * @dev Quarantine is not local bookkeeping — it IS TAGITCore's FLAGGED state. This
     *      reports true only if a case still OWNS the token's dispute slot AND TAGITCore
     *      still reports the asset as FLAGGED. A REJECTED case owns that slot until its
     *      appeal window lapses, so this stays true across the window and goes false when
     *      the stale link is released — lazily, by the next initiateRecovery.
     * @param tokenId The asset token ID
     * @return True if asset is quarantined
     */
    function isQuarantined(uint256 tokenId) external view returns (bool) {
        if (!_quarantined[tokenId] || _tokenToCase[tokenId] == 0) return false;
        (,, ITAGITCoreRecovery.State st,,) = ITAGITCoreRecovery(core).getAsset(tokenId);
        return st == ITAGITCoreRecovery.State.FLAGGED;
    }

    /**
     * @notice Get the enforcement deadline for a case
     * @param caseId The recovery case ID
     * @return The deadline timestamp (0 if the case is not ENFORCING)
     */
    function enforcementDeadline(uint256 caseId) external view returns (uint256) {
        return _enforcementEndsAt[caseId];
    }

    /**
     * @notice Get the enforcement window this contract actually applies
     * @dev Returns the EFFECTIVE value, not the raw slot. A proxy upgraded from v1 has
     *      never written the slot, so the old public auto-getter reported 0 while every
     *      new ENFORCING case was in fact given ENFORCEMENT_WINDOW_DEFAULT — off-chain
     *      consumers read that 0 as "no enforcement window configured". The selector is
     *      unchanged, so existing callers keep working and simply get the truth.
     * @return The configured window, or ENFORCEMENT_WINDOW_DEFAULT while unset
     */
    function enforcementWindow() public view returns (uint256) {
        return _window();
    }

    /**
     * @notice Get the raw configured enforcement window
     * @dev 0 means a governor has never called setEnforcementWindow() on this proxy. Use
     *      enforcementWindow() for the value the contract enforces.
     * @return The stored window, or 0 if never configured
     */
    function configuredEnforcementWindow() external view returns (uint256) {
        return _enforcementWindow;
    }

    /**
     * @notice Get the RAW instant recorded when a case was REJECTED
     * @dev NOT the deadline this contract enforces — appealDeadlineEffective() is. This is the
     *      wall-clock value written at rejection; the enforced instant is this one plus every
     *      second the contract has spent paused since, because appeal() is whenNotPaused. The
     *      two are equal only while no pause has occurred since the rejection.
     *
     *      0 means no window is recorded: the case was never REJECTED, appeal() has already
     *      reopened it, or it was rejected by an implementation that predates the bounded
     *      window (which appeal() still honours — see its legacy carve-out).
     * @param caseId The recovery case ID
     * @return The recorded deadline timestamp (0 if none recorded)
     */
    function appealDeadline(uint256 caseId) external view returns (uint256) {
        return _appealDeadline[caseId];
    }

    /**
     * @notice Get the instant a REJECTED case's appeal right lapses, AFTER pause credit
     * @dev THE NUMBER THE CONTRACT ACTUALLY ENFORCES. appealDeadline() returns the raw
     *      wall-clock instant recorded at rejection; this returns that instant pushed
     *      forward by every second the contract has spent paused since — including a pause
     *      still in progress. appeal() and initiateRecovery's active-case guard both consult
     *      the private helper behind this getter, so an off-chain consumer reading this sees
     *      exactly what the chain will do. Mirrors how appealWindow() exposes the effective
     *      window rather than the raw slot.
     *
     *      0 means no window is recorded: the case was never REJECTED, appeal() has already
     *      reopened it, or it predates the bounded window (which appeal() still honours as an
     *      unbounded right — see its legacy carve-out).
     * @param caseId The recovery case ID
     * @return The effective deadline timestamp (0 if none recorded)
     */
    function appealDeadlineEffective(uint256 caseId) external view returns (uint256) {
        return _appealDeadlineEffective(caseId);
    }

    /**
     * @notice Get the appeal window this contract actually applies
     * @dev Returns the EFFECTIVE value, not the raw slot, for the same reason
     *      enforcementWindow() does: a proxy upgraded from an implementation that predates
     *      this slot has never written it, so a raw getter would report 0 — "no appeal
     *      window configured" — about a contract that is in fact giving every rejected
     *      claimant 7 days.
     * @return The configured window, or APPEAL_WINDOW_DEFAULT while unset
     */
    function appealWindow() public view returns (uint256) {
        return _appealWindowEffective();
    }

    /**
     * @notice Get the raw configured appeal window
     * @dev 0 means a governor has never called setAppealWindow() on this proxy. Use
     *      appealWindow() for the value the contract enforces.
     * @return The stored window, or 0 if never configured
     */
    function configuredAppealWindow() external view returns (uint256) {
        return _appealWindow;
    }

    /**
     * @notice Get the current voting round of a case
     * @dev 0 is the original round; appeal() increments it. Vote records are keyed by
     *      (caseId, round), so a round-one juror may vote again in round two.
     * @param caseId The recovery case ID
     * @return The current round number
     */
    function caseRound(uint256 caseId) external view returns (uint256) {
        return _caseRound[caseId];
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
     * @notice Check if address has voted in the CURRENT round of a case
     * @dev Scoped to the live round on purpose: this is what vote() enforces. Use
     *      hasVotedInRound() to inspect a closed round.
     * @param caseId The recovery case ID
     * @param voter The address to check
     * @return True if voter has already voted in the current round
     */
    function hasVoted(uint256 caseId, address voter) external view returns (bool) {
        return _hasVoted[_voteKey(caseId, _caseRound[caseId])][voter];
    }

    /**
     * @notice Check if address voted in a specific round of a case
     * @param caseId The recovery case ID
     * @param round The round number (0 = the original round)
     * @param voter The address to check
     * @return True if voter voted in that round
     */
    function hasVotedInRound(uint256 caseId, uint256 round, address voter) external view returns (bool) {
        return _hasVoted[_voteKey(caseId, round)][voter];
    }

    /**
     * @notice Get vote details for a voter in the CURRENT round of a case
     * @param caseId The recovery case ID
     * @param voter The voter address
     * @return The Vote struct
     */
    function getVote(uint256 caseId, address voter) external view returns (Vote memory) {
        return _votes[_voteKey(caseId, _caseRound[caseId])][voter];
    }

    /**
     * @notice Get vote details for a voter in a specific round of a case
     * @param caseId The recovery case ID
     * @param round The round number (0 = the original round)
     * @param voter The voter address
     * @return The Vote struct
     */
    function getVoteInRound(uint256 caseId, uint256 round, address voter) external view returns (Vote memory) {
        return _votes[_voteKey(caseId, round)][voter];
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
        return "2.0.0";
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
     * @notice Update core contract address
     * @param newCore New TAGITCore address
     * @custom:security Only owner can call
     * @custom:emits CoreUpdated
     */
    function setCore(address newCore) external onlyOwner {
        if (newCore == address(0)) revert ZeroAddress();
        address oldCore = core;
        core = newCore;
        emit CoreUpdated(oldCore, newCore);
    }

    /**
     * @notice Update token contract address
     * @param newToken New TAGITToken address
     * @custom:security Only owner can call
     * @custom:emits TokenUpdated
     */
    function setToken(address newToken) external onlyOwner {
        if (newToken == address(0)) revert ZeroAddress();
        address oldToken = address(token);
        token = IERC20(newToken);
        emit TokenUpdated(oldToken, newToken);
    }

    /**
     * @notice Update voting duration
     * @param newDuration New voting duration in seconds
     * @custom:security Only governor can call
     * @custom:emits VotingDurationUpdated
     */
    function setVotingDuration(uint256 newDuration) external onlyGovernor {
        if (newDuration == 0) revert InvalidParameterValue("votingDuration", 0);
        uint256 oldDuration = votingDuration;
        votingDuration = newDuration;
        emit VotingDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Update minimum stake requirement
     * @dev FLOORED AT MINIMUM_STAKE_FLOOR. Any value below BASIS_POINTS / SQUAT_FEE_RATE
     *      makes (bond * SQUAT_FEE_RATE) / BASIS_POINTS truncate to zero, so the anti-squat
     *      fee would stop existing with no revert, no event and no other signal — squatting
     *      would silently be free again while every document still said it costs 10%. Both
     *      window setters were already bounded; this one, which the whole anti-squat
     *      economics rest on, was not.
     * @param newMinimumStake New minimum stake amount, at least MINIMUM_STAKE_FLOOR
     * @custom:security Only governor can call
     * @custom:emits MinimumStakeUpdated
     */
    function setMinimumStake(uint256 newMinimumStake) external onlyGovernor {
        if (newMinimumStake == 0) revert InvalidParameterValue("minimumStake", 0);
        if (newMinimumStake < MINIMUM_STAKE_FLOOR) {
            revert MinimumStakeBelowFloor(newMinimumStake, MINIMUM_STAKE_FLOOR);
        }
        uint256 oldStake = minimumStake;
        minimumStake = newMinimumStake;
        emit MinimumStakeUpdated(oldStake, newMinimumStake);
    }

    /**
     * @notice Update the enforcement window for approved verdicts
     * @param newWindow New window in seconds, within [7 days, 365 days]
     * @custom:security Only governor can call
     * @custom:emits EnforcementWindowUpdated
     */
    function setEnforcementWindow(uint256 newWindow) external onlyGovernor {
        if (newWindow < ENFORCEMENT_WINDOW_MIN || newWindow > ENFORCEMENT_WINDOW_MAX) {
            revert InvalidEnforcementWindow(newWindow);
        }
        uint256 old = _window();
        _enforcementWindow = newWindow;
        emit EnforcementWindowUpdated(old, newWindow);
    }

    /**
     * @notice Update the window in which a REJECTED case may still be appealed
     * @dev Applies to cases rejected from here on. A case already in its window keeps the
     *      deadline recorded at its rejection, so nobody's appeal right can be shortened
     *      out from under them by a governance action taken mid-window.
     * @param newWindow New window in seconds, within [1 day, 30 days]
     * @custom:security Only governor can call
     * @custom:emits AppealWindowUpdated
     */
    function setAppealWindow(uint256 newWindow) external onlyGovernor {
        if (newWindow < APPEAL_WINDOW_MIN || newWindow > APPEAL_WINDOW_MAX) {
            revert InvalidAppealWindow(newWindow);
        }
        uint256 old = _appealWindowEffective();
        _appealWindow = newWindow;
        emit AppealWindowUpdated(old, newWindow);
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

    /**
     * @notice Start the clock on a pause, whoever started it
     * @dev OVERRIDDEN RATHER THAN HOOKED INTO pause(). The CircuitBreaker auto-trip inside
     *      initiateRecovery() and appeal() calls _pause() DIRECTLY, so hooking only the
     *      external owner-only pause() would leave the exact path that made this urgent
     *      completely unfixed — ordinary volume can pause this contract with nobody's
     *      permission. Overriding the internal function is what covers both.
     *
     *      super._pause() carries whenNotPaused, so it reverts on a redundant pause before
     *      _pausedAt is touched: an already-running pause can never have its start time
     *      reset forward, which would silently discard the credit accrued so far.
     */
    function _pause() internal virtual override {
        super._pause();
        _pausedAt = block.timestamp;
    }

    /**
     * @notice Bank the seconds this pause cost, so the appeal window can give them back
     * @dev super._unpause() carries whenPaused, so this can only run on a real transition.
     *
     *      The _pausedAt == 0 guard is NOT dead code: a proxy that was already paused by an
     *      implementation predating slot 25 reads 0 there, and crediting
     *      block.timestamp - 0 would hand every open appeal window fifty-odd years. Such a
     *      pause simply contributes no credit — its start time is not recoverable, and
     *      inventing one is worse than declining to.
     */
    function _unpause() internal virtual override {
        super._unpause();
        uint256 startedAt = _pausedAt;
        if (startedAt != 0) {
            _pauseCredit += block.timestamp - startedAt;
            _pausedAt = 0;
        }
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
    function setRateLimitConfig(uint64 maxPerWindow, uint64 windowDuration, uint64 cooldownDuration, uint64 globalMax)
        external
        onlyGovernor
    {
        RateLimiter.updateConfig(_rateLimitConfig, maxPerWindow, windowDuration, cooldownDuration, globalMax);
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
    function getCircuitBreakerState()
        external
        view
        returns (uint64 count, uint64 windowStart, bool tripped, uint64 cooldownEnds)
    {
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
    function getUserRateLimitState(address user)
        external
        view
        returns (uint64 count, uint64 windowStart, uint64 lockedUntil)
    {
        return RateLimiter.getUserState(_rateLimitStates, user);
    }

    /**
     * @notice Check remaining actions before rate limit
     * @param user User address to query
     * @return canAct_ Whether user can perform action
     * @return remaining Actions remaining in current window
     * @return lockedUntil Lockout end timestamp (0 = not locked)
     */
    function getRemainingActions(address user)
        external
        view
        returns (bool canAct_, uint256 remaining, uint256 lockedUntil)
    {
        return _rateLimitConfig.canAct(_rateLimitStates, user);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Resolve the effective enforcement window
     * @dev Zero-fallback rather than a reinitializer. A proxy upgraded from v1 has never
     *      written _enforcementWindow, so it reads 0; without this fallback every ENFORCING
     *      case created immediately after the upgrade would be instantly expirable. A
     *      reinitializer(2) would fix it only if someone remembered to call it — a missed
     *      call is unsafe, a zero-fallback cannot be missed.
     * @return The configured window, or ENFORCEMENT_WINDOW_DEFAULT when unset
     */
    function _window() private view returns (uint256) {
        uint256 w = _enforcementWindow;
        return w == 0 ? ENFORCEMENT_WINDOW_DEFAULT : w;
    }

    /**
     * @notice Resolve the effective appeal window
     * @dev The same zero-fallback as _window(), for the same reason. A proxy upgraded from
     *      an implementation that predates this slot reads 0; without the fallback every
     *      case rejected right after the upgrade would get a deadline of exactly
     *      block.timestamp — an appeal right that expires in the transaction that creates
     *      it, which is the D2 grief this window exists to close. A reinitializer would fix
     *      it only if somebody remembered to call it; a fallback cannot be missed.
     * @return The configured window, or APPEAL_WINDOW_DEFAULT when unset
     */
    function _appealWindowEffective() private view returns (uint256) {
        uint256 w = _appealWindow;
        return w == 0 ? APPEAL_WINDOW_DEFAULT : w;
    }

    /**
     * @notice Seconds of pause time a REJECTED case is owed since it was rejected
     * @dev O(1) and iterates over nothing. `_pauseCreditAtRejection` stores the credit
     *      reading at rejection OFFSET BY ONE, so a stored 0 means "never recorded" —
     *      unambiguously distinct from "recorded when the credit happened to be 0".
     *
     *      A CASE REJECTED BEFORE THIS UPGRADE therefore gets ZERO credit, not the whole
     *      historical balance. Treating its unwritten 0 as a genuine baseline would extend a
     *      right that was never contingent on pauses by however long the contract had been
     *      paused since — an arbitrary, unbounded grant nobody voted for. The residual is
     *      that such a case can still lose its window to a long pause, exactly as it could
     *      before this change; it is bounded by the fact that the live deployment has opened
     *      ZERO cases (nextCaseId() == 1), so the set of affected cases is empty.
     * @param caseId The recovery case ID
     * @return The credit, in seconds, including a pause still in progress
     */
    function _pauseCreditSince(uint256 caseId) private view returns (uint256) {
        uint256 mark = _pauseCreditAtRejection[caseId];
        if (mark == 0) return 0;
        return _creditNow() - (mark - 1);
    }

    /**
     * @notice Cumulative seconds this contract has spent paused, AS OF NOW
     * @dev Counts a pause still in progress, which `_pauseCredit` alone does not — that field
     *      is only banked by `_unpause()`. Both the stamp taken at rejection and the credit
     *      read afterwards go through THIS function, which is what makes the arithmetic sound:
     *      the baseline and the reading are measured the same way, so a pause already running
     *      when a case is rejected sits INSIDE the baseline instead of being added to it.
     *
     *      Stamping raw `_pauseCredit` instead credited a case every second of an overlapping
     *      pause that elapsed BEFORE its window existed, and the eventual unpause banked that
     *      over-credit permanently — an unbounded extension of the dispute-slot lock, reachable
     *      with no privileged actor because executeResolution is deliberately not whenNotPaused.
     *
     *      Monotonically non-decreasing, so `_creditNow() - (mark - 1)` can never underflow.
     * @return Paused seconds to date, including any pause currently in progress
     */
    function _creditNow() private view returns (uint256) {
        uint256 pausedAt = _pausedAt;
        return pausedAt == 0 ? _pauseCredit : _pauseCredit + (block.timestamp - pausedAt);
    }

    /**
     * @notice The instant a REJECTED case's appeal right actually lapses
     * @dev THE SINGLE SOURCE OF TRUTH, consulted by appeal(), by initiateRecovery()'s
     *      active-case guard and by the public appealDeadlineEffective(). One helper, three
     *      readers: the guard and the appeal right are exact complements by construction
     *      rather than by two conditions that have to be kept in step by hand.
     *
     *      The window therefore measures UNPAUSED seconds. Credit is always at most the wall
     *      time elapsed since the rejection, so this can never resurrect a window that
     *      already lapsed in fully-unpaused time — it can only refuse to count time in which
     *      appeal() was unreachable.
     *
     *      Returns 0 when nothing is recorded, which every reader treats as "no bounded
     *      window": the guard releases the stale link, appeal() falls through to its legacy
     *      carve-out. A 0 is never a deadline of the Unix epoch.
     * @param caseId The recovery case ID
     * @return The effective deadline (0 if no window is recorded)
     */
    function _appealDeadlineEffective(uint256 caseId) private view returns (uint256) {
        uint256 recorded = _appealDeadline[caseId];
        if (recorded == 0) return 0;
        return recorded + _pauseCreditSince(caseId);
    }

    /**
     * @notice Namespace a case's vote records by voting round
     * @dev Round 0 keeps the RAW caseId, so every record written before appeal rounds
     *      existed — and every value already stored on the live proxy — keeps reading from
     *      exactly the slots it always did. Later rounds get a keccak-derived namespace,
     *      which cannot collide with a sequential caseId in practice. Keying the records
     *      this way is what lets an appealed case reach quorum: appeal() reset the tally
     *      but not the per-address records, so round-one jurors were locked out for good.
     * @param caseId The recovery case ID
     * @param round The voting round (0 = original)
     * @return The key under which _votes / _hasVoted are stored for that round
     */
    function _voteKey(uint256 caseId, uint256 round) private pure returns (uint256) {
        return round == 0 ? caseId : uint256(keccak256(abi.encode(caseId, round)));
    }

    /**
     * @notice Release the token -> case link, but only if it still points at THIS case
     * @dev Defence in depth behind initiateRecovery()'s active-case guard. The guard is
     *      the fix; this is what survives someone adding a new non-terminal CaseStatus and
     *      forgetting to list it there. An unconditional clear let a stale or decoy case
     *      erase a LIVE case's link and switch isQuarantined() off for an asset TAGITCore
     *      still reports as FLAGGED.
     * @param caseId The case that is terminating
     * @param tokenId The asset it was opened over
     */
    function _unlinkToken(uint256 caseId, uint256 tokenId) private {
        if (_tokenToCase[tokenId] == caseId) {
            _tokenToCase[tokenId] = 0;
            _quarantined[tokenId] = false;
        }
    }

    /**
     * @notice The ONE settlement path for a case that terminates as EXPIRED
     * @dev Shared by every EXPIRED exit — the no-quorum branch of executeResolution,
     *      expireEnforcement and abandonEnforcement — so the anti-squat fee cannot be
     *      present on one expiry path and quietly missing from another. Never slashes: a
     *      slash means a jury voted against the claimant, and no jury did here.
     *
     *      THE FEE. A case that expires having drawn FEWER THAN FEE_EXEMPT_MIN_VOTES votes
     *      pays SQUAT_FEE_RATE of its recorded bond to the treasury and keeps the rest.
     *      Opening a case takes an asset's only dispute slot for the whole voting period; a
     *      100% refund on no engagement made that free and infinitely repeatable, so anyone
     *      who was not the current holder could lock the real owner out of AIRP for
     *      votingDuration, take the entire bond back, and do it again for gas.
     *
     *      THE THRESHOLD IS TWO, NOT ONE. Keyed on voteCount == 0 the fee was dodgeable:
     *      vote() excludes only the claimant and the current holder, so ONE address holding
     *      a single juror seat that a griefer controls, rents or bribes could cast one vote
     *      per decoy and tip every case into the carve-out below. One vote is purchasable
     *      from one seat; two requires two independently-granted seats to collude.
     *
     *      A case that drew two or more votes pays NOTHING — it is still below MINIMUM_VOTES
     *      (3) and still EXPIRES, but that is voter apathy, not claimant conduct. The
     *      threshold sits strictly below quorum precisely so that carve-out survives.
     *
     *      On the two ENFORCEMENT exits the fee is unreachable by construction rather than
     *      by a second condition: ENFORCING is only entered from the approved branch of
     *      executeResolution, which is past the voteCount >= MINIMUM_VOTES test. The rule
     *      lives here anyway so that the single expiry path states it once.
     *
     *      The asset remains FLAGGED — the state AIRP found it in.
     * @param caseId The recovery case ID (caller has already validated status/authority)
     * @custom:emits AntiSquatFeeCharged, StakeReturned, CaseExpired, CaseResolved
     */
    function _releaseEscrowAsExpired(uint256 caseId) private {
        RecoveryCase storage c = _cases[caseId];
        uint256 tokenId = c.tokenId;
        uint256 bond = c.stakeBond;
        address claimant = c.claimant;

        uint256 fee = c.voteCount < FEE_EXEMPT_MIN_VOTES ? (bond * SQUAT_FEE_RATE) / BASIS_POINTS : 0;
        uint256 refund = bond - fee;

        // ============================================
        // EFFECTS
        // ============================================
        c.status = CaseStatus.EXPIRED;
        _unlinkToken(caseId, tokenId);
        _enforcementEndsAt[caseId] = 0;
        // Clear the appeal bookkeeping HERE, beside the enforcement deadline it was already
        // clearing. It was safe to omit only because appeal() is the sole exit from REJECTED
        // and zeroes the deadline itself — an invariant enforced 550 lines away, in another
        // function, which is exactly the kind of long-range coupling that rots. Clearing it
        // locally costs two zero-writes and makes this function's postcondition — "this case
        // holds nothing further" — true on its own terms.
        _appealDeadline[caseId] = 0;
        _pauseCreditAtRejection[caseId] = 0;
        totalStakesHeld -= bond;

        // ============================================
        // INTERACTIONS
        // ============================================
        // fee + refund == bond exactly, so nothing is stranded on either branch.
        if (fee > 0) {
            token.safeTransfer(treasury, fee);
            emit AntiSquatFeeCharged(caseId, claimant, fee, treasury);
        }
        if (refund > 0) {
            token.safeTransfer(claimant, refund);
            emit StakeReturned(caseId, claimant, refund);
        }
        emit CaseExpired(caseId, tokenId, refund);
        emit CaseResolved(caseId, CaseStatus.EXPIRED, c.currentHolder, c.votesFor, c.votesAgainst);
    }

    /**
     * @notice Calculate vote weight based on badges
     * @dev Checks badges in order of weight (highest first).
     *
     *      Voting weight is read from the SOULBOUND IdentityBadge (ERC-5192), never from
     *      CapabilityBadge. CapabilityBadge is a transferable ERC-1155 with no _update
     *      override, and _hasVoted is keyed by address, so capability-based weights let one
     *      badge be walked through N addresses to manufacture a unanimous verdict.
     *
     *      hasIdentity() is zero-trust: it returns false (never reverts) when TAGITAccess
     *      has no IdentityBadge configured, so an unwired deployment yields weight 0 and
     *      every vote reverts NotBadgeHolder — fail-closed.
     *
     *      The four ids read here are AIRP-SPECIFIC seats in the reserved 70-79 range of the
     *      IdentityBadge registry. They are NOT KYC_L1/L2 (1/2), NOT MANUFACTURER (10) and
     *      NOT GOV_MIL (20): reusing those would make every KYC'd account in the protocol an
     *      AIRP juror able to vote a claimant's bond away. A juror seat is granted
     *      deliberately, one badge at a time, by the IdentityBadge owner.
     * @param voter Address to check
     * @return weight Vote weight (0 if no AIRP juror badge)
     */
    function _getVoteWeight(address voter) internal view returns (uint256 weight) {
        // Check seats in order of weight (highest first)
        // Tribunal = 4x
        if (access.hasIdentity(voter, BADGE_AIRP_TRIBUNAL)) {
            return 4;
        }
        // Arbiter = 3x
        if (access.hasIdentity(voter, BADGE_AIRP_ARBITER)) {
            return 3;
        }
        // Senior juror = 2x
        if (access.hasIdentity(voter, BADGE_AIRP_SENIOR_JUROR)) {
            return 2;
        }
        // Juror = 1x
        if (access.hasIdentity(voter, BADGE_AIRP_JUROR)) {
            return 1;
        }
        // No AIRP seat = 0 (cannot vote)
        return 0;
    }

    /**
     * @notice Authorize upgrade (owner only)
     * @param newImplementation New implementation address
     * @custom:security Only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
