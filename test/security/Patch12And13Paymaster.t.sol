// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {TAGITPaymaster} from "../../src/account/TAGITPaymaster.sol";
import {ITAGITPaymaster} from "../../src/interfaces/ITAGITPaymaster.sol";

// Minimal mock EntryPoint for paymaster tests
contract MockEntryPointP1213 {
    mapping(address => uint256) public balances;

    function depositTo(address account) external payable {
        balances[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function withdrawTo(address payable withdrawAddress, uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        (bool success,) = withdrawAddress.call{value: amount}("");
        require(success, "Transfer failed");
    }

    function getNonce(address, uint192) external pure returns (uint256) {
        return 0;
    }

    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEntryPoint).interfaceId;
    }

    receive() external payable {}
}

/**
 * @title Patch12And13PaymasterTest
 * @notice Tests for PATCH-12 (brand ownership) and PATCH-13 (registration gate)
 */
contract Patch12And13PaymasterTest is Test {
    TAGITPaymaster public paymaster;
    MockEntryPointP1213 public entryPoint;

    address public governor = makeAddr("governor");
    address public brandOwnerAddr = makeAddr("brandOwner");
    address public attacker = makeAddr("attacker");
    address public newOwner = makeAddr("newOwner");

    bytes32 public constant BRAND_ID = keccak256("NIKE");

    function setUp() public {
        entryPoint = new MockEntryPointP1213();

        // Deploy paymaster via proxy
        TAGITPaymaster paymasterImpl = new TAGITPaymaster();
        bytes memory initData = abi.encodeCall(TAGITPaymaster.initialize, (address(entryPoint), governor, governor));
        ERC1967Proxy proxy = new ERC1967Proxy(address(paymasterImpl), initData);
        paymaster = TAGITPaymaster(payable(address(proxy)));

        // Register brand with governor
        vm.prank(governor);
        paymaster.registerBrand(BRAND_ID, brandOwnerAddr);

        // Fund the entrypoint mock so withdrawals work
        vm.deal(address(entryPoint), 100 ether);

        // Brand owner deposits
        vm.deal(brandOwnerAddr, 10 ether);
        vm.prank(brandOwnerAddr);
        paymaster.depositForBrand{value: 5 ether}(BRAND_ID);
    }

    // ============================================
    // PATCH-13: REGISTRATION GATE
    // ============================================

    function test_registerBrand_requires_governor() public {
        bytes32 newBrand = keccak256("ADIDAS");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotGovernor.selector, attacker));
        paymaster.registerBrand(newBrand, attacker);
    }

    function test_depositForBrand_requires_registration() public {
        bytes32 unregistered = keccak256("UNREGISTERED");
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.BrandNotRegistered.selector, unregistered));
        paymaster.depositForBrand{value: 1 ether}(unregistered);
    }

    function test_squatting_blocked() public {
        // Attacker cannot register or create any brand without governor role
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.depositForBrand{value: 1 ether}(keccak256("SQUATTED"));
    }

    function test_double_registration_reverts() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.BrandAlreadyRegistered.selector, BRAND_ID));
        paymaster.registerBrand(BRAND_ID, brandOwnerAddr);
    }

    // ============================================
    // PATCH-12: BRAND OWNERSHIP
    // ============================================

    function test_withdraw_by_owner_succeeds() public {
        uint256 balanceBefore = brandOwnerAddr.balance;
        vm.prank(brandOwnerAddr);
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);
        assertEq(brandOwnerAddr.balance, balanceBefore + 1 ether);
    }

    function test_withdraw_by_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotBrandOwner.selector, BRAND_ID, attacker));
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);
    }

    function test_brand_ownership_two_step_transfer() public {
        // Initiate transfer
        vm.prank(brandOwnerAddr);
        paymaster.transferBrandOwnership(BRAND_ID, newOwner);

        // Before accept — old owner still in control
        assertEq(paymaster.brandOwner(BRAND_ID), brandOwnerAddr);

        // New owner cannot withdraw yet
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotBrandOwner.selector, BRAND_ID, newOwner));
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);

        // Accept ownership
        vm.prank(newOwner);
        paymaster.acceptBrandOwnership(BRAND_ID);
        assertEq(paymaster.brandOwner(BRAND_ID), newOwner);

        // New owner can now withdraw
        vm.prank(newOwner);
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);
    }

    function test_accept_ownership_requires_pending() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NoPendingTransfer.selector, BRAND_ID));
        paymaster.acceptBrandOwnership(BRAND_ID);
    }

    function test_transfer_ownership_requires_owner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotBrandOwner.selector, BRAND_ID, attacker));
        paymaster.transferBrandOwnership(BRAND_ID, attacker);
    }

    function testFuzz_withdraw_random_caller(address caller) public {
        vm.assume(caller != brandOwnerAddr);
        vm.prank(caller);
        vm.expectRevert();
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);
    }
}
