// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {TAGITRecovery} from "../../src/recovery/TAGITRecovery.sol";
import {IRecovery} from "../../src/interfaces/IRecovery.sol";
import {ITAGITCoreRecovery} from "../../src/interfaces/ITAGITCoreRecovery.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {IIdentityBadge} from "../../src/interfaces/IIdentityBadge.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITRecoveryV1Layout} from "./TAGITRecoveryV1Layout.sol";

/**
 * @title TAGITRecoveryVerdictTest
 * @notice Regression suite for TAGIT-VDP-2026-001 — "AIRP is an adjudicator, not a custodian".
 * @dev The pre-fix executeResolution() ran the entire dispute flow (bonded claim,
 *      badge-weighted voting, 66% threshold, 50% slashing) and then never moved the NFT.
 *      These tests pin the replacement: flag-gated cases, verdict-bound execution, escrow
 *      until delivery, and the trust boundary that makes it auditable.
 */
contract TAGITRecoveryVerdictTest is Test {
    // ============================================
    // EVENTS (mirrored from IRecovery for expectEmit)
    // ============================================

    event RecoveryInitiated(
        uint256 indexed caseId,
        uint256 indexed tokenId,
        address indexed claimant,
        address currentHolder,
        uint256 stakeBond,
        bytes32 evidenceHash
    );
    event AssetQuarantined(uint256 indexed tokenId, uint256 indexed caseId);
    event CaseResolved(
        uint256 indexed caseId, IRecovery.CaseStatus outcome, address awardedTo, uint256 votesFor, uint256 votesAgainst
    );
    event ResolutionPending(
        uint256 indexed caseId, uint256 indexed tokenId, address indexed awardedTo, uint256 deadline
    );
    event ResolutionDelivered(uint256 indexed caseId, uint256 indexed tokenId, address indexed awardedTo);
    event CaseVoided(
        uint256 indexed caseId, uint256 indexed tokenId, address expectedRecipient, address actualOwner, uint8 coreState
    );
    event CaseExpired(uint256 indexed caseId, uint256 indexed tokenId, uint256 bondReturned);
    event EnforcementWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event StakeSlashed(uint256 indexed caseId, address indexed claimant, uint256 amount, address treasury);
    event AntiSquatFeeCharged(uint256 indexed caseId, address indexed claimant, uint256 amount, address treasury);
    event AppealWindowOpened(uint256 indexed caseId, uint256 indexed tokenId, uint256 deadline);
    event AppealWindowUpdated(uint256 oldWindow, uint256 newWindow);

    // ============================================
    // CONTRACTS
    // ============================================

    TAGITRecovery public recovery;
    TAGITCore public core;
    TAGITAccess public access;
    CapabilityBadge public capabilityBadge;
    IdentityBadge public identityBadge;
    TAGITToken public token;

    // ============================================
    // ADDRESSES
    // ============================================

    address public owner;
    address public governor;
    address public treasury;
    address public manufacturer;
    address public holder;
    address public claimant;
    address public verifier;
    address public certifiedVerifier;
    address public governanceVoter;
    address public randomUser;
    address public resolverA;
    address public resolverB;
    address public thirdParty;
    address public buyer;

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 public constant MINIMUM_STAKE = 100e18;
    uint256 public constant VOTING_DURATION = 7 days;
    uint256 public constant ENFORCEMENT_WINDOW = 30 days;
    uint256 public constant APPEAL_WINDOW = 7 days;
    /// @dev 10% of the recorded bond, charged when a case expires with FEWER THAN
    ///      FEE_EXEMPT_MIN_VOTES votes
    uint256 public constant SQUAT_FEE = (MINIMUM_STAKE * 1000) / 10000;

    /// @dev Votes a case must draw to be exempt from the anti-squat fee (TAGITRecovery.FEE_EXEMPT_MIN_VOTES)
    uint256 public constant FEE_EXEMPT_MIN_VOTES = 2;
    bytes32 public constant EVIDENCE_HASH = keccak256("evidence");
    bytes32 public constant REASON_HASH = keccak256("reason");
    uint256 constant ORACLE_PK = 0xA11CE;

    // AIRP jury seats live in the reserved 70-79 IdentityBadge range. They are NOT
    // KYC_L1/L2 (1/2), MANUFACTURER (10) or GOV_MIL (20): reusing those ids would make
    // every KYC'd account in the protocol an AIRP juror able to slash a claimant's bond.
    uint256 public constant BADGE_AIRP_JUROR = 70;
    uint256 public constant BADGE_AIRP_SENIOR_JUROR = 71;
    uint256 public constant BADGE_AIRP_ARBITER = 72;
    uint256 public constant BADGE_AIRP_TRIBUNAL = 73;

    bytes32 public constant MINTER_CAPABILITY = keccak256("MINTER");
    bytes32 public constant BINDER_CAPABILITY = keccak256("BINDER");
    bytes32 public constant ACTIVATOR_CAPABILITY = keccak256("ACTIVATOR");
    bytes32 public constant CLAIMER_CAPABILITY = keccak256("CLAIMER");
    bytes32 public constant FLAGGER_CAPABILITY = keccak256("FLAGGER");
    bytes32 public constant RESOLVER_CAPABILITY = keccak256("RESOLVER");

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        treasury = makeAddr("treasury");
        manufacturer = makeAddr("manufacturer");
        holder = makeAddr("holder");
        claimant = makeAddr("claimant");
        verifier = makeAddr("verifier");
        certifiedVerifier = makeAddr("certifiedVerifier");
        governanceVoter = makeAddr("governanceVoter");
        randomUser = makeAddr("randomUser");
        resolverA = makeAddr("resolverA");
        resolverB = makeAddr("resolverB");
        thirdParty = makeAddr("thirdParty");
        buyer = makeAddr("buyer");

        vm.startPrank(owner);

        TAGITCore coreImpl = new TAGITCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), abi.encodeCall(TAGITCore.initialize, (owner)));
        core = TAGITCore(address(coreProxy));

        access = new TAGITAccess();
        capabilityBadge = new CapabilityBadge();
        access.setCapabilityBadge(address(capabilityBadge));
        identityBadge = new IdentityBadge();
        access.setIdentityBadge(address(identityBadge));

        core.setAccessController(address(access));
        core.setTrustedOracle(vm.addr(ORACLE_PK));
        core.setFlagCircuitBreakerThreshold(500);

        TAGITToken tokenImpl = new TAGITToken();
        ERC1967Proxy tokenProxy =
            new ERC1967Proxy(address(tokenImpl), abi.encodeCall(TAGITToken.initialize, (owner, treasury)));
        token = TAGITToken(address(tokenProxy));

        TAGITRecovery recoveryImpl = new TAGITRecovery();
        ERC1967Proxy recoveryProxy = new ERC1967Proxy(
            address(recoveryImpl),
            abi.encodeCall(
                TAGITRecovery.initialize, (address(core), address(access), address(token), governor, treasury, owner)
            )
        );
        recovery = TAGITRecovery(address(recoveryProxy));

        capabilityBadge.grantCapability(manufacturer, uint256(MINTER_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(BINDER_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(ACTIVATOR_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(CLAIMER_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(FLAGGER_CAPABILITY));

        // Two independent human resolvers satisfy TAGITCore's 2-of-3 quorum.
        capabilityBadge.grantCapability(resolverA, uint256(RESOLVER_CAPABILITY));
        capabilityBadge.grantCapability(resolverB, uint256(RESOLVER_CAPABILITY));

        // Voting weight comes from the SOULBOUND IdentityBadge.
        identityBadge.grantIdentity(verifier, BADGE_AIRP_JUROR);
        identityBadge.grantIdentity(certifiedVerifier, BADGE_AIRP_SENIOR_JUROR);
        identityBadge.grantIdentity(manufacturer, BADGE_AIRP_ARBITER);
        identityBadge.grantIdentity(governanceVoter, BADGE_AIRP_TRIBUNAL);

        token.transfer(claimant, 10_000 ether);
        token.transfer(thirdParty, 10_000 ether);

        vm.stopPrank();

        vm.prank(claimant);
        token.approve(address(recovery), type(uint256).max);
        vm.prank(thirdParty);
        token.approve(address(recovery), type(uint256).max);
    }

    // ============================================
    // HELPERS
    // ============================================

    function _oracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        returns (bytes memory challengeResponse, bytes memory oracleSignature)
    {
        challengeResponse = abi.encodePacked("challenge", tokenId);
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, ethHash);
        oracleSignature = abi.encodePacked(r, s, v);
    }

    function _mintBound(address to) internal returns (uint256 tokenId) {
        vm.prank(manufacturer);
        tokenId = core.mint(to, keccak256(abi.encodePacked("metadata", block.timestamp, gasleft())));

        bytes32 tagHash = keccak256(abi.encodePacked("tag", tokenId));
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        core.bindTag(tokenId, tagHash, cr, sig);
    }

    function _mintActivated(address to) internal returns (uint256 tokenId) {
        tokenId = _mintBound(to);
        vm.prank(manufacturer);
        core.activate(tokenId);
    }

    function _mintClaimed(address to) internal returns (uint256 tokenId) {
        tokenId = _mintActivated(manufacturer);
        vm.prank(manufacturer);
        core.claim(tokenId, to);
    }

    /// @notice The standard AIRP fixture: CLAIMED then FLAGGED (preFlagState == CLAIMED)
    function _mintClaimedAndFlagged(address to) internal returns (uint256 tokenId) {
        tokenId = _mintClaimed(to);
        vm.prank(manufacturer);
        core.flag(tokenId);
    }

    function _openCase(uint256 tokenId) internal returns (uint256 caseId) {
        vm.prank(claimant);
        caseId = recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    function _vote(uint256 caseId, address voter, bool approve) internal {
        vm.prank(voter);
        recovery.vote(caseId, approve, REASON_HASH);
    }

    /// @notice Open a case, approve it unanimously, and land it in ENFORCING
    function _caseInEnforcing(uint256 tokenId) internal returns (uint256 caseId) {
        caseId = _openCase(tokenId);
        _vote(caseId, governanceVoter, true);
        _vote(caseId, manufacturer, true);
        _vote(caseId, verifier, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);
    }

    /// @notice TAGITCore's 2-of-3 HUMAN quorum. Never the Recovery contract.
    function _resolversDeliver(uint256 tokenId, address to) internal {
        vm.prank(resolverA);
        core.approveResolve(tokenId, to);
        vm.prank(resolverB);
        core.approveResolve(tokenId, to);
        vm.prank(resolverA);
        core.resolve(tokenId, to);
    }

    // ============================================
    // WIRE COMPATIBILITY OF THE DECOUPLED ENUM
    // ============================================

    /// @dev TAGITRecovery talks to Core through ITAGITCoreRecovery so it does not link
    ///      Core's bytecode. That decoupling is only safe while the ordinals agree.
    function test_enumOrdinals_matchTAGITCoreExactly() public pure {
        assertEq(uint8(ITAGITCoreRecovery.State.NONE), uint8(TAGITCore.State.NONE));
        assertEq(uint8(ITAGITCoreRecovery.State.MINTED), uint8(TAGITCore.State.MINTED));
        assertEq(uint8(ITAGITCoreRecovery.State.BOUND), uint8(TAGITCore.State.BOUND));
        assertEq(uint8(ITAGITCoreRecovery.State.ACTIVATED), uint8(TAGITCore.State.ACTIVATED));
        assertEq(uint8(ITAGITCoreRecovery.State.CLAIMED), uint8(TAGITCore.State.CLAIMED));
        assertEq(uint8(ITAGITCoreRecovery.State.FLAGGED), uint8(TAGITCore.State.FLAGGED));
        assertEq(uint8(ITAGITCoreRecovery.State.RECYCLED), uint8(TAGITCore.State.RECYCLED));

        // Pin the absolute values too, so a reorder in either enum is caught even if both move
        assertEq(uint8(ITAGITCoreRecovery.State.CLAIMED), 4);
        assertEq(uint8(TAGITCore.State.CLAIMED), 4);
        assertEq(uint8(ITAGITCoreRecovery.State.FLAGGED), 5);
        assertEq(uint8(TAGITCore.State.RECYCLED), 6);
    }

    // ============================================
    // TAGITCore.preFlagState() (the one Core addition)
    // ============================================

    function test_preFlagState_lifecycle() public {
        uint256 tokenId = _mintClaimed(holder);

        // Never flagged
        assertEq(uint8(core.preFlagState(tokenId)), uint8(TAGITCore.State.NONE));

        vm.prank(manufacturer);
        core.flag(tokenId);
        assertEq(uint8(core.preFlagState(tokenId)), uint8(TAGITCore.State.CLAIMED));

        _resolversDeliver(tokenId, claimant);
        // resolve() clears the marker
        assertEq(uint8(core.preFlagState(tokenId)), uint8(TAGITCore.State.NONE));
    }

    function test_preFlagState_recordsBoundAndActivated() public {
        uint256 boundToken = _mintBound(manufacturer);
        vm.prank(manufacturer);
        core.flag(boundToken);
        assertEq(uint8(core.preFlagState(boundToken)), uint8(TAGITCore.State.BOUND));

        uint256 activatedToken = _mintActivated(manufacturer);
        vm.prank(manufacturer);
        core.flag(activatedToken);
        assertEq(uint8(core.preFlagState(activatedToken)), uint8(TAGITCore.State.ACTIVATED));
    }

    // ============================================
    // THE TRUST BOUNDARY (the design's central claim)
    // ============================================

    /// @dev The machine-checkable form of "the adjudicator holds no keys to the vault".
    ///      MUST NEVER BE WEAKENED. If this fails, treat it as a security incident.
    function test_trustBoundary_recoveryHoldsNoCapability() public view {
        assertFalse(
            access.hasCapability(address(recovery), uint256(RESOLVER_CAPABILITY)),
            "TAGITRecovery must never hold RESOLVER_CAPABILITY"
        );
        assertFalse(
            access.hasCapability(address(recovery), uint256(FLAGGER_CAPABILITY)),
            "TAGITRecovery must never hold FLAGGER_CAPABILITY"
        );
        assertFalse(access.hasCapability(address(recovery), uint256(MINTER_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(BINDER_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(ACTIVATOR_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(CLAIMER_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(keccak256("RECYCLER"))));
        // All NINE of TAGITCore's capabilities, not the seven that move custody. The claim
        // this test backs is "ZERO capabilities", and a partial check makes that claim
        // falsifiable by an auditor who counts the constants in TAGITCore.
        assertFalse(access.hasCapability(address(recovery), uint256(keccak256("VIEWER"))));
        assertFalse(access.hasCapability(address(recovery), uint256(keccak256("AUDITOR"))));
    }

    // ============================================
    // FLAG-GATED CASE ADMISSION
    // ============================================

    function test_initiateRecovery_revert_assetNotQuarantined_whenClaimed() public {
        uint256 tokenId = _mintClaimed(holder);

        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AssetNotQuarantined.selector, tokenId));
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    function test_initiateRecovery_revert_assetNotRecoverable_flaggedFromBound() public {
        uint256 tokenId = _mintBound(manufacturer);
        vm.prank(manufacturer);
        core.flag(tokenId);

        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecovery.AssetNotRecoverable.selector, tokenId, uint8(ITAGITCoreRecovery.State.BOUND)
            )
        );
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    function test_initiateRecovery_revert_assetNotRecoverable_flaggedFromActivated() public {
        uint256 tokenId = _mintActivated(manufacturer);
        vm.prank(manufacturer);
        core.flag(tokenId);

        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecovery.AssetNotRecoverable.selector, tokenId, uint8(ITAGITCoreRecovery.State.ACTIVATED)
            )
        );
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    function test_initiateRecovery_succeedsOnFlaggedClaimedAsset() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);

        vm.expectEmit(true, true, true, true);
        emit RecoveryInitiated(1, tokenId, claimant, holder, MINIMUM_STAKE, EVIDENCE_HASH);
        vm.expectEmit(true, true, false, false);
        emit AssetQuarantined(tokenId, 1);

        vm.prank(claimant);
        uint256 caseId = recovery.initiateRecovery(tokenId, EVIDENCE_HASH);

        assertEq(caseId, 1);
        assertEq(balanceBefore - token.balanceOf(claimant), MINIMUM_STAKE, "exactly minimumStake pulled");
        assertEq(recovery.totalStakesHeld(), MINIMUM_STAKE);
        assertTrue(recovery.isQuarantined(tokenId));
    }

    // ============================================
    // QUARANTINE IS REAL (constraint 5: mid-vote resale)
    // ============================================

    /// @dev The pre-fix quarantine was decorative: _quarantined was read by nothing outside
    ///      TAGITRecovery, so a disputed asset could be sold mid-vote. Quarantine is now
    ///      TAGITCore's FLAGGED state, which transferAsset() itself refuses.
    function test_quarantineIsReal_resaleBlockedDuringCase() public {
        uint256 tokenId = _mintClaimed(holder);

        // Before the flag, the very same call succeeds — proving the block comes from
        // the freeze and not from some pre-existing restriction on the fixture.
        uint256 snap = vm.snapshotState();
        vm.prank(holder);
        core.transferAsset(tokenId, buyer);
        assertEq(core.ownerOf(tokenId), buyer, "resale works while CLAIMED");
        vm.revertToState(snap);

        vm.prank(manufacturer);
        core.flag(tokenId);
        uint256 caseId = _openCase(tokenId);
        assertTrue(recovery.isQuarantined(tokenId));

        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.FLAGGED, TAGITCore.State.CLAIMED
            )
        );
        core.transferAsset(tokenId, buyer);

        assertEq(core.ownerOf(tokenId), holder, "asset stayed put through the whole dispute");
        assertEq(recovery.getCase(caseId).currentHolder, holder);
    }

    function test_quarantineIsReal_erc721TransfersBlocked() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        _openCase(tokenId);

        vm.prank(holder);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        core.transferFrom(holder, buyer, tokenId);

        vm.prank(holder);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        core.safeTransferFrom(holder, buyer, tokenId);
    }

    // ============================================
    // NO-QUORUM: THE PERMANENT LOCK IS GONE
    // ============================================

    /// @dev Regression for the proven permanent lock. vote() closes at votingEndsAt,
    ///      executeResolution reverted QuorumNotReached forever, and appeal() only accepts
    ///      REJECTED — so a case with fewer than 3 votes could never leave VOTING and its
    ///      bond was locked in totalStakesHeld for good.
    ///
    ///      PREMISE UPDATED. The lock is still gone — that is what this test exists for —
    ///      but the 100% refund that replaced it was itself the D1 defect: an unengaged case
    ///      cost its opener nothing, which made squatting an asset's dispute slot free and
    ///      infinitely repeatable. An expiry below FEE_EXEMPT_MIN_VOTES now pays the 10%
    ///      anti-squat fee. The case still terminates, the bond is still not trapped, and
    ///      nothing is slashed.
    function test_noQuorum_expiresWithFee_insteadOfBricking() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _openCase(tokenId);

        vm.warp(block.timestamp + VOTING_DURATION + 1);

        vm.expectEmit(true, true, false, true);
        emit AntiSquatFeeCharged(caseId, claimant, SQUAT_FEE, treasury);
        vm.expectEmit(true, true, false, true);
        emit CaseExpired(caseId, tokenId, MINIMUM_STAKE - SQUAT_FEE);
        recovery.executeResolution(caseId);

        IRecovery.RecoveryCase memory c = recovery.getCase(caseId);
        assertEq(uint8(c.status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(claimant), balanceBefore - SQUAT_FEE, "refunded all but the 10% fee");
        assertEq(token.balanceOf(treasury), SQUAT_FEE, "the fee, and only the fee, reached the treasury");
        assertLt(SQUAT_FEE, (MINIMUM_STAKE * 5000) / 10000, "a fee, not the adverse-vote slash");
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(recovery.getActiveCaseForToken(tokenId), 0, "_tokenToCase cleared");
        assertFalse(recovery.isQuarantined(tokenId));

        // Nothing remains trapped, ever.
        vm.warp(block.timestamp + 5 * 365 days);
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(token.balanceOf(address(recovery)), 0, "no funds trapped in the contract");
    }

    /// @dev THE APATHY CARVE-OUT, at the exact boundary — which is TWO, not one. Two votes
    ///      is still below MINIMUM_VOTES and still EXPIRES, but jurors not turning up is not
    ///      the claimant's conduct: that case refunds in FULL and the treasury gets nothing.
    ///      ONE vote does NOT qualify: a single juror seat is purchasable, so a one-vote
    ///      exemption was a fee anyone holding or renting one seat could dodge.
    function test_noQuorum_twoVotesRefundInFull_fewerThanTwoPaysTheFee() public {
        // ONE vote: below FEE_EXEMPT_MIN_VOTES, so the fee applies.
        uint256 t1 = _mintClaimedAndFlagged(holder);
        uint256 before1 = token.balanceOf(claimant);
        uint256 treasury1 = token.balanceOf(treasury);
        uint256 c1 = _openCase(t1);
        _vote(c1, verifier, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c1);
        assertEq(uint8(recovery.getCase(c1).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(claimant), before1 - SQUAT_FEE, "1 vote: one seat cannot buy the exemption");
        assertEq(token.balanceOf(treasury), treasury1 + SQUAT_FEE, "1 vote: the fee still bites");

        // TWO votes: the apathy carve-out, refunded in full.
        uint256 t2 = _mintClaimedAndFlagged(holder);
        uint256 before2 = token.balanceOf(claimant);
        uint256 treasury2 = token.balanceOf(treasury);
        uint256 c2 = _openCase(t2);
        _vote(c2, verifier, true);
        _vote(c2, certifiedVerifier, false);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c2);
        assertEq(uint8(recovery.getCase(c2).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(claimant), before2, "2 votes: 100% refund");
        assertEq(token.balanceOf(treasury), treasury2, "2 votes: treasury gets nothing");

        // And zero votes on the very same fixture pays too.
        uint256 t3 = _mintClaimedAndFlagged(holder);
        uint256 before3 = token.balanceOf(claimant);
        uint256 treasury3 = token.balanceOf(treasury);
        uint256 c3 = _openCase(t3);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c3);
        assertEq(token.balanceOf(claimant), before3 - SQUAT_FEE, "0 votes: the fee bites");
        assertEq(token.balanceOf(treasury), treasury3 + SQUAT_FEE);

        // The threshold sits STRICTLY BELOW quorum, which is what preserves the carve-out.
        assertLt(FEE_EXEMPT_MIN_VOTES, recovery.MINIMUM_VOTES());
        assertEq(recovery.FEE_EXEMPT_MIN_VOTES(), FEE_EXEMPT_MIN_VOTES);
    }

    function test_noQuorum_boundaryAtMinimumVotesMinusOne() public {
        // 1 vote -> EXPIRED
        uint256 t1 = _mintClaimedAndFlagged(holder);
        uint256 c1 = _openCase(t1);
        _vote(c1, verifier, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c1);
        assertEq(uint8(recovery.getCase(c1).status), uint8(IRecovery.CaseStatus.EXPIRED));

        // 2 votes -> EXPIRED
        uint256 t2 = _mintClaimedAndFlagged(holder);
        uint256 c2 = _openCase(t2);
        _vote(c2, verifier, true);
        _vote(c2, certifiedVerifier, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c2);
        assertEq(uint8(recovery.getCase(c2).status), uint8(IRecovery.CaseStatus.EXPIRED));

        // 3 votes -> NOT expired (this one is adjudicated)
        uint256 t3 = _mintClaimedAndFlagged(holder);
        uint256 c3 = _openCase(t3);
        _vote(c3, verifier, true);
        _vote(c3, certifiedVerifier, true);
        _vote(c3, governanceVoter, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c3);
        assertEq(uint8(recovery.getCase(c3).status), uint8(IRecovery.CaseStatus.ENFORCING));
    }

    // ============================================
    // THE BUG ITSELF: A VERDICT IS NOT A TRANSFER
    // ============================================

    function test_approvedVerdict_doesNotMoveTheAsset_andSaysSo() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        _vote(caseId, governanceVoter, true);
        _vote(caseId, manufacturer, true);
        _vote(caseId, verifier, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);

        uint256 expectedDeadline = block.timestamp + ENFORCEMENT_WINDOW;
        vm.expectEmit(true, true, true, true);
        emit ResolutionPending(caseId, tokenId, claimant, expectedDeadline);
        recovery.executeResolution(caseId);

        IRecovery.RecoveryCase memory c = recovery.getCase(caseId);
        assertEq(uint8(c.status), uint8(IRecovery.CaseStatus.ENFORCING));
        assertEq(core.ownerOf(tokenId), holder, "the asset has NOT moved");
        (,, TAGITCore.State st,,) = core.getAsset(tokenId);
        assertEq(uint8(st), uint8(TAGITCore.State.FLAGGED), "the asset is still FLAGGED");
        assertEq(recovery.totalStakesHeld(), MINIMUM_STAKE, "bond stays escrowed");
        assertEq(recovery.enforcementDeadline(caseId), expectedDeadline);
    }

    /// @dev THE test that proves TAGIT-VDP-2026-001 is fixed: a winning claimant now
    ///      actually receives the asset, and the case only reads RESOLVED once they have.
    function test_endToEndDelivery_claimantActuallyReceivesTheAsset() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _caseInEnforcing(tokenId);

        // TAGITCore's 2-of-3 human quorum
        vm.prank(resolverA);
        core.approveResolve(tokenId, claimant);
        vm.prank(resolverB);
        core.approveResolve(tokenId, claimant);
        vm.prank(resolverA);
        core.resolve(tokenId, claimant);

        assertEq(core.ownerOf(tokenId), claimant, "custody moved");
        (address o,, TAGITCore.State st,,) = core.getAsset(tokenId);
        assertEq(o, claimant);
        assertEq(uint8(st), uint8(TAGITCore.State.CLAIMED), "pre-flag state restored");

        vm.expectEmit(true, true, true, true);
        emit ResolutionDelivered(caseId, tokenId, claimant);
        vm.expectEmit(true, false, false, true);
        emit CaseResolved(caseId, IRecovery.CaseStatus.RESOLVED, claimant, 8, 0);
        recovery.finalizeResolution(caseId);

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.RESOLVED));
        assertEq(token.balanceOf(claimant), balanceBefore, "bond returned 100%");
        assertEq(recovery.totalStakesHeld(), 0);
        assertFalse(recovery.isQuarantined(tokenId));
    }

    // ============================================
    // finalizeResolution DIAGNOSTICS
    // ============================================

    function test_finalizeResolution_surfacesExactlyWhatIsMissing() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _caseInEnforcing(tokenId);

        // No approvals yet
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ResolverQuorumMissing.selector, caseId, 0, 2));
        recovery.finalizeResolution(caseId);

        // One approval
        vm.prank(resolverA);
        core.approveResolve(tokenId, claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ResolverQuorumMissing.selector, caseId, 1, 2));
        recovery.finalizeResolution(caseId);

        // Quorum and recipient are now both correct — resolve() has simply not been called
        vm.prank(resolverB);
        core.approveResolve(tokenId, claimant);
        vm.expectRevert(
            abi.encodeWithSelector(IRecovery.EnforcementActive.selector, caseId, recovery.enforcementDeadline(caseId))
        );
        recovery.finalizeResolution(caseId);
    }

    function test_finalizeResolution_revert_resolverRecipientMismatch() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _caseInEnforcing(tokenId);

        // Resolvers bind a recipient other than the party the vote awarded
        vm.prank(resolverA);
        core.approveResolve(tokenId, thirdParty);
        vm.prank(resolverB);
        core.approveResolve(tokenId, thirdParty);

        vm.expectRevert(
            abi.encodeWithSelector(IRecovery.ResolverRecipientMismatch.selector, caseId, claimant, thirdParty)
        );
        recovery.finalizeResolution(caseId);
    }

    /// @dev Resolver divergence is detected and NEVER slashes — a machinery failure is
    ///      not claimant fraud.
    function test_resolverDivergence_voidsCaseAndRefundsInFull() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _caseInEnforcing(tokenId);

        // The quorum resolves to a third party instead of the voted winner
        _resolversDeliver(tokenId, thirdParty);
        assertEq(core.ownerOf(tokenId), thirdParty);

        vm.expectEmit(true, true, false, true);
        emit CaseVoided(caseId, tokenId, claimant, thirdParty, uint8(TAGITCore.State.CLAIMED));
        recovery.finalizeResolution(caseId);

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.VOIDED));
        assertEq(token.balanceOf(claimant), balanceBefore, "100% refunded");
        assertEq(token.balanceOf(treasury), 0, "no slash on a machinery failure");
        assertEq(recovery.totalStakesHeld(), 0);
    }

    // ============================================
    // REJECTED PATH — THE ONLY PATH THAT SLASHES
    // ============================================

    function test_rejected_slashesFiftyPercentAndLeavesAssetFlagged() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _openCase(tokenId);

        _vote(caseId, governanceVoter, false); // 4 against
        _vote(caseId, manufacturer, false); // 3 against
        _vote(caseId, verifier, true); // 1 for
        vm.warp(block.timestamp + VOTING_DURATION + 1);

        uint256 slash = (MINIMUM_STAKE * 5000) / 10000;

        vm.expectEmit(true, true, false, true);
        emit StakeSlashed(caseId, claimant, slash, treasury);
        vm.expectEmit(true, false, false, true);
        emit CaseResolved(caseId, IRecovery.CaseStatus.REJECTED, holder, 1, 7);
        recovery.executeResolution(caseId);

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.REJECTED));
        assertEq(token.balanceOf(treasury), slash, "exactly 50% to treasury");
        assertEq(token.balanceOf(claimant), balanceBefore - slash, "exactly 50% back to claimant");

        // AIRP made NO state-changing call into Core: the asset is exactly as it found it.
        (address o,, TAGITCore.State st,,) = core.getAsset(tokenId);
        assertEq(o, holder);
        assertEq(uint8(st), uint8(TAGITCore.State.FLAGGED), "asset REMAINS FLAGGED");
        assertEq(uint8(core.preFlagState(tokenId)), uint8(TAGITCore.State.CLAIMED), "marker untouched");
    }

    // ============================================
    // ENFORCEMENT WINDOW EXITS
    // ============================================

    function test_expireEnforcement_beforeDeadlineReverts_afterDeadlineRefunds() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _caseInEnforcing(tokenId);
        uint256 deadline = recovery.enforcementDeadline(caseId);

        vm.expectRevert(abi.encodeWithSelector(IRecovery.EnforcementActive.selector, caseId, deadline));
        recovery.expireEnforcement(caseId);

        vm.warp(deadline + 1);
        recovery.expireEnforcement(caseId);

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(claimant), balanceBefore, "100% refund, no slash");
        assertEq(token.balanceOf(treasury), 0);
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(recovery.enforcementDeadline(caseId), 0);

        // The asset remains FLAGGED — the state AIRP found it in.
        (,, TAGITCore.State st,,) = core.getAsset(tokenId);
        assertEq(uint8(st), uint8(TAGITCore.State.FLAGGED));
    }

    function test_expireEnforcement_revert_useFinalizeResolution_whenResolversActed() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _caseInEnforcing(tokenId);

        _resolversDeliver(tokenId, claimant);
        vm.warp(recovery.enforcementDeadline(caseId) + 1);

        vm.expectRevert(abi.encodeWithSelector(IRecovery.UseFinalizeResolution.selector, caseId));
        recovery.expireEnforcement(caseId);

        // finalize then classifies it correctly
        recovery.finalizeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.RESOLVED));
    }

    function test_abandonEnforcement_claimantOnly_anyTime_fullRefund() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _caseInEnforcing(tokenId);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, randomUser));
        recovery.abandonEnforcement(caseId);

        // No warp: the claimant may exit at any time
        vm.prank(claimant);
        recovery.abandonEnforcement(caseId);

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(claimant), balanceBefore, "100% refund");
        assertEq(token.balanceOf(treasury), 0);
        assertEq(recovery.totalStakesHeld(), 0);
    }

    // ============================================
    // UPGRADE-SAFE ENFORCEMENT WINDOW DEFAULT
    // ============================================

    /// @dev A proxy upgraded from v1 has never written the enforcement window slot, so the
    ///      RAW slot reads 0. Without the zero-fallback every ENFORCING case would be
    ///      instantly expirable — and the public getter must report the window the contract
    ///      actually applies, not the unset slot, or off-chain consumers read "unconfigured".
    function test_enforcementWindow_zeroFallbackAfterUpgradeFromV1() public {
        // Simulate the upgraded-but-never-reinitialized proxy exactly: slot 20 == 0.
        vm.store(address(recovery), bytes32(uint256(20)), bytes32(0));
        assertEq(uint256(vm.load(address(recovery), bytes32(uint256(20)))), 0, "raw storage really is zero");
        assertEq(recovery.configuredEnforcementWindow(), 0, "raw getter still reports unconfigured");
        assertEq(recovery.enforcementWindow(), ENFORCEMENT_WINDOW, "effective getter reports what is actually enforced");

        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _caseInEnforcing(tokenId);

        assertEq(
            recovery.enforcementDeadline(caseId),
            block.timestamp + ENFORCEMENT_WINDOW,
            "must fall back to 30 days, not to block.timestamp"
        );

        // And it is genuinely not expirable right away.
        vm.expectRevert(
            abi.encodeWithSelector(IRecovery.EnforcementActive.selector, caseId, recovery.enforcementDeadline(caseId))
        );
        recovery.expireEnforcement(caseId);
    }

    function test_setEnforcementWindow_boundsAndAuthority() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.InvalidEnforcementWindow.selector, 7 days - 1));
        recovery.setEnforcementWindow(7 days - 1);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.InvalidEnforcementWindow.selector, 365 days + 1));
        recovery.setEnforcementWindow(365 days + 1);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, randomUser));
        recovery.setEnforcementWindow(60 days);

        vm.expectEmit(false, false, false, true);
        emit EnforcementWindowUpdated(ENFORCEMENT_WINDOW, 60 days);
        vm.prank(governor);
        recovery.setEnforcementWindow(60 days);
        assertEq(recovery.enforcementWindow(), 60 days);

        // Boundaries themselves are valid
        vm.prank(governor);
        recovery.setEnforcementWindow(7 days);
        vm.prank(governor);
        recovery.setEnforcementWindow(365 days);
        assertEq(recovery.enforcementWindow(), 365 days);
    }

    // ============================================
    // SYBIL RESISTANCE (soulbound voting weight)
    // ============================================

    /// @dev Inversion of the SybilPoC. CapabilityBadge is a transferable ERC-1155 with no
    ///      _update override and _hasVoted is keyed by address, so ONE badge walked through
    ///      three EOAs used to produce voteCount 3 / 12-0 / a unanimous verdict.
    function test_sybilRegression_walkedCapabilityBadgeCannotManufactureAVerdict() public {
        address b1 = makeAddr("sybil1");
        address b2 = makeAddr("sybil2");
        address b3 = makeAddr("sybil3");

        // ONE governance CapabilityBadge, minted to b1
        vm.prank(owner);
        capabilityBadge.grantCapability(b1, BADGE_AIRP_TRIBUNAL);
        assertTrue(access.hasCapability(b1, BADGE_AIRP_TRIBUNAL), "the walkable badge exists");

        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);

        // Under capability-based weighting this vote had weight 4. It is now worth nothing.
        vm.prank(b1);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotBadgeHolder.selector, b1));
        recovery.vote(caseId, true, REASON_HASH);

        // Walk the badge b1 -> b2 -> b3; every hop is still worthless.
        vm.prank(b1);
        capabilityBadge.safeTransferFrom(b1, b2, BADGE_AIRP_TRIBUNAL, 1, "");
        assertTrue(access.hasCapability(b2, BADGE_AIRP_TRIBUNAL), "the badge really did move");

        vm.prank(b2);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotBadgeHolder.selector, b2));
        recovery.vote(caseId, true, REASON_HASH);

        vm.prank(b2);
        capabilityBadge.safeTransferFrom(b2, b3, BADGE_AIRP_TRIBUNAL, 1, "");
        vm.prank(b3);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotBadgeHolder.selector, b3));
        recovery.vote(caseId, true, REASON_HASH);

        assertEq(recovery.getCase(caseId).voteCount, 0, "no votes were manufactured");
        assertEq(recovery.getCase(caseId).votesFor, 0);
    }

    /// @dev The sybil has no substitute path: the IdentityBadge cannot be walked at all.
    function test_identityBadgeCannotBeWalked() public {
        address newVoter = makeAddr("newVoter");
        vm.prank(owner);
        uint256 badgeTokenId = identityBadge.grantIdentity(newVoter, BADGE_AIRP_TRIBUNAL);
        assertEq(recovery.getVoteWeight(newVoter), 4);

        vm.prank(newVoter);
        vm.expectRevert(abi.encodeWithSelector(IIdentityBadge.BadgeLocked.selector, badgeTokenId));
        identityBadge.transferFrom(newVoter, randomUser, badgeTokenId);

        vm.prank(newVoter);
        vm.expectRevert(abi.encodeWithSelector(IIdentityBadge.BadgeLocked.selector, badgeTokenId));
        identityBadge.safeTransferFrom(newVoter, randomUser, badgeTokenId);

        vm.prank(newVoter);
        vm.expectRevert(abi.encodeWithSelector(IIdentityBadge.BadgeLocked.selector, badgeTokenId));
        identityBadge.approve(randomUser, badgeTokenId);

        vm.prank(newVoter);
        vm.expectRevert(abi.encodeWithSelector(IIdentityBadge.BadgeLocked.selector, uint256(0)));
        identityBadge.setApprovalForAll(randomUser, true);

        assertEq(recovery.getVoteWeight(randomUser), 0, "weight never moved");
    }

    function test_voteWeights_readFromIdentityBadge() public view {
        assertEq(recovery.getVoteWeight(governanceVoter), 4);
        assertEq(recovery.getVoteWeight(manufacturer), 3);
        assertEq(recovery.getVoteWeight(certifiedVerifier), 2);
        assertEq(recovery.getVoteWeight(verifier), 1);
        assertEq(recovery.getVoteWeight(randomUser), 0);
    }

    /// @dev hasIdentity() is zero-trust: it returns false rather than reverting when
    ///      TAGITAccess has no IdentityBadge configured, so an unwired deployment
    ///      fails CLOSED — every vote reverts NotBadgeHolder instead of sailing through.
    function test_unwiredIdentityBadge_failsClosed() public {
        vm.startPrank(owner);
        TAGITAccess unwired = new TAGITAccess();
        unwired.setCapabilityBadge(address(capabilityBadge));
        // deliberately NO setIdentityBadge

        TAGITRecovery altImpl = new TAGITRecovery();
        ERC1967Proxy altProxy = new ERC1967Proxy(
            address(altImpl),
            abi.encodeCall(
                TAGITRecovery.initialize, (address(core), address(unwired), address(token), governor, treasury, owner)
            )
        );
        TAGITRecovery alt = TAGITRecovery(address(altProxy));
        vm.stopPrank();

        assertEq(unwired.identityBadge(), address(0));
        assertFalse(unwired.hasIdentity(governanceVoter, BADGE_AIRP_TRIBUNAL), "false, not a revert");
        assertEq(alt.getVoteWeight(governanceVoter), 0, "heaviest badge holder has no weight");

        uint256 tokenId = _mintClaimedAndFlagged(holder);
        vm.startPrank(claimant);
        token.approve(address(alt), type(uint256).max);
        uint256 caseId = alt.initiateRecovery(tokenId, EVIDENCE_HASH);
        vm.stopPrank();

        vm.prank(governanceVoter);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotBadgeHolder.selector, governanceVoter));
        alt.vote(caseId, true, REASON_HASH);
    }

    // ============================================
    // PARTIES CANNOT ADJUDICATE THEIR OWN DISPUTE
    // ============================================

    function test_claimantAndHolderCannotVote() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);

        // Give both parties the heaviest badge — authority is irrelevant, standing is not
        vm.startPrank(owner);
        identityBadge.grantIdentity(claimant, BADGE_AIRP_TRIBUNAL);
        identityBadge.grantIdentity(holder, BADGE_AIRP_TRIBUNAL);
        vm.stopPrank();
        assertEq(recovery.getVoteWeight(claimant), 4);
        assertEq(recovery.getVoteWeight(holder), 4);

        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, claimant));
        recovery.vote(caseId, true, REASON_HASH);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, holder));
        recovery.vote(caseId, false, REASON_HASH);

        assertEq(recovery.getCase(caseId).voteCount, 0);
    }

    // ============================================
    // APPEAL
    // ============================================

    function test_appeal_refreshesCurrentHolder() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);

        _vote(caseId, governanceVoter, false);
        _vote(caseId, manufacturer, false);
        _vote(caseId, verifier, false);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.REJECTED));

        // The holder changes between rounds: resolvers hand the asset to a new owner,
        // who is then flagged again. The v1 appeal() carried the stale holder forward.
        _resolversDeliver(tokenId, buyer);
        vm.prank(manufacturer);
        core.flag(tokenId);
        assertEq(core.ownerOf(tokenId), buyer);

        vm.prank(owner);
        token.transfer(claimant, 300 ether);

        vm.prank(claimant);
        recovery.appeal(caseId, keccak256("appeal-evidence"));

        IRecovery.RecoveryCase memory c = recovery.getCase(caseId);
        assertEq(c.currentHolder, buyer, "currentHolder refreshed to the live owner");
        assertEq(c.currentHolder, core.ownerOf(tokenId));
        assertEq(uint8(c.status), uint8(IRecovery.CaseStatus.VOTING));
    }

    function test_appeal_revert_assetNoLongerFlagged() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);

        _vote(caseId, governanceVoter, false);
        _vote(caseId, manufacturer, false);
        _vote(caseId, verifier, false);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        // Resolvers unfreeze the asset by resolving it back to the holder
        _resolversDeliver(tokenId, holder);

        vm.prank(owner);
        token.transfer(claimant, 300 ether);
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AssetNotQuarantined.selector, tokenId));
        recovery.appeal(caseId, keccak256("appeal-evidence"));
    }

    function test_appeal_revert_cannotAppealExpiredVoidedOrEnforcing() public {
        vm.prank(owner);
        token.transfer(claimant, 1000 ether);

        // ENFORCING
        uint256 t1 = _mintClaimedAndFlagged(holder);
        uint256 c1 = _caseInEnforcing(t1);
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.CannotAppeal.selector, c1, IRecovery.CaseStatus.ENFORCING));
        recovery.appeal(c1, keccak256("a"));

        // VOIDED
        _resolversDeliver(t1, thirdParty);
        recovery.finalizeResolution(c1);
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.CannotAppeal.selector, c1, IRecovery.CaseStatus.VOIDED));
        recovery.appeal(c1, keccak256("a"));

        // EXPIRED
        uint256 t2 = _mintClaimedAndFlagged(holder);
        uint256 c2 = _openCase(t2);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c2);
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.CannotAppeal.selector, c2, IRecovery.CaseStatus.EXPIRED));
        recovery.appeal(c2, keccak256("a"));
    }

    // ============================================
    // CIRCUIT BREAKER MUST NEVER TRAP A BOND
    // ============================================

    function test_pausedContract_stillReleasesEscrowedBonds() public {
        uint256 t1 = _mintClaimedAndFlagged(holder);
        uint256 t2 = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);

        uint256 c1 = _openCase(t1); // will be executed while paused
        uint256 c2 = _caseInEnforcing(t2); // will be finalized while paused

        vm.prank(owner);
        recovery.pause();

        // Exit paths stay open
        recovery.executeResolution(c1);
        assertEq(uint8(recovery.getCase(c1).status), uint8(IRecovery.CaseStatus.EXPIRED));

        _resolversDeliver(t2, claimant);
        recovery.finalizeResolution(c2);
        assertEq(uint8(recovery.getCase(c2).status), uint8(IRecovery.CaseStatus.RESOLVED));

        // c1 drew zero votes, so its expiry pays the 10% anti-squat fee; c2 was voted
        // through and delivered, so it refunds whole. The point of THIS test is that a
        // pause traps neither escrow — the fee is a settlement, not a trap.
        assertEq(token.balanceOf(claimant), balanceBefore - SQUAT_FEE, "both bonds settled despite the pause");
        assertEq(token.balanceOf(treasury), SQUAT_FEE, "only c1's zero-vote fee");
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(token.balanceOf(address(recovery)), 0, "nothing stranded behind the pause");

        // Entry paths stay closed
        uint256 t3 = _mintClaimedAndFlagged(holder);
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        recovery.initiateRecovery(t3, EVIDENCE_HASH);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        recovery.vote(c1, true, REASON_HASH);

        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        recovery.appeal(c1, keccak256("a"));
    }

    function test_pausedContract_stillAllowsExpireAndAbandon() public {
        uint256 t1 = _mintClaimedAndFlagged(holder);
        uint256 t2 = _mintClaimedAndFlagged(holder);
        uint256 c1 = _caseInEnforcing(t1);
        uint256 c2 = _caseInEnforcing(t2);

        vm.prank(owner);
        recovery.pause();

        vm.prank(claimant);
        recovery.abandonEnforcement(c1);
        assertEq(uint8(recovery.getCase(c1).status), uint8(IRecovery.CaseStatus.EXPIRED));

        vm.warp(recovery.enforcementDeadline(c2) + 1);
        recovery.expireEnforcement(c2);
        assertEq(uint8(recovery.getCase(c2).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(recovery.totalStakesHeld(), 0);
    }

    // ============================================
    // AIRP CONSUMES ZERO OF CORE'S FLAG BUDGET
    // ============================================

    /// @dev Design 2 discovered a circuit-breaker coupling when Recovery called flag().
    ///      Under this design AIRP never calls flag(), so the coupling does not exist.
    function test_airpConsumesZeroCoreFlagBudget() public {
        // Pre-flag the fixture assets FIRST, then measure capacity, then open cases.
        uint256[] memory ids = new uint256[](3); // rate limiter allows 3 per user per window
        for (uint256 i = 0; i < 3; i++) {
            ids[i] = _mintClaimedAndFlagged(holder);
        }

        uint256 capacityBefore = core.getFlagCircuitBreakerCapacity();

        vm.startPrank(claimant);
        for (uint256 i = 0; i < 3; i++) {
            recovery.initiateRecovery(ids[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        assertEq(
            core.getFlagCircuitBreakerCapacity(),
            capacityBefore,
            "opening AIRP cases must not consume any of TAGITCore's flag budget"
        );
        (bool tripped,) = core.getFlagCircuitBreakerStatus();
        assertFalse(tripped);
    }

    // ============================================
    // STORAGE UPGRADE SAFETY (v1 layout -> v2)
    // ============================================

    /// @dev Deploy a proxy on a faithful reproduction of the v1 storage layout, populate a
    ///      case and votes, upgrade to the real v2 implementation, and assert every
    ///      pre-existing field survives bit-identically — plus raw slots 0..19.
    function test_storageUpgradeSafety_v1LayoutToV2() public {
        vm.startPrank(owner);
        TAGITRecoveryV1Layout v1Impl = new TAGITRecoveryV1Layout();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v1Impl),
            abi.encodeCall(
                TAGITRecoveryV1Layout.initialize,
                (address(core), address(access), address(token), governor, treasury, owner)
            )
        );
        TAGITRecoveryV1Layout v1 = TAGITRecoveryV1Layout(address(proxy));
        vm.stopPrank();

        uint256 tokenId = _mintClaimedAndFlagged(holder);

        address[] memory voters = new address[](2);
        voters[0] = governanceVoter;
        voters[1] = verifier;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 4;
        weights[1] = 1;

        uint256 caseId = v1.seedCase(tokenId, claimant, holder, EVIDENCE_HASH, MINIMUM_STAKE, voters, weights);
        bytes32 caseBefore = keccak256(abi.encode(v1.getCase(caseId)));
        uint256 nextBefore = v1.nextCaseId();

        // Snapshot raw slots 0..19 (every pre-existing sequential slot)
        bytes32[20] memory rawBefore;
        for (uint256 i = 0; i < 20; i++) {
            rawBefore[i] = vm.load(address(proxy), bytes32(i));
        }

        // ---- UPGRADE ---- (deploy BEFORE the prank; a `new` argument would consume it)
        address v2Impl = address(new TAGITRecovery());
        vm.prank(owner);
        v1.upgradeToAndCall(v2Impl, "");
        TAGITRecovery v2 = TAGITRecovery(address(proxy));

        // Raw slots unchanged
        for (uint256 i = 0; i < 20; i++) {
            assertEq(vm.load(address(proxy), bytes32(i)), rawBefore[i], "raw slot moved across the upgrade");
        }

        // Every case field bit-identical
        assertEq(keccak256(abi.encode(v2.getCase(caseId))), caseBefore, "a case field changed across the upgrade");

        _assertV2ConfigPreserved(v2, nextBefore);

        // Vote bookkeeping survives
        assertTrue(v2.hasVoted(caseId, governanceVoter));
        assertTrue(v2.hasVoted(caseId, verifier));
        assertEq(v2.getVote(caseId, governanceVoter).weight, 4);
        assertEq(v2.getVote(caseId, verifier).weight, 1);
        assertEq(v2.getActiveCaseForToken(tokenId), caseId);
        assertTrue(v2.isQuarantined(tokenId));

        // The appended slots read as fresh zeros, and the fallback covers the window
        assertEq(uint256(vm.load(address(proxy), bytes32(uint256(20)))), 0, "v1 storage never wrote slot 20");
        assertEq(v2.configuredEnforcementWindow(), 0, "raw window is unconfigured");
        assertEq(v2.enforcementWindow(), ENFORCEMENT_WINDOW, "getter reports the EFFECTIVE window, not 0");
        assertEq(uint256(vm.load(address(proxy), bytes32(uint256(22)))), 0, "appended _caseRound slot is fresh");
        assertEq(v2.caseRound(caseId), 0, "a v1 case is in round 0");
        assertEq(v2.enforcementDeadline(caseId), 0);

        // Same story one slot further on: the appeal window was appended after _caseRound,
        // so a v1 proxy has never written slot 23 either. The getter must report the window
        // the contract APPLIES, not the unwritten slot — the F-H mistake, one slot along.
        assertEq(uint256(vm.load(address(proxy), bytes32(uint256(23)))), 0, "v1 storage never wrote slot 23");
        assertEq(v2.configuredAppealWindow(), 0, "raw appeal window is unconfigured");
        assertEq(v2.appealWindow(), APPEAL_WINDOW, "getter reports the EFFECTIVE window, not 0");
        assertEq(v2.appealDeadline(caseId), 0, "a v1 case has no appeal deadline on record");

        assertEq(v2.version(), "2.0.0");
    }

    function _assertV2ConfigPreserved(TAGITRecovery v2, uint256 nextBefore) internal view {
        assertEq(v2.core(), address(core));
        assertEq(address(v2.access()), address(access));
        assertEq(address(v2.token()), address(token));
        assertEq(v2.governor(), governor);
        assertEq(v2.treasury(), treasury);
        assertEq(v2.minimumStake(), MINIMUM_STAKE);
        assertEq(v2.votingDuration(), VOTING_DURATION);
        assertEq(v2.totalStakesHeld(), MINIMUM_STAKE);
        assertEq(v2.nextCaseId(), nextBefore);
        assertEq(v2.owner(), owner);
    }

    /// @dev TAGITCore's own storage must survive the preFlagState() addition. The layout
    ///      diff is verified out-of-band with `forge inspect`; this pins the behaviour.
    function test_coreUpgrade_preservesAssetState() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        bytes32 assetBefore = _assetFingerprint(tokenId);
        uint256 supply0 = core.totalSupply();
        bytes32 tag0 = core.getTagByToken(tokenId);

        // NB: deploy BEFORE the prank — a `new` inside the argument list would consume it
        address newCoreImpl = address(new TAGITCore());
        vm.prank(owner);
        core.upgradeToAndCall(newCoreImpl, "");

        assertEq(_assetFingerprint(tokenId), assetBefore, "asset record changed across the upgrade");
        assertEq(core.totalSupply(), supply0);
        assertEq(core.getTagByToken(tokenId), tag0);
        assertEq(uint8(core.preFlagState(tokenId)), uint8(TAGITCore.State.CLAIMED));
    }

    /// @notice Hash every field of an Asset record so it can be compared in one assert
    function _assetFingerprint(uint256 tokenId) internal view returns (bytes32) {
        (address o, uint64 ts, TAGITCore.State st, uint8 f, uint16 r) = core.getAsset(tokenId);
        return keccak256(abi.encode(o, ts, uint8(st), f, r, core.ownerOf(tokenId)));
    }
}
