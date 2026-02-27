// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {TAGITRecovery} from "../../src/recovery/TAGITRecovery.sol";
import {IRecovery} from "../../src/interfaces/IRecovery.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";

/**
 * @title TAGITRecoveryTest
 * @notice Comprehensive unit tests for TAGITRecovery (AIRP)
 */
contract TAGITRecoveryTest is Test {
    // ============================================
    // EVENTS (copied from IRecovery for testing)
    // ============================================

    event RecoveryInitiated(
        uint256 indexed caseId,
        uint256 indexed tokenId,
        address indexed claimant,
        address currentHolder,
        uint256 stakeBond,
        bytes32 evidenceHash
    );
    event EvidenceSubmitted(uint256 indexed caseId, address indexed submitter, bytes32 evidenceHash);
    event VoteCast(uint256 indexed caseId, address indexed voter, bool approve, uint256 weight, bytes32 reasonHash);
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event VotingDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event MinimumStakeUpdated(uint256 oldStake, uint256 newStake);

    // ============================================
    // CONTRACTS
    // ============================================

    TAGITRecovery public recovery;
    TAGITCore public core;
    TAGITAccess public access;
    CapabilityBadge public capabilityBadge;
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

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 public constant MINIMUM_STAKE = 100e18;
    uint256 public constant VOTING_DURATION = 7 days;
    bytes32 public constant EVIDENCE_HASH = keccak256("evidence");
    bytes32 public constant EVIDENCE_HASH_2 = keccak256("evidence2");
    bytes32 public constant REASON_HASH = keccak256("reason");

    uint256 constant ORACLE_PK = 0xA11CE;

    // Badge IDs
    uint256 public constant BADGE_VERIFIER = 1;
    uint256 public constant BADGE_CERTIFIED_VERIFIER = 2;
    uint256 public constant BADGE_MANUFACTURER = 10;
    uint256 public constant BADGE_GOVERNANCE = 20;

    // TAGITCore capabilities
    bytes32 public constant MINTER_CAPABILITY = keccak256("MINTER");
    bytes32 public constant BINDER_CAPABILITY = keccak256("BINDER");
    bytes32 public constant ACTIVATOR_CAPABILITY = keccak256("ACTIVATOR");
    bytes32 public constant CLAIMER_CAPABILITY = keccak256("CLAIMER");
    bytes32 public constant FLAGGER_CAPABILITY = keccak256("FLAGGER");

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        // Create addresses
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

        vm.startPrank(owner);

        // Deploy TAGITCore (upgradeable via UUPS proxy)
        TAGITCore coreImpl = new TAGITCore();
        bytes memory coreData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), coreData);
        core = TAGITCore(address(coreProxy));

        // Deploy TAGITAccess + CapabilityBadge
        access = new TAGITAccess();
        capabilityBadge = new CapabilityBadge();
        access.setCapabilityBadge(address(capabilityBadge));

        // Set access controller on TAGITCore
        core.setAccessController(address(access));

        // Set trusted oracle
        core.setTrustedOracle(vm.addr(ORACLE_PK));

        // Deploy TAGITToken (upgradeable)
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(TAGITToken.initialize, (owner, treasury));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITRecovery (upgradeable)
        TAGITRecovery recoveryImpl = new TAGITRecovery();
        bytes memory recoveryData = abi.encodeCall(
            TAGITRecovery.initialize, (address(core), address(access), address(token), governor, treasury, owner)
        );
        ERC1967Proxy recoveryProxy = new ERC1967Proxy(address(recoveryImpl), recoveryData);
        recovery = TAGITRecovery(address(recoveryProxy));

        // Grant TAGITCore capabilities to manufacturer
        capabilityBadge.grantCapability(manufacturer, uint256(MINTER_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(BINDER_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(ACTIVATOR_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(CLAIMER_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(FLAGGER_CAPABILITY));

        // Grant voting badges
        capabilityBadge.grantCapability(verifier, BADGE_VERIFIER);
        capabilityBadge.grantCapability(certifiedVerifier, BADGE_CERTIFIED_VERIFIER);
        capabilityBadge.grantCapability(manufacturer, BADGE_MANUFACTURER);
        capabilityBadge.grantCapability(governanceVoter, BADGE_GOVERNANCE);

        // Transfer tokens to claimant for stake bonds
        token.transfer(claimant, 10_000 ether);

        vm.stopPrank();

        // Approve recovery contract to spend claimant's tokens
        vm.prank(claimant);
        token.approve(address(recovery), type(uint256).max);
    }

    // ============================================
    // ORACLE HELPER
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

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _mintAndClaimAsset(address to) internal returns (uint256 tokenId) {
        vm.prank(manufacturer);
        tokenId = core.mint(manufacturer, keccak256("metadata"));

        bytes32 tagHash = keccak256(abi.encodePacked("tag", tokenId));
        (bytes memory challengeResponse, bytes memory oracleSignature) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        core.bindTag(tokenId, tagHash, challengeResponse, oracleSignature);

        vm.startPrank(manufacturer);
        core.activate(tokenId);
        core.claim(tokenId, to);
        vm.stopPrank();
    }

    function _initiateRecovery(uint256 tokenId) internal returns (uint256 caseId) {
        vm.prank(claimant);
        caseId = recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    function _voteOnCase(uint256 caseId, address voter, bool approve) internal {
        vm.prank(voter);
        recovery.vote(caseId, approve, REASON_HASH);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsCore() public view {
        assertEq(recovery.core(), address(core));
    }

    function test_initialize_setsAccess() public view {
        assertEq(address(recovery.access()), address(access));
    }

    function test_initialize_setsToken() public view {
        assertEq(address(recovery.token()), address(token));
    }

    function test_initialize_setsGovernor() public view {
        assertEq(recovery.governor(), governor);
    }

    function test_initialize_setsTreasury() public view {
        assertEq(recovery.treasury(), treasury);
    }

    function test_initialize_setsMinimumStake() public view {
        assertEq(recovery.minimumStake(), MINIMUM_STAKE);
    }

    function test_initialize_setsVotingDuration() public view {
        assertEq(recovery.votingDuration(), VOTING_DURATION);
    }

    function test_initialize_revert_zeroCore() public {
        TAGITRecovery impl = new TAGITRecovery();
        bytes memory data = abi.encodeCall(
            TAGITRecovery.initialize, (address(0), address(access), address(token), governor, treasury, owner)
        );
        vm.expectRevert(IRecovery.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_initialize_revert_zeroAccess() public {
        TAGITRecovery impl = new TAGITRecovery();
        bytes memory data = abi.encodeCall(
            TAGITRecovery.initialize, (address(core), address(0), address(token), governor, treasury, owner)
        );
        vm.expectRevert(IRecovery.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    // ============================================
    // INITIATE RECOVERY TESTS
    // ============================================

    function test_initiateRecovery_createsCase() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(claimant);
        uint256 caseId = recovery.initiateRecovery(tokenId, EVIDENCE_HASH);

        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertEq(recoveryCase.tokenId, tokenId);
        assertEq(recoveryCase.claimant, claimant);
        assertEq(recoveryCase.currentHolder, holder);
        assertEq(recoveryCase.evidenceHash, EVIDENCE_HASH);
        assertEq(recoveryCase.stakeBond, MINIMUM_STAKE);
        assertEq(uint8(recoveryCase.status), uint8(IRecovery.CaseStatus.VOTING));
    }

    function test_initiateRecovery_quarantinesAsset() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(claimant);
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);

        assertTrue(recovery.isQuarantined(tokenId));
    }

    function test_initiateRecovery_locksStakeBond() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 balanceBefore = token.balanceOf(claimant);

        vm.prank(claimant);
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);

        uint256 balanceAfter = token.balanceOf(claimant);
        assertEq(balanceBefore - balanceAfter, MINIMUM_STAKE);
        assertEq(recovery.totalStakesHeld(), MINIMUM_STAKE);
    }

    function test_initiateRecovery_emitsEvent() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.expectEmit(true, true, true, true);
        emit RecoveryInitiated(1, tokenId, claimant, holder, MINIMUM_STAKE, EVIDENCE_HASH);

        vm.prank(claimant);
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    function test_initiateRecovery_revert_invalidTokenId() public {
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.InvalidTokenId.selector, 0));
        recovery.initiateRecovery(0, EVIDENCE_HASH);
    }

    function test_initiateRecovery_revert_invalidEvidenceHash() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(claimant);
        vm.expectRevert(IRecovery.InvalidEvidenceHash.selector);
        recovery.initiateRecovery(tokenId, bytes32(0));
    }

    function test_initiateRecovery_revert_activeCaseExists() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(claimant);
        uint256 caseId = recovery.initiateRecovery(tokenId, EVIDENCE_HASH);

        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.ActiveCaseExists.selector, tokenId, caseId));
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    function test_initiateRecovery_revert_claimantIsHolder() public {
        uint256 tokenId = _mintAndClaimAsset(claimant);

        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, claimant));
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    // ============================================
    // SUBMIT EVIDENCE TESTS
    // ============================================

    function test_submitEvidence_emitsEvent() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        vm.expectEmit(true, true, false, true);
        emit EvidenceSubmitted(caseId, claimant, EVIDENCE_HASH_2);

        vm.prank(claimant);
        recovery.submitEvidence(caseId, EVIDENCE_HASH_2);
    }

    function test_submitEvidence_holderCanSubmit() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        vm.expectEmit(true, true, false, true);
        emit EvidenceSubmitted(caseId, holder, EVIDENCE_HASH_2);

        vm.prank(holder);
        recovery.submitEvidence(caseId, EVIDENCE_HASH_2);
    }

    function test_submitEvidence_revert_notAuthorized() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, randomUser));
        recovery.submitEvidence(caseId, EVIDENCE_HASH_2);
    }

    function test_submitEvidence_revert_caseNotFound() public {
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.CaseNotFound.selector, 999));
        recovery.submitEvidence(999, EVIDENCE_HASH_2);
    }

    // ============================================
    // VOTING TESTS
    // ============================================

    function test_vote_recordsVote() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        _voteOnCase(caseId, verifier, true);

        assertTrue(recovery.hasVoted(caseId, verifier));
        IRecovery.Vote memory vote = recovery.getVote(caseId, verifier);
        assertEq(vote.approve, true);
        assertEq(vote.weight, 1);
        assertEq(vote.reasonHash, REASON_HASH);
    }

    function test_vote_verifierWeight() public view {
        uint256 weight = recovery.getVoteWeight(verifier);
        assertEq(weight, 1);
    }

    function test_vote_certifiedVerifierWeight() public view {
        uint256 weight = recovery.getVoteWeight(certifiedVerifier);
        assertEq(weight, 2);
    }

    function test_vote_manufacturerWeight() public view {
        uint256 weight = recovery.getVoteWeight(manufacturer);
        assertEq(weight, 3);
    }

    function test_vote_governanceWeight() public view {
        uint256 weight = recovery.getVoteWeight(governanceVoter);
        assertEq(weight, 4);
    }

    function test_vote_updatesVoteCounts() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        _voteOnCase(caseId, verifier, true);
        _voteOnCase(caseId, certifiedVerifier, false);

        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertEq(recoveryCase.votesFor, 1);
        assertEq(recoveryCase.votesAgainst, 2);
        assertEq(recoveryCase.voteCount, 2);
    }

    function test_vote_emitsEvent() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        vm.expectEmit(true, true, false, true);
        emit VoteCast(caseId, verifier, true, 1, REASON_HASH);

        _voteOnCase(caseId, verifier, true);
    }

    function test_vote_revert_alreadyVoted() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        _voteOnCase(caseId, verifier, true);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.AlreadyVoted.selector, caseId, verifier));
        recovery.vote(caseId, true, REASON_HASH);
    }

    function test_vote_revert_notBadgeHolder() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotBadgeHolder.selector, randomUser));
        recovery.vote(caseId, true, REASON_HASH);
    }

    function test_vote_revert_votingEnded() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        // Fast forward past voting period
        vm.warp(block.timestamp + VOTING_DURATION + 1);

        vm.prank(verifier);
        vm.expectRevert();
        recovery.vote(caseId, true, REASON_HASH);
    }

    // ============================================
    // EXECUTE RESOLUTION TESTS
    // ============================================

    function test_executeResolution_approved() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        // Vote to approve (need 66%+ approval)
        _voteOnCase(caseId, governanceVoter, true); // 4 weight
        _voteOnCase(caseId, manufacturer, true); // 3 weight
        _voteOnCase(caseId, verifier, true); // 1 weight

        // Fast forward past voting period
        vm.warp(block.timestamp + VOTING_DURATION + 1);

        uint256 claimantBalanceBefore = token.balanceOf(claimant);

        recovery.executeResolution(caseId);

        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertEq(uint8(recoveryCase.status), uint8(IRecovery.CaseStatus.RESOLVED));
        assertFalse(recovery.isQuarantined(tokenId));

        // Stake returned to claimant
        assertEq(token.balanceOf(claimant), claimantBalanceBefore + MINIMUM_STAKE);
    }

    function test_executeResolution_rejected() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        // Vote to reject (need <66% approval)
        _voteOnCase(caseId, governanceVoter, false); // 4 weight against
        _voteOnCase(caseId, manufacturer, false); // 3 weight against
        _voteOnCase(caseId, verifier, true); // 1 weight for

        // Fast forward past voting period
        vm.warp(block.timestamp + VOTING_DURATION + 1);

        uint256 treasuryBalanceBefore = token.balanceOf(treasury);
        uint256 claimantBalanceBefore = token.balanceOf(claimant);

        recovery.executeResolution(caseId);

        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertEq(uint8(recoveryCase.status), uint8(IRecovery.CaseStatus.REJECTED));
        assertFalse(recovery.isQuarantined(tokenId));

        // 50% stake slashed to treasury
        uint256 slashAmount = (MINIMUM_STAKE * 5000) / 10000;
        assertEq(token.balanceOf(treasury), treasuryBalanceBefore + slashAmount);

        // 50% returned to claimant
        assertEq(token.balanceOf(claimant), claimantBalanceBefore + (MINIMUM_STAKE - slashAmount));
    }

    function test_executeResolution_revert_votingStillActive() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        _voteOnCase(caseId, verifier, true);
        _voteOnCase(caseId, certifiedVerifier, true);
        _voteOnCase(caseId, manufacturer, true);

        // Don't fast forward - voting still active
        vm.expectRevert();
        recovery.executeResolution(caseId);
    }

    function test_executeResolution_revert_quorumNotReached() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        // Only 2 votes (quorum is 3)
        _voteOnCase(caseId, verifier, true);
        _voteOnCase(caseId, certifiedVerifier, true);

        vm.warp(block.timestamp + VOTING_DURATION + 1);

        vm.expectRevert(abi.encodeWithSelector(IRecovery.QuorumNotReached.selector, caseId, 2, 3));
        recovery.executeResolution(caseId);
    }

    // ============================================
    // APPEAL TESTS
    // ============================================

    function test_appeal_resetsCaseForVoting() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        // Vote to reject
        _voteOnCase(caseId, governanceVoter, false);
        _voteOnCase(caseId, manufacturer, false);
        _voteOnCase(caseId, verifier, false);

        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        // Give claimant more tokens for appeal
        vm.prank(owner);
        token.transfer(claimant, 300 ether);

        vm.prank(claimant);
        recovery.appeal(caseId, EVIDENCE_HASH_2);

        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertEq(uint8(recoveryCase.status), uint8(IRecovery.CaseStatus.VOTING));
        assertEq(recoveryCase.votesFor, 0);
        assertEq(recoveryCase.votesAgainst, 0);
        assertEq(recoveryCase.voteCount, 0);
        assertTrue(recovery.isQuarantined(tokenId));
    }

    function test_appeal_requires2xBond() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        // Vote to reject
        _voteOnCase(caseId, governanceVoter, false);
        _voteOnCase(caseId, manufacturer, false);
        _voteOnCase(caseId, verifier, false);

        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        uint256 balanceBefore = token.balanceOf(claimant);
        uint256 expectedAppealBond = MINIMUM_STAKE * 2;

        // Give claimant more tokens for appeal
        vm.prank(owner);
        token.transfer(claimant, 300 ether);

        vm.prank(claimant);
        recovery.appeal(caseId, EVIDENCE_HASH_2);

        // Balance should decrease by 2x stake (appeal bond)
        // Note: Original stake was partially slashed, so we're adding 2x original
        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertEq(recoveryCase.stakeBond, MINIMUM_STAKE + expectedAppealBond);
    }

    function test_appeal_revert_notClaimant() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        _voteOnCase(caseId, governanceVoter, false);
        _voteOnCase(caseId, manufacturer, false);
        _voteOnCase(caseId, verifier, false);

        vm.warp(block.timestamp + VOTING_DURATION + 1);
        recovery.executeResolution(caseId);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, randomUser));
        recovery.appeal(caseId, EVIDENCE_HASH_2);
    }

    function test_appeal_revert_notRejected() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        // Case still in VOTING status
        vm.prank(claimant);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.CannotAppeal.selector, caseId, IRecovery.CaseStatus.VOTING));
        recovery.appeal(caseId, EVIDENCE_HASH_2);
    }

    // ============================================
    // ADMIN TESTS
    // ============================================

    function test_setGovernor_success() public {
        address newGovernor = makeAddr("newGovernor");

        vm.expectEmit(true, true, false, false);
        emit GovernorUpdated(governor, newGovernor);

        vm.prank(owner);
        recovery.setGovernor(newGovernor);

        assertEq(recovery.governor(), newGovernor);
    }

    function test_setGovernor_revert_notOwner() public {
        vm.prank(randomUser);
        vm.expectRevert();
        recovery.setGovernor(makeAddr("newGovernor"));
    }

    function test_setTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(treasury, newTreasury);

        vm.prank(owner);
        recovery.setTreasury(newTreasury);

        assertEq(recovery.treasury(), newTreasury);
    }

    function test_setVotingDuration_success() public {
        uint256 newDuration = 14 days;

        vm.expectEmit(false, false, false, true);
        emit VotingDurationUpdated(VOTING_DURATION, newDuration);

        vm.prank(governor);
        recovery.setVotingDuration(newDuration);

        assertEq(recovery.votingDuration(), newDuration);
    }

    function test_setVotingDuration_revert_notGovernor() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(IRecovery.NotAuthorized.selector, randomUser));
        recovery.setVotingDuration(14 days);
    }

    function test_setMinimumStake_success() public {
        uint256 newStake = 200e18;

        vm.expectEmit(false, false, false, true);
        emit MinimumStakeUpdated(MINIMUM_STAKE, newStake);

        vm.prank(governor);
        recovery.setMinimumStake(newStake);

        assertEq(recovery.minimumStake(), newStake);
    }

    function test_pause_blocksInitiateRecovery() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(owner);
        recovery.pause();

        vm.prank(claimant);
        vm.expectRevert();
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    function test_unpause_allowsOperations() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(owner);
        recovery.pause();

        vm.prank(owner);
        recovery.unpause();

        vm.prank(claimant);
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_version() public view {
        assertEq(recovery.version(), "1.0.0");
    }

    function test_getActiveCaseForToken() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        assertEq(recovery.getActiveCaseForToken(tokenId), caseId);
    }

    function test_nextCaseId() public {
        assertEq(recovery.nextCaseId(), 1);

        uint256 tokenId = _mintAndClaimAsset(holder);
        _initiateRecovery(tokenId);

        assertEq(recovery.nextCaseId(), 2);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_voteWeights(uint256 seed) public {
        // Use seed to determine voting pattern (0-15 covers all combinations of 4 voters)
        uint256 pattern = seed % 16;

        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        address[] memory voters = new address[](4);
        voters[0] = verifier; // weight 1
        voters[1] = certifiedVerifier; // weight 2
        voters[2] = manufacturer; // weight 3
        voters[3] = governanceVoter; // weight 4

        uint256[] memory weights = new uint256[](4);
        weights[0] = 1;
        weights[1] = 2;
        weights[2] = 3;
        weights[3] = 4;

        uint256 totalFor = 0;
        uint256 totalAgainst = 0;

        // Each bit in pattern determines if voter i votes for (1) or against (0)
        for (uint256 i = 0; i < 4; i++) {
            bool voteFor = (pattern >> i) & 1 == 1;
            _voteOnCase(caseId, voters[i], voteFor);
            if (voteFor) {
                totalFor += weights[i];
            } else {
                totalAgainst += weights[i];
            }
        }

        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertEq(recoveryCase.votesFor, totalFor);
        assertEq(recoveryCase.votesAgainst, totalAgainst);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_initiateRecovery() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(claimant);
        uint256 gasBefore = gasleft();
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 315,000 (includes SafeERC20 transferFrom + storage writes + NFT lookup)
        assertLt(gasUsed, 315000, "initiateRecovery() exceeds gas target");
    }

    function test_gas_vote() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        vm.prank(verifier);
        uint256 gasBefore = gasleft();
        recovery.vote(caseId, true, REASON_HASH);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 170,000 (includes badge lookups + storage writes)
        assertLt(gasUsed, 170000, "vote() exceeds gas target");
    }

    function test_gas_executeResolution() public {
        uint256 tokenId = _mintAndClaimAsset(holder);
        uint256 caseId = _initiateRecovery(tokenId);

        _voteOnCase(caseId, governanceVoter, true);
        _voteOnCase(caseId, manufacturer, true);
        _voteOnCase(caseId, verifier, true);

        vm.warp(block.timestamp + VOTING_DURATION + 1);

        uint256 gasBefore = gasleft();
        recovery.executeResolution(caseId);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 150,000
        assertLt(gasUsed, 150000, "executeResolution() exceeds gas target");
    }
}
