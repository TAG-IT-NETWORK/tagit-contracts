// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TAGITRecoveryVerdictTest} from "./TAGITRecoveryVerdict.t.sol";
import {IRecovery} from "../../src/interfaces/IRecovery.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";

/**
 * @title TAGITRecoveryRegression
 * @author TAG IT Network <dev@tagit.network>
 * @notice Permanent regression suite for the eight defects two independent adversarial
 *         reviews proved against the first TAGIT-VDP-2026-001 remediation.
 * @dev Every scenario here began life as a PoC that PASSED by demonstrating a bug. Each
 *      one is now inverted: it passes by demonstrating the bug is gone. Do not delete a
 *      scenario — deleting one deletes the proof.
 *
 *      F-A  appeal() accumulated the bond (recorded 3x, held 2x) so every round-two exit
 *           path panicked on a checked-arithmetic underflow and stranded the escrow.
 *      F-B  ENFORCING was missing from initiateRecovery()'s active-case guard, so a decoy
 *           case could repoint _tokenToCase and then erase a live case's link for free.
 *      F-C  the juror lookup read IdentityBadge ids 1/2/10/20 — KYC_L1, KYC_L2,
 *           MANUFACTURER, GOV_MIL — so every KYC'd account was an AIRP juror.
 *      F-D  appeal() reset the tally but not the per-voter records, so round two could
 *           never reach MINIMUM_VOTES.
 *      F-E  initiateRecovery() rejected a pre-flag marker of NONE that resolve() honours.
 *      F-F  vote() reverted VotingStillActive when voting had ENDED.
 *      F-G  KNOWN-ISSUES claimed no bond can ever be trapped; F-A falsified it.
 *      F-H  enforcementWindow() reported 0 on an upgraded proxy (pinned in the verdict
 *           suite, which owns the upgrade fixture).
 *
 *      A THIRD review then proved two more, both rooted in the SAME line: the EXPIRED
 *      branch refunded 100% when voteCount < MINIMUM_VOTES, which made a decoy case free.
 *
 *      D-1  ZERO-COST CASE-SLOT SQUATTING. Anyone who is not the current holder could bond
 *           over a FLAGGED asset, cast no votes, take the whole bond back after
 *           votingDuration — having locked the real owner out of AIRP for 7 days — and
 *           repeat forever. An approved decoy stretched one cycle to 37 days, still free.
 *           This was a REGRESSION IN COST-TO-GRIEF introduced by the F-A/F-B cut: before
 *           it, a no-quorum case reverted QuorumNotReached and permanently trapped the
 *           squatter's own bond. Closed by SQUAT_FEE_RATE — see the D-1 block below.
 *      D-2  THE APPEAL RIGHT COULD BE GRIEFED AWAY. The REJECTED branch called
 *           _unlinkToken, freeing the token's dispute slot in the same transaction that
 *           created the claimant's appeal right. executeResolution is permissionless while
 *           appeal() is claimant-only, so an EOA appellant could not atomically expire a
 *           decoy and appeal; a griefer front-ran the freed slot indefinitely, for gas.
 *           Closed by the bounded appeal window — see the D-2 block below.
 *
 *      Reuses TAGITRecoveryVerdictTest for the fixture only.
 */
