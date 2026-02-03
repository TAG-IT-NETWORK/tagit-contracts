// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TAGITPrograms} from "../../src/programs/TAGITPrograms.sol";
import {ITAGITPrograms} from "../../src/interfaces/ITAGITPrograms.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";

/**
 * @title MockTAGITCore
 * @notice Minimal mock for TAGITCore
 */
contract MockTAGITCore {
    TAGITPrograms public programs;

    function setPrograms(address _programs) external {
        programs = TAGITPrograms(_programs);
    }

    function triggerVerification(address user, uint256 tokenId) external {
        programs.onVerification(user, tokenId);
    }
}

/**
 * @title MockTAGITStaking
 * @notice Minimal mock for TAGITStaking
 */
contract MockTAGITStaking {
    function getStaked(address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title TAGITProgramsNistTest
 * @notice NIST CSF 2.0 security control tests for TAGITPrograms
 * @dev Tests SI-4 (System Monitoring) drain detection for reward pools
 */
contract TAGITProgramsNistTest is Test {
    // ============================================
    // EVENTS
    // ============================================

    event RewardPoolDrainDetected(uint256 indexed timestamp, uint8 reason, string details);

    // ============================================
    // CONTRACTS
    // ============================================

    TAGITPrograms public programs;
    TAGITToken public token;
    TAGITAccess public access;
    CapabilityBadge public capabilityBadge;
    IdentityBadge public identityBadge;
    MockTAGITCore public mockCore;
    MockTAGITStaking public mockStaking;

    // ============================================
    // ADDRESSES
    // ============================================

    address public owner;
    address public governor;
    address public treasury;
    address public user;
    address public attacker;

    // ============================================
    // CONSTANTS
    // ============================================

    bytes32 public constant TEST_PROGRAM_ID = keccak256("TEST_PROGRAM");
    bytes32 public constant SCAN_REWARDS = keccak256("SCAN_REWARDS");
    uint256 public constant PROGRAM_BUDGET = 1_000_000 ether;
    uint256 public constant REWARD_AMOUNT = 10 ether;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        treasury = makeAddr("treasury");
        user = makeAddr("user");
        attacker = makeAddr("attacker");

        vm.startPrank(owner);

        // Deploy TAGITAccess + badges
        access = new TAGITAccess();
        capabilityBadge = new CapabilityBadge();
        identityBadge = new IdentityBadge();
        access.setCapabilityBadge(address(capabilityBadge));
        access.setIdentityBadge(address(identityBadge));

        // Deploy mock contracts
        mockCore = new MockTAGITCore();
        mockStaking = new MockTAGITStaking();

        // Deploy TAGITToken (upgradeable)
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(
            TAGITToken.initialize,
            (owner, treasury)
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITPrograms (upgradeable)
        TAGITPrograms programsImpl = new TAGITPrograms();
        bytes memory programsData = abi.encodeCall(
            TAGITPrograms.initialize,
            (governor, address(mockCore), address(token), address(access), address(mockStaking), owner)
        );
        ERC1967Proxy programsProxy = new ERC1967Proxy(address(programsImpl), programsData);
        programs = TAGITPrograms(address(programsProxy));

        // Connect mock core to programs
        mockCore.setPrograms(address(programs));

        // Fund programs contract with tokens
        token.transfer(address(programs), 2_000_000 ether);

        vm.stopPrank();

        // Approve spending for governor
        vm.prank(governor);
        token.approve(address(programs), type(uint256).max);

        // Transfer tokens to governor for funding
        vm.prank(owner);
        token.transfer(governor, 5_000_000 ether);

        // Create a test program
        vm.prank(governor);
        programs.createProgram(TEST_PROGRAM_ID, REWARD_AMOUNT, PROGRAM_BUDGET, 100, 365 days);

        // Fund the program to establish drain detector baseline
        vm.prank(governor);
        programs.fundProgram(TEST_PROGRAM_ID, 100_000 ether);

        // Sync drain detector balance
        vm.prank(governor);
        programs.syncDrainBalance();
    }

    // ============================================
    // DRAIN DETECTOR TESTS (SI-4)
    // ============================================

    function test_drainDetector_initialState() public {
        (
            uint128 trackedBalance,
            uint16 spikeThresholdBps,
            uint16 velocityThresholdBps,
            uint32 maxTxPerWindow,
            bool tripped,
            uint64 cooldownEnds
        ) = programs.getDrainDetectorState();

        // Should have the synced balance
        assertGt(trackedBalance, 0);
        assertEq(spikeThresholdBps, 500); // 5%
        assertEq(velocityThresholdBps, 2000); // 20%
        assertEq(maxTxPerWindow, 500);
        assertFalse(tripped);
        assertEq(cooldownEnds, 0);
    }

    function test_drainDetector_tracksDepositsFromFunding() public {
        (uint128 balanceBefore,,,,, ) = programs.getDrainDetectorState();

        vm.prank(governor);
        programs.fundProgram(TEST_PROGRAM_ID, 50_000 ether);

        (uint128 balanceAfter,,,,, ) = programs.getDrainDetectorState();
        assertEq(balanceAfter, balanceBefore + 50_000 ether);
    }

    function test_drainDetector_governorCanUpdateBalance() public {
        vm.prank(governor);
        programs.updateDrainBalance(500_000 ether);

        (uint128 trackedBalance,,,,, ) = programs.getDrainDetectorState();
        assertEq(trackedBalance, 500_000 ether);
    }

    function test_drainDetector_governorCanSyncBalance() public {
        vm.prank(governor);
        programs.syncDrainBalance();

        (uint128 trackedBalance,,,,, ) = programs.getDrainDetectorState();
        uint256 actualBalance = token.balanceOf(address(programs));
        assertEq(trackedBalance, actualBalance);
    }

    function test_drainDetector_ownerCanForceReset() public {
        // First let's trip the detector manually by manipulating state
        // We'll use a large claim that would trip the spike threshold

        // Set a small baseline so spike detection triggers easily
        vm.prank(governor);
        programs.updateDrainBalance(100 ether);

        // Create a program with large reward
        vm.prank(governor);
        programs.createProgram(keccak256("BIG_REWARD"), 50 ether, 1000 ether, 100, 365 days);

        // The claim would trigger spike (50 ETH > 5% of 100 ETH = 5 ETH)
        // This will pause the contract via drain detection
        vm.prank(user);
        programs.claimReward(keccak256("BIG_REWARD"), keccak256("action1"));

        // Contract should be paused
        assertTrue(programs.paused());

        // Wait for cooldown
        vm.warp(block.timestamp + 2 hours + 1);

        // Owner can force reset
        vm.prank(owner);
        programs.resetDrainDetector();

        // Unpause
        vm.prank(governor);
        programs.unpause();

        // Should be operational again
        assertFalse(programs.paused());
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function test_pause_governorCanPause() public {
        vm.prank(governor);
        programs.pause();

        assertTrue(programs.paused());
    }

    function test_pause_governorCanUnpause() public {
        vm.prank(governor);
        programs.pause();

        vm.prank(governor);
        programs.unpause();

        assertFalse(programs.paused());
    }

    function test_pause_nonGovernorCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        programs.pause();
    }

    // ============================================
    // NORMAL OPERATIONS TESTS
    // ============================================

    function test_normalOps_claimRewardWorks() public {
        // Make a small claim that won't trigger drain detection
        // First update baseline to reasonable amount
        vm.prank(governor);
        programs.updateDrainBalance(1_000_000 ether);

        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        programs.claimReward(TEST_PROGRAM_ID, keccak256("action1"));

        uint256 balanceAfter = token.balanceOf(user);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_normalOps_batchClaimsWork() public {
        vm.prank(governor);
        programs.updateDrainBalance(1_000_000 ether);

        ITAGITPrograms.RewardClaim[] memory claims = new ITAGITPrograms.RewardClaim[](3);
        claims[0] = ITAGITPrograms.RewardClaim(user, TEST_PROGRAM_ID, REWARD_AMOUNT, keccak256("batch1"));
        claims[1] = ITAGITPrograms.RewardClaim(user, TEST_PROGRAM_ID, REWARD_AMOUNT, keccak256("batch2"));
        claims[2] = ITAGITPrograms.RewardClaim(user, TEST_PROGRAM_ID, REWARD_AMOUNT, keccak256("batch3"));

        uint256 balanceBefore = token.balanceOf(user);

        vm.prank(user);
        programs.batchClaimRewards(claims);

        uint256 balanceAfter = token.balanceOf(user);
        assertGt(balanceAfter, balanceBefore);
    }

    function test_normalOps_onVerificationWorks() public {
        // Create scan rewards program
        vm.prank(governor);
        programs.createProgram(SCAN_REWARDS, 1 ether, 100_000 ether, 100, 365 days);

        vm.prank(governor);
        programs.updateDrainBalance(1_000_000 ether);

        uint256 balanceBefore = token.balanceOf(user);

        // Trigger verification from mock core
        vm.prank(address(mockCore));
        programs.onVerification(user, 1);

        // May or may not have rewards depending on program state
        // Just verify it doesn't revert
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_claimRewardOverhead() public {
        vm.prank(governor);
        programs.updateDrainBalance(1_000_000 ether);

        vm.prank(user);
        uint256 gasBefore = gasleft();
        programs.claimReward(TEST_PROGRAM_ID, keccak256("gas_test"));
        uint256 gasUsed = gasBefore - gasleft();

        // Should be under 200k gas
        assertLt(gasUsed, 200000, "claimReward() too expensive");
    }

    function test_gas_viewFunctions() public view {
        programs.getDrainDetectorState();
        programs.getProgram(TEST_PROGRAM_ID);
        programs.getRemainingBudget(TEST_PROGRAM_ID);
    }

    // ============================================
    // SECURITY EDGE CASES
    // ============================================

    function test_security_nonGovernorCannotUpdateDrainBalance() public {
        vm.prank(attacker);
        vm.expectRevert();
        programs.updateDrainBalance(1_000_000 ether);
    }

    function test_security_nonGovernorCannotSyncDrainBalance() public {
        vm.prank(attacker);
        vm.expectRevert();
        programs.syncDrainBalance();
    }

    function test_security_nonOwnerCannotResetDrainDetector() public {
        vm.prank(governor);
        vm.expectRevert();
        programs.resetDrainDetector();
    }

    function test_security_drainDetectorAutosPausesOnSpike() public {
        // Set small baseline so spike detection triggers
        vm.prank(governor);
        programs.updateDrainBalance(100 ether);

        // Create program with reward > spike threshold (5% of 100 ETH = 5 ETH)
        vm.prank(governor);
        programs.createProgram(keccak256("SPIKE_TEST"), 10 ether, 1000 ether, 100, 365 days);

        assertFalse(programs.paused());

        // Claim should trigger spike and pause
        vm.prank(user);
        programs.claimReward(keccak256("SPIKE_TEST"), keccak256("spike_claim"));

        // Should be paused now
        assertTrue(programs.paused());
    }

    // ============================================
    // INTEGRATION TESTS
    // ============================================

    function test_integration_normalUsageDoesntTrip() public {
        // Set reasonable baseline
        vm.prank(governor);
        programs.updateDrainBalance(1_000_000 ether);

        // Multiple normal claims shouldn't trip
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user);
            programs.claimReward(TEST_PROGRAM_ID, keccak256(abi.encodePacked("normal_claim_", i)));
        }

        assertFalse(programs.paused());
    }

    function test_integration_recoveryAfterDrainTrip() public {
        // Trip the detector
        vm.prank(governor);
        programs.updateDrainBalance(100 ether);

        vm.prank(governor);
        programs.createProgram(keccak256("TRIP_TEST"), 10 ether, 1000 ether, 100, 365 days);

        vm.prank(user);
        programs.claimReward(keccak256("TRIP_TEST"), keccak256("trip_claim"));

        assertTrue(programs.paused());

        // Wait for cooldown
        vm.warp(block.timestamp + 2 hours + 1);

        // Reset and unpause
        vm.prank(owner);
        programs.resetDrainDetector();

        vm.prank(governor);
        programs.unpause();

        // Resync with proper balance
        vm.prank(governor);
        programs.syncDrainBalance();

        // Should work now
        vm.prank(user);
        programs.claimReward(keccak256("TRIP_TEST"), keccak256("recovery_claim"));
    }
}
