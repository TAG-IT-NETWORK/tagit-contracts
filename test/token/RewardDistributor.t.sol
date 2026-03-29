// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {RewardDistributor} from "../../src/token/RewardDistributor.sol";
import {GENESIS_SUPPLY, BASIS_POINTS} from "../../src/libraries/Constants.sol";

/**
 * @title RewardDistributor Unit Tests
 * @notice Comprehensive tests for ecosystem, referral, verification, and governance rewards
 */
contract RewardDistributorTest is Test {
    TAGITToken public token;
    TAGITToken public tokenImpl;
    RewardDistributor public distributor;

    address public owner;
    address public treasury;
    address public alice;
    address public bob;
    address public carol;
    address public unauthorized;

    // Events to test
    event RewardDistributed(
        address indexed recipient,
        uint256 amount,
        RewardDistributor.TriggerType indexed triggerType,
        uint256 cumulativeDistributed
    );
    event ReferralRewardDistributed(address indexed referrer, address indexed referee, uint256 amount);
    event GovernanceRewardDistributed(address indexed voter, uint256 indexed proposalId, uint256 amount);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        unauthorized = makeAddr("unauthorized");

        // Deploy TAGITToken via proxy
        tokenImpl = new TAGITToken();
        bytes memory initData = abi.encodeWithSelector(TAGITToken.initialize.selector, treasury, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(tokenImpl), initData);
        token = TAGITToken(address(proxy));

        // Deploy RewardDistributor with owner as admin
        distributor = new RewardDistributor(address(token), owner);

        // Fund distributor with tokens from treasury (5% of supply)
        uint256 fundAmount = (GENESIS_SUPPLY * 500) / BASIS_POINTS;
        vm.prank(treasury);
        token.transfer(address(distributor), fundAmount);
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function test_constructor_setsToken() public view {
        assertEq(address(distributor.token()), address(token));
    }

    function test_constructor_grantsAdminRole() public view {
        assertTrue(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), owner));
    }

    function test_constructor_grantsDistributorRole() public view {
        assertTrue(distributor.hasRole(distributor.DISTRIBUTOR_ROLE(), owner));
    }

    function test_constructor_revert_zeroToken() public {
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(address(0), owner);
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(address(token), address(0));
    }

    function test_constructor_initialCumulativeIsZero() public view {
        assertEq(distributor.cumulativeDistributed(), 0);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_distributionCap_isFivePercentOfSupply() public view {
        uint256 expectedCap = (token.totalSupply() * 500) / BASIS_POINTS;
        assertEq(distributor.distributionCap(), expectedCap);
    }

    function test_remainingDistributable_initiallyEqualsCap() public view {
        assertEq(distributor.remainingDistributable(), distributor.distributionCap());
    }

    // ============================================
    // ECOSYSTEM REWARD TESTS
    // ============================================

    function test_distributeEcosystemReward_success() public {
        uint256 amount = 1000 * 1e18;
        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RewardDistributed(alice, amount, RewardDistributor.TriggerType.ECOSYSTEM, amount);
        distributor.distributeEcosystemReward(alice, amount);

        assertEq(token.balanceOf(alice), aliceBalBefore + amount);
        assertEq(distributor.cumulativeDistributed(), amount);
    }

    function test_distributeEcosystemReward_revert_capExceeded() public {
        uint256 cap = distributor.distributionCap();
        uint256 overCap = cap + 1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardDistributor.MintCapExceeded.selector, overCap, cap));
        distributor.distributeEcosystemReward(alice, overCap);
    }

    function test_distributeEcosystemReward_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        distributor.distributeEcosystemReward(address(0), 1000);
    }

    function test_distributeEcosystemReward_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        distributor.distributeEcosystemReward(alice, 0);
    }

    function test_distributeEcosystemReward_revert_unauthorized() public {
        bytes32 role = distributor.DISTRIBUTOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, role)
        );
        vm.prank(unauthorized);
        distributor.distributeEcosystemReward(alice, 1000);
    }

    // ============================================
    // REFERRAL REWARD TESTS
    // ============================================

    function test_distributeReferralReward_success() public {
        uint256 amount = 500 * 1e18;

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ReferralRewardDistributed(alice, bob, amount);
        distributor.distributeReferralReward(alice, bob, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(distributor.cumulativeDistributed(), amount);
    }

    function test_distributeReferralReward_revert_zeroReferrer() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        distributor.distributeReferralReward(address(0), bob, 1000);
    }

    function test_distributeReferralReward_revert_zeroReferee() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        distributor.distributeReferralReward(alice, address(0), 1000);
    }

    function test_distributeReferralReward_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        distributor.distributeReferralReward(alice, bob, 0);
    }

    function test_distributeReferralReward_revert_capExceeded() public {
        uint256 cap = distributor.distributionCap();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardDistributor.MintCapExceeded.selector, cap + 1, cap));
        distributor.distributeReferralReward(alice, bob, cap + 1);
    }

    // ============================================
    // VERIFICATION REWARD TESTS
    // ============================================

    function test_distributeVerificationReward_success() public {
        uint256 amount = 200 * 1e18;

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RewardDistributed(alice, amount, RewardDistributor.TriggerType.VERIFICATION, amount);
        distributor.distributeVerificationReward(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(distributor.cumulativeDistributed(), amount);
    }

    function test_distributeVerificationReward_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        distributor.distributeVerificationReward(address(0), 1000);
    }

    function test_distributeVerificationReward_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        distributor.distributeVerificationReward(alice, 0);
    }

    function test_distributeVerificationReward_revert_unauthorized() public {
        bytes32 role = distributor.DISTRIBUTOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, role)
        );
        vm.prank(unauthorized);
        distributor.distributeVerificationReward(alice, 1000);
    }

    // ============================================
    // GOVERNANCE REWARD TESTS
    // ============================================

    function test_distributeGovernanceReward_success() public {
        uint256 amount = 100 * 1e18;
        uint256 proposalId = 42;

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit GovernanceRewardDistributed(alice, proposalId, amount);
        distributor.distributeGovernanceReward(alice, proposalId, amount);

        assertEq(token.balanceOf(alice), amount);
        assertTrue(distributor.hasClaimedGovernanceReward(proposalId, alice));
        assertEq(distributor.cumulativeDistributed(), amount);
    }

    function test_distributeGovernanceReward_revert_duplicateClaim() public {
        uint256 amount = 100 * 1e18;
        uint256 proposalId = 42;

        vm.prank(owner);
        distributor.distributeGovernanceReward(alice, proposalId, amount);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.GovernanceRewardAlreadyClaimed.selector, proposalId, alice)
        );
        distributor.distributeGovernanceReward(alice, proposalId, amount);
    }

    function test_distributeGovernanceReward_differentProposalAllowed() public {
        uint256 amount = 100 * 1e18;

        vm.startPrank(owner);
        distributor.distributeGovernanceReward(alice, 1, amount);
        distributor.distributeGovernanceReward(alice, 2, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), amount * 2);
        assertTrue(distributor.hasClaimedGovernanceReward(1, alice));
        assertTrue(distributor.hasClaimedGovernanceReward(2, alice));
    }

    function test_distributeGovernanceReward_differentVoterSameProposal() public {
        uint256 amount = 100 * 1e18;
        uint256 proposalId = 42;

        vm.startPrank(owner);
        distributor.distributeGovernanceReward(alice, proposalId, amount);
        distributor.distributeGovernanceReward(bob, proposalId, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function test_distributeGovernanceReward_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        distributor.distributeGovernanceReward(address(0), 42, 1000);
    }

    function test_distributeGovernanceReward_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        distributor.distributeGovernanceReward(alice, 42, 0);
    }

    // ============================================
    // INTEGRATION TEST: DRAIN TO CAP
    // ============================================

    function test_integration_drainExactlyFivePercent() public {
        uint256 cap = distributor.distributionCap();
        uint256 quarterCap = cap / 4;
        // Remainder to account for integer division
        uint256 remainder = cap - (quarterCap * 4);

        vm.startPrank(owner);

        // Trigger 1: Ecosystem action
        distributor.distributeEcosystemReward(alice, quarterCap);
        assertEq(distributor.cumulativeDistributed(), quarterCap);

        // Trigger 2: Referral
        distributor.distributeReferralReward(bob, carol, quarterCap);
        assertEq(distributor.cumulativeDistributed(), quarterCap * 2);

        // Trigger 3: Verification
        distributor.distributeVerificationReward(carol, quarterCap);
        assertEq(distributor.cumulativeDistributed(), quarterCap * 3);

        // Trigger 4: Governance (uses quarterCap + remainder to hit exact cap)
        distributor.distributeGovernanceReward(alice, 1, quarterCap + remainder);
        assertEq(distributor.cumulativeDistributed(), cap);

        // Trigger 5: Should revert - cap fully drained
        vm.expectRevert(abi.encodeWithSelector(RewardDistributor.MintCapExceeded.selector, cap + 1, cap));
        distributor.distributeEcosystemReward(alice, 1);

        vm.stopPrank();

        // Verify remaining is zero
        assertEq(distributor.remainingDistributable(), 0);
    }

    // ============================================
    // REMAINING DISTRIBUTABLE TESTS
    // ============================================

    function test_remainingDistributable_decreasesAfterDistribution() public {
        uint256 cap = distributor.distributionCap();
        uint256 amount = 1000 * 1e18;

        vm.prank(owner);
        distributor.distributeEcosystemReward(alice, amount);

        assertEq(distributor.remainingDistributable(), cap - amount);
    }

    function test_remainingDistributable_zeroAtCap() public {
        uint256 cap = distributor.distributionCap();

        vm.prank(owner);
        distributor.distributeEcosystemReward(alice, cap);

        assertEq(distributor.remainingDistributable(), 0);
    }

    // ============================================
    // ROLE MANAGEMENT TESTS
    // ============================================

    function test_grantDistributorRole_allowsDistribution() public {
        address newDistributor = makeAddr("newDistributor");
        bytes32 role = distributor.DISTRIBUTOR_ROLE();

        vm.prank(owner);
        distributor.grantRole(role, newDistributor);

        vm.prank(newDistributor);
        distributor.distributeEcosystemReward(alice, 100 * 1e18);

        assertEq(token.balanceOf(alice), 100 * 1e18);
    }

    function test_revokeDistributorRole_blocksDistribution() public {
        address newDistributor = makeAddr("newDistributor");
        bytes32 role = distributor.DISTRIBUTOR_ROLE();

        vm.startPrank(owner);
        distributor.grantRole(role, newDistributor);
        distributor.revokeRole(role, newDistributor);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, newDistributor, role)
        );
        vm.prank(newDistributor);
        distributor.distributeEcosystemReward(alice, 100);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_distributeEcosystemReward(uint256 amount) public {
        uint256 cap = distributor.distributionCap();
        amount = bound(amount, 1, cap);

        vm.prank(owner);
        distributor.distributeEcosystemReward(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(distributor.cumulativeDistributed(), amount);
    }

    function testFuzz_capAlwaysEnforced(uint256 amount) public {
        uint256 cap = distributor.distributionCap();
        amount = bound(amount, cap + 1, type(uint128).max);

        vm.prank(owner);
        vm.expectRevert();
        distributor.distributeEcosystemReward(alice, amount);
    }
}
