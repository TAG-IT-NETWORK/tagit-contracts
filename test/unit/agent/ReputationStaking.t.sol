// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {ReputationStaking} from "../../../src/agent/ReputationStaking.sol";
import {IReputationStaking} from "../../../src/interfaces/IReputationStaking.sol";
import {TAGITAgentIdentity} from "../../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAccess} from "../../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../../src/access/CapabilityBadge.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockTAGIT
 * @notice Minimal ERC20 mock for testing staking
 */
contract MockTAGIT is ERC20 {
    constructor() ERC20("TAG IT Token", "TAGIT") {
        _mint(msg.sender, 1_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title ReputationStakingTest
 * @notice Comprehensive unit tests for ReputationStaking contract
 * @dev Tests cover: stake, unstake, slash, access control, edge cases, events
 */
contract ReputationStakingTest is Test {
    ReputationStaking public staking;
    MockTAGIT public tagToken;
    TAGITAgentIdentity public agentIdentity;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    // Test accounts
    address public owner;
    address public registrant1;
    address public registrant2;
    address public agentWallet1;
    address public agentWallet2;
    address public treasury;
    address public attacker;

    // Events (redeclared for testing)
    event StakeDeposited(uint256 indexed agentId, address indexed staker, uint256 amount);
    event StakeWithdrawn(uint256 indexed agentId, address indexed staker, uint256 amount);
    event StakeSlashed(uint256 indexed agentId, uint256 amount, address indexed slashedBy);
    event MinBondUpdated(uint256 oldMinBond, uint256 newMinBond);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        registrant1 = makeAddr("registrant1");
        registrant2 = makeAddr("registrant2");
        agentWallet1 = makeAddr("agentWallet1");
        agentWallet2 = makeAddr("agentWallet2");
        treasury = makeAddr("treasury");
        attacker = makeAddr("attacker");

        // Deploy mock TAGIT token
        vm.prank(owner);
        tagToken = new MockTAGIT();

        // Deploy BIDGES stack
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Deploy AgentIdentity
        vm.prank(owner);
        agentIdentity = new TAGITAgentIdentity();
        vm.prank(owner);
        agentIdentity.setAccessController(address(tagitAccess));

        // Deploy ReputationStaking
        vm.prank(owner);
        staking = new ReputationStaking(address(tagToken), treasury, owner);
        vm.prank(owner);
        staking.setAgentIdentity(address(agentIdentity));

        // Grant KYC_L1 identity to registrants
        identityBadge.grantIdentity(registrant1, 1);
        identityBadge.grantIdentity(registrant2, 1);

        // Distribute TAGIT tokens to registrants
        vm.startPrank(owner);
        tagToken.transfer(registrant1, 10_000 * 1e18);
        tagToken.transfer(registrant2, 10_000 * 1e18);
        vm.stopPrank();

        // Register agent 1
        vm.prank(registrant1);
        agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        // Approve staking contract for registrant1
        vm.prank(registrant1);
        tagToken.approve(address(staking), type(uint256).max);
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function test_constructor_setsInitialState() public view {
        assertEq(address(staking.tagToken()), address(tagToken));
        assertEq(staking.treasury(), treasury);
        assertEq(staking.minBond(), 100 * 1e18);
        assertEq(staking.owner(), owner);
    }

    function test_constructor_reverts_zeroToken() public {
        vm.expectRevert(IReputationStaking.ZeroAddress.selector);
        vm.prank(owner);
        new ReputationStaking(address(0), treasury, owner);
    }

    function test_constructor_reverts_zeroTreasury() public {
        vm.expectRevert(IReputationStaking.ZeroAddress.selector);
        vm.prank(owner);
        new ReputationStaking(address(tagToken), address(0), owner);
    }

    // ============================================
    // STAKE HAPPY PATH TESTS
    // ============================================

    function test_stake_success() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        assertEq(staking.getStake(1), 200 * 1e18);
        assertEq(staking.getStaker(1), registrant1);
        assertTrue(staking.hasMinBond(1));
    }

    function test_stake_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit StakeDeposited(1, registrant1, 200 * 1e18);

        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);
    }

    function test_stake_accumulatesMultipleStakes() public {
        vm.startPrank(registrant1);
        staking.stake(1, 100 * 1e18);
        staking.stake(1, 50 * 1e18);
        vm.stopPrank();

        assertEq(staking.getStake(1), 150 * 1e18);
    }

    function test_stake_transfersTokens() public {
        uint256 balanceBefore = tagToken.balanceOf(registrant1);

        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        assertEq(tagToken.balanceOf(registrant1), balanceBefore - 200 * 1e18);
        assertEq(tagToken.balanceOf(address(staking)), 200 * 1e18);
    }

    function test_stake_exactMinBond() public {
        vm.prank(registrant1);
        staking.stake(1, 100 * 1e18);

        assertTrue(staking.hasMinBond(1));
    }

    // ============================================
    // STAKE REVERT TESTS
    // ============================================

    function test_stake_reverts_zeroAmount() public {
        vm.expectRevert(IReputationStaking.ZeroAmount.selector);
        vm.prank(registrant1);
        staking.stake(1, 0);
    }

    function test_stake_reverts_nonRegistrant() public {
        vm.expectRevert(abi.encodeWithSelector(IReputationStaking.NotAgentRegistrant.selector, attacker, 1));
        vm.prank(attacker);
        staking.stake(1, 200 * 1e18);
    }

    function test_stake_reverts_nonExistentAgent() public {
        vm.expectRevert(abi.encodeWithSelector(IReputationStaking.NotAgentRegistrant.selector, registrant1, 999));
        vm.prank(registrant1);
        staking.stake(999, 200 * 1e18);
    }

    function test_stake_reverts_whenPaused() public {
        vm.prank(owner);
        staking.pause();

        vm.expectRevert();
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);
    }

    function test_stake_reverts_agentIdentityNotSet() public {
        // Deploy staking without agentIdentity
        vm.prank(owner);
        ReputationStaking freshStaking = new ReputationStaking(address(tagToken), treasury, owner);

        vm.expectRevert(IReputationStaking.AgentIdentityNotSet.selector);
        vm.prank(registrant1);
        freshStaking.stake(1, 200 * 1e18);
    }

    // ============================================
    // UNSTAKE TESTS
    // ============================================

    function test_unstake_afterDecommission() public {
        // Stake
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        // Decommission agent
        vm.prank(registrant1);
        agentIdentity.decommissionAgent(1);

        // Unstake
        uint256 balanceBefore = tagToken.balanceOf(registrant1);
        vm.prank(registrant1);
        staking.unstake(1);

        assertEq(staking.getStake(1), 0);
        assertEq(tagToken.balanceOf(registrant1), balanceBefore + 200 * 1e18);
    }

    function test_unstake_emitsEvent() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.prank(registrant1);
        agentIdentity.decommissionAgent(1);

        vm.expectEmit(true, true, false, true);
        emit StakeWithdrawn(1, registrant1, 200 * 1e18);

        vm.prank(registrant1);
        staking.unstake(1);
    }

    function test_unstake_reverts_agentStillActive() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.expectRevert(abi.encodeWithSelector(IReputationStaking.AgentStillActive.selector, 1));
        vm.prank(registrant1);
        staking.unstake(1);
    }

    function test_unstake_reverts_noStake() public {
        // Decommission agent first (no stake deposited)
        vm.prank(registrant1);
        agentIdentity.decommissionAgent(1);

        vm.expectRevert(abi.encodeWithSelector(IReputationStaking.NoStakeToWithdraw.selector, 1));
        vm.prank(registrant1);
        staking.unstake(1);
    }

    function test_unstake_reverts_nonStaker() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.prank(registrant1);
        agentIdentity.decommissionAgent(1);

        vm.expectRevert(abi.encodeWithSelector(IReputationStaking.NotAgentRegistrant.selector, attacker, 1));
        vm.prank(attacker);
        staking.unstake(1);
    }

    function test_unstake_reverts_whenPaused() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.prank(registrant1);
        agentIdentity.decommissionAgent(1);

        vm.prank(owner);
        staking.pause();

        vm.expectRevert();
        vm.prank(registrant1);
        staking.unstake(1);
    }

    // ============================================
    // SLASH TESTS
    // ============================================

    function test_slash_byOwner() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.prank(owner);
        staking.slash(1, 50 * 1e18);

        assertEq(staking.getStake(1), 150 * 1e18);
        assertEq(tagToken.balanceOf(treasury), 50 * 1e18);
    }

    function test_slash_emitsEvent() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.expectEmit(true, false, true, true);
        emit StakeSlashed(1, 50 * 1e18, owner);

        vm.prank(owner);
        staking.slash(1, 50 * 1e18);
    }

    function test_slash_entireStake() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.prank(owner);
        staking.slash(1, 200 * 1e18);

        assertEq(staking.getStake(1), 0);
        assertEq(tagToken.balanceOf(treasury), 200 * 1e18);
        assertFalse(staking.hasMinBond(1));
    }

    function test_slash_reverts_byNonOwner() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.expectRevert();
        vm.prank(attacker);
        staking.slash(1, 50 * 1e18);
    }

    function test_slash_reverts_exceedsStake() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(IReputationStaking.SlashExceedsStake.selector, 1, 300 * 1e18, 200 * 1e18)
        );
        vm.prank(owner);
        staking.slash(1, 300 * 1e18);
    }

    function test_slash_reverts_zeroAmount() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.expectRevert(IReputationStaking.ZeroAmount.selector);
        vm.prank(owner);
        staking.slash(1, 0);
    }

    // ============================================
    // hasMinBond VIEW TESTS
    // ============================================

    function test_hasMinBond_false_noStake() public view {
        assertFalse(staking.hasMinBond(1));
    }

    function test_hasMinBond_false_belowMin() public {
        vm.prank(registrant1);
        staking.stake(1, 50 * 1e18);

        assertFalse(staking.hasMinBond(1));
    }

    function test_hasMinBond_true_atMin() public {
        vm.prank(registrant1);
        staking.stake(1, 100 * 1e18);

        assertTrue(staking.hasMinBond(1));
    }

    function test_hasMinBond_true_aboveMin() public {
        vm.prank(registrant1);
        staking.stake(1, 500 * 1e18);

        assertTrue(staking.hasMinBond(1));
    }

    function test_hasMinBond_false_afterFullSlash() public {
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.prank(owner);
        staking.slash(1, 200 * 1e18);

        assertFalse(staking.hasMinBond(1));
    }

    // ============================================
    // ADMIN FUNCTION TESTS
    // ============================================

    function test_setMinBond_success() public {
        vm.expectEmit(false, false, false, true);
        emit MinBondUpdated(100 * 1e18, 200 * 1e18);

        vm.prank(owner);
        staking.setMinBond(200 * 1e18);

        assertEq(staking.getMinBond(), 200 * 1e18);
    }

    function test_setMinBond_reverts_nonOwner() public {
        vm.expectRevert();
        vm.prank(attacker);
        staking.setMinBond(200 * 1e18);
    }

    function test_setTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(treasury, newTreasury);

        vm.prank(owner);
        staking.setTreasury(newTreasury);

        assertEq(staking.treasury(), newTreasury);
    }

    function test_setTreasury_reverts_zeroAddress() public {
        vm.expectRevert(IReputationStaking.ZeroAddress.selector);
        vm.prank(owner);
        staking.setTreasury(address(0));
    }

    function test_setAgentIdentity_reverts_zeroAddress() public {
        vm.expectRevert(IReputationStaking.ZeroAddress.selector);
        vm.prank(owner);
        staking.setAgentIdentity(address(0));
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function test_pause_unpause() public {
        vm.prank(owner);
        staking.pause();
        assertTrue(staking.paused());

        vm.prank(owner);
        staking.unpause();
        assertFalse(staking.paused());
    }

    // ============================================
    // INTEGRATION: SLASH THEN UNSTAKE
    // ============================================

    function test_integration_slashThenUnstake() public {
        // Stake 200
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        // Slash 50
        vm.prank(owner);
        staking.slash(1, 50 * 1e18);

        // Decommission
        vm.prank(registrant1);
        agentIdentity.decommissionAgent(1);

        // Unstake remaining 150
        uint256 balanceBefore = tagToken.balanceOf(registrant1);
        vm.prank(registrant1);
        staking.unstake(1);

        assertEq(tagToken.balanceOf(registrant1), balanceBefore + 150 * 1e18);
        assertEq(staking.getStake(1), 0);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_stake_arbitraryAmount(uint256 amount) public {
        amount = bound(amount, 1, 10_000 * 1e18);

        vm.prank(registrant1);
        staking.stake(1, amount);

        assertEq(staking.getStake(1), amount);
    }

    function testFuzz_slash_withinBounds(uint256 stakeAmount, uint256 slashAmount) public {
        stakeAmount = bound(stakeAmount, 1, 10_000 * 1e18);
        slashAmount = bound(slashAmount, 1, stakeAmount);

        vm.prank(registrant1);
        staking.stake(1, stakeAmount);

        vm.prank(owner);
        staking.slash(1, slashAmount);

        assertEq(staking.getStake(1), stakeAmount - slashAmount);
    }

    // ============================================
    // MULTIPLE AGENTS
    // ============================================

    function test_multipleAgents_independentStakes() public {
        // Register second agent
        vm.prank(registrant2);
        tagToken.approve(address(staking), type(uint256).max);
        vm.prank(registrant2);
        agentIdentity.register(agentWallet2, "ipfs://QmAgent2");

        // Stake for both agents
        vm.prank(registrant1);
        staking.stake(1, 200 * 1e18);

        vm.prank(registrant2);
        staking.stake(2, 300 * 1e18);

        assertEq(staking.getStake(1), 200 * 1e18);
        assertEq(staking.getStake(2), 300 * 1e18);

        // Slash agent 1 doesn't affect agent 2
        vm.prank(owner);
        staking.slash(1, 100 * 1e18);

        assertEq(staking.getStake(1), 100 * 1e18);
        assertEq(staking.getStake(2), 300 * 1e18);
    }
}