contract TAGITRecoveryRegression is TAGITRecoveryVerdictTest {
    /// @dev The protocol-wide IdentityBadge ids an AIRP jury seat must NEVER be
    uint256 internal constant KYC_L1_IDENTITY = 1; // TAGITAgentIdentity.KYC_L1_IDENTITY
    uint256 internal constant KYC_L2_IDENTITY = 2;
    uint256 internal constant REGISTRY_MANUFACTURER = 10; // RobotTypes.BADGE_MANUFACTURER
    uint256 internal constant REGISTRY_GOV_MIL = 20; // RobotTypes.BADGE_GOV_MIL

    bytes32 internal constant APPEAL_EVIDENCE = keccak256("appeal-evidence");

    /// @dev Storage slot of TAGITRecovery._tokenToCase (verified by forge inspect)
    uint256 internal constant SLOT_TOKEN_TO_CASE = 10;
    /// @dev Storage slot of TAGITCore._preFlagState (verified by forge inspect)
    uint256 internal constant SLOT_PRE_FLAG_STATE = 20;
    /// @dev Storage slot of TAGITRecovery._appealDeadline (verified by forge inspect)
    uint256 internal constant SLOT_APPEAL_DEADLINE = 24;
    /// @dev Storage slot of TAGITRecovery._appealWindow (verified by forge inspect)
    uint256 internal constant SLOT_APPEAL_WINDOW = 23;
    /// @dev Storage slot of TAGITRecovery._pauseCreditAtRejection (verified by forge inspect)
    uint256 internal constant SLOT_PAUSE_CREDIT_AT_REJECTION = 27;
    /// @dev Storage slot of TAGITRecovery._recoveryCircuit (CircuitBreaker.Config, slots 15-16)
    uint256 internal constant SLOT_RECOVERY_CIRCUIT = 15;

    // ------------------------------------------------------------------
    // HELPERS
    // ------------------------------------------------------------------

    /// @notice Run a full round to a REJECTED verdict (the only appealable status)
    function _rejectRound(uint256 caseId) internal {
        _vote(caseId, governanceVoter, false);
        _vote(caseId, manufacturer, false);
        _vote(caseId, verifier, false);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);
    }

    /// @notice Put the circuit breaker one event below its trip threshold
    /// @dev Rewrites the packed CircuitBreaker.Config slot directly rather than making 49
    ///      real recoveries, which would need 49 minted, bound, activated, claimed and
    ///      flagged tokens and would drown the property under fixture noise. Slot 15 packs
    ///      windowStart(64) | cooldownEnds(64) | count(64) | threshold(32) | tripped(8).
    ///      windowStart is set to now so check() does not open a fresh window and reset the
    ///      count on the very call that is supposed to trip it.
    function _armCircuitBreaker() internal {
        uint256 v = uint256(vm.load(address(recovery), bytes32(SLOT_RECOVERY_CIRCUIT)));
        uint32 threshold = uint32(v >> 192);
        assertGt(threshold, 1, "circuit breaker must be initialized");
        v &= ~uint256(type(uint64).max); // clear windowStart
        v |= uint256(uint64(block.timestamp));
        v &= ~(uint256(type(uint64).max) << 128); // clear count
        v |= uint256(uint64(threshold - 1)) << 128;
        vm.store(address(recovery), bytes32(SLOT_RECOVERY_CIRCUIT), bytes32(v));

        (uint64 count,, bool tripped,) = recovery.getCircuitBreakerState();
        assertEq(count, threshold - 1, "armed one event below the threshold");
        assertFalse(tripped, "not tripped yet - the NEXT call must be what trips it");
    }

    /// @notice Erase a case's pause-credit stamp, reproducing a case rejected BEFORE this upgrade
    /// @dev The stamp is stored offset by one, so a raw 0 is exactly what an implementation
    ///      that predates slot 27 leaves behind.
    function _erasePauseCreditStamp(uint256 caseId) internal {
        vm.store(address(recovery), keccak256(abi.encode(caseId, SLOT_PAUSE_CREDIT_AT_REJECTION)), bytes32(0));
    }

    /// @notice Pause for `duration`, then unpause, banking `duration` seconds of pause credit
    function _pauseFor(uint256 duration) internal {
        vm.prank(owner);
        recovery.pause();
        vm.warp(block.timestamp + duration);
        vm.prank(owner);
        recovery.unpause();
    }

    /// @notice Vote a round through with the STANDARD fixture roster
    /// @dev Deliberately the same three addresses in every round. Reusing them is the
    ///      whole point of F-D: before the round counter they were locked out of round two.
    function _rosterVotes(uint256 caseId, bool approve) internal {
        _vote(caseId, governanceVoter, approve);
        _vote(caseId, manufacturer, approve);
        _vote(caseId, verifier, approve);
    }

    // ==================================================================
    // LENS — what the design is supposed to do (unchanged, still true)
    // ==================================================================

    function test_regression_executeResolutionAloneMovesNothing() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        _rosterVotes(caseId, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        assertEq(core.ownerOf(tokenId), holder, "asset must not move on a vote alone");
        assertEq(
            uint8(recovery.getCase(caseId).status),
            uint8(IRecovery.CaseStatus.ENFORCING),
            "must NOT claim RESOLVED over a no-op"
        );
        assertEq(recovery.totalStakesHeld(), MINIMUM_STAKE, "bond still escrowed");
    }

    function test_regression_wonCaseEndsWithClaimantOwningTheNFT() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 before = token.balanceOf(claimant);
        uint256 caseId = _caseInEnforcing(tokenId);

        _resolversDeliver(tokenId, claimant);
        recovery.finalizeResolution(caseId);

        assertEq(core.ownerOf(tokenId), claimant, "NFT OWNERSHIP: claimant");
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.RESOLVED));
        assertEq(token.balanceOf(claimant), before, "bond refunded 100%");
    }

    // ==================================================================
    // F-B — ENFORCING/APPEALED belong in the active-case guard
    // ==================================================================

    /// @dev WAS: a second bonded case opened over a token with a live ENFORCING verdict and
    ///      silently repointed _tokenToCase at itself.
    function test_regression_secondCaseCannotOpenWhileFirstIsEnforcing() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _caseInEnforcing(tokenId);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.ENFORCING));
        assertEq(recovery.getActiveCaseForToken(tokenId), caseA);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ActiveCaseExists.selector, tokenId, caseA));
        recovery.initiateRecovery(tokenId, keccak256("second"));

        assertEq(recovery.getActiveCaseForToken(tokenId), caseA, "the live case still owns the link");
        assertTrue(recovery.isQuarantined(tokenId));
    }

    /// @dev WAS: a free grief. The decoy cast no votes, EXPIRED with a 100% refund, and on
    ///      the way out cleared _quarantined and _tokenToCase for a token that was still
    ///      FLAGGED with a live bonded case against it — isQuarantined() then lied.
    function test_regression_freeGriefIsRefusedAtTheDoor() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _caseInEnforcing(tokenId);
        assertTrue(recovery.isQuarantined(tokenId), "quarantined while enforcing");

        uint256 griefBalanceBefore = token.balanceOf(thirdParty);
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ActiveCaseExists.selector, tokenId, caseA));
        recovery.initiateRecovery(tokenId, keccak256("grief"));

        // Nothing was taken from the griefer and nothing was disturbed.
        assertEq(token.balanceOf(thirdParty), griefBalanceBefore, "no bond was even collected");
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.ENFORCING));
        (,, TAGITCore.State st,,) = core.getAsset(tokenId);
        assertEq(uint8(st), uint8(TAGITCore.State.FLAGGED));
        assertTrue(recovery.isQuarantined(tokenId), "isQuarantined() still tells the truth");
        assertEq(recovery.getActiveCaseForToken(tokenId), caseA, "active case link intact");
    }

    /// @dev DEFENCE IN DEPTH. The guard above is the fix; this is what survives someone
    ///      adding a new non-terminal CaseStatus and forgetting to list it in the guard.
    ///      A terminating case must only clear a link that still points at ITSELF.
    function test_regression_terminalPathNeverUnlinksAnotherCasesToken() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _caseInEnforcing(tokenId);
        assertEq(recovery.getActiveCaseForToken(tokenId), caseA);

        // Force the exact damage the missing guard used to allow. This is unreachable
        // through the public API now, so it is written directly to storage: without it the
        // defence inside _unlinkToken would never be exercised by any test.
        uint256 foreignCase = 999;
        vm.store(address(recovery), keccak256(abi.encode(tokenId, SLOT_TOKEN_TO_CASE)), bytes32(uint256(foreignCase)));
        assertEq(recovery.getActiveCaseForToken(tokenId), foreignCase, "link now belongs to someone else");

        vm.warp(recovery.enforcementDeadline(caseA) + 1);
        recovery.expireEnforcement(caseA);

        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.EXPIRED), "caseA still settles");
        assertEq(recovery.getActiveCaseForToken(tokenId), foreignCase, "caseA must not erase a link it does not own");
        assertTrue(recovery.isQuarantined(tokenId), "and must not switch the quarantine view off");
    }

    /// @dev The guard must not over-block: once a case is genuinely terminal the asset is
    ///      available for a fresh case again.
    function test_regression_guardReleasesAfterTerminalStatus() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _caseInEnforcing(tokenId);

        vm.warp(recovery.enforcementDeadline(caseA) + 1);
        recovery.expireEnforcement(caseA);
        assertEq(recovery.getActiveCaseForToken(tokenId), 0);

        vm.prank(thirdParty);
        uint256 caseB = recovery.initiateRecovery(tokenId, keccak256("second"));
        assertTrue(caseB != caseA);
        assertEq(recovery.getActiveCaseForToken(tokenId), caseB);
    }

    /// @dev WAS: appeal() unconditionally repointed _tokenToCase at itself, stealing the
    ///      link from a different, still-live case opened after the first was rejected.
    ///
    ///      PREMISE UPDATED FOR D-2. A case rejected under the bounded appeal window keeps
    ///      its own link, so through the ordinary API no other case can hold that link while
    ///      this one is appealable — which would leave this guard unexercised and the proof
    ///      dead. The one state where the two really do coexist is the UPGRADE state: a case
    ///      rejected by the previous implementation has NO recorded deadline and already
    ///      released its link, so appeal()'s legacy carve-out lets it through and the link
    ///      may since have been taken. That is simulated here exactly — zero the deadline
    ///      slot, which is what an upgraded proxy actually holds — rather than being faked
    ///      with an unreachable status.
    function test_regression_appealCannotClobberAnotherLiveCasesTokenLink() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenId);
        _rejectRound(caseA);

        // Reproduce a case rejected BEFORE the bounded window shipped: no deadline recorded.
        vm.store(address(recovery), keccak256(abi.encode(caseA, SLOT_APPEAL_DEADLINE)), bytes32(0));
        assertEq(recovery.appealDeadline(caseA), 0, "legacy REJECTED case: no window on record");

        // Its link is therefore stale, and the next initiateRecovery lazily releases it.
        vm.prank(thirdParty);
        uint256 caseB = recovery.initiateRecovery(tokenId, keccak256("second"));
        assertEq(recovery.getActiveCaseForToken(tokenId), caseB);

        // The legacy carve-out keeps caseA appealable — but never at caseB's expense.
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ActiveCaseExists.selector, tokenId, caseB));
        recovery.appeal(caseA, APPEAL_EVIDENCE);

        assertEq(recovery.getActiveCaseForToken(tokenId), caseB, "caseB keeps its link");
        assertEq(uint8(recovery.getCase(caseB).status), uint8(IRecovery.CaseStatus.VOTING), "caseB still live");
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.REJECTED), "caseA unchanged");
    }

    // ==================================================================
    // F-A — appeal() bond accounting
    // ==================================================================

    /// @dev WAS: round one had already disbursed its bond in full, yet appeal() collected
    ///      2x and RECORDED 3x. Every round-two exit then subtracted 3x from a 2x ledger.
    function test_regression_appealedCaseBondAccountingIsExact() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.REJECTED));
        assertEq(recovery.totalStakesHeld(), 0, "round-one bond fully disbursed");
        assertEq(token.balanceOf(address(recovery)), 0, "contract holds nothing");

        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);

        // Collected, recorded and held are one number.
        assertEq(token.balanceOf(address(recovery)), 2 * MINIMUM_STAKE, "2x collected");
        assertEq(recovery.totalStakesHeld(), 2 * MINIMUM_STAKE, "2x recorded in the ledger");
        assertEq(recovery.getCase(caseId).stakeBond, 2 * MINIMUM_STAKE, "2x recorded on the case");
        assertGe(
            token.balanceOf(address(recovery)), recovery.getCase(caseId).stakeBond, "escrow covers the recorded bond"
        );
    }

    /// @dev WAS THE WORST CASE: the claimant WON the appeal, TAGITCore delivered the asset,
    ///      and finalizeResolution() could never be called — the bond was stuck forever.
    ///      This is the exact "permanent lock" class the remediation claimed to have killed.
    function test_regression_wonAppealFinalizesAndRefundsInFull() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);

        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);

        // The SAME roster votes round two. That is only possible because appeal() opens a
        // new round (F-D); before that these three were locked out for good.
        _rosterVotes(caseId, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.ENFORCING));

        _resolversDeliver(tokenId, claimant);
        assertEq(core.ownerOf(tokenId), claimant, "asset WAS delivered");

        recovery.finalizeResolution(caseId);

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.RESOLVED));
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(token.balanceOf(address(recovery)), 0, "nothing stranded in the contract");
        // Only round one's 50% slash was ever taken; the appeal bond came back whole.
        assertEq(token.balanceOf(claimant), balanceBefore - MINIMUM_STAKE / 2, "appeal bond refunded 100%");
        assertEq(token.balanceOf(treasury), MINIMUM_STAKE / 2, "treasury kept only the round-one slash");
    }

    /// @dev WAS: a rejected appeal panicked on totalStakesHeld underflow.
    function test_regression_rejectedAppealSettlesCleanly() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);

        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);

        _rosterVotes(caseId, false);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.REJECTED));
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(token.balanceOf(address(recovery)), 0, "nothing stranded");
        // Slashes: 50 (round one, of 100) + 100 (round two, of 200)
        assertEq(token.balanceOf(treasury), MINIMUM_STAKE / 2 + MINIMUM_STAKE, "50% of each round's own bond");
        assertEq(token.balanceOf(claimant), balanceBefore - (MINIMUM_STAKE / 2 + MINIMUM_STAKE));
    }

    /// @dev WAS: an appealed case that drew no votes panicked in the EXPIRED branch — the
    ///      branch that exists precisely so a bond can never be trapped by voter apathy.
    ///
    ///      PREMISE UPDATED FOR D-1. The branch still settles instead of panicking, which is
    ///      what this test is for, but a ZERO-vote expiry is no longer free: the anti-squat
    ///      fee applies to the 2x appeal bond exactly as it applies to a first-round bond.
    ///      Nothing may be stranded on the way out.
    function test_regression_appealWithNoQuorumExpiresAndPaysTheFeeOnTheDoubledBond() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);

        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);
        assertEq(recovery.getCase(caseId).stakeBond, 2 * MINIMUM_STAKE, "2x escrowed");

        uint256 treasuryBeforeExpiry = token.balanceOf(treasury);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        uint256 appealFee = (2 * MINIMUM_STAKE * 1000) / 10000; // 10% of the 2x bond
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(token.balanceOf(address(recovery)), 0, "nothing stranded");
        assertEq(token.balanceOf(treasury) - treasuryBeforeExpiry, appealFee, "fee scales with the recorded bond");
        // Total out of pocket: round one's 50% slash of 100, plus 10% of the 200 appeal bond.
        assertEq(
            token.balanceOf(claimant),
            balanceBefore - MINIMUM_STAKE / 2 - appealFee,
            "appeal bond refunded less the anti-squat fee"
        );
        assertEq(recovery.getActiveCaseForToken(tokenId), 0);
        assertFalse(recovery.isQuarantined(tokenId));
    }

    /// @dev The abandon/expire exits must settle an appealed escrow too.
    function test_regression_abandonedAppealReleasesTheDoubledEscrow() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);

        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);
        _rosterVotes(caseId, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        vm.prank(claimant);
        recovery.abandonEnforcement(caseId);

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(token.balanceOf(claimant), balanceBefore - MINIMUM_STAKE / 2, "2x bond returned unslashed");
    }

    // ==================================================================
    // F-G — "a tripped circuit breaker can never trap an escrowed bond"
    // ==================================================================

    /// @dev KNOWN-ISSUES KI-25 items 4 and 6 were FALSE for appealed cases while F-A stood.
    ///      This is the test that makes both claims true rather than merely written down.
    function test_regression_pausedContractStillReleasesAnAppealedBond() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);

        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);
        _rosterVotes(caseId, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        vm.prank(owner);
        recovery.pause();

        _resolversDeliver(tokenId, claimant);
        recovery.finalizeResolution(caseId); // exit paths are never whenNotPaused

        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.RESOLVED));
        assertEq(token.balanceOf(claimant), balanceBefore - MINIMUM_STAKE / 2, "appealed bond released despite pause");
        assertEq(recovery.totalStakesHeld(), 0);
        assertEq(token.balanceOf(address(recovery)), 0);
    }

    // ==================================================================
    // F-D — appeal() opens a new voting round
    // ==================================================================

    /// @dev WAS: appeal() reset votesFor/votesAgainst/voteCount but left _hasVoted set, so
    ///      every round-one juror was locked out of round two. With the fixture roster and
    ///      MINIMUM_VOTES=3 an appealed case could never reach quorum again.
    function test_regression_appealOpensANewRoundAndUnlocksTheRoster() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);
        assertEq(recovery.caseRound(caseId), 0, "round one");
        assertTrue(recovery.hasVoted(caseId, verifier), "verifier voted in round one");

        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);

        assertEq(recovery.caseRound(caseId), 1, "appeal opened round two");
        assertEq(recovery.getCase(caseId).voteCount, 0, "tally reset");
        assertFalse(recovery.hasVoted(caseId, verifier), "round-two record is clean");

        // The round-one record is preserved, not destroyed — it is simply a closed round.
        assertTrue(recovery.hasVotedInRound(caseId, 0, verifier), "round-one record survives");
        assertEq(recovery.getVoteInRound(caseId, 0, verifier).weight, 1);
        assertFalse(recovery.getVoteInRound(caseId, 0, verifier).approve, "round one was a NO");

        // And the same juror may now vote again, the other way.
        _vote(caseId, verifier, true);
        assertTrue(recovery.hasVoted(caseId, verifier));
        assertTrue(recovery.getVote(caseId, verifier).approve, "round two is a YES");
        assertFalse(recovery.getVoteInRound(caseId, 0, verifier).approve, "round one is still a NO");

        // Double-voting is still impossible WITHIN a round.
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AlreadyVoted.selector, caseId, verifier));
        recovery.vote(caseId, true, REASON_HASH);
    }

    /// @dev The end-to-end consequence: an appealed case reaches quorum with the ordinary
    ///      roster instead of falling into EXPIRED for want of eligible voters.
    function test_regression_appealedCaseReachesQuorumWithTheOrdinaryRoster() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);

        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);
        _rosterVotes(caseId, true);

        IRecovery.RecoveryCase memory c = recovery.getCase(caseId);
        assertEq(c.voteCount, 3, "quorum reached in round two");
        assertEq(c.votesFor, 8, "4 + 3 + 1");
        assertEq(c.votesAgainst, 0);

        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);
        assertEq(
            uint8(recovery.getCase(caseId).status),
            uint8(IRecovery.CaseStatus.ENFORCING),
            "adjudicated, not expired for want of voters"
        );
    }

    // ==================================================================
    // F-E — the pre-flag gate must mirror resolve()'s own predicate
    // ==================================================================

    /// @dev WAS: initiateRecovery() demanded preFlagState == CLAIMED, but TAGITCore.resolve()
    ///      treats a stored NONE (a token flagged BEFORE the marker shipped) as CLAIMED and
    ///      delivers it. Legacy-flagged assets were locked out of AIRP for no reason.
    function test_regression_legacyFlaggedTokenIsAdmittedAndDeliverable() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);

        // Simulate a token flagged before _preFlagState existed: the marker reads NONE.
        vm.store(address(core), keccak256(abi.encode(tokenId, SLOT_PRE_FLAG_STATE)), bytes32(0));
        assertEq(uint8(core.preFlagState(tokenId)), uint8(TAGITCore.State.NONE));

        // AIRP now admits exactly what resolve() would honour.
        uint256 caseId = _openCase(tokenId);
        _rosterVotes(caseId, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        _resolversDeliver(tokenId, claimant);
        recovery.finalizeResolution(caseId);

        assertEq(core.ownerOf(tokenId), claimant, "legacy-flagged asset really is deliverable");
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.RESOLVED));
    }

    /// @dev The gate must still refuse what resolve() genuinely cannot reassign.
    function test_regression_boundAndActivatedPreFlagStatesStayRejected() public {
        uint256 boundToken = _mintBound(manufacturer);
        vm.prank(manufacturer);
        core.flag(boundToken);
        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(IRecovery.AssetNotRecoverable.selector, boundToken, uint8(TAGITCore.State.BOUND))
        );
        recovery.initiateRecovery(boundToken, EVIDENCE_HASH);

        uint256 activatedToken = _mintActivated(manufacturer);
        vm.prank(manufacturer);
        core.flag(activatedToken);
        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecovery.AssetNotRecoverable.selector, activatedToken, uint8(TAGITCore.State.ACTIVATED)
            )
        );
        recovery.initiateRecovery(activatedToken, EVIDENCE_HASH);
    }

    // ==================================================================
    // F-C — AIRP jury seats are their own IdentityBadge namespace
    // ==================================================================

    /// @dev WAS: the juror lookup moved from the transferable CapabilityBadge to the
    ///      soulbound IdentityBadge (correct) but kept ids 1/2/10/20 (wrong). Those are
    ///      KYC_L1, KYC_L2, MANUFACTURER and GOV_MIL in the ONE flat IdentityBadge
    ///      registry, so three ordinary KYC'd accounts formed a jury and slashed a bond.
    function test_regression_plainKycUsersAreNotAirpJurors() public {
        // The seats live in the reserved 70-79 range and collide with nothing.
        assertEq(recovery.BADGE_AIRP_JUROR(), 70);
        assertEq(recovery.BADGE_AIRP_SENIOR_JUROR(), 71);
        assertEq(recovery.BADGE_AIRP_ARBITER(), 72);
        assertEq(recovery.BADGE_AIRP_TRIBUNAL(), 73);

        uint256[4] memory seats = [
            recovery.BADGE_AIRP_JUROR(),
            recovery.BADGE_AIRP_SENIOR_JUROR(),
            recovery.BADGE_AIRP_ARBITER(),
            recovery.BADGE_AIRP_TRIBUNAL()
        ];
        for (uint256 i = 0; i < seats.length; i++) {
            assertTrue(seats[i] >= 70 && seats[i] <= 79, "seat outside the reserved AIRP range");
            assertTrue(seats[i] != KYC_L1_IDENTITY, "an AIRP seat must never be KYC_L1");
            assertTrue(seats[i] != KYC_L2_IDENTITY, "an AIRP seat must never be KYC_L2");
            assertTrue(seats[i] != REGISTRY_MANUFACTURER, "an AIRP seat must never be MANUFACTURER");
            assertTrue(seats[i] != REGISTRY_GOV_MIL, "an AIRP seat must never be GOV_MIL");
        }

        // Three fully KYC'd accounts. None of them carries any AIRP weight.
        address[3] memory kycUsers = [makeAddr("kyc1"), makeAddr("kyc2"), makeAddr("kyc3")];
        vm.startPrank(owner);
        for (uint256 i = 0; i < 3; i++) {
            identityBadge.grantIdentity(kycUsers[i], KYC_L1_IDENTITY);
            identityBadge.grantIdentity(kycUsers[i], KYC_L2_IDENTITY);
            identityBadge.grantIdentity(kycUsers[i], REGISTRY_MANUFACTURER);
            identityBadge.grantIdentity(kycUsers[i], REGISTRY_GOV_MIL);
        }
        vm.stopPrank();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(recovery.getVoteWeight(kycUsers[i]), 0, "KYC / business / gov badges are NOT jury seats");
        }

        // And they cannot vote, so they cannot slash.
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        uint256 balanceBefore = token.balanceOf(claimant);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(kycUsers[i]);
            vm.expectRevert(abi.encodeWithSelector(IRecovery.NotBadgeHolder.selector, kycUsers[i]));
            recovery.vote(caseId, false, REASON_HASH);
        }

        // No quorum was manufactured, so the case EXPIRES and is never SLASHED. Since the
        // decoy jury could not cast a single vote, the expiry is a zero-vote expiry and pays
        // the 10% anti-squat fee — a fee for occupying the slot, not a 50% finding of fraud.
        // The claim this test defends is that no jury of KYC'd strangers can take half a
        // bond, and that is still exactly what it shows.
        uint256 squatFee = (MINIMUM_STAKE * 1000) / 10000;
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(claimant), balanceBefore + MINIMUM_STAKE - squatFee, "no 50% slash");
        assertEq(token.balanceOf(treasury), squatFee, "the anti-squat fee, not a slash");
        assertLt(squatFee, (MINIMUM_STAKE * 5000) / 10000);
    }

    /// @dev An explicitly granted seat still works, and still weighs what it should.
    function test_regression_grantedAirpSeatsCarryTheirWeight() public {
        address juror = makeAddr("seatJuror");
        address senior = makeAddr("seatSenior");
        address arbiter = makeAddr("seatArbiter");
        address tribunal = makeAddr("seatTribunal");

        vm.startPrank(owner);
        identityBadge.grantIdentity(juror, recovery.BADGE_AIRP_JUROR());
        identityBadge.grantIdentity(senior, recovery.BADGE_AIRP_SENIOR_JUROR());
        identityBadge.grantIdentity(arbiter, recovery.BADGE_AIRP_ARBITER());
        identityBadge.grantIdentity(tribunal, recovery.BADGE_AIRP_TRIBUNAL());
        vm.stopPrank();

        assertEq(recovery.getVoteWeight(juror), 1);
        assertEq(recovery.getVoteWeight(senior), 2);
        assertEq(recovery.getVoteWeight(arbiter), 3);
        assertEq(recovery.getVoteWeight(tribunal), 4);
    }

    // ==================================================================
    // F-F — an error name must state the condition it fires on
    // ==================================================================

    /// @dev WAS: vote() reverted VotingStillActive when the voting period had ENDED — the
    ///      exact opposite of what the name says. executeResolution() keeps that error for
    ///      its correct meaning, so the two must be distinguishable.
    function test_regression_voteAfterDeadlineRevertsVotingPeriodEnded() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        uint256 endsAt = recovery.getCase(caseId).votingEndsAt;

        // Before the deadline: executeResolution is the one that is premature.
        vm.expectRevert(abi.encodeWithSelector(IRecovery.VotingStillActive.selector, caseId, endsAt));
        recovery.executeResolution(caseId);

        // After the deadline: voting is the one that is late.
        vm.warp(endsAt + 1);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.VotingPeriodEnded.selector, caseId, endsAt));
        recovery.vote(caseId, true, REASON_HASH);
    }

    // ==================================================================
    // D-1 — a decoy case must never be free
    // ==================================================================

    /// @dev THE POC, INVERTED. The original PoC ran five squat cycles and asserted the
    ///      griefer's balance was UNCHANGED at the end: bond in, whole bond out, the real
    ///      owner locked out of AIRP for 7 days per cycle, repeatable forever for gas.
    ///      Now every cycle costs 10% and the ledger moves one way only.
    function test_regression_repeatedSquattingNowCostsTheGrieferEveryCycle() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 squatFee = (MINIMUM_STAKE * 1000) / 10000;

        uint256 grieferBalance = token.balanceOf(thirdParty);
        uint256 treasuryBalance = token.balanceOf(treasury);

        for (uint256 cycle = 0; cycle < 5; cycle++) {
            // The squatter is NOT the holder, casts no votes, and takes the slot.
            vm.prank(thirdParty);
            uint256 decoy = recovery.initiateRecovery(tokenId, keccak256(abi.encode("squat", cycle)));
            assertEq(recovery.getActiveCaseForToken(tokenId), decoy, "the real owner is locked out");

            vm.warp(block.timestamp + VOTING_DURATION + 1);
            recovery.executeResolution(decoy);
            assertEq(uint8(recovery.getCase(decoy).status), uint8(IRecovery.CaseStatus.EXPIRED));
            assertEq(recovery.getCase(decoy).voteCount, 0, "zero engagement is the whole premise");

            uint256 grieferAfter = token.balanceOf(thirdParty);
            uint256 treasuryAfter = token.balanceOf(treasury);

            assertLt(grieferAfter, grieferBalance, "cycle must cost the griefer strictly more");
            assertGt(treasuryAfter, treasuryBalance, "treasury must gain strictly on every cycle");
            assertEq(grieferBalance - grieferAfter, squatFee, "exactly the 10% fee, per cycle");
            assertEq(treasuryAfter - treasuryBalance, squatFee, "and every wei of it lands in the treasury");

            grieferBalance = grieferAfter;
            treasuryBalance = treasuryAfter;

            // Nothing is left behind between cycles.
            assertEq(recovery.totalStakesHeld(), 0);
            assertEq(token.balanceOf(address(recovery)), 0, "no residue between cycles");
        }

        assertEq(token.balanceOf(treasury), 5 * squatFee, "five cycles, five fees");
    }

    /// @dev M1, THE POC INVERTED. The fee used to be keyed on voteCount == 0, so ONE address
    ///      holding a single AIRP juror seat that a griefer controls, rents or bribes could
    ///      cast one vote per decoy and drop every squat into the apathy carve-out. The
    ///      original PoC ran three cycles and asserted the griefer's balance was EXACTLY
    ///      unchanged and the treasury EXACTLY zero. It is now the same three cycles,
    ///      asserting the opposite.
    ///
    ///      vote() excludes only the claimant and the current holder, so the bribed seat is
    ///      an eligible voter on every decoy and this exploit needs no privilege at all
    ///      beyond one seat. That is precisely why one vote cannot be the bar.
    function test_regression_oneColludingVoteNoLongerExemptsADecoy() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 squatFee = (MINIMUM_STAKE * 1000) / 10000;

        uint256 grieferBalance = token.balanceOf(thirdParty);
        uint256 treasuryBalance = token.balanceOf(treasury);
        assertEq(treasuryBalance, 0, "the PoC starts from an empty treasury, as it did");

        for (uint256 cycle = 0; cycle < 3; cycle++) {
            vm.prank(thirdParty);
            uint256 decoy = recovery.initiateRecovery(tokenId, keccak256(abi.encode("collude", cycle)));

            // THE DODGE: exactly one vote, from a single seat the griefer has bought.
            _vote(decoy, verifier, true);

            vm.warp(block.timestamp + VOTING_DURATION + 1);
            recovery.executeResolution(decoy);

            IRecovery.RecoveryCase memory c = recovery.getCase(decoy);
            assertEq(uint8(c.status), uint8(IRecovery.CaseStatus.EXPIRED));
            assertEq(c.voteCount, 1, "one vote is the whole premise of the dodge");

            uint256 grieferAfter = token.balanceOf(thirdParty);
            uint256 treasuryAfter = token.balanceOf(treasury);
            assertEq(grieferBalance - grieferAfter, squatFee, "one bought vote must NOT buy the exemption");
            assertEq(treasuryAfter - treasuryBalance, squatFee, "and the fee lands in the treasury every cycle");

            grieferBalance = grieferAfter;
            treasuryBalance = treasuryAfter;
            assertEq(recovery.totalStakesHeld(), 0);
            assertEq(token.balanceOf(address(recovery)), 0, "no residue between cycles");
        }

        assertEq(token.balanceOf(treasury), 3 * squatFee, "three cycles, three fees");
    }

    /// @dev THE CARVE-OUT THE FEE MUST NOT SWALLOW — now at TWO votes, not one. Two votes is
    ///      still below MINIMUM_VOTES (3) and still EXPIRES, but it means two INDEPENDENTLY
    ///      GRANTED seats engaged and simply did not reach quorum. That is the jury's
    ///      failure, not the claimant's, and it refunds in full. If this ever starts
    ///      charging, the fee has stopped being an anti-squat fee and has become a tax on
    ///      being unlucky with turnout. One vote is deliberately NOT exempt: a single seat is
    ///      purchasable, which is exactly how the fee was being dodged.
    function test_regression_twoVotesExemptADecoyButOneDoesNot() public {
        uint256 squatFee = (MINIMUM_STAKE * 1000) / 10000;

        // ONE vote — below the threshold, so the fee applies.
        uint256 t1 = _mintClaimedAndFlagged(holder);
        uint256 before1 = token.balanceOf(claimant);
        uint256 treasury1 = token.balanceOf(treasury);
        uint256 c1 = _openCase(t1);
        _vote(c1, verifier, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c1);
        assertEq(uint8(recovery.getCase(c1).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(claimant), before1 - squatFee, "1 vote: one seat cannot buy the exemption");
        assertEq(token.balanceOf(treasury), treasury1 + squatFee, "1 vote: the fee still bites");

        // TWO votes, and split, so it is not a near-verdict either — refunded in FULL.
        uint256 t2 = _mintClaimedAndFlagged(holder);
        uint256 before2 = token.balanceOf(claimant);
        uint256 treasury2 = token.balanceOf(treasury);
        uint256 c2 = _openCase(t2);
        _vote(c2, verifier, true);
        _vote(c2, certifiedVerifier, false);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c2);
        assertEq(uint8(recovery.getCase(c2).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(claimant), before2, "2 votes: the bond comes back WHOLE");
        assertEq(token.balanceOf(treasury), treasury2, "2 votes: the treasury takes nothing");

        // ZERO votes still pays.
        uint256 t3 = _mintClaimedAndFlagged(holder);
        uint256 before3 = token.balanceOf(claimant);
        uint256 treasury3 = token.balanceOf(treasury);
        uint256 c3 = _openCase(t3);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c3);
        assertEq(token.balanceOf(claimant), before3 - squatFee, "0 votes: pays");
        assertEq(token.balanceOf(treasury), treasury3 + squatFee);

        // THREE votes still reaches quorum and is adjudicated, exactly as before.
        uint256 t4 = _mintClaimedAndFlagged(holder);
        uint256 treasury4 = token.balanceOf(treasury);
        uint256 c4 = _openCase(t4);
        _rosterVotes(c4, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c4);
        assertEq(recovery.getCase(c4).voteCount, 3, "quorum");
        assertEq(
            uint8(recovery.getCase(c4).status),
            uint8(IRecovery.CaseStatus.ENFORCING),
            "3 votes: adjudicated, never routed through the fee at all"
        );
        assertEq(token.balanceOf(treasury), treasury4, "an approved case pays no fee");

        // The threshold is a named constant, and it sits STRICTLY BELOW quorum — which is
        // what keeps the apathy carve-out alive at all.
        assertEq(recovery.FEE_EXEMPT_MIN_VOTES(), 2, "two, not one, and not a bare literal");
        assertLt(recovery.FEE_EXEMPT_MIN_VOTES(), recovery.MINIMUM_VOTES());
    }

    /// @dev ACCOUNTING, EVERY TERMINAL PATH. After each one the contract's real token
    ///      balance must reconcile with totalStakesHeld and nothing may be stranded. The
    ///      appealed zero-vote expiry is included because that is where the fee is applied
    ///      to a 2x bond — the one place a fixed-amount fee would have gone wrong.
    function test_regression_bondAccountingIsExactOnEveryTerminalPath() public {
        // --- EXPIRED, zero votes (fee on 1x) ---
        uint256 t1 = _mintClaimedAndFlagged(holder);
        uint256 c1 = _openCase(t1);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c1);
        _assertEscrowReconciles();

        // --- EXPIRED, two votes (no fee) ---
        uint256 t2 = _mintClaimedAndFlagged(holder);
        uint256 c2 = _openCase(t2);
        _vote(c2, verifier, true);
        _vote(c2, certifiedVerifier, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c2);
        _assertEscrowReconciles();

        // --- REJECTED (50% slash) ---
        uint256 t3 = _mintClaimedAndFlagged(holder);
        uint256 c3 = _openCase(t3);
        _rejectRound(c3);
        _assertEscrowReconciles();

        // --- APPEALED then EXPIRED with ZERO votes: the fee lands on the 2x bond ---
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(claimant);
        recovery.appeal(c3, APPEAL_EVIDENCE);
        assertEq(recovery.totalStakesHeld(), 2 * MINIMUM_STAKE, "2x escrowed");
        assertEq(token.balanceOf(address(recovery)), 2 * MINIMUM_STAKE, "2x actually held");
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(c3);
        assertEq(
            token.balanceOf(treasury) - treasuryBefore,
            (2 * MINIMUM_STAKE * 1000) / 10000,
            "the fee is a RATE on the recorded bond, not a fixed amount"
        );
        _assertEscrowReconciles();

        // --- RESOLVED (delivered) ---
        uint256 t4 = _mintClaimedAndFlagged(holder);
        uint256 c4 = _caseInEnforcing(t4);
        _resolversDeliver(t4, claimant);
        recovery.finalizeResolution(c4);
        _assertEscrowReconciles();

        // --- VOIDED (resolvers diverged) ---
        uint256 t5 = _mintClaimedAndFlagged(holder);
        uint256 c5 = _caseInEnforcing(t5);
        _resolversDeliver(t5, thirdParty);
        recovery.finalizeResolution(c5);
        _assertEscrowReconciles();

        // --- EXPIRED via expireEnforcement (approved, quorum never acted) ---
        uint256 t6 = _mintClaimedAndFlagged(holder);
        uint256 c6 = _caseInEnforcing(t6);
        vm.warp(recovery.enforcementDeadline(c6) + 1);
        recovery.expireEnforcement(c6);
        _assertEscrowReconciles();

        // --- EXPIRED via abandonEnforcement ---
        uint256 t7 = _mintClaimedAndFlagged(holder);
        uint256 c7 = _caseInEnforcing(t7);
        vm.prank(claimant);
        recovery.abandonEnforcement(c7);
        _assertEscrowReconciles();
    }

    /// @notice The escrow ledger and the contract's real balance must agree, with no residue
    function _assertEscrowReconciles() internal view {
        assertEq(
            token.balanceOf(address(recovery)),
            recovery.totalStakesHeld(),
            "escrow ledger does not match the tokens actually held"
        );
        assertEq(recovery.totalStakesHeld(), 0, "every case above is terminal: nothing may remain");
    }

    // ==================================================================
    // D-2 — a REJECTED case owns its own appeal window
    // ==================================================================

    /// @dev THE POC, INVERTED. Originally: caseA is REJECTED, executeResolution unlinks the
    ///      token in the same transaction, and a third party opens a decoy on the freed slot
    ///      before the claimant — who just paid a 50% slash to earn the appeal — can use it.
    ///      appeal() then reverted ActiveCaseExists. executeResolution is permissionless but
    ///      appeal() is claimant-only, so an EOA could not expire the decoy and appeal
    ///      atomically and the griefer simply front-ran the slot again, forever, for gas.
    function test_regression_thirdPartyCannotGriefAwayTheAppealRight() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenId);
        _rejectRound(caseA);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.REJECTED));

        // The rejected case KEEPS the token's dispute slot for the length of its window.
        uint256 deadline = recovery.appealDeadline(caseA);
        assertEq(deadline, block.timestamp + APPEAL_WINDOW, "7-day window recorded at rejection");
        assertEq(recovery.getActiveCaseForToken(tokenId), caseA, "caseA still owns the slot");

        // THE GRIEF, REFUSED AT THE DOOR — and not one wei was taken from the griefer.
        uint256 grieferBefore = token.balanceOf(thirdParty);
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ActiveCaseExists.selector, tokenId, caseA));
        recovery.initiateRecovery(tokenId, keccak256("decoy"));
        assertEq(token.balanceOf(thirdParty), grieferBefore, "no bond collected on a refused case");

        // It stays refused for the whole window, right up to the last second.
        vm.warp(deadline);
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ActiveCaseExists.selector, tokenId, caseA));
        recovery.initiateRecovery(tokenId, keccak256("decoy-late"));

        // AND THE RIGHT THE WINDOW EXISTS TO PROTECT ACTUALLY WORKS.
        vm.prank(claimant);
        recovery.appeal(caseA, APPEAL_EVIDENCE);

        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.VOTING), "round two is live");
        assertEq(recovery.caseRound(caseA), 1);
        assertEq(recovery.getCase(caseA).stakeBond, 2 * MINIMUM_STAKE);
        assertEq(recovery.getActiveCaseForToken(tokenId), caseA);
        assertEq(recovery.appealDeadline(caseA), 0, "the window is spent once the case reopens");
    }

    /// @dev The window must be a WINDOW, not a lock. Once it lapses with no appeal, the slot
    ///      belongs to whoever wants it, the stale link is cleaned up LAZILY inside
    ///      initiateRecovery — no keeper, no cleanup function, no way to strand an asset —
    ///      and the lapsed case can no longer reopen.
    function test_regression_lapsedAppealWindowFreesTheSlotLazily() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenId);
        _rejectRound(caseA);
        uint256 deadline = recovery.appealDeadline(caseA);

        vm.warp(deadline + 1);

        // Nobody had to call anything: the stale link is still recorded...
        assertEq(recovery.getActiveCaseForToken(tokenId), caseA, "still stale: cleanup is lazy, not scheduled");

        // ...and the next case sweeps it up on the way in.
        vm.prank(thirdParty);
        uint256 caseB = recovery.initiateRecovery(tokenId, keccak256("second"));
        assertTrue(caseB != caseA);
        assertEq(recovery.getActiveCaseForToken(tokenId), caseB, "the new case owns the slot");
        assertEq(uint8(recovery.getCase(caseB).status), uint8(IRecovery.CaseStatus.VOTING));
        assertTrue(recovery.isQuarantined(tokenId));

        // The lapsed case is genuinely closed to appeal, and says so honestly.
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AppealWindowClosed.selector, caseA, deadline));
        recovery.appeal(caseA, APPEAL_EVIDENCE);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.REJECTED), "caseA untouched");
    }

    /// @dev The boundary itself: appealable AT the deadline, closed one second later.
    function test_regression_appealWindowBoundaryIsInclusive() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenId);
        _rejectRound(caseA);
        uint256 deadline = recovery.appealDeadline(caseA);

        vm.warp(deadline + 1);
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AppealWindowClosed.selector, caseA, deadline));
        recovery.appeal(caseA, APPEAL_EVIDENCE);

        // Rewind to the exact deadline: still open.
        vm.warp(deadline);
        vm.prank(claimant);
        recovery.appeal(caseA, APPEAL_EVIDENCE);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.VOTING));
    }

    // ==================================================================
    // D-2 — the window getter must not repeat the F-H mistake
    // ==================================================================

    /// @dev MIRRORS test_enforcementWindow_zeroFallbackAfterUpgradeFromV1 exactly, because
    ///      the appeal window is the same shape of slot and would fail the same way. A proxy
    ///      upgraded from an implementation that predates slot 23 reads 0 there. It is not
    ///      enough for the getter to REPORT 7 days: the fallback must actually be APPLIED,
    ///      or every case rejected right after the upgrade gets a deadline of exactly
    ///      block.timestamp — an appeal right that expires in the transaction that creates
    ///      it, which is precisely the D-2 grief this window exists to close.
    function test_regression_appealWindowZeroFallbackIsReportedAndApplied() public {
        // Reproduce the upgraded-but-never-reinitialized proxy: raw slot 23 == 0.
        vm.store(address(recovery), bytes32(SLOT_APPEAL_WINDOW), bytes32(0));
        assertEq(uint256(vm.load(address(recovery), bytes32(SLOT_APPEAL_WINDOW))), 0, "raw storage really is zero");
        assertEq(recovery.configuredAppealWindow(), 0, "raw getter still reports unconfigured");
        assertEq(recovery.appealWindow(), APPEAL_WINDOW, "effective getter reports what is actually enforced");

        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenId);
        _rejectRound(caseA);

        // APPLIED, not merely reported.
        assertEq(
            recovery.appealDeadline(caseA),
            block.timestamp + APPEAL_WINDOW,
            "must fall back to 7 days, not to block.timestamp"
        );

        // And the protection is real on an upgraded proxy: the slot is genuinely held.
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ActiveCaseExists.selector, tokenId, caseA));
        recovery.initiateRecovery(tokenId, keccak256("decoy"));

        vm.prank(claimant);
        recovery.appeal(caseA, APPEAL_EVIDENCE);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.VOTING));
    }

    /// @dev Bounds and authority, mirroring test_setEnforcementWindow_boundsAndAuthority.
    function test_regression_setAppealWindowBoundsAndAuthority() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.InvalidAppealWindow.selector, 1 days - 1));
        recovery.setAppealWindow(1 days - 1);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.InvalidAppealWindow.selector, 30 days + 1));
        recovery.setAppealWindow(30 days + 1);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, randomUser));
        recovery.setAppealWindow(14 days);

        vm.expectEmit(false, false, false, true);
        emit AppealWindowUpdated(APPEAL_WINDOW, 14 days);
        vm.prank(governor);
        recovery.setAppealWindow(14 days);
        assertEq(recovery.appealWindow(), 14 days);
        assertEq(recovery.configuredAppealWindow(), 14 days);

        // Boundaries themselves are valid
        vm.prank(governor);
        recovery.setAppealWindow(1 days);
        vm.prank(governor);
        recovery.setAppealWindow(30 days);
        assertEq(recovery.appealWindow(), 30 days);

        // A configured window is what a newly rejected case actually gets...
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenId);
        _rejectRound(caseA);
        assertEq(recovery.appealDeadline(caseA), block.timestamp + 30 days, "the configured window is applied");

        // ...and shortening it afterwards must NOT retract a right already granted.
        vm.prank(governor);
        recovery.setAppealWindow(1 days);
        assertEq(recovery.appealDeadline(caseA), block.timestamp + 30 days, "recorded deadlines are not retroactive");
        vm.warp(block.timestamp + 20 days);
        vm.prank(claimant);
        recovery.appeal(caseA, APPEAL_EVIDENCE);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.VOTING));
    }

    // ==================================================================
    // M2 — a pause must never consume a paid-for appeal right
    // ==================================================================

    /// @dev THE POC, INVERTED. appeal() carries whenNotPaused and _appealDeadline was an
    ///      absolute wall-clock instant that nothing extended, so a pause outlasting the
    ///      window destroyed an appeal right the claimant had just paid a 50% slash to earn.
    ///      Before the window existed a pause merely DELAYED the appeal; the window turned
    ///      the same pause into a permanent taking. The window now counts UNPAUSED seconds.
    function test_regression_pauseSpanningTheWindowDoesNotDestroyTheAppealRight() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenId);
        _rejectRound(caseA);

        uint256 recorded = recovery.appealDeadline(caseA);
        assertEq(recorded, block.timestamp + APPEAL_WINDOW, "the raw wall-clock deadline is still recorded");
        assertEq(recovery.appealDeadlineEffective(caseA), recorded, "no pause yet: effective == recorded");

        // A pause that swallows the whole window and then some.
        vm.prank(owner);
        recovery.pause();
        vm.warp(recorded + 3 days);
        // Even mid-pause the effective deadline is honest about the credit accruing.
        assertGt(recovery.appealDeadlineEffective(caseA), block.timestamp, "credit accrues during the pause");
        vm.prank(owner);
        recovery.unpause();

        // THE ORIGINAL WALL-CLOCK DEADLINE IS LONG GONE. That is the premise.
        assertGt(block.timestamp, recorded, "the raw deadline really has passed");

        // The window was credited the full 10 days it spent paused.
        assertEq(recovery.appealDeadlineEffective(caseA), recorded + 10 days, "credited every paused second");

        // The slot was never released either, so nobody could have taken it meanwhile.
        assertEq(recovery.getActiveCaseForToken(tokenId), caseA, "the case still owns the slot");

        // AND THE RIGHT ACTUALLY WORKS.
        vm.prank(claimant);
        recovery.appeal(caseA, APPEAL_EVIDENCE);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.VOTING), "round two is live");
        assertEq(recovery.appealDeadline(caseA), 0, "the window is spent once the case reopens");
        assertEq(recovery.appealDeadlineEffective(caseA), 0, "and so is its pause credit");
    }

    /// @dev The credit must be a CREDIT, not a suspension. Once the contract is unpaused the
    ///      clock runs again, the credited window really does expire, and the token's dispute
    ///      slot goes to whoever wants it. A fix that made the window unbounded under any
    ///      historical pause would just be D-2 again with extra steps.
    function test_regression_pauseCreditExpiresAndTheSlotIsReleased() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenId);
        _rejectRound(caseA);
        uint256 recorded = recovery.appealDeadline(caseA);

        _pauseFor(2 days);
        uint256 eff = recovery.appealDeadlineEffective(caseA);
        assertEq(eff, recorded + 2 days, "exactly the paused seconds, no more");

        vm.warp(eff + 1);

        // The credited window has genuinely lapsed, and says so honestly — quoting the
        // EFFECTIVE deadline, which is the number the contract actually enforced.
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AppealWindowClosed.selector, caseA, eff));
        recovery.appeal(caseA, APPEAL_EVIDENCE);

        // And the slot is free for a third party, swept lazily as always.
        vm.prank(thirdParty);
        uint256 caseB = recovery.initiateRecovery(tokenId, keccak256("after-credit"));
        assertTrue(caseB != caseA);
        assertEq(recovery.getActiveCaseForToken(tokenId), caseB, "the new case owns the slot");
    }

    /// @dev EXACT COMPLEMENTARITY UNDER PAUSE CREDIT. initiateRecovery's active-case guard and
    ///      appeal() consult ONE private helper, so at every instant exactly one of them is
    ///      open. If they ever read different numbers there is an interval in which nobody may
    ///      open a case and the claimant may not appeal either — the asset's dispute slot
    ///      would be dead. This is the property a reviewer verified before pause credit
    ///      existed; it must survive pause credit.
    function test_regression_guardAndAppealStayExactComplementsUnderPauseCredit() public {
        // ---- AT the effective deadline: third party BLOCKED, claimant may appeal ----
        uint256 tokenA = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenA);
        _rejectRound(caseA);
        _pauseFor(4 days);
        uint256 effA = recovery.appealDeadlineEffective(caseA);
        assertEq(effA, recovery.appealDeadline(caseA) + 4 days);

        vm.warp(effA);
        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ActiveCaseExists.selector, tokenA, caseA));
        recovery.initiateRecovery(tokenA, keccak256("at-deadline"));
        // The revert changed nothing, so the same instant still belongs to the claimant.
        vm.prank(claimant);
        recovery.appeal(caseA, APPEAL_EVIDENCE);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.VOTING));

        // ---- ONE SECOND LATER: exactly the reverse ----
        uint256 tokenB = _mintClaimedAndFlagged(holder);
        uint256 caseB = _openCase(tokenB);
        _rejectRound(caseB);
        _pauseFor(4 days);
        uint256 effB = recovery.appealDeadlineEffective(caseB);

        vm.warp(effB + 1);
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AppealWindowClosed.selector, caseB, effB));
        recovery.appeal(caseB, APPEAL_EVIDENCE);

        vm.prank(thirdParty);
        uint256 caseC = recovery.initiateRecovery(tokenB, keccak256("one-second-later"));
        assertEq(recovery.getActiveCaseForToken(tokenB), caseC, "the slot really did change hands");
    }

    /// @dev A case rejected BEFORE this upgrade has no pause-credit stamp. Reading its
    ///      unwritten 0 as a genuine baseline would hand it the ENTIRE credit accrued since
    ///      the upgrade — an unbounded extension nobody granted. The stamp is stored offset by
    ///      one precisely so "never recorded" and "recorded at zero" are distinguishable.
    ///      Both legacy shapes are covered: no deadline at all, and a deadline with no stamp.
    /// @notice A pause already running when a case is rejected must not credit the case for
    ///         seconds that elapsed BEFORE its window existed.
    /// @dev Regression for the over-credit both round-2 reviewers proved independently. The stamp
    ///      recorded raw `_pauseCredit`, which excludes a pause in progress, while the reader added
    ///      that in-progress pause in full — so a case rejected mid-pause was handed every second
    ///      the contract had already been paused, and the eventual unpause banked it permanently.
    ///      Reachable with no privileged actor: executeResolution is deliberately not
    ///      whenNotPaused, so the REJECTED branch is live during a pause. Both the stamp and the
    ///      reader now go through _creditNow(), so the baseline and the reading are measured the
    ///      same way and the in-progress pause sits inside the baseline.
    function test_regression_pauseStartingBeforeRejectionDoesNotOverCredit() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);

        // Vote it down but do NOT execute yet — the rejection must land DURING the pause.
        _vote(caseId, governanceVoter, false);
        _vote(caseId, manufacturer, false);
        _vote(caseId, verifier, false);
        vm.warp(block.timestamp + VOTING_DURATION + 1);

        // A long pause begins BEFORE the rejection lands.
        uint256 preRejectionPause = 100 days;
        vm.prank(owner);
        recovery.pause();
        vm.warp(block.timestamp + preRejectionPause);

        // executeResolution is intentionally callable while paused.
        recovery.executeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.REJECTED), "rejected mid-pause");

        uint256 rejectedAt = block.timestamp;
        uint256 recorded = recovery.appealDeadline(caseId);
        assertEq(recorded, rejectedAt + APPEAL_WINDOW, "raw deadline is the plain wall-clock window");

        // At the instant of rejection the case is owed NOTHING: no paused time has elapsed since.
        assertEq(
            recovery.appealDeadlineEffective(caseId),
            recorded,
            "credit at the rejection instant must be zero, not the 100 days already spent paused"
        );

        // Unpause and confirm the over-credit was not banked.
        vm.prank(owner);
        recovery.unpause();
        assertEq(
            recovery.appealDeadlineEffective(caseId),
            recorded,
            "closing the pre-rejection pause must not retroactively extend the window"
        );

        // A pause AFTER the rejection is still credited correctly.
        uint256 postPause = 3 days;
        vm.prank(owner);
        recovery.pause();
        vm.warp(block.timestamp + postPause);
        assertEq(
            recovery.appealDeadlineEffective(caseId),
            recorded + postPause,
            "paused seconds after the rejection ARE credited"
        );
        vm.prank(owner);
        recovery.unpause();
        assertEq(recovery.appealDeadlineEffective(caseId), recorded + postPause, "and banked exactly once");
    }

    function test_regression_preUpgradeRejectionGetsNoHistoricalPauseCredit() public {
        // ---- SHAPE 1: rejected before the bounded window shipped (deadline 0, stamp 0) ----
        uint256 tokenA = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenA);
        _rejectRound(caseA);
        vm.store(address(recovery), keccak256(abi.encode(caseA, SLOT_APPEAL_DEADLINE)), bytes32(0));
        _erasePauseCreditStamp(caseA);
        assertEq(recovery.appealDeadline(caseA), 0, "reproduced: no deadline on record");

        // Bank a large pause credit AFTER the fact.
        _pauseFor(20 days);

        // A recorded deadline of 0 is the legacy carve-out, not an epoch timestamp: the
        // effective getter reports 0 too, and never 0 + 20 days.
        assertEq(recovery.appealDeadlineEffective(caseA), 0, "0 means unbounded, not epoch + credit");
        vm.prank(claimant);
        recovery.appeal(caseA, APPEAL_EVIDENCE); // the unbounded legacy right still works
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.VOTING));

        // ---- SHAPE 2: rejected under the window but before pause credit existed ----
        uint256 tokenB = _mintClaimedAndFlagged(holder);
        uint256 caseB = _openCase(tokenB);
        _rejectRound(caseB);
        uint256 recordedB = recovery.appealDeadline(caseB);
        _erasePauseCreditStamp(caseB);

        // The contract goes on to spend 20 more days paused. None of it is this case's.
        _pauseFor(20 days);
        assertEq(recovery.appealDeadlineEffective(caseB), recordedB, "NO retroactive credit for an unstamped case");

        // Which means it lapses on its original wall-clock deadline, as it always would have.
        vm.warp(recordedB + 1);
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AppealWindowClosed.selector, caseB, recordedB));
        recovery.appeal(caseB, APPEAL_EVIDENCE);

        // ---- AND A CASE REJECTED FROM HERE ON IS STAMPED, so it does get credit ----
        uint256 tokenC = _mintClaimedAndFlagged(holder);
        uint256 caseC = _openCase(tokenC);
        _rejectRound(caseC);
        uint256 recordedC = recovery.appealDeadline(caseC);
        _pauseFor(5 days);
        assertEq(recovery.appealDeadlineEffective(caseC), recordedC + 5 days, "a stamped case IS credited");
    }

    /// @dev THE PATH THAT MADE THIS URGENT. The CircuitBreaker auto-trip inside
    ///      initiateRecovery/appeal calls _pause() DIRECTLY — it does not go through the
    ///      owner-only pause(). Hooking only pause() would have left ordinary volume able to
    ///      pause the contract and eat an appeal window with nobody's permission, since the
    ///      breaker's 4-hour cooldown does NOT clear Pausable; only unpause() does. The
    ///      overrides are on _pause/_unpause for exactly this reason, and this test proves it
    ///      by tripping the breaker for real rather than calling pause().
    function test_regression_circuitBreakerAutoTripAccruesPauseCredit() public {
        uint256 tokenA = _mintClaimedAndFlagged(holder);
        uint256 caseA = _openCase(tokenA);
        _rejectRound(caseA);
        uint256 recorded = recovery.appealDeadline(caseA);

        // A second asset, so the trip comes from an ordinary unrelated recovery.
        uint256 tokenB = _mintClaimedAndFlagged(holder);
        _armCircuitBreaker();

        assertFalse(recovery.paused(), "not paused before the trip");
        vm.prank(thirdParty);
        recovery.initiateRecovery(tokenB, keccak256("volume"));

        // NOBODY called pause(). The breaker did it.
        (,, bool tripped,) = recovery.getCircuitBreakerState();
        assertTrue(tripped, "the breaker tripped");
        assertTrue(recovery.paused(), "and it paused the contract by itself");

        // It stays paused across the breaker's own cooldown — only unpause() clears Pausable.
        vm.warp(recorded + 3 days);
        assertTrue(recovery.paused(), "the 4h cooldown does NOT clear Pausable");
        assertGt(block.timestamp, recorded, "the raw wall-clock deadline has passed while paused");

        vm.prank(owner);
        recovery.unpause();

        // The breaker-trip pause accrued credit exactly as an owner pause would have.
        assertEq(recovery.appealDeadlineEffective(caseA), recorded + 10 days, "breaker pause is credited too");
        vm.prank(claimant);
        recovery.appeal(caseA, APPEAL_EVIDENCE);
        assertEq(uint8(recovery.getCase(caseA).status), uint8(IRecovery.CaseStatus.VOTING), "the right survived");
    }

    // ==================================================================
    // L5 — the fee must never silently round to zero
    // ==================================================================

    /// @dev THE POC, INVERTED. Originally: the governor set minimumStake to 9, the griefer
    ///      squatted, and BOTH balances were exactly unchanged — the fee had truncated to
    ///      zero with no revert, no event and no other signal, so squatting was free again
    ///      while every document still said it cost 10%. Both window setters were bounded;
    ///      the parameter the anti-squat economics rest on was not.
    function test_regression_setMinimumStakeFloorBoundsAndAuthority() public {
        // The floor is derived from the fee itself, not picked by hand.
        assertEq(recovery.MINIMUM_STAKE_FLOOR(), recovery.BASIS_POINTS() / recovery.SQUAT_FEE_RATE());
        assertEq(recovery.MINIMUM_STAKE_FLOOR(), 10);

        // THE EXACT PoC VALUE IS NOW REFUSED AT THE DOOR.
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.MinimumStakeBelowFloor.selector, 9, 10));
        recovery.setMinimumStake(9);
        assertEq(recovery.minimumStake(), MINIMUM_STAKE, "the rejected value was not written");

        // Zero keeps its own, older error rather than being folded into the floor.
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.InvalidParameterValue.selector, "minimumStake", 0));
        recovery.setMinimumStake(0);

        // Authority is unchanged: governor-only, exactly like the window setters.
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, randomUser));
        recovery.setMinimumStake(200e18);

        // The boundary itself is valid, and at the boundary the fee is still a real amount.
        // (Read the floor BEFORE the prank — an argument call would consume it.)
        uint256 floor = recovery.MINIMUM_STAKE_FLOOR();
        vm.prank(governor);
        recovery.setMinimumStake(floor);
        assertEq(recovery.minimumStake(), 10);

        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 grieferBefore = token.balanceOf(thirdParty);
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.prank(thirdParty);
        uint256 decoy = recovery.initiateRecovery(tokenId, keccak256("floor-squat"));
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(decoy);

        // 10 * 1000 / 10000 == 1 wei. Small, but it EXISTS — which is the whole point.
        assertEq(grieferBefore - token.balanceOf(thirdParty), 1, "the fee is still non-zero at the floor");
        assertEq(token.balanceOf(treasury) - treasuryBefore, 1, "and it still reaches the treasury");
    }

    // ==================================================================
    // THE GOVERNING INVARIANT — must never weaken
    // ==================================================================

    /// @dev Re-asserted here so the invariant is pinned by BOTH suites. TAGITRecovery
    ///      adjudicates and escrows; it holds no key to the vault.
    function test_regression_trustBoundaryHoldsAcrossAnAppealedCase() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        _rejectRound(caseId);
        vm.prank(claimant);
        recovery.appeal(caseId, APPEAL_EVIDENCE);
        _rosterVotes(caseId, true);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        assertFalse(access.hasCapability(address(recovery), uint256(RESOLVER_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(FLAGGER_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(MINTER_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(BINDER_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(ACTIVATOR_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(CLAIMER_CAPABILITY)));
        assertFalse(access.hasCapability(address(recovery), uint256(keccak256("RECYCLER"))));

        // The asset has still not moved: only the human resolver quorum can move it.
        assertEq(core.ownerOf(tokenId), holder);
    }
}
