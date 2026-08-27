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
     * @dev NONE is default (case doesn't exist), others represent case lifecycle.
     *      Members 0-5 are frozen for ABI/indexer compatibility; 6-8 are appended.
     *
     *      TERMINAL: RESOLVED, EXPIRED, VOIDED. Nothing reopens these.
     *      NON-TERMINAL: PENDING, VOTING, APPEALED, ENFORCING — and REJECTED, which
     *      appeal() reopens into a new voting round with a fresh 2x bond, but only
     *      within a BOUNDED appeal window. A REJECTED case keeps its token's dispute
     *      slot for appealWindow() seconds and then releases it; see appealDeadline().
     */
    enum CaseStatus {
        NONE, // 0 - Case doesn't exist
        PENDING, // 1 - UNREACHABLE. Frozen for ABI compat; initiateRecovery opens directly in VOTING.
        VOTING, // 2 - Voting period active
        RESOLVED, // 3 - TERMINAL. Approved AND delivered: TAGITCore.resolve() moved the asset
        REJECTED, // 4 - Rejected, asset stays with holder. NOT terminal: appeal() reopens it within its window.
        APPEALED, // 5 - Transient marker set inside appeal() before round two opens as VOTING
        ENFORCING, // 6 - Vote approved; awaiting the 2-of-3 resolver quorum to move custody
        // 7 - TERMINAL: no quorum of votes, or resolvers never acted. THE BOND IS NOT ALWAYS FULLY
        // REFUNDED on this member: it refunds in full only from FEE_EXEMPT_MIN_VOTES (2) votes up.
        // An expiry that drew FEWER THAN TWO votes pays the SQUAT_FEE_RATE anti-squat fee to the
        // treasury first — see AntiSquatFeeCharged, and CaseExpired.bondReturned, which carries the
        // NET amount the claimant actually received rather than the recorded bond.
        EXPIRED,
        VOIDED // 8 - TERMINAL: custody left AIRP's expected path. Bond fully refunded.
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Recovery case data structure
     * @dev Packed for gas efficiency where possible
     */
    struct RecoveryCase {
        uint256 tokenId; // Asset in dispute
        address claimant; // Who initiated recovery
        address currentHolder; // Current NFT owner at initiation
        bytes32 evidenceHash; // Initial evidence IPFS hash
        uint48 createdAt; // Case creation timestamp
        uint48 votingEndsAt; // Voting deadline
        CaseStatus status; // Current case status
        uint256 stakeBond; // Claimant's staked collateral
        uint256 votesFor; // Weighted votes approving return to claimant
        uint256 votesAgainst; // Weighted votes rejecting claim
        uint256 voteCount; // Total number of votes cast
    }

    /**
     * @notice Individual vote record
     */
    struct Vote {
        bool approve; // true = return to claimant
        uint256 weight; // Badge-weighted vote power
        bytes32 reasonHash; // Optional rationale (IPFS hash)
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================
    //
    // ABI POLICY: every error declared here is reachable from TAGITRecovery. Errors that
    // no code path can revert are DELETED rather than kept for shape, matching the removal
    // of CannotTransferQuarantined — a declared-but-unreachable error is dead code that
    // misleads an auditor into believing an enforcement path exists. Removed in this
    // change (7): QuorumNotReached, InsufficientStake, VotingNotOpen,
    // AssetAlreadyQuarantined, InsufficientAppealBond, CircuitBreakerTripped,
    // RateLimitExceeded. The last two were shadows: the real reverts come from
    // CircuitBreaker.CircuitBreakerTripped(uint256) and
    // RateLimiter.RateLimitExceeded(address,uint256), which have DIFFERENT signatures, so
    // the copies here could never decode an actual revert.
    //
    // The CircuitTripped / CircuitReset / RateLimitHit EVENTS below are NOT dead: the
    // libraries emit them with identical signatures from this contract's context, so their
    // topic0 really does appear in TAGITRecovery logs. Do not "clean" them.

    /// @notice Case ID does not exist
    error CaseNotFound(uint256 caseId);

    /// @notice Token ID is invalid (zero or doesn't exist)
    error InvalidTokenId(uint256 tokenId);

    /// @notice A governor-supplied configuration value was zero or out of range
    /// @dev Distinct from InvalidTokenId, which these setters previously misused: a governor
    ///      who mistyped a duration was told their token ID was bad.
    /// @param name The parameter that was rejected
    /// @param value The offending value
    error InvalidParameterValue(string name, uint256 value);

    /// @notice Evidence hash is invalid (zero)
    error InvalidEvidenceHash();

    /// @notice Voting period is still active (executeResolution called before votingEndsAt)
    error VotingStillActive(uint256 caseId, uint256 endsAt);

    /// @notice Voting period has already closed (vote cast after votingEndsAt)
    /// @dev Distinct from VotingStillActive, which is its exact opposite. vote() used to
    ///      revert VotingStillActive on a CLOSED period — a name that stated the reverse
    ///      of the condition it fired on.
    error VotingPeriodEnded(uint256 caseId, uint256 endsAt);

    /// @notice Caller has already voted on this case
    error AlreadyVoted(uint256 caseId, address voter);

    /// @notice Caller does not hold required badge for voting
    error NotBadgeHolder(address caller);

    /// @notice Asset is not quarantined (TAGITCore does not report it as FLAGGED)
    error AssetNotQuarantined(uint256 tokenId);

    /// @notice Case is not in expected status
    error InvalidCaseStatus(uint256 caseId, CaseStatus current, CaseStatus required);

    /// @notice Caller is not authorized for this action
    error NotAuthorized(address caller);

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Asset already has active recovery case
    error ActiveCaseExists(uint256 tokenId, uint256 existingCaseId);

    /// @notice Case cannot be appealed (wrong status)
    error CannotAppeal(uint256 caseId, CaseStatus status);

    /// @notice The escrow ledger claims more than the contract actually holds
    /// @dev Asserted after appeal() collects its bond. `totalStakesHeld` must never exceed
    ///      the token balance; the pre-fix appeal() recorded 3x while collecting 2x, which
    ///      made every round-two terminal path panic and stranded the bond forever.
    error EscrowUnderfunded(uint256 held, uint256 recorded);

    /// @notice Asset was flagged from a state TAGITCore.resolve() can never reassign
    /// @dev resolve() reassigns to a new owner only when the restored state is CLAIMED. It
    ///      computes `restored = (stored is BOUND|ACTIVATED|CLAIMED) ? stored : CLAIMED`, so
    ///      a pre-flag marker of NONE — a token flagged before the marker shipped — is
    ///      treated as CLAIMED and IS deliverable. Only BOUND and ACTIVATED are rejected:
    ///      those must resolve back to their CURRENT owner, so such a case could never
    ///      deliver and taking a bond for it would be dishonest.
    error AssetNotRecoverable(uint256 tokenId, uint8 preFlagState);

    /// @notice TAGITCore's 2-of-3 resolver quorum has not been reached for this token
    error ResolverQuorumMissing(uint256 caseId, uint256 approvals, uint256 required);

    /// @notice Resolvers bound a recipient other than the party the vote awarded
    error ResolverRecipientMismatch(uint256 caseId, address expected, address approved);

    /// @notice Enforcement window is still open (or Core has simply not acted yet)
    error EnforcementActive(uint256 caseId, uint256 deadline);

    /// @notice TAGITCore already acted on this token — settle via finalizeResolution()
    error UseFinalizeResolution(uint256 caseId);

    /// @notice The enforcement window has lapsed; finalizeResolution can no longer settle this case
    /// @dev Mirrors UseFinalizeResolution. Reached when the resolver quorum was satisfied and the
    ///      recipient matched but resolve() was never called, and the deadline has since passed.
    ///      Previously this state reverted EnforcementActive, which asserted the window was open
    ///      at a moment when it was not.
    /// @param caseId The recovery case ID
    error UseExpireEnforcement(uint256 caseId);

    /// @notice Enforcement window outside [ENFORCEMENT_WINDOW_MIN, ENFORCEMENT_WINDOW_MAX]
    error InvalidEnforcementWindow(uint256 provided);

    /// @notice The bounded appeal window of a REJECTED case has lapsed
    /// @dev A REJECTED case owns its token's dispute slot for exactly appealWindow() seconds
    ///      after the rejection. Past `deadline` the slot is released to any new claimant
    ///      (lazily, inside initiateRecovery) and this case can no longer reopen.
    /// @param caseId The recovery case ID
    /// @param deadline The instant the appeal right lapsed
    error AppealWindowClosed(uint256 caseId, uint256 deadline);

    /// @notice Appeal window outside [APPEAL_WINDOW_MIN, APPEAL_WINDOW_MAX]
    error InvalidAppealWindow(uint256 provided);

    /// @notice A governor tried to set minimumStake below the floor the anti-squat fee needs
    /// @dev Any bond below BASIS_POINTS / SQUAT_FEE_RATE makes the fee truncate to zero, so
    ///      squatting would become free again with no revert, no event and no other signal.
    ///      Both window setters were already bounded; this parameter was not.
    /// @param provided The rejected value
    /// @param floor The smallest value on which the anti-squat fee is still non-zero
    error MinimumStakeBelowFloor(uint256 provided, uint256 floor);

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
    event EvidenceSubmitted(uint256 indexed caseId, address indexed submitter, bytes32 evidenceHash);

    /// @notice Emitted when vote is cast
    event VoteCast(uint256 indexed caseId, address indexed voter, bool approve, uint256 weight, bytes32 reasonHash);

    /// @notice Emitted when a case reaches an outcome
    /// @dev NOT necessarily terminal. RESOLVED, EXPIRED and VOIDED are terminal; REJECTED
    ///      is NOT — appeal() reopens a REJECTED case into a new voting round, so a single
    ///      caseId can emit CaseResolved more than once and a consumer must treat the
    ///      LATEST one as authoritative.
    ///      `awardedTo` is the party the case ended in favour of; for RESOLVED this is the
    ///      confirmed on-chain owner. Renaming the parameter (was `winner`) does not change
    ///      the event signature, so topic0 and existing indexers are unaffected.
    event CaseResolved(
        uint256 indexed caseId, CaseStatus outcome, address awardedTo, uint256 votesFor, uint256 votesAgainst
    );

    /// @notice Emitted when a bonded case opens (or reopens on appeal) over an asset that
    ///         TAGITCore ALREADY reports as FLAGGED
    /// @dev AIRP does not quarantine anything and cannot: quarantine IS TAGITCore's FLAGGED
    ///      state, a FLAGGER must have frozen the asset before a case is admissible, and
    ///      TAGITRecovery holds no capability to create or release that freeze. This records
    ///      that a case now covers an already-frozen asset — not that a freeze was applied.
    event AssetQuarantined(uint256 indexed tokenId, uint256 indexed caseId);

    /// @notice Emitted when an appeal opens a new voting round on an existing case
    /// @dev Vote records are keyed by (caseId, round), so every VoteCast after this event
    ///      belongs to `round`. Consumers that tally VoteCast per case must partition by
    ///      round or they will mix a closed round into a live one.
    event AppealRoundOpened(uint256 indexed caseId, uint256 indexed round, uint256 bond);

    /// @notice Emitted when a vote approves a claim and the case enters ENFORCING
    /// @dev The asset has NOT moved. This is an instruction to TAGITCore's 2-of-3
    ///      resolver quorum to call approveResolve()/resolve() before `deadline`.
    event ResolutionPending(
        uint256 indexed caseId, uint256 indexed tokenId, address indexed awardedTo, uint256 deadline
    );

    /// @notice Emitted when TAGITCore is observed to have delivered the asset to the claimant
    event ResolutionDelivered(uint256 indexed caseId, uint256 indexed tokenId, address indexed awardedTo);

    /// @notice Emitted when custody left AIRP's expected path (resolvers diverged from the verdict)
    event CaseVoided(
        uint256 indexed caseId, uint256 indexed tokenId, address expectedRecipient, address actualOwner, uint8 coreState
    );

    /// @notice Emitted when a case terminates as EXPIRED
    /// @dev `bondReturned` is the amount the claimant ACTUALLY received, net of the
    ///      anti-squat fee. It equals the whole bond on every path except a case that
    ///      expired having drawn FEWER THAN TWO votes, where SQUAT_FEE_RATE of the bond went
    ///      to the treasury and a matching AntiSquatFeeCharged was emitted immediately before
    ///      this.
    event CaseExpired(uint256 indexed caseId, uint256 indexed tokenId, uint256 bondReturned);

    /// @notice Emitted when a case that drew FEWER THAN TWO votes pays the anti-squat fee on expiry
    /// @dev DISTINCT FROM StakeSlashed on purpose. StakeSlashed means "a jury voted against
    ///      you"; this means "you opened a bonded case, occupied an asset's only dispute slot
    ///      for the whole voting period, and never drew plural engagement". It is a fee on
    ///      absent engagement, not a finding of fraud. A case that drew TWO or more votes —
    ///      still below MINIMUM_VOTES (3), so still EXPIRED — pays NOTHING: voter apathy is
    ///      not the claimant's fault, and that distinction is the entire point of the fee.
    ///      The bar is two rather than one because vote() excludes only the claimant and the
    ///      current holder, so a single juror seat a griefer controls, rents or bribes could
    ///      supply one vote per decoy and exempt every squat.
    /// @param caseId The recovery case ID
    /// @param claimant The party that opened the case and paid the fee
    /// @param amount The fee taken from the recorded bond
    /// @param treasury The address the fee was sent to
    event AntiSquatFeeCharged(uint256 indexed caseId, address indexed claimant, uint256 amount, address treasury);

    /// @notice Emitted when a REJECTED case starts its bounded, exclusive appeal window
    /// @dev While the window is open the case keeps _tokenToCase[tokenId], so initiateRecovery
    ///      reverts ActiveCaseExists for anyone else and only this case's claimant may appeal.
    ///      After it the slot is free and is unlinked lazily by the next initiateRecovery.
    ///
    ///      `deadline` IS THE RAW WALL-CLOCK INSTANT RECORDED AT REJECTION, AND THE CONTRACT MAY
    ///      ENFORCE A LATER ONE. The window counts UNPAUSED seconds, so every second spent paused
    ///      after this event pushes the enforced instant out, and nothing is emitted when that
    ///      happens. A consumer that treats this value as final will call a window closed while
    ///      appeal() still accepts it — read appealDeadlineEffective(caseId) for the enforced
    ///      number and appealDeadline(caseId) for the raw one this event carries.
    event AppealWindowOpened(uint256 indexed caseId, uint256 indexed tokenId, uint256 deadline);

    /// @notice Emitted when the enforcement window is updated
    event EnforcementWindowUpdated(uint256 oldWindow, uint256 newWindow);

    /// @notice Emitted when the appeal window is updated
    /// @dev `oldWindow` is the EFFECTIVE value that was in force, not the raw slot: on a proxy
    ///      that never configured one the slot reads 0 while APPEAL_WINDOW_DEFAULT applies.
    ///      Already-rejected cases keep the deadline recorded at their rejection; this changes
    ///      only cases rejected from here on.
    event AppealWindowUpdated(uint256 oldWindow, uint256 newWindow);

    /// @notice Emitted when stake is slashed
    event StakeSlashed(uint256 indexed caseId, address indexed claimant, uint256 amount, address treasury);

    /// @notice Emitted when stake is returned
    event StakeReturned(uint256 indexed caseId, address indexed claimant, uint256 amount);

    /// @notice Emitted when appeal is filed
    event AppealFiled(uint256 indexed caseId, address indexed appellant, uint256 newBond, bytes32 newEvidenceHash);

    /// @notice Emitted when governor is updated
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    /// @notice Emitted when treasury is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when core contract is updated
    event CoreUpdated(address indexed oldCore, address indexed newCore);

    /// @notice Emitted when token contract is updated
    event TokenUpdated(address indexed oldToken, address indexed newToken);

    /// @notice Emitted when voting duration is updated
    event VotingDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice Emitted when minimum stake is updated
    event MinimumStakeUpdated(uint256 oldStake, uint256 newStake);

    /// @notice Emitted when circuit breaker trips
    event CircuitTripped(uint256 indexed timestamp, uint256 count, uint256 threshold, uint256 cooldownEnds);

    /// @notice Emitted when circuit breaker resets
    event CircuitReset(uint256 indexed timestamp, uint256 previousCooldownEnds);

    /// @notice Emitted when rate limit is hit
    event RateLimitHit(address indexed user, uint256 count, uint256 lockedUntil);

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Initiate a recovery claim for a disputed asset
     * @dev Opens a bonded dispute over an asset that is ALREADY FLAGGED in TAGITCore.
     *      Does NOT flag the asset and cannot: TAGITRecovery holds no capability in
     *      TAGITCore.
     * @param tokenId The asset token ID to recover
     * @param evidenceHash IPFS hash of supporting evidence
     * @return caseId The ID of the created recovery case
     */
    function initiateRecovery(uint256 tokenId, bytes32 evidenceHash) external returns (uint256 caseId);

    /**
     * @notice Submit additional evidence to an active case
     * @dev Only claimant or current holder can submit
     * @param caseId The recovery case ID
     * @param evidenceHash IPFS hash of additional evidence
     */
    function submitEvidence(uint256 caseId, bytes32 evidenceHash) external;

    /**
     * @notice Cast a vote on a recovery case
     * @dev Only badge holders can vote, weighted by badge level
     * @param caseId The recovery case ID
     * @param approve True to approve return to claimant, false to reject
     * @param reasonHash Optional IPFS hash of vote rationale
     */
    function vote(uint256 caseId, bool approve, bytes32 reasonHash) external;

    /**
     * @notice Execute resolution after voting period ends
     * @dev Tallies the vote and settles the bond. Does NOT transfer the asset and
     *      cannot. An approved verdict moves the case to ENFORCING and instructs
     *      TAGITCore's 2-of-3 resolver quorum; custody is moved only by
     *      TAGITCore.resolve().
     *
     *      A case below MINIMUM_VOTES terminates as EXPIRED. It refunds in full from two
     *      votes up, and refunds all but SQUAT_FEE_RATE on fewer than two — see
     *      AntiSquatFeeCharged. A REJECTED case keeps its token's dispute slot until its
     *      appeal window lapses; it is not unlinked here.
     * @param caseId The recovery case ID
     */
    function executeResolution(uint256 caseId) external;

    /**
     * @notice Settle an ENFORCING case by observing what TAGITCore actually did
     * @dev Permissionless. Reads TAGITCore only; never writes to it. Records RESOLVED
     *      when the claimant holds the asset, VOIDED otherwise. Both refund 100%.
     * @param caseId The recovery case ID
     */
    function finalizeResolution(uint256 caseId) external;

    /**
     * @notice Release an ENFORCING case whose enforcement window elapsed unused
     * @dev Permissionless. Full, unslashed refund. The asset remains FLAGGED.
     * @param caseId The recovery case ID
     */
    function expireEnforcement(uint256 caseId) external;

    /**
     * @notice Let the claimant abandon their own ENFORCING case early
     * @dev Claimant-only. Full, unslashed refund. The asset remains FLAGGED.
     * @param caseId The recovery case ID
     */
    function abandonEnforcement(uint256 caseId) external;

    /**
     * @notice Appeal a rejected case with a fresh, higher bond
     * @dev Requires 2x the previous stake and opens a NEW voting round. The asset must
     *      still be FLAGGED. The recorded bond is REPLACED, not accumulated: round one was
     *      already disbursed (50% slashed, 50% returned) before the case became appealable.
     *      Only callable while the case's appeal window is open — see
     *      appealDeadlineEffective(), which is the deadline the contract enforces — WITH ONE
     *      EXCEPTION: a case rejected before the bounded window shipped has no recorded
     *      deadline and keeps the unbounded appeal right the code gave it at the time. That
     *      legacy carve-out is documented in KNOWN-ISSUES KI-25 item 13.
     * @param caseId The recovery case ID
     * @param newEvidenceHash IPFS hash of appeal evidence
     */
    function appeal(uint256 caseId, bytes32 newEvidenceHash) external;

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
     * @dev True only if a case still OWNS the token's dispute slot AND TAGITCore reports
     *      the asset is FLAGGED. A REJECTED case owns that slot until its appeal window
     *      lapses, so this stays true across the window.
     * @param tokenId The asset token ID
     * @return True if asset is quarantined
     */
    function isQuarantined(uint256 tokenId) external view returns (bool);

    /**
     * @notice Get the RAW instant recorded when a case was REJECTED
     * @dev NOT the deadline the contract enforces — use appealDeadlineEffective() for that.
     *      This is the wall-clock value written at rejection; the enforced instant is this one
     *      plus every second the contract has spent paused since. 0 means no window is
     *      recorded: the case was never REJECTED, was reopened by appeal(), or was rejected
     *      before the bounded window shipped.
     * @param caseId The recovery case ID
     * @return The recorded deadline timestamp (0 if none recorded)
     */
    function appealDeadline(uint256 caseId) external view returns (uint256);

    /**
     * @notice Get the instant a REJECTED case's appeal right lapses, AFTER pause credit
     * @dev THE NUMBER THE CONTRACT ENFORCES. appealDeadline() is the raw wall-clock instant
     *      recorded at rejection; this is that instant pushed forward by every second the
     *      contract has spent paused since, because appeal() is whenNotPaused and a pause
     *      spanning the window would otherwise destroy a right the claimant paid a 50% slash
     *      to earn. appeal() and initiateRecovery's active-case guard read the same value, so
     *      they are exact complements. 0 means no window is recorded.
     * @param caseId The recovery case ID
     * @return The effective deadline timestamp (0 if none recorded)
     */
    function appealDeadlineEffective(uint256 caseId) external view returns (uint256);

    /**
     * @notice Get the appeal window this contract actually applies
     * @dev Returns the EFFECTIVE value, not the raw slot — a proxy upgraded from an earlier
     *      implementation has never written it, so the raw slot reads 0 while the contract
     *      in fact applies APPEAL_WINDOW_DEFAULT.
     * @return The configured window, or APPEAL_WINDOW_DEFAULT while unset
     */
    function appealWindow() external view returns (uint256);

    /**
     * @notice Get the raw configured appeal window
     * @dev 0 means a governor has never called setAppealWindow() on this proxy. Use
     *      appealWindow() for the value the contract enforces.
     * @return The stored window, or 0 if never configured
     */
    function configuredAppealWindow() external view returns (uint256);

    /**
     * @notice Get the enforcement deadline for a case
     * @param caseId The recovery case ID
     * @return The deadline timestamp (0 if the case is not ENFORCING)
     */
    function enforcementDeadline(uint256 caseId) external view returns (uint256);

    /**
     * @notice Get active case ID for an asset
     * @param tokenId The asset token ID
     * @return caseId The active case ID (0 if none)
     */
    function getActiveCaseForToken(uint256 tokenId) external view returns (uint256);

    /**
     * @notice Get the current voting round of a case
     * @dev 0 is the original round; each appeal() increments it.
     * @param caseId The recovery case ID
     * @return The current round number
     */
    function caseRound(uint256 caseId) external view returns (uint256);

    /**
     * @notice Check if address has voted in the CURRENT round of a case
     * @param caseId The recovery case ID
     * @param voter The address to check
     * @return True if voter has already voted in the current round
     */
    function hasVoted(uint256 caseId, address voter) external view returns (bool);

    /**
     * @notice Check if address voted in a specific round of a case
     * @param caseId The recovery case ID
     * @param round The round number (0 = the original round)
     * @param voter The address to check
     * @return True if voter voted in that round
     */
    function hasVotedInRound(uint256 caseId, uint256 round, address voter) external view returns (bool);

    /**
     * @notice Get vote details for a voter in the CURRENT round of a case
     * @param caseId The recovery case ID
     * @param voter The voter address
     * @return The Vote struct
     */
    function getVote(uint256 caseId, address voter) external view returns (Vote memory);

    /**
     * @notice Get vote details for a voter in a specific round of a case
     * @param caseId The recovery case ID
     * @param round The round number (0 = the original round)
     * @param voter The voter address
     * @return The Vote struct
     */
    function getVoteInRound(uint256 caseId, uint256 round, address voter) external view returns (Vote memory);

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
