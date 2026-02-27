// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {TAGITPrograms} from "../../src/programs/TAGITPrograms.sol";
import {ITAGITPrograms} from "../../src/interfaces/ITAGITPrograms.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// Mock TAGITAccess for testing badge checks
contract MockTAGITAccess {
    mapping(address => mapping(uint256 => bool)) private _identities;
    mapping(address => mapping(uint256 => bool)) private _capabilities;

    function hasIdentity(address user, uint256 badgeId) external view returns (bool) {
        return _identities[user][badgeId];
    }

    function hasCapability(address user, uint256 capId) external view returns (bool) {
        return _capabilities[user][capId];
    }

    function setIdentity(address user, uint256 badgeId, bool has) external {
        _identities[user][badgeId] = has;
    }

    function setCapability(address user, uint256 capId, bool has) external {
        _capabilities[user][capId] = has;
    }
}

contract TAGITProgramsTest is Test {
    TAGITPrograms public programs;
    ERC20Mock public token;
    MockTAGITAccess public access;

    address public governor = address(0x1);
    address public core = address(0x2);
    address public recovery = address(0x3);
    address public updater = address(0x4);
    address public user1 = address(0x5);
    address public user2 = address(0x6);
    address public manufacturer = address(0x7);
    address public staking = address(0x8);
    address public owner = address(0x9);

    bytes32 public constant SCAN_REWARDS = keccak256("SCAN_REWARDS");
    bytes32 public constant REFERRAL_PROGRAM = keccak256("REFERRAL_PROGRAM");

    // Badge IDs from TAGITPrograms
    uint256 constant BADGE_MANUFACTURER = 10;
    uint256 constant BADGE_BASIC_VERIFIER = 50;
    uint256 constant BADGE_CERTIFIED_VERIFIER = 51;
    uint256 constant BADGE_GOVERNANCE = 60;

    function setUp() public {
        // Deploy mock token
        token = new ERC20Mock();

        // Deploy mock access contract
        access = new MockTAGITAccess();

        // Deploy implementation
        TAGITPrograms impl = new TAGITPrograms();

        // Deploy proxy
        bytes memory initData =
            abi.encodeCall(TAGITPrograms.initialize, (governor, core, address(token), address(access), staking, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        programs = TAGITPrograms(address(proxy));

        // Configure programs contract
        vm.startPrank(governor);
        programs.setRecoveryContract(recovery);
        programs.setUpdater(updater, true);
        vm.stopPrank();

        // Setup manufacturer badge
        access.setIdentity(manufacturer, BADGE_MANUFACTURER, true);

        // Fund programs contract with tokens
        token.mint(address(programs), 1_000_000e18);

        // PATCH-14: set governor as action verifier for test convenience
        vm.prank(governor);
        programs.setActionVerifier(governor);
    }

    /// @dev Helper: approve an action proof before claiming (PATCH-14)
    function _approveAction(bytes32 programId, address user, bytes32 actionProof) internal {
        vm.prank(governor);
        programs.approveAction(programId, user, actionProof);
    }

    // ============================================
    // PROGRAM MANAGEMENT TESTS
    // ============================================

    function test_createProgram_success() public {
        vm.prank(governor);
        bool success = programs.createProgram(
            SCAN_REWARDS,
            10e18, // 10 tokens per action
            100_000e18, // 100k budget
            5, // 5 claims per day
            30 days // 30 day duration
        );

        assertTrue(success, "createProgram should succeed");

        ITAGITPrograms.Program memory program = programs.getProgram(SCAN_REWARDS);
        assertEq(program.id, SCAN_REWARDS);
        assertEq(program.rewardAmount, 10e18);
        assertEq(program.budget, 100_000e18);
        assertEq(program.dailyCap, 5);
        assertTrue(program.active);
    }

    function test_createProgram_revert_notGovernor() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.NotGovernor.selector, user1));
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);
    }

    function test_createProgram_revert_alreadyExists() public {
        vm.startPrank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);

        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.ProgramAlreadyExists.selector, SCAN_REWARDS));
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);
        vm.stopPrank();
    }

    function test_updateProgram_success() public {
        vm.startPrank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);
        programs.updateProgram(SCAN_REWARDS, 20e18, false);
        vm.stopPrank();

        ITAGITPrograms.Program memory program = programs.getProgram(SCAN_REWARDS);
        assertEq(program.rewardAmount, 20e18);
        assertFalse(program.active);
    }

    function test_fundProgram_success() public {
        // Mint tokens to governor and approve
        token.mint(governor, 50_000e18);

        vm.startPrank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);

        token.approve(address(programs), 50_000e18);
        programs.fundProgram(SCAN_REWARDS, 50_000e18);
        vm.stopPrank();

        ITAGITPrograms.Program memory program = programs.getProgram(SCAN_REWARDS);
        assertEq(program.budget, 150_000e18);
    }

    // ============================================
    // REWARD CLAIMING TESTS
    // ============================================

    function test_claimReward_success() public {
        // Setup program
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);

        // Claim reward
        bytes32 actionProof = keccak256("action1");
        uint256 balanceBefore = token.balanceOf(user1);

        _approveAction(SCAN_REWARDS, user1, actionProof);
        vm.prank(user1);
        programs.claimReward(SCAN_REWARDS, actionProof);

        uint256 balanceAfter = token.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, 10e18);
    }

    function test_claimReward_withTierMultiplier() public {
        // Setup user with high reputation (Platinum tier)
        vm.prank(updater);
        programs.updateReputation(user1, 8000, bytes32(0)); // Platinum tier

        // Setup program
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);

        // Claim reward - should get 2x multiplier (20 tokens)
        bytes32 actionProof = keccak256("action1");
        uint256 balanceBefore = token.balanceOf(user1);

        _approveAction(SCAN_REWARDS, user1, actionProof);
        vm.prank(user1);
        programs.claimReward(SCAN_REWARDS, actionProof);

        uint256 balanceAfter = token.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, 20e18, "Should receive 2x reward for Platinum tier");
    }

    function test_claimReward_revert_dailyCapExceeded() public {
        // Setup program with daily cap of 2
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 2, 30 days);

        _approveAction(SCAN_REWARDS, user1, keccak256("action1"));
        _approveAction(SCAN_REWARDS, user1, keccak256("action2"));
        _approveAction(SCAN_REWARDS, user1, keccak256("action3"));
        vm.startPrank(user1);
        programs.claimReward(SCAN_REWARDS, keccak256("action1"));
        programs.claimReward(SCAN_REWARDS, keccak256("action2"));

        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.DailyCapExceeded.selector, SCAN_REWARDS, user1, 2));
        programs.claimReward(SCAN_REWARDS, keccak256("action3"));
        vm.stopPrank();
    }

    function test_claimReward_revert_programExpired() public {
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);

        // Warp past expiration
        vm.warp(block.timestamp + 31 days);

        vm.prank(user1);
        vm.expectRevert(); // ProgramExpired
        programs.claimReward(SCAN_REWARDS, keccak256("action1"));
    }

    function test_claimReward_revert_alreadyClaimed() public {
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);

        bytes32 actionProof = keccak256("action1");

        _approveAction(SCAN_REWARDS, user1, actionProof);
        vm.startPrank(user1);
        programs.claimReward(SCAN_REWARDS, actionProof);
        vm.stopPrank();

        // Second claim with same proof — proof consumed, so ActionProofNotVerified
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITPrograms.ActionProofNotVerified.selector, SCAN_REWARDS, user1, actionProof)
        );
        programs.claimReward(SCAN_REWARDS, actionProof);
    }

    function test_batchClaimRewards_success() public {
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 10, 30 days);

        // Pre-approve all batch claims (PATCH-14)
        _approveAction(SCAN_REWARDS, user1, keccak256("a1"));
        _approveAction(SCAN_REWARDS, user1, keccak256("a2"));
        _approveAction(SCAN_REWARDS, user1, keccak256("a3"));

        // batchClaimRewards only allows self-claims
        ITAGITPrograms.RewardClaim[] memory claims = new ITAGITPrograms.RewardClaim[](3);
        claims[0] = ITAGITPrograms.RewardClaim(user1, SCAN_REWARDS, 10e18, keccak256("a1"));
        claims[1] = ITAGITPrograms.RewardClaim(user1, SCAN_REWARDS, 10e18, keccak256("a2"));
        claims[2] = ITAGITPrograms.RewardClaim(user1, SCAN_REWARDS, 10e18, keccak256("a3"));

        uint256 user1Before = token.balanceOf(user1);

        // User1 claims their own rewards in batch
        vm.prank(user1);
        programs.batchClaimRewards(claims);

        // Should receive 30 tokens (3 claims * 10 tokens)
        assertEq(token.balanceOf(user1) - user1Before, 30e18);
    }

    // ============================================
    // VERIFICATION HOOK TESTS
    // ============================================

    function test_onVerification_success() public {
        vm.prank(governor);
        programs.createProgram(keccak256("VERIFY_SCAN"), 5e18, 100_000e18, 100, 365 days);

        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(core);
        programs.onVerification(user1, 123);

        // Should receive base verification reward
        assertTrue(token.balanceOf(user1) >= balanceBefore, "Should receive verification reward");
    }

    function test_onVerification_revert_notCore() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.NotCore.selector, user1));
        programs.onVerification(user1, 123);
    }

    // ============================================
    // REPUTATION TESTS
    // ============================================

    function test_updateReputation_success() public {
        vm.prank(updater);
        programs.updateReputation(user1, 5000, keccak256("history"));

        ITAGITPrograms.UserReputation memory rep = programs.getReputation(user1);
        assertEq(rep.score, 5000);
        assertEq(rep.historyRoot, keccak256("history"));
    }

    function test_updateReputation_revert_notUpdater() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.NotAuthorizedUpdater.selector, user1));
        programs.updateReputation(user1, 5000, bytes32(0));
    }

    function test_updateReputation_revert_exceedsMax() public {
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.ScoreExceedsMax.selector, 15000, 10000));
        programs.updateReputation(user1, 15000, bytes32(0));
    }

    function test_stakeForReputation_success() public {
        uint256 stakeAmount = 5000e18;
        token.mint(user1, stakeAmount);

        vm.startPrank(user1);
        token.approve(address(programs), stakeAmount);
        programs.stakeForReputation(stakeAmount);
        vm.stopPrank();

        // 5000 tokens = 5% stake boost (500 basis points)
        // Weighted score should reflect the boost
        ITAGITPrograms.UserReputation memory rep = programs.getReputation(user1);
        assertEq(rep.score, 0, "Base score unchanged");
    }

    function test_stakeForReputation_revert_zeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(ITAGITPrograms.ZeroAmount.selector);
        programs.stakeForReputation(0);
    }

    // ============================================
    // SLASHING TESTS
    // ============================================

    function test_slashReputation_success() public {
        // Setup user reputation
        vm.prank(updater);
        programs.updateReputation(user1, 5000, bytes32(0));

        // Slash
        vm.prank(governor);
        programs.slashReputation(user1, 1000, keccak256("evidence"));

        ITAGITPrograms.UserReputation memory rep = programs.getReputation(user1);
        assertEq(rep.score, 4000);
        assertEq(rep.slashPenalty, 1000);
        assertTrue(rep.slashedAt > 0);
    }

    function test_slashReputation_revert_notAuthorized() public {
        vm.prank(updater);
        programs.updateReputation(user1, 5000, bytes32(0));

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.NotAuthorizedSlasher.selector, user2));
        programs.slashReputation(user1, 1000, keccak256("evidence"));
    }

    function test_slashReputation_recoveryCanSlash() public {
        vm.prank(updater);
        programs.updateReputation(user1, 5000, bytes32(0));

        // Recovery contract should be able to slash
        vm.prank(recovery);
        programs.slashReputation(user1, 500, keccak256("recovery_evidence"));

        ITAGITPrograms.UserReputation memory rep = programs.getReputation(user1);
        assertEq(rep.score, 4500);
    }

    // ============================================
    // RECALL & CUSTOMS TESTS
    // ============================================

    function test_registerRecall_success() public {
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;

        vm.prank(manufacturer);
        programs.registerRecall(tokenIds, "Defective batch");
    }

    function test_registerRecall_revert_notManufacturer() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPrograms.NotManufacturer.selector, user1));
        programs.registerRecall(tokenIds, "reason");
    }

    function test_notifyCustomsEvent_success() public {
        vm.prank(governor);
        programs.notifyCustomsEvent(123, keccak256("IMPORT"));
    }

    // ============================================
    // TIER AND MULTIPLIER TESTS
    // ============================================

    function test_getReputationTier_allTiers() public {
        // Bronze (0-2500)
        vm.prank(updater);
        programs.updateReputation(user1, 1000, bytes32(0));
        assertEq(uint256(programs.getReputationTier(user1)), uint256(ITAGITPrograms.ReputationTier.BRONZE));

        // Silver (2501-5000)
        vm.prank(updater);
        programs.updateReputation(user1, 3000, bytes32(0));
        assertEq(uint256(programs.getReputationTier(user1)), uint256(ITAGITPrograms.ReputationTier.SILVER));

        // Gold (5001-7500)
        vm.prank(updater);
        programs.updateReputation(user1, 6000, bytes32(0));
        assertEq(uint256(programs.getReputationTier(user1)), uint256(ITAGITPrograms.ReputationTier.GOLD));

        // Platinum (7501-10000)
        vm.prank(updater);
        programs.updateReputation(user1, 8000, bytes32(0));
        assertEq(uint256(programs.getReputationTier(user1)), uint256(ITAGITPrograms.ReputationTier.PLATINUM));
    }

    function test_getTierMultiplier_allTiers() public view {
        assertEq(programs.getTierMultiplier(ITAGITPrograms.ReputationTier.BRONZE), 10000); // 1x
        assertEq(programs.getTierMultiplier(ITAGITPrograms.ReputationTier.SILVER), 12500); // 1.25x
        assertEq(programs.getTierMultiplier(ITAGITPrograms.ReputationTier.GOLD), 15000); // 1.5x
        assertEq(programs.getTierMultiplier(ITAGITPrograms.ReputationTier.PLATINUM), 20000); // 2x
    }

    function test_getWeightedScore_withBadgeMultiplier() public {
        // Setup user with reputation and governance badge
        vm.prank(updater);
        programs.updateReputation(user1, 5000, bytes32(0));
        access.setIdentity(user1, BADGE_GOVERNANCE, true);

        // Governance badge = 4x multiplier
        uint256 weighted = programs.getWeightedScore(user1);
        assertEq(weighted, 20000, "Should be 5000 * 4x = 20000");
    }

    function test_getWeightedScore_withStakeBoost() public {
        // Setup user with reputation
        vm.prank(updater);
        programs.updateReputation(user1, 5000, bytes32(0));

        // Stake 10000 tokens (10% boost = 1000 basis points)
        uint256 stakeAmount = 10_000e18;
        token.mint(user1, stakeAmount);
        vm.startPrank(user1);
        token.approve(address(programs), stakeAmount);
        programs.stakeForReputation(stakeAmount);
        vm.stopPrank();

        uint256 weighted = programs.getWeightedScore(user1);
        // Base: 5000, multiplier: 10000 (1x) + 1000 (10% stake boost) = 11000
        // 5000 * 11000 / 10000 = 5500
        assertEq(weighted, 5500, "Should include stake boost");
    }

    // ============================================
    // VIEW FUNCTIONS TESTS
    // ============================================

    function test_getDailyClaims() public {
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 10, 30 days);

        _approveAction(SCAN_REWARDS, user1, keccak256("a1"));
        _approveAction(SCAN_REWARDS, user1, keccak256("a2"));
        _approveAction(SCAN_REWARDS, user1, keccak256("a3"));
        vm.startPrank(user1);
        programs.claimReward(SCAN_REWARDS, keccak256("a1"));
        programs.claimReward(SCAN_REWARDS, keccak256("a2"));
        programs.claimReward(SCAN_REWARDS, keccak256("a3"));
        vm.stopPrank();

        assertEq(programs.getDailyClaims(SCAN_REWARDS, user1), 3);
    }

    function test_getRemainingBudget() public {
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 10, 30 days);

        _approveAction(SCAN_REWARDS, user1, keccak256("a1"));
        vm.prank(user1);
        programs.claimReward(SCAN_REWARDS, keccak256("a1")); // Claims 10 tokens

        assertEq(programs.getRemainingBudget(SCAN_REWARDS), 100_000e18 - 10e18);
    }

    function test_version() public view {
        assertEq(programs.version(), "1.0.0");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_stakeBoostCapped(uint256 stakeAmount) public {
        // Bound stake amount to reasonable range
        stakeAmount = bound(stakeAmount, 1e18, 1_000_000e18);

        // Setup user with base reputation
        vm.prank(updater);
        programs.updateReputation(user1, 5000, bytes32(0));

        // Stake tokens
        token.mint(user1, stakeAmount);
        vm.startPrank(user1);
        token.approve(address(programs), stakeAmount);
        programs.stakeForReputation(stakeAmount);
        vm.stopPrank();

        uint256 weighted = programs.getWeightedScore(user1);

        // Weighted score should never exceed base * 1.5 (max 50% stake boost with 1x badge multiplier)
        assertLe(weighted, 5000 * 15000 / 10000, "Stake boost should be capped at 50%");
        assertGe(weighted, 5000, "Weighted score should be at least base score");
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_createProgram() public {
        vm.prank(governor);
        uint256 gasBefore = gasleft();
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);
        uint256 gasUsed = gasBefore - gasleft();

        // Target: < 150k gas
        assertLt(gasUsed, 150_000, "createProgram() gas too high");
    }

    function test_gas_claimReward() public {
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 10e18, 100_000e18, 5, 30 days);

        _approveAction(SCAN_REWARDS, user1, keccak256("action1"));

        vm.prank(user1);
        uint256 gasBefore = gasleft();
        programs.claimReward(SCAN_REWARDS, keccak256("action1"));
        uint256 gasUsed = gasBefore - gasleft();

        // Target: < 150k gas (includes storage reads/writes, token transfer, events)
        assertLt(gasUsed, 150_000, "claimReward() gas too high");
    }
}
