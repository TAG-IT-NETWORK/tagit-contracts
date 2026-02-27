// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITEmissions} from "../../src/token/TAGITEmissions.sol";
import {ITAGITEmissions} from "../../src/interfaces/ITAGITEmissions.sol";
import {
    GENESIS_SUPPLY,
    INFLATION_RATE,
    EPOCHS_PER_YEAR,
    EPOCH_DURATION,
    BASIS_POINTS
} from "../../src/libraries/Constants.sol";

/**
 * @title TAGITEmissions Unit Tests
 * @notice Comprehensive tests for the TAGIT emissions/inflation contract
 */
contract TAGITEmissionsTest is Test {
    TAGITToken public token;
    TAGITToken public tokenImpl;
    TAGITEmissions public emissions;
    TAGITEmissions public emissionsImpl;

    address public owner;
    address public treasury;
    address public governor;
    address public ecosystem;
    address public staking;
    address public devFund;
    address public alice;

    // Events
    event EpochDistributed(uint256 indexed epoch, uint256 amount, uint256 timestamp);
    event AllocationsUpdated(address[] recipients, uint256[] weights);
    event TokenSet(address indexed token);
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        governor = makeAddr("governor");
        ecosystem = makeAddr("ecosystem");
        staking = makeAddr("staking");
        devFund = makeAddr("devFund");
        alice = makeAddr("alice");

        // Deploy TAGITToken
        tokenImpl = new TAGITToken();
        bytes memory tokenInitData = abi.encodeWithSelector(TAGITToken.initialize.selector, treasury, owner);
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITEmissions
        emissionsImpl = new TAGITEmissions();
        bytes memory emissionsInitData =
            abi.encodeWithSelector(TAGITEmissions.initialize.selector, address(token), governor, owner);
        ERC1967Proxy emissionsProxy = new ERC1967Proxy(address(emissionsImpl), emissionsInitData);
        emissions = TAGITEmissions(address(emissionsProxy));

        // Configure token to allow emissions to mint
        vm.prank(owner);
        token.setEmissionsAddress(address(emissions));
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsToken() public view {
        assertEq(address(emissions.token()), address(token));
    }

    function test_initialize_setsGovernor() public view {
        assertEq(emissions.governor(), governor);
    }

    function test_initialize_setsGenesisTimestamp() public view {
        assertEq(emissions.genesisTimestamp(), block.timestamp);
    }

    function test_initialize_startsAtEpochZero() public view {
        assertEq(emissions.currentEpoch(), 0);
    }

    function test_initialize_setsDefaultAllocations() public view {
        assertEq(emissions.allocationCount(), 1);
    }

    function test_initialize_revert_zeroToken() public {
        TAGITEmissions newImpl = new TAGITEmissions();
        bytes memory initData = abi.encodeWithSelector(TAGITEmissions.initialize.selector, address(0), governor, owner);
        vm.expectRevert(ITAGITEmissions.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_revert_zeroGovernor() public {
        TAGITEmissions newImpl = new TAGITEmissions();
        bytes memory initData =
            abi.encodeWithSelector(TAGITEmissions.initialize.selector, address(token), address(0), owner);
        vm.expectRevert(ITAGITEmissions.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============================================
    // EPOCH TRACKING TESTS
    // ============================================

    function test_currentEpoch_startsAtZero() public view {
        assertEq(emissions.currentEpoch(), 0);
    }

    function test_currentEpoch_incrementsAfterOneWeek() public {
        assertEq(emissions.currentEpoch(), 0);

        // Advance 1 week
        vm.warp(block.timestamp + 1 weeks);
        assertEq(emissions.currentEpoch(), 1);

        // Advance another week
        vm.warp(block.timestamp + 1 weeks);
        assertEq(emissions.currentEpoch(), 2);
    }

    function test_currentEpoch_partialWeekStaysSameEpoch() public {
        assertEq(emissions.currentEpoch(), 0);

        // Advance less than 1 week
        vm.warp(block.timestamp + 6 days);
        assertEq(emissions.currentEpoch(), 0);

        // Cross to next week
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(emissions.currentEpoch(), 1);
    }

    function test_nextDistributionTime_calculatesCorrectly() public view {
        // With no distributions yet, next is epoch 1
        uint256 expectedNext = emissions.genesisTimestamp() + EPOCH_DURATION;
        assertEq(emissions.nextDistributionTime(), expectedNext);
    }

    // ============================================
    // DISTRIBUTE EPOCH TESTS
    // ============================================

    function test_distributeEpoch_mintsCorrectAmount() public {
        // Advance to epoch 1
        vm.warp(block.timestamp + 1 weeks);

        uint256 totalSupply = token.totalSupply();
        uint256 expectedDistribution = (totalSupply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

        emissions.distributeEpoch();

        // Check total supply increased
        assertEq(token.totalSupply(), totalSupply + expectedDistribution);
    }

    function test_distributeEpoch_emitsEvent() public {
        vm.warp(block.timestamp + 1 weeks);

        uint256 totalSupply = token.totalSupply();
        uint256 expectedAmount = (totalSupply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

        vm.expectEmit(true, false, false, true);
        emit EpochDistributed(1, expectedAmount, block.timestamp);
        emissions.distributeEpoch();
    }

    function test_distributeEpoch_updatesLastDistributedEpoch() public {
        vm.warp(block.timestamp + 1 weeks);

        assertEq(emissions.lastDistributedEpoch(), 0);
        emissions.distributeEpoch();
        assertEq(emissions.lastDistributedEpoch(), 1);
    }

    function test_distributeEpoch_updatesTotalDistributed() public {
        vm.warp(block.timestamp + 1 weeks);

        uint256 totalSupply = token.totalSupply();
        uint256 expectedAmount = (totalSupply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

        assertEq(emissions.totalDistributed(), 0);
        emissions.distributeEpoch();
        assertEq(emissions.totalDistributed(), expectedAmount);
    }

    function test_distributeEpoch_recordsEpochDistribution() public {
        vm.warp(block.timestamp + 1 weeks);

        uint256 totalSupply = token.totalSupply();
        uint256 expectedAmount = (totalSupply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

        emissions.distributeEpoch();
        assertEq(emissions.epochDistribution(1), expectedAmount);
    }

    function test_distributeEpoch_isPermissionless() public {
        vm.warp(block.timestamp + 1 weeks);

        // Anyone can call distributeEpoch
        vm.prank(alice);
        emissions.distributeEpoch();

        assertEq(emissions.lastDistributedEpoch(), 1);
    }

    function test_distributeEpoch_revert_cannotDistributeEpochZero() public {
        // At genesis, epoch 0 cannot be distributed (nothing has elapsed)
        vm.expectRevert(abi.encodeWithSelector(ITAGITEmissions.EpochAlreadyDistributed.selector, 0));
        emissions.distributeEpoch();
    }

    function test_distributeEpoch_revert_cannotDoubleDistribute() public {
        vm.warp(block.timestamp + 1 weeks);

        emissions.distributeEpoch();

        // Try to distribute same epoch again
        vm.expectRevert(abi.encodeWithSelector(ITAGITEmissions.EpochAlreadyDistributed.selector, 1));
        emissions.distributeEpoch();
    }

    function test_distributeEpoch_canCatchUpMultipleEpochs() public {
        // Skip 3 weeks
        vm.warp(block.timestamp + 3 weeks);

        // Distribute epoch 3 (latest)
        emissions.distributeEpoch();
        assertEq(emissions.lastDistributedEpoch(), 3);

        // Epochs 1 and 2 are skipped (allowed - no forced sequential)
    }

    function test_distributeEpoch_distributesToAllRecipients() public {
        // Setup allocations: 50% ecosystem, 30% staking, 20% devFund
        address[] memory recipients = new address[](3);
        uint256[] memory weights = new uint256[](3);
        recipients[0] = ecosystem;
        recipients[1] = staking;
        recipients[2] = devFund;
        weights[0] = 5000; // 50%
        weights[1] = 3000; // 30%
        weights[2] = 2000; // 20%

        vm.prank(governor);
        emissions.setAllocationWeights(recipients, weights);

        vm.warp(block.timestamp + 1 weeks);

        uint256 totalSupply = token.totalSupply();
        uint256 weeklyAmount = (totalSupply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

        emissions.distributeEpoch();

        // Check balances
        assertEq(token.balanceOf(ecosystem), (weeklyAmount * 5000) / BASIS_POINTS);
        assertEq(token.balanceOf(staking), (weeklyAmount * 3000) / BASIS_POINTS);
        assertEq(token.balanceOf(devFund), (weeklyAmount * 2000) / BASIS_POINTS);
    }

    // ============================================
    // SET ALLOCATION WEIGHTS TESTS
    // ============================================

    function test_setAllocationWeights_success() public {
        address[] memory recipients = new address[](2);
        uint256[] memory weights = new uint256[](2);
        recipients[0] = ecosystem;
        recipients[1] = staking;
        weights[0] = 6000;
        weights[1] = 4000;

        vm.prank(governor);
        vm.expectEmit(false, false, false, true);
        emit AllocationsUpdated(recipients, weights);
        emissions.setAllocationWeights(recipients, weights);

        ITAGITEmissions.Allocation[] memory allocations = emissions.getAllocations();
        assertEq(allocations.length, 2);
        assertEq(allocations[0].recipient, ecosystem);
        assertEq(allocations[0].weight, 6000);
        assertEq(allocations[1].recipient, staking);
        assertEq(allocations[1].weight, 4000);
    }

    function test_setAllocationWeights_revert_notGovernor() public {
        address[] memory recipients = new address[](1);
        uint256[] memory weights = new uint256[](1);
        recipients[0] = ecosystem;
        weights[0] = 10000;

        vm.prank(alice);
        vm.expectRevert(ITAGITEmissions.Unauthorized.selector);
        emissions.setAllocationWeights(recipients, weights);
    }

    function test_setAllocationWeights_revert_weightsDontSum10000() public {
        address[] memory recipients = new address[](2);
        uint256[] memory weights = new uint256[](2);
        recipients[0] = ecosystem;
        recipients[1] = staking;
        weights[0] = 5000;
        weights[1] = 4000; // Only 9000 total

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITEmissions.InvalidAllocationWeights.selector, 9000));
        emissions.setAllocationWeights(recipients, weights);
    }

    function test_setAllocationWeights_revert_zeroAddress() public {
        address[] memory recipients = new address[](2);
        uint256[] memory weights = new uint256[](2);
        recipients[0] = ecosystem;
        recipients[1] = address(0);
        weights[0] = 5000;
        weights[1] = 5000;

        vm.prank(governor);
        vm.expectRevert(ITAGITEmissions.ZeroAddress.selector);
        emissions.setAllocationWeights(recipients, weights);
    }

    function test_setAllocationWeights_revert_arrayLengthMismatch() public {
        address[] memory recipients = new address[](2);
        uint256[] memory weights = new uint256[](1);
        recipients[0] = ecosystem;
        recipients[1] = staking;
        weights[0] = 10000;

        vm.prank(governor);
        vm.expectRevert(ITAGITEmissions.ArrayLengthMismatch.selector);
        emissions.setAllocationWeights(recipients, weights);
    }

    function test_setAllocationWeights_revert_emptyAllocations() public {
        address[] memory recipients = new address[](0);
        uint256[] memory weights = new uint256[](0);

        vm.prank(governor);
        vm.expectRevert(ITAGITEmissions.EmptyAllocations.selector);
        emissions.setAllocationWeights(recipients, weights);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_canDistribute_falseAtGenesis() public view {
        assertFalse(emissions.canDistribute());
    }

    function test_canDistribute_trueAfterOneWeek() public {
        vm.warp(block.timestamp + 1 weeks);
        assertTrue(emissions.canDistribute());
    }

    function test_canDistribute_falseAfterDistribution() public {
        vm.warp(block.timestamp + 1 weeks);
        emissions.distributeEpoch();
        assertFalse(emissions.canDistribute());
    }

    function test_pendingDistribution_zeroAtGenesis() public view {
        assertEq(emissions.pendingDistribution(), 0);
    }

    function test_pendingDistribution_calculatesCorrectly() public {
        vm.warp(block.timestamp + 1 weeks);

        uint256 totalSupply = token.totalSupply();
        uint256 expected = (totalSupply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

        assertEq(emissions.pendingDistribution(), expected);
    }

    // ============================================
    // GOVERNOR MANAGEMENT TESTS
    // ============================================

    function test_setGovernor_success() public {
        address newGovernor = makeAddr("newGovernor");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit GovernorUpdated(governor, newGovernor);
        emissions.setGovernor(newGovernor);

        assertEq(emissions.governor(), newGovernor);
    }

    function test_setGovernor_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        emissions.setGovernor(alice);
    }

    function test_setGovernor_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ITAGITEmissions.ZeroAddress.selector);
        emissions.setGovernor(address(0));
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_distributeEpoch_timing(uint256 weeksElapsed) public {
        weeksElapsed = bound(weeksElapsed, 1, 520); // Up to 10 years

        vm.warp(block.timestamp + weeksElapsed * 1 weeks);

        // PATCH-10: catch-up is capped at MAX_CATCH_UP_EPOCHS per call
        uint256 maxCatchUp = emissions.MAX_CATCH_UP_EPOCHS();
        uint256 expectedEpoch = weeksElapsed > maxCatchUp ? maxCatchUp : weeksElapsed;
        emissions.distributeEpoch();

        assertEq(emissions.lastDistributedEpoch(), expectedEpoch);
    }

    function testFuzz_allocationDistribution(uint256 weight1, uint256 weight2) public {
        // Ensure weights sum to 10000
        weight1 = bound(weight1, 1, 9999);
        weight2 = BASIS_POINTS - weight1;

        address[] memory recipients = new address[](2);
        uint256[] memory weights = new uint256[](2);
        recipients[0] = ecosystem;
        recipients[1] = staking;
        weights[0] = weight1;
        weights[1] = weight2;

        vm.prank(governor);
        emissions.setAllocationWeights(recipients, weights);

        vm.warp(block.timestamp + 1 weeks);
        emissions.distributeEpoch();

        // Verify distribution proportions
        uint256 ecosystemBal = token.balanceOf(ecosystem);
        uint256 stakingBal = token.balanceOf(staking);
        uint256 total = ecosystemBal + stakingBal;

        // Allow 1 wei rounding error per recipient
        assertApproxEqAbs(ecosystemBal, (total * weight1) / BASIS_POINTS, 1);
        assertApproxEqAbs(stakingBal, (total * weight2) / BASIS_POINTS, 1);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_distributeEpoch_1recipient() public {
        // Default allocation: 1 recipient (owner gets 100%)
        vm.warp(block.timestamp + 1 weeks);

        uint256 gasBefore = gasleft();
        emissions.distributeEpoch();
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target for 1 recipient: < 200,000
        assertLt(gasUsed, 200000, "distributeEpoch() exceeds gas target for 1 recipient");
    }

    function test_gas_distributeEpoch_4recipients() public {
        // Setup 4 allocations (realistic production config)
        address[] memory recipients = new address[](4);
        uint256[] memory weights = new uint256[](4);
        recipients[0] = ecosystem;
        recipients[1] = staking;
        recipients[2] = treasury;
        recipients[3] = devFund;
        weights[0] = 5000;
        weights[1] = 3000;
        weights[2] = 1500;
        weights[3] = 500;

        vm.prank(governor);
        emissions.setAllocationWeights(recipients, weights);

        vm.warp(block.timestamp + 1 weeks);

        uint256 gasBefore = gasleft();
        emissions.distributeEpoch();
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target for 4 recipients: < 270,000 (each mint ~65k due to ERC20Votes checkpoints)
        assertLt(gasUsed, 270000, "distributeEpoch() exceeds gas target for 4 recipients");
    }

    // ============================================
    // UPGRADE TESTS
    // ============================================

    function test_upgrade_preservesState() public {
        // Setup allocations
        address[] memory recipients = new address[](2);
        uint256[] memory weights = new uint256[](2);
        recipients[0] = ecosystem;
        recipients[1] = staking;
        weights[0] = 7000;
        weights[1] = 3000;

        vm.prank(governor);
        emissions.setAllocationWeights(recipients, weights);

        // Distribute epoch 1
        vm.warp(block.timestamp + 1 weeks);
        emissions.distributeEpoch();

        uint256 distributedBefore = emissions.totalDistributed();
        uint256 lastEpochBefore = emissions.lastDistributedEpoch();

        // Upgrade
        TAGITEmissions newImpl = new TAGITEmissions();
        vm.prank(owner);
        emissions.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(emissions.totalDistributed(), distributedBefore);
        assertEq(emissions.lastDistributedEpoch(), lastEpochBefore);
        assertEq(emissions.allocationCount(), 2);
    }
}
