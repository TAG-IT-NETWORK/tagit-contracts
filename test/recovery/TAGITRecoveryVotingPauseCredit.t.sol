// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {TAGITRecoveryVerdictTest} from "./TAGITRecoveryVerdict.t.sol";
import {IRecovery} from "../../src/interfaces/IRecovery.sol";

/**
 * @title Voting-window pause credit (independent review finding R-1, 2026-10-07)
 * @notice `vote()` is `whenNotPaused`; `executeResolution()` deliberately is not. Before this
 *         fix a pause spanning the VOTING window made every vote revert, let the wall-clock
 *         deadline lapse, and then let anyone EXPIRE the case and charge the claimant the 10%
 *         anti-squat fee for engagement that had been impossible. The appeal window already
 *         counted unpaused seconds (KI-25 item 15); the voting window now does too.
 *
 *         Each test here was mutation-checked: with `_votingEndsAtEffective` returning the raw
 *         `votingEndsAt`, the first three go red.
 */
contract TAGITRecoveryVotingPauseCreditTest is TAGITRecoveryVerdictTest {
    function test_r1_pauseSpanningVotingWindowDoesNotExpireTheCase() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 caseId = _openCase(tokenId);
        uint256 recorded = recovery.getCase(caseId).votingEndsAt;
        assertEq(recovery.votingEndsAtEffective(caseId), recorded, "no pause yet: effective == recorded");

        // Pause lands one second after the case opens and outlasts the whole voting window.
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        recovery.pause();

        vm.prank(governanceVoter);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        recovery.vote(caseId, true, REASON_HASH);

        uint256 paused = VOTING_DURATION + 1;
        vm.warp(block.timestamp + paused);
        assertEq(recovery.votingEndsAtEffective(caseId), recorded + paused, "a running pause is credited on the fly");

        vm.prank(owner);
        recovery.unpause();
        assertEq(recovery.votingEndsAtEffective(caseId), recorded + paused, "a banked pause stays credited");

        // The wall-clock deadline has passed, but nobody can expire the case: the jurors
        // still have every unpaused second they were promised.
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.VotingStillActive.selector, caseId, recorded + paused));
        recovery.executeResolution(caseId);

        // ...and they can use it.
        _vote(caseId, governanceVoter, true);
        _vote(caseId, manufacturer, true);
        _vote(caseId, verifier, true);

        // vote() and executeResolution() are exact complements around the effective deadline.
        vm.warp(recorded + paused);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.VotingStillActive.selector, caseId, recorded + paused));
        recovery.executeResolution(caseId);

        vm.warp(recorded + paused + 1);
        vm.prank(governanceVoter);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.VotingPeriodEnded.selector, caseId, recorded + paused));
        recovery.vote(caseId, true, REASON_HASH);

        vm.prank(randomUser);
        recovery.executeResolution(caseId);
        assertEq(
            uint8(recovery.getCase(caseId).status),
            uint8(IRecovery.CaseStatus.ENFORCING),
            "quorum reached: verdict handed to the human resolvers, not EXPIRED"
        );
        assertEq(token.balanceOf(treasury), treasuryBefore, "no anti-squat fee for a pause the claimant did not cause");
    }

    function test_r1_noVotesAfterTheCreditedWindowStillExpiresWithTheFee() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 claimantBefore = token.balanceOf(claimant);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 caseId = _openCase(tokenId);
        uint256 recorded = recovery.getCase(caseId).votingEndsAt;

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        recovery.pause();
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        recovery.unpause();

        // One second past the RAW deadline is still inside the credited window.
        vm.warp(recorded + 1);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.VotingStillActive.selector, caseId, recorded + 2 days));
        recovery.executeResolution(caseId);

        // Past the credited window with no engagement, the anti-squat fee applies exactly as
        // before: the claimant had the full unpaused window and drew nothing.
        vm.warp(recorded + 2 days + 1);
        vm.prank(randomUser);
        recovery.executeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.EXPIRED));
        assertEq(token.balanceOf(treasury) - treasuryBefore, SQUAT_FEE, "fee unchanged when engagement was possible");
        assertEq(claimantBefore - token.balanceOf(claimant), SQUAT_FEE);
    }

    function test_r1_appealRoundGetsItsOwnBaselineAndCredit() public {
        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        _vote(caseId, governanceVoter, false);
        _vote(caseId, manufacturer, false);
        _vote(caseId, verifier, false);
        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.REJECTED));

        // A pause BEFORE the appeal round opens must not leak into the new window's credit.
        vm.prank(owner);
        recovery.pause();
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        recovery.unpause();

        _resolversDeliver(tokenId, buyer);
        vm.prank(manufacturer);
        core.flag(tokenId);
        vm.prank(owner);
        token.transfer(claimant, 300 ether);
        vm.prank(claimant);
        recovery.appeal(caseId, keccak256("appeal-evidence"));

        uint256 recorded = recovery.getCase(caseId).votingEndsAt;
        assertEq(recovery.votingEndsAtEffective(caseId), recorded, "fresh baseline: earlier pause not credited");

        vm.prank(owner);
        recovery.pause();
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        recovery.unpause();
        assertEq(recovery.votingEndsAtEffective(caseId), recorded + 1 days, "round-two pause is credited");

        // Round-two jurors can still vote after the raw deadline, inside the credited one.
        vm.warp(recorded + 1);
        _vote(caseId, governanceVoter, true);
        _vote(caseId, manufacturer, true);
        _vote(caseId, verifier, true);
        vm.warp(recorded + 1 days + 1);
        recovery.executeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.ENFORCING));
    }

    function test_r1_pauseBankedBeforeTheWindowOpensIsNotCredited() public {
        vm.prank(owner);
        recovery.pause();
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        recovery.unpause();

        uint256 tokenId = _mintClaimedAndFlagged(holder);
        uint256 caseId = _openCase(tokenId);
        uint256 recorded = recovery.getCase(caseId).votingEndsAt;
        assertEq(recovery.votingEndsAtEffective(caseId), recorded, "historical pause credit is not a grant");

        vm.warp(recorded + 1);
        vm.prank(randomUser);
        recovery.executeResolution(caseId);
        assertEq(uint8(recovery.getCase(caseId).status), uint8(IRecovery.CaseStatus.EXPIRED));
    }
}
