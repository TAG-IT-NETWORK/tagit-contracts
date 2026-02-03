// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {TAGITGovernor} from "../../src/governance/TAGITGovernor.sol";
import {ITAGITGovernor} from "../../src/interfaces/ITAGITGovernor.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITStaking} from "../../src/token/TAGITStaking.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

contract TAGITGovernorTest is Test {
    // Contracts
    TAGITGovernor public governor;
    TAGITGovernor public governorImpl;
    TAGITToken public token;
    TAGITStaking public staking;
    TAGITStaking public stakingImpl;
    TAGITAccess public access;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;
    TimelockController public timelock;

    // Actors
    address public owner;
    address public guardian;
    address public treasury;
    address public proposer;
    address public govMilVoter;
    address public enterpriseVoter;
    address public devVoter;
    address public regulatoryVoter;
    address public publicVoter;
    address public alice;
    address public bob;

    // Constants
    uint256 public constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 public constant STAKE_AMOUNT = 150_000e18;
    uint256 public constant VOTING_DELAY = 1 days;
    uint256 public constant VOTING_PERIOD = 7 days;

    // Badge IDs
    uint256 public constant BADGE_GOV_MIL = 20;
    uint256 public constant BADGE_MANUFACTURER = 10;
    uint256 public constant BADGE_DEV = 30;
    uint256 public constant BADGE_REGULATORY = 40;

    // Events
    event HouseVoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        ITAGITGovernor.House house,
        uint8 support,
        uint256 weight
    );
    event EmergencyPaused(address indexed guardian);
    event GovernorUnpaused(address indexed guardian);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    function setUp() public {
        owner = makeAddr("owner");
        guardian = makeAddr("guardian");
        treasury = makeAddr("treasury");
        proposer = makeAddr("proposer");
        govMilVoter = makeAddr("govMilVoter");
        enterpriseVoter = makeAddr("enterpriseVoter");
        devVoter = makeAddr("devVoter");
        regulatoryVoter = makeAddr("regulatoryVoter");
        publicVoter = makeAddr("publicVoter");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.startPrank(owner);

        // Deploy token (upgradeable)
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(
            TAGITToken.initialize,
            (owner, treasury)
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        // Deploy access control (not upgradeable)
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        access = new TAGITAccess();
        access.setIdentityBadge(address(identityBadge));
        access.setCapabilityBadge(address(capabilityBadge));

        // Deploy staking (upgradeable)
        stakingImpl = new TAGITStaking();
        staking = TAGITStaking(address(new ERC1967Proxy(
            address(stakingImpl),
            abi.encodeCall(TAGITStaking.initialize, (address(token), owner, owner))
        )));

        // Deploy timelock (non-upgradeable)
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(0); // Will be set to governor
        executors[0] = address(0); // Open executor

        timelock = new TimelockController(2 days, proposers, executors, owner);

        // Deploy governor (upgradeable)
        governorImpl = new TAGITGovernor();
        governor = TAGITGovernor(payable(address(new ERC1967Proxy(
            address(governorImpl),
            abi.encodeCall(TAGITGovernor.initialize, (
                IVotes(address(token)),
                TimelockControllerUpgradeable(payable(address(timelock))),
                access,
                staking,
                guardian,
                owner
            ))
        ))));

        // Grant timelock roles to governor
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        timelock.grantRole(proposerRole, address(governor));
        timelock.grantRole(executorRole, address(0)); // Open execution
        timelock.grantRole(cancellerRole, address(governor));

        // Grant identity badges
        identityBadge.grantIdentity(govMilVoter, BADGE_GOV_MIL);
        identityBadge.grantIdentity(enterpriseVoter, BADGE_MANUFACTURER);
        identityBadge.grantIdentity(devVoter, BADGE_DEV);
        identityBadge.grantIdentity(regulatoryVoter, BADGE_REGULATORY);

        // Distribute tokens - proposer needs tokens to stake AND tokens to have voting power
        // Give proposer extra for voting power
        token.transfer(proposer, STAKE_AMOUNT + PROPOSAL_THRESHOLD);
        token.transfer(publicVoter, 1_000_000e18);
        token.transfer(alice, 500_000e18);
        token.transfer(bob, 500_000e18);

        vm.stopPrank();

        // Setup staking for proposer
        vm.startPrank(proposer);
        token.approve(address(staking), STAKE_AMOUNT);
        staking.stake(STAKE_AMOUNT);
        // Delegate remaining tokens for voting power
        token.delegate(proposer);
        vm.stopPrank();

        // Delegate tokens for voting
        vm.prank(publicVoter);
        token.delegate(publicVoter);
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);

        // Advance block for voting power snapshot
        vm.roll(block.number + 1);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialization() public view {
        assertEq(governor.version(), "1.0.0");
        assertEq(governor.guardian(), guardian);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.accessControl(), address(access));
        assertEq(governor.stakingContract(), address(staking));
    }

    function test_initialization_revert_zeroAddress() public {
        TAGITGovernor newGov = new TAGITGovernor();

        vm.expectRevert(ITAGITGovernor.ZeroAddress.selector);
        new ERC1967Proxy(
            address(newGov),
            abi.encodeCall(TAGITGovernor.initialize, (
                IVotes(address(0)),
                TimelockControllerUpgradeable(payable(address(timelock))),
                access,
                staking,
                guardian,
                owner
            ))
        );
    }

    // ============================================
    // VOTING POWER TESTS
    // ============================================

    function test_getVotingPower_govMil() public view {
        (uint256 weight, ITAGITGovernor.House house) = governor.getVotingPower(govMilVoter);
        assertEq(weight, governor.BASIS_POINTS()); // 10000 for badge holders
        assertEq(uint256(house), uint256(ITAGITGovernor.House.GOV_MIL));
    }

    function test_getVotingPower_enterprise() public view {
        (uint256 weight, ITAGITGovernor.House house) = governor.getVotingPower(enterpriseVoter);
        assertEq(weight, governor.BASIS_POINTS()); // 10000 for badge holders
        assertEq(uint256(house), uint256(ITAGITGovernor.House.ENTERPRISE));
    }

    function test_getVotingPower_dev() public view {
        (uint256 weight, ITAGITGovernor.House house) = governor.getVotingPower(devVoter);
        assertEq(weight, governor.BASIS_POINTS()); // 10000 for badge holders
        assertEq(uint256(house), uint256(ITAGITGovernor.House.DEV));
    }

    function test_getVotingPower_regulatory() public view {
        (uint256 weight, ITAGITGovernor.House house) = governor.getVotingPower(regulatoryVoter);
        assertEq(weight, governor.BASIS_POINTS()); // 10000 for badge holders
        assertEq(uint256(house), uint256(ITAGITGovernor.House.REGULATORY));
    }

    function test_getVotingPower_public() public view {
        (uint256 weight, ITAGITGovernor.House house) = governor.getVotingPower(publicVoter);
        assertEq(weight, 1_000_000e18);
        assertEq(uint256(house), uint256(ITAGITGovernor.House.PUBLIC));
    }

    function test_getVotingPower_noVotingPower() public {
        address nobody = makeAddr("nobody");
        (uint256 weight, ITAGITGovernor.House house) = governor.getVotingPower(nobody);
        assertEq(weight, 0);
        assertEq(uint256(house), uint256(ITAGITGovernor.House.PUBLIC));
    }

    // ============================================
    // PROPOSAL TESTS
    // ============================================

    function test_propose_success() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(governor);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(governor.setGuardian, (alice));

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Set new guardian");

        assertGt(proposalId, 0);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_propose_revert_insufficientStake() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(governor);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(governor.setGuardian, (alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITGovernor.InsufficientStake.selector,
            alice,
            PROPOSAL_THRESHOLD,
            0
        ));
        governor.propose(targets, values, calldatas, "Set new guardian");
    }

    // ============================================
    // VOTING TESTS
    // ============================================

    function test_castVote_success() public {
        uint256 proposalId = _createProposal();

        // Advance to voting period (votingDelay blocks + 1)
        vm.roll(block.number + governor.votingDelay() + 1);

        uint256 badgeWeight = governor.BASIS_POINTS();
        vm.expectEmit(true, true, false, true);
        emit HouseVoteCast(proposalId, govMilVoter, ITAGITGovernor.House.GOV_MIL, 1, badgeWeight);

        vm.prank(govMilVoter);
        uint256 weight = governor.castVote(proposalId, 1);

        assertEq(weight, badgeWeight);
        assertTrue(governor.hasVoted(proposalId, govMilVoter));
    }

    function test_castVote_allHouses() public {
        uint256 proposalId = _createProposal();

        // Advance to voting period (votingDelay blocks + 1)
        vm.roll(block.number + governor.votingDelay() + 1);

        // Vote from all houses
        vm.prank(govMilVoter);
        governor.castVote(proposalId, 1);

        vm.prank(enterpriseVoter);
        governor.castVote(proposalId, 1);

        vm.prank(devVoter);
        governor.castVote(proposalId, 1);

        vm.prank(regulatoryVoter);
        governor.castVote(proposalId, 1);

        vm.prank(publicVoter);
        governor.castVote(proposalId, 1);

        // Check house votes
        ITAGITGovernor.HouseVotes[5] memory houseVotes = governor.getHouseVotes(proposalId);
        uint256 badgeWeight = governor.BASIS_POINTS(); // 10000 for badge holders

        assertEq(houseVotes[0].forVotes, badgeWeight); // GOV_MIL
        assertEq(houseVotes[1].forVotes, badgeWeight); // ENTERPRISE
        assertEq(houseVotes[2].forVotes, 1_000_000e18); // PUBLIC
        assertEq(houseVotes[3].forVotes, badgeWeight); // DEV
        assertEq(houseVotes[4].forVotes, badgeWeight); // REGULATORY
    }

    function test_castVote_revert_alreadyVoted() public {
        uint256 proposalId = _createProposal();

        vm.roll(block.number + governor.votingDelay() + 1);

        vm.startPrank(govMilVoter);
        governor.castVote(proposalId, 1);

        vm.expectRevert(abi.encodeWithSelector(
            ITAGITGovernor.AlreadyVoted.selector,
            proposalId,
            govMilVoter
        ));
        governor.castVote(proposalId, 0);
        vm.stopPrank();
    }

    function test_castVote_revert_noVotingPower() public {
        uint256 proposalId = _createProposal();
        address nobody = makeAddr("nobody");

        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITGovernor.NoVotingPower.selector,
            nobody
        ));
        governor.castVote(proposalId, 1);
    }

    function test_castVote_revert_invalidVoteType() public {
        uint256 proposalId = _createProposal();

        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(govMilVoter);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITGovernor.InvalidVoteType.selector,
            3
        ));
        governor.castVote(proposalId, 3);
    }

    function test_castVoteWithReason() public {
        uint256 proposalId = _createProposal();

        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(govMilVoter);
        uint256 weight = governor.castVoteWithReason(proposalId, 1, "I support this proposal");

        assertEq(weight, governor.BASIS_POINTS()); // 10000 for badge holders
        assertTrue(governor.hasVoted(proposalId, govMilVoter));
    }

    // ============================================
    // QUORUM TESTS
    // ============================================

    function test_quorum() public view {
        uint256 totalSupply = token.totalSupply();
        uint256 expectedQuorum = (totalSupply * 400) / 10000; // 4%
        assertEq(governor.quorum(), expectedQuorum);
    }

    // ============================================
    // EMERGENCY TESTS
    // ============================================

    function test_emergencyPause() public {
        vm.expectEmit(true, false, false, false);
        emit EmergencyPaused(guardian);

        vm.prank(guardian);
        governor.emergencyPause();

        assertTrue(governor.paused());
    }

    function test_emergencyPause_revert_notGuardian() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITGovernor.NotGuardian.selector,
            alice
        ));
        governor.emergencyPause();
    }

    function test_unpause() public {
        vm.prank(guardian);
        governor.emergencyPause();

        vm.expectEmit(true, false, false, false);
        emit GovernorUnpaused(guardian);

        vm.prank(guardian);
        governor.unpause();

        assertFalse(governor.paused());
    }

    function test_unpause_revert_notGuardian() public {
        vm.prank(guardian);
        governor.emergencyPause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITGovernor.NotGuardian.selector,
            alice
        ));
        governor.unpause();
    }

    function test_propose_revert_whenPaused() public {
        vm.prank(guardian);
        governor.emergencyPause();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(governor);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(governor.setGuardian, (alice));

        vm.prank(proposer);
        vm.expectRevert();
        governor.propose(targets, values, calldatas, "Set new guardian");
    }

    function test_castVote_revert_whenPaused() public {
        uint256 proposalId = _createProposal();

        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(guardian);
        governor.emergencyPause();

        vm.prank(govMilVoter);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_proposalVotes() public {
        uint256 proposalId = _createProposal();

        vm.roll(block.number + governor.votingDelay() + 1);

        // Cast votes
        vm.prank(govMilVoter);
        governor.castVote(proposalId, 1); // For

        vm.prank(devVoter);
        governor.castVote(proposalId, 0); // Against

        vm.prank(regulatoryVoter);
        governor.castVote(proposalId, 2); // Abstain

        (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes) = governor.proposalVotes(proposalId);

        // Gov/Mil: 1 vote * 30% = 0.3 (scaled)
        // Dev: 1 vote * 10% = 0.1 (scaled)
        // Regulatory: 1 vote * 10% = 0.1 (scaled)
        assertGt(forVotes, 0);
        assertGt(againstVotes, 0);
        assertGt(abstainVotes, 0);
    }

    function test_countingMode() public view {
        string memory mode = governor.COUNTING_MODE();
        assertEq(mode, "support=bravo&quorum=for,against,abstain&params=house");
    }

    // ============================================
    // HOUSE WEIGHT TESTS
    // ============================================

    function test_houseWeights() public view {
        assertEq(governor.HOUSE_WEIGHT_GOV_MIL(), 3000);
        assertEq(governor.HOUSE_WEIGHT_ENTERPRISE(), 3000);
        assertEq(governor.HOUSE_WEIGHT_PUBLIC(), 2000);
        assertEq(governor.HOUSE_WEIGHT_DEV(), 1000);
        assertEq(governor.HOUSE_WEIGHT_REGULATORY(), 1000);
    }

    function test_weightedVotes() public {
        uint256 proposalId = _createProposal();

        vm.roll(block.number + governor.votingDelay() + 1);

        // Vote from Gov/Mil (30% weight)
        vm.prank(govMilVoter);
        governor.castVote(proposalId, 1);

        // Vote from Dev (10% weight)
        vm.prank(devVoter);
        governor.castVote(proposalId, 0);

        (uint256 forVotes, uint256 againstVotes,) = governor.proposalVotes(proposalId);

        // Gov/Mil has 3x the weight of Dev
        // forVotes should be 3x againstVotes (for unit weight badges)
        assertEq(forVotes * 1000 / againstVotes, 3000);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_propose() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(governor);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(governor.setGuardian, (alice));

        vm.prank(proposer);
        uint256 gasBefore = gasleft();
        governor.propose(targets, values, calldatas, "Test proposal");
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 300_000, "propose() gas too high");
    }

    function test_gas_castVote() public {
        uint256 proposalId = _createProposal();
        vm.roll(block.number + governor.votingDelay() + 1);

        vm.prank(govMilVoter);
        uint256 gasBefore = gasleft();
        governor.castVote(proposalId, 1);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 120_000, "castVote() gas too high");
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _createProposal() internal returns (uint256) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(governor);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(governor.setGuardian, (alice));

        vm.prank(proposer);
        return governor.propose(targets, values, calldatas, "Test proposal");
    }
}
