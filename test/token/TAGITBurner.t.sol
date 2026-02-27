// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITBurner} from "../../src/token/TAGITBurner.sol";
import {ITAGITBurner} from "../../src/interfaces/ITAGITBurner.sol";
import {GENESIS_SUPPLY, BURN_FLOOR, DEFAULT_BURN_RATE, BASIS_POINTS, VERSION} from "../../src/libraries/Constants.sol";

/**
 * @title TAGITBurner Unit Tests
 * @notice Comprehensive tests for the TAGIT fee burning contract
 */
contract TAGITBurnerTest is Test {
    TAGITToken public token;
    TAGITToken public tokenImpl;
    TAGITBurner public burner;
    TAGITBurner public burnerImpl;

    address public owner;
    address public treasury;
    address public governor;
    address public alice;
    address public bob;

    // Events
    event FeeRouted(uint256 amount, uint256 burned, uint256 toTreasury);
    event BurnRateUpdated(uint256 oldRate, uint256 newRate);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        governor = makeAddr("governor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy TAGITToken
        tokenImpl = new TAGITToken();
        bytes memory tokenInitData = abi.encodeWithSelector(TAGITToken.initialize.selector, treasury, owner);
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITBurner
        burnerImpl = new TAGITBurner();
        bytes memory burnerInitData =
            abi.encodeWithSelector(TAGITBurner.initialize.selector, address(token), treasury, governor, owner);
        ERC1967Proxy burnerProxy = new ERC1967Proxy(address(burnerImpl), burnerInitData);
        burner = TAGITBurner(address(burnerProxy));
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsToken() public view {
        assertEq(address(burner.token()), address(token));
    }

    function test_initialize_setsTreasury() public view {
        assertEq(burner.treasury(), treasury);
    }

    function test_initialize_setsGovernor() public view {
        assertEq(burner.governor(), governor);
    }

    function test_initialize_setsDefaultBurnRate() public view {
        assertEq(burner.burnRate(), DEFAULT_BURN_RATE);
    }

    function test_initialize_startsWithZeroTotals() public view {
        assertEq(burner.totalBurned(), 0);
        assertEq(burner.totalToTreasury(), 0);
    }

    function test_initialize_revert_zeroToken() public {
        TAGITBurner newImpl = new TAGITBurner();
        bytes memory initData =
            abi.encodeWithSelector(TAGITBurner.initialize.selector, address(0), treasury, governor, owner);

        vm.expectRevert(ITAGITBurner.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_revert_zeroTreasury() public {
        TAGITBurner newImpl = new TAGITBurner();
        bytes memory initData =
            abi.encodeWithSelector(TAGITBurner.initialize.selector, address(token), address(0), governor, owner);

        vm.expectRevert(ITAGITBurner.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_revert_zeroGovernor() public {
        TAGITBurner newImpl = new TAGITBurner();
        bytes memory initData =
            abi.encodeWithSelector(TAGITBurner.initialize.selector, address(token), treasury, address(0), owner);

        vm.expectRevert(ITAGITBurner.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_revert_zeroOwner() public {
        TAGITBurner newImpl = new TAGITBurner();
        bytes memory initData =
            abi.encodeWithSelector(TAGITBurner.initialize.selector, address(token), treasury, governor, address(0));

        vm.expectRevert(ITAGITBurner.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============================================
    // ROUTE FEE TESTS
    // ============================================

    function test_routeFee_splitsCorrectly() public {
        uint256 amount = 1000 ether;

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve burner
        vm.prank(alice);
        token.approve(address(burner), amount);

        // Route fee
        vm.prank(alice);
        burner.routeFee(amount);

        // Calculate expected split (33.3% burn, 66.7% treasury)
        uint256 expectedBurn = (amount * DEFAULT_BURN_RATE) / BASIS_POINTS;
        uint256 expectedTreasury = amount - expectedBurn;

        assertEq(burner.totalBurned(), expectedBurn);
        assertEq(burner.totalToTreasury(), expectedTreasury);
    }

    function test_routeFee_burnsTokens() public {
        uint256 amount = 1000 ether;
        uint256 initialSupply = token.totalSupply();

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve and route
        vm.prank(alice);
        token.approve(address(burner), amount);
        vm.prank(alice);
        burner.routeFee(amount);

        uint256 expectedBurn = (amount * DEFAULT_BURN_RATE) / BASIS_POINTS;

        // Verify supply decreased
        assertEq(token.totalSupply(), initialSupply - expectedBurn);
    }

    function test_routeFee_sendsTreasury() public {
        uint256 amount = 1000 ether;
        uint256 initialTreasuryBalance = token.balanceOf(treasury);

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve and route
        vm.prank(alice);
        token.approve(address(burner), amount);
        vm.prank(alice);
        burner.routeFee(amount);

        uint256 expectedTreasury = amount - ((amount * DEFAULT_BURN_RATE) / BASIS_POINTS);

        // Verify treasury received tokens
        assertEq(token.balanceOf(treasury), initialTreasuryBalance - amount + expectedTreasury);
    }

    function test_routeFee_emitsEvent() public {
        uint256 amount = 1000 ether;

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve
        vm.prank(alice);
        token.approve(address(burner), amount);

        uint256 expectedBurn = (amount * DEFAULT_BURN_RATE) / BASIS_POINTS;
        uint256 expectedTreasury = amount - expectedBurn;

        vm.prank(alice);
        vm.expectEmit(false, false, false, true);
        emit FeeRouted(amount, expectedBurn, expectedTreasury);
        burner.routeFee(amount);
    }

    function test_routeFee_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ITAGITBurner.ZeroAmount.selector);
        burner.routeFee(0);
    }

    function test_routeFee_revert_insufficientBalance() public {
        vm.prank(alice);
        token.approve(address(burner), 1000 ether);

        vm.prank(alice);
        vm.expectRevert();
        burner.routeFee(1000 ether);
    }

    function test_routeFee_revert_insufficientAllowance() public {
        // Transfer tokens but don't approve
        vm.prank(treasury);
        token.transfer(alice, 1000 ether);

        vm.prank(alice);
        vm.expectRevert();
        burner.routeFee(1000 ether);
    }

    function test_routeFee_multipleCalls() public {
        uint256 amount = 100 ether;

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, 1000 ether);

        // Approve for multiple calls
        vm.prank(alice);
        token.approve(address(burner), 1000 ether);

        // Route fees 5 times
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            burner.routeFee(amount);
        }

        uint256 expectedBurnPerCall = (amount * DEFAULT_BURN_RATE) / BASIS_POINTS;
        uint256 expectedTreasuryPerCall = amount - expectedBurnPerCall;

        assertEq(burner.totalBurned(), expectedBurnPerCall * 5);
        assertEq(burner.totalToTreasury(), expectedTreasuryPerCall * 5);
    }

    // ============================================
    // SET BURN RATE TESTS
    // ============================================

    function test_setBurnRate_success() public {
        uint256 newRate = 5000; // 50%

        vm.prank(governor);
        vm.expectEmit(false, false, false, true);
        emit BurnRateUpdated(DEFAULT_BURN_RATE, newRate);
        burner.setBurnRate(newRate);

        assertEq(burner.burnRate(), newRate);
    }

    function test_setBurnRate_atFloor() public {
        // Should succeed at exactly BURN_FLOOR
        vm.prank(governor);
        burner.setBurnRate(BURN_FLOOR);

        assertEq(burner.burnRate(), BURN_FLOOR);
    }

    function test_setBurnRate_at100Percent() public {
        // Should succeed at exactly 100%
        vm.prank(governor);
        burner.setBurnRate(BASIS_POINTS);

        assertEq(burner.burnRate(), BASIS_POINTS);
    }

    function test_setBurnRate_revert_belowFloor() public {
        uint256 belowFloor = BURN_FLOOR - 1;

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITBurner.BurnRateBelowFloor.selector, belowFloor, BURN_FLOOR));
        burner.setBurnRate(belowFloor);
    }

    function test_setBurnRate_revert_zeroRate() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITBurner.BurnRateBelowFloor.selector, 0, BURN_FLOOR));
        burner.setBurnRate(0);
    }

    function test_setBurnRate_revert_above100Percent() public {
        uint256 tooHigh = BASIS_POINTS + 1;

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITBurner.BurnRateExceedsMax.selector, tooHigh));
        burner.setBurnRate(tooHigh);
    }

    function test_setBurnRate_revert_notGovernor() public {
        vm.prank(alice);
        vm.expectRevert(ITAGITBurner.Unauthorized.selector);
        burner.setBurnRate(5000);
    }

    function test_setBurnRate_affectsRouteFee() public {
        uint256 amount = 1000 ether;
        uint256 newRate = 5000; // 50%

        // Update burn rate
        vm.prank(governor);
        burner.setBurnRate(newRate);

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve and route
        vm.prank(alice);
        token.approve(address(burner), amount);
        vm.prank(alice);
        burner.routeFee(amount);

        uint256 expectedBurn = (amount * newRate) / BASIS_POINTS;
        uint256 expectedTreasury = amount - expectedBurn;

        assertEq(burner.totalBurned(), expectedBurn);
        assertEq(burner.totalToTreasury(), expectedTreasury);
    }

    // ============================================
    // SET TREASURY TESTS
    // ============================================

    function test_setTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(governor);
        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(treasury, newTreasury);
        burner.setTreasury(newTreasury);

        assertEq(burner.treasury(), newTreasury);
    }

    function test_setTreasury_revert_zeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(ITAGITBurner.ZeroAddress.selector);
        burner.setTreasury(address(0));
    }

    function test_setTreasury_revert_notGovernor() public {
        vm.prank(alice);
        vm.expectRevert(ITAGITBurner.Unauthorized.selector);
        burner.setTreasury(makeAddr("newTreasury"));
    }

    function test_setTreasury_affectsRouteFee() public {
        address newTreasury = makeAddr("newTreasury");
        uint256 amount = 1000 ether;

        // Update treasury
        vm.prank(governor);
        burner.setTreasury(newTreasury);

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve and route
        vm.prank(alice);
        token.approve(address(burner), amount);
        vm.prank(alice);
        burner.routeFee(amount);

        uint256 expectedTreasury = amount - ((amount * DEFAULT_BURN_RATE) / BASIS_POINTS);

        // New treasury should have received the tokens
        assertEq(token.balanceOf(newTreasury), expectedTreasury);
    }

    // ============================================
    // SET GOVERNOR TESTS
    // ============================================

    function test_setGovernor_success() public {
        address newGovernor = makeAddr("newGovernor");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit GovernorUpdated(governor, newGovernor);
        burner.setGovernor(newGovernor);

        assertEq(burner.governor(), newGovernor);
    }

    function test_setGovernor_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ITAGITBurner.ZeroAddress.selector);
        burner.setGovernor(address(0));
    }

    function test_setGovernor_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        burner.setGovernor(makeAddr("newGovernor"));
    }

    function test_setGovernor_newGovernorCanSetBurnRate() public {
        address newGovernor = makeAddr("newGovernor");

        // Owner sets new governor
        vm.prank(owner);
        burner.setGovernor(newGovernor);

        // New governor can update burn rate
        vm.prank(newGovernor);
        burner.setBurnRate(5000);

        assertEq(burner.burnRate(), 5000);

        // Old governor cannot
        vm.prank(governor);
        vm.expectRevert(ITAGITBurner.Unauthorized.selector);
        burner.setBurnRate(6000);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_burnFloor_returnsConstant() public view {
        assertEq(burner.burnFloor(), BURN_FLOOR);
    }

    function test_version_returnsConstant() public view {
        assertEq(burner.version(), VERSION);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_routeFee_anyAmount(uint256 amount) public {
        // Bound to reasonable amounts (1 wei to 10% of genesis supply)
        amount = bound(amount, 1, GENESIS_SUPPLY / 10);

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve and route
        vm.prank(alice);
        token.approve(address(burner), amount);
        vm.prank(alice);
        burner.routeFee(amount);

        uint256 expectedBurn = (amount * DEFAULT_BURN_RATE) / BASIS_POINTS;
        uint256 expectedTreasury = amount - expectedBurn;

        assertEq(burner.totalBurned(), expectedBurn);
        assertEq(burner.totalToTreasury(), expectedTreasury);
    }

    function testFuzz_setBurnRate_validRange(uint256 rate) public {
        // Bound to valid range
        rate = bound(rate, BURN_FLOOR, BASIS_POINTS);

        vm.prank(governor);
        burner.setBurnRate(rate);

        assertEq(burner.burnRate(), rate);
    }

    function testFuzz_setBurnRate_belowFloor_reverts(uint256 rate) public {
        // Bound to invalid range (0 to BURN_FLOOR - 1)
        rate = bound(rate, 0, BURN_FLOOR - 1);

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITBurner.BurnRateBelowFloor.selector, rate, BURN_FLOOR));
        burner.setBurnRate(rate);
    }

    function testFuzz_burnPlusTreasury_equalsInput(uint256 amount, uint256 rate) public {
        // Bound inputs
        amount = bound(amount, 1, GENESIS_SUPPLY / 10);
        rate = bound(rate, BURN_FLOOR, BASIS_POINTS);

        // Set burn rate
        vm.prank(governor);
        burner.setBurnRate(rate);

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve and route
        vm.prank(alice);
        token.approve(address(burner), amount);
        vm.prank(alice);
        burner.routeFee(amount);

        // Verify: burned + treasury = input amount
        assertEq(burner.totalBurned() + burner.totalToTreasury(), amount);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_routeFee() public {
        uint256 amount = 1000 ether;

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Approve
        vm.prank(alice);
        token.approve(address(burner), amount);

        // Measure gas
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        burner.routeFee(amount);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 170,000 (includes SafeERC20 transferFrom + burn + safeTransfer)
        assertLt(gasUsed, 170000, "routeFee() exceeds gas target");
    }

    // ============================================
    // UPGRADE TESTS
    // ============================================

    function test_upgrade_preservesState() public {
        uint256 amount = 1000 ether;

        // Route some fees first
        vm.prank(treasury);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.approve(address(burner), amount);
        vm.prank(alice);
        burner.routeFee(amount);

        // Update burn rate
        vm.prank(governor);
        burner.setBurnRate(5000);

        uint256 totalBurnedBefore = burner.totalBurned();
        uint256 totalToTreasuryBefore = burner.totalToTreasury();
        uint256 burnRateBefore = burner.burnRate();

        // Upgrade
        TAGITBurner newImpl = new TAGITBurner();
        vm.prank(owner);
        burner.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(burner.totalBurned(), totalBurnedBefore);
        assertEq(burner.totalToTreasury(), totalToTreasuryBefore);
        assertEq(burner.burnRate(), burnRateBefore);
        assertEq(burner.treasury(), treasury);
        assertEq(burner.governor(), governor);
    }

    function test_upgrade_revert_notOwner() public {
        TAGITBurner newImpl = new TAGITBurner();

        vm.prank(alice);
        vm.expectRevert();
        burner.upgradeToAndCall(address(newImpl), "");
    }

    // ============================================
    // INVARIANT HELPERS
    // ============================================

    function test_invariant_burnRate_neverBelowFloor() public {
        // Try multiple rate changes
        uint256[] memory rates = new uint256[](5);
        rates[0] = BURN_FLOOR;
        rates[1] = 1000;
        rates[2] = 5000;
        rates[3] = 8000;
        rates[4] = BASIS_POINTS;

        for (uint256 i = 0; i < rates.length; i++) {
            vm.prank(governor);
            burner.setBurnRate(rates[i]);
            assertGe(burner.burnRate(), BURN_FLOOR, "Burn rate below floor");
        }
    }
}
