// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {GENESIS_SUPPLY, TOKEN_NAME, TOKEN_SYMBOL, VERSION} from "../../src/libraries/Constants.sol";

/**
 * @title TAGITToken Unit Tests
 * @notice Comprehensive tests for the TAGIT governance token
 */
contract TAGITTokenTest is Test {
    TAGITToken public token;
    TAGITToken public tokenImpl;

    address public owner;
    address public treasury;
    address public emissions;
    address public alice;
    address public bob;

    // Events to test
    event EmissionsAddressSet(address indexed emissions, address indexed setter);
    event TokensMinted(address indexed to, uint256 amount, uint256 totalSupply);
    event TokensBurned(address indexed from, uint256 amount, uint256 totalSupply);
    event ContractUpgraded(address indexed newImplementation, string version);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        emissions = makeAddr("emissions");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy implementation
        tokenImpl = new TAGITToken();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            TAGITToken.initialize.selector,
            treasury,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(tokenImpl), initData);
        token = TAGITToken(address(proxy));
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsNameAndSymbol() public view {
        assertEq(token.name(), TOKEN_NAME);
        assertEq(token.symbol(), TOKEN_SYMBOL);
    }

    function test_initialize_mintsGenesisSupplyToTreasury() public view {
        assertEq(token.balanceOf(treasury), GENESIS_SUPPLY);
        assertEq(token.totalSupply(), GENESIS_SUPPLY);
    }

    function test_initialize_setsOwner() public view {
        assertEq(token.owner(), owner);
    }

    function test_initialize_revert_zeroTreasury() public {
        TAGITToken newImpl = new TAGITToken();
        bytes memory initData = abi.encodeWithSelector(
            TAGITToken.initialize.selector,
            address(0),
            owner
        );

        vm.expectRevert(TAGITToken.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_revert_zeroOwner() public {
        TAGITToken newImpl = new TAGITToken();
        bytes memory initData = abi.encodeWithSelector(
            TAGITToken.initialize.selector,
            treasury,
            address(0)
        );

        vm.expectRevert(TAGITToken.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_revert_cannotReinitialize() public {
        vm.expectRevert();
        token.initialize(treasury, owner);
    }

    // ============================================
    // EMISSIONS CONFIGURATION TESTS
    // ============================================

    function test_setEmissionsAddress_success() public {
        assertFalse(token.isEmissionsConfigured());

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit EmissionsAddressSet(emissions, owner);
        token.setEmissionsAddress(emissions);

        assertEq(token.emissionsAddress(), emissions);
        assertTrue(token.isEmissionsConfigured());
    }

    function test_setEmissionsAddress_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setEmissionsAddress(emissions);
    }

    function test_setEmissionsAddress_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TAGITToken.ZeroAddress.selector);
        token.setEmissionsAddress(address(0));
    }

    function test_setEmissionsAddress_revert_alreadySet() public {
        vm.startPrank(owner);
        token.setEmissionsAddress(emissions);

        vm.expectRevert(TAGITToken.EmissionsAlreadySet.selector);
        token.setEmissionsAddress(alice);
        vm.stopPrank();
    }

    // ============================================
    // MINT TESTS
    // ============================================

    function test_mint_success() public {
        vm.prank(owner);
        token.setEmissionsAddress(emissions);

        uint256 amount = 1000 ether;
        uint256 expectedSupply = GENESIS_SUPPLY + amount;

        vm.prank(emissions);
        vm.expectEmit(true, false, false, true);
        emit TokensMinted(alice, amount, expectedSupply);
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), expectedSupply);
    }

    function test_mint_revert_notEmissions() public {
        vm.prank(owner);
        token.setEmissionsAddress(emissions);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITToken.OnlyEmissionsCanMint.selector,
            alice,
            emissions
        ));
        token.mint(bob, 1000 ether);
    }

    function test_mint_revert_emissionsNotSet() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITToken.OnlyEmissionsCanMint.selector,
            alice,
            address(0)
        ));
        token.mint(bob, 1000 ether);
    }

    function test_mint_revert_zeroAddress() public {
        vm.prank(owner);
        token.setEmissionsAddress(emissions);

        vm.prank(emissions);
        vm.expectRevert(TAGITToken.ZeroAddress.selector);
        token.mint(address(0), 1000 ether);
    }

    function test_mint_revert_zeroAmount() public {
        vm.prank(owner);
        token.setEmissionsAddress(emissions);

        vm.prank(emissions);
        vm.expectRevert(TAGITToken.ZeroAmount.selector);
        token.mint(alice, 0);
    }

    function testFuzz_mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to != treasury); // Exclude treasury to avoid balance collision
        // ERC20Votes has a max safe supply of ~2^208 for checkpoints
        // Bound amount to avoid overflow
        amount = bound(amount, 1, 1e50);

        vm.prank(owner);
        token.setEmissionsAddress(emissions);

        vm.prank(emissions);
        token.mint(to, amount);

        assertEq(token.balanceOf(to), amount);
    }

    // ============================================
    // BURN TESTS
    // ============================================

    function test_burn_success() public {
        uint256 burnAmount = 100 ether;

        // Transfer some tokens to alice first
        vm.prank(treasury);
        token.transfer(alice, burnAmount);

        uint256 expectedSupply = GENESIS_SUPPLY - burnAmount;

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit TokensBurned(alice, burnAmount, expectedSupply);
        token.burn(burnAmount);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), expectedSupply);
    }

    function test_burn_revert_insufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burn(100 ether);
    }

    function test_burnFrom_success() public {
        uint256 burnAmount = 100 ether;

        // Transfer tokens to alice and approve bob
        vm.prank(treasury);
        token.transfer(alice, burnAmount);

        vm.prank(alice);
        token.approve(bob, burnAmount);

        uint256 expectedSupply = GENESIS_SUPPLY - burnAmount;

        vm.prank(bob);
        vm.expectEmit(true, false, false, true);
        emit TokensBurned(alice, burnAmount, expectedSupply);
        token.burnFrom(alice, burnAmount);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), expectedSupply);
    }

    function test_burnFrom_revert_insufficientAllowance() public {
        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, 100 ether);

        // Bob has no allowance
        vm.prank(bob);
        vm.expectRevert();
        token.burnFrom(alice, 100 ether);
    }

    function testFuzz_burn(uint256 amount) public {
        vm.assume(amount > 0 && amount <= GENESIS_SUPPLY);

        vm.prank(treasury);
        token.burn(amount);

        assertEq(token.totalSupply(), GENESIS_SUPPLY - amount);
    }

    // ============================================
    // ERC20 TRANSFER TESTS
    // ============================================

    function test_transfer_success() public {
        uint256 amount = 1000 ether;

        vm.prank(treasury);
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(treasury), GENESIS_SUPPLY - amount);
    }

    function test_transferFrom_success() public {
        uint256 amount = 1000 ether;

        vm.prank(treasury);
        token.approve(alice, amount);

        vm.prank(alice);
        token.transferFrom(treasury, bob, amount);

        assertEq(token.balanceOf(bob), amount);
    }

    // ============================================
    // ERC20VOTES TESTS
    // ============================================

    function test_delegate_success() public {
        uint256 amount = 1000 ether;

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Alice delegates to herself
        vm.prank(alice);
        token.delegate(alice);

        assertEq(token.getVotes(alice), amount);
    }

    function test_delegate_toOther() public {
        uint256 amount = 1000 ether;

        // Transfer tokens to alice
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Alice delegates to bob
        vm.prank(alice);
        token.delegate(bob);

        assertEq(token.getVotes(alice), 0);
        assertEq(token.getVotes(bob), amount);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_version() public view {
        assertEq(token.version(), VERSION);
    }

    function test_decimals() public view {
        assertEq(token.decimals(), 18);
    }

    // ============================================
    // UUPS UPGRADE TESTS
    // ============================================

    function test_upgrade_success() public {
        // Deploy new implementation
        TAGITToken newImpl = new TAGITToken();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ContractUpgraded(address(newImpl), VERSION);
        token.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_revert_notOwner() public {
        TAGITToken newImpl = new TAGITToken();

        vm.prank(alice);
        vm.expectRevert();
        token.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_preservesState() public {
        // Set emissions before upgrade
        vm.prank(owner);
        token.setEmissionsAddress(emissions);

        // Transfer tokens
        vm.prank(treasury);
        token.transfer(alice, 1000 ether);

        // Upgrade
        TAGITToken newImpl = new TAGITToken();
        vm.prank(owner);
        token.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(token.emissionsAddress(), emissions);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.totalSupply(), GENESIS_SUPPLY);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_mint() public {
        vm.prank(owner);
        token.setEmissionsAddress(emissions);

        vm.prank(emissions);
        uint256 gasBefore = gasleft();
        token.mint(alice, 1000 ether);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 150,000
        assertLt(gasUsed, 150000, "mint() exceeds gas target");
    }

    function test_gas_transfer() public {
        vm.prank(treasury);
        uint256 gasBefore = gasleft();
        token.transfer(alice, 1000 ether);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 100,000
        assertLt(gasUsed, 100000, "transfer() exceeds gas target");
    }

    function test_gas_burn() public {
        vm.prank(treasury);
        token.transfer(alice, 1000 ether);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        token.burn(1000 ether);
        uint256 gasUsed = gasBefore - gasleft();

        // Gas target: < 60,000
        assertLt(gasUsed, 60000, "burn() exceeds gas target");
    }
}
