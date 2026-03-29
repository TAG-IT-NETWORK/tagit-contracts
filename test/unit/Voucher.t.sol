// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Voucher} from "../../src/token/Voucher.sol";
import {wTAG} from "../../src/token/wTAG.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {IVoucher} from "../../src/interfaces/IVoucher.sol";

/**
 * @title VoucherTest
 * @notice Unit tests for Voucher: issuance trigger, redeem flow, event emission, access control
 */
contract VoucherTest is Test {
    Voucher public voucher;
    wTAG public wtag;
    TAGITToken public tagitToken;

    address public owner;
    address public treasury;
    address public coreContract; // simulates TAGITCore
    address public alice;
    address public bob;
    address public unauthorized;

    uint256 public constant INITIAL_REDEMPTION_RATE = 10000; // 1:1
    uint256 public constant ISSUE_AMOUNT = 500e18;

    // Events
    event VoucherIssued(address indexed to, uint256 amount, uint256 indexed tokenId, string reason);
    event VoucherRedeemed(address indexed account, uint256 voucherAmount, uint256 wtagAmount);
    event VoucherBurned(address indexed from, uint256 amount);
    event RedemptionRateUpdated(uint256 oldRate, uint256 newRate);
    event RedemptionPauseToggled(bool paused);
    event CoreUpdated(address indexed previousCore, address indexed newCore);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        coreContract = makeAddr("coreContract");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        unauthorized = makeAddr("unauthorized");

        vm.startPrank(owner);

        // Deploy TAGIT token
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenInitData = abi.encodeCall(TAGITToken.initialize, (treasury, owner));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        tagitToken = TAGITToken(address(tokenProxy));

        // Deploy wTAG
        wTAG wtagImpl = new wTAG();
        bytes memory wtagInitData = abi.encodeCall(wTAG.initialize, (address(tagitToken), owner));
        ERC1967Proxy wtagProxy = new ERC1967Proxy(address(wtagImpl), wtagInitData);
        wtag = wTAG(address(wtagProxy));

        // Deploy Voucher
        Voucher voucherImpl = new Voucher();
        bytes memory voucherInitData =
            abi.encodeCall(Voucher.initialize, (coreContract, address(wtag), owner, INITIAL_REDEMPTION_RATE));
        ERC1967Proxy voucherProxy = new ERC1967Proxy(address(voucherImpl), voucherInitData);
        voucher = Voucher(address(voucherProxy));

        // Grant Voucher contract MINTER_ROLE on wTAG (for redemption)
        wtag.grantMinter(address(voucher));

        vm.stopPrank();
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialization() public view {
        assertEq(voucher.name(), "TAG IT Voucher");
        assertEq(voucher.symbol(), "vTAG");
        assertEq(voucher.core(), coreContract);
        assertEq(voucher.wtag(), address(wtag));
        assertEq(voucher.redemptionRate(), INITIAL_REDEMPTION_RATE);
        assertFalse(voucher.isRedemptionPaused());
        assertEq(voucher.version(), "1.0.0");
    }

    function test_initialize_reverts_zeroCore() public {
        Voucher impl = new Voucher();
        vm.expectRevert(IVoucher.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(Voucher.initialize, (address(0), address(wtag), owner, INITIAL_REDEMPTION_RATE))
        );
    }

    function test_initialize_reverts_invalidRate() public {
        Voucher impl = new Voucher();
        vm.expectRevert(abi.encodeWithSelector(IVoucher.InvalidRedemptionRate.selector, 0));
        new ERC1967Proxy(address(impl), abi.encodeCall(Voucher.initialize, (coreContract, address(wtag), owner, 0)));
    }

    // ============================================
    // ISSUANCE TESTS (TAGITCore only)
    // ============================================

    function test_issue_success() public {
        vm.prank(coreContract);
        vm.expectEmit(true, true, false, true);
        emit VoucherIssued(alice, ISSUE_AMOUNT, 42, "activation");
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");

        assertEq(voucher.balanceOf(alice), ISSUE_AMOUNT);
    }

    function test_issue_reverts_notCore() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IVoucher.OnlyCore.selector, unauthorized, coreContract));
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");
    }

    function test_issue_reverts_zeroAddress() public {
        vm.prank(coreContract);
        vm.expectRevert(IVoucher.ZeroAddress.selector);
        voucher.issue(address(0), ISSUE_AMOUNT, 42, "activation");
    }

    function test_issue_reverts_zeroAmount() public {
        vm.prank(coreContract);
        vm.expectRevert(IVoucher.ZeroAmount.selector);
        voucher.issue(alice, 0, 42, "activation");
    }

    // ============================================
    // BURN TESTS (TAGITCore only)
    // ============================================

    function test_burnFrom_success() public {
        // Issue first
        vm.prank(coreContract);
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");

        // Burn
        vm.prank(coreContract);
        vm.expectEmit(true, false, false, true);
        emit VoucherBurned(alice, 200e18);
        voucher.burnFrom(alice, 200e18);

        assertEq(voucher.balanceOf(alice), ISSUE_AMOUNT - 200e18);
    }

    function test_burnFrom_reverts_notCore() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IVoucher.OnlyCore.selector, unauthorized, coreContract));
        voucher.burnFrom(alice, 100e18);
    }

    function test_burnFrom_reverts_insufficientBalance() public {
        vm.prank(coreContract);
        vm.expectRevert(abi.encodeWithSelector(IVoucher.InsufficientVouchers.selector, alice, 100e18, 0));
        voucher.burnFrom(alice, 100e18);
    }

    // ============================================
    // REDEEM TESTS
    // ============================================

    function test_redeem_1to1_success() public {
        // Issue vouchers to alice
        vm.prank(coreContract);
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");

        // Redeem
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit VoucherRedeemed(alice, ISSUE_AMOUNT, ISSUE_AMOUNT); // 1:1 at 10000 bps
        uint256 wtagReceived = voucher.redeem(ISSUE_AMOUNT);

        assertEq(wtagReceived, ISSUE_AMOUNT);
        assertEq(wtag.balanceOf(alice), ISSUE_AMOUNT);
        assertEq(voucher.balanceOf(alice), 0);
    }

    function test_redeem_halfRate_success() public {
        // Set redemption rate to 50% (5000 bps)
        vm.prank(owner);
        voucher.setRedemptionRate(5000);

        // Issue vouchers
        vm.prank(coreContract);
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");

        // Redeem - should get half
        vm.prank(alice);
        uint256 wtagReceived = voucher.redeem(ISSUE_AMOUNT);

        assertEq(wtagReceived, ISSUE_AMOUNT / 2);
        assertEq(wtag.balanceOf(alice), ISSUE_AMOUNT / 2);
    }

    function test_redeem_doubleRate_success() public {
        // Set redemption rate to 200% (20000 bps)
        vm.prank(owner);
        voucher.setRedemptionRate(20000);

        // Issue vouchers
        vm.prank(coreContract);
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");

        // Redeem - should get double
        vm.prank(alice);
        uint256 wtagReceived = voucher.redeem(ISSUE_AMOUNT);

        assertEq(wtagReceived, ISSUE_AMOUNT * 2);
    }

    function test_redeem_reverts_paused() public {
        vm.prank(owner);
        voucher.setRedemptionPaused(true);

        vm.prank(coreContract);
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");

        vm.prank(alice);
        vm.expectRevert(IVoucher.RedemptionPaused.selector);
        voucher.redeem(ISSUE_AMOUNT);
    }

    function test_redeem_reverts_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IVoucher.ZeroAmount.selector);
        voucher.redeem(0);
    }

    function test_redeem_reverts_insufficientVouchers() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IVoucher.InsufficientVouchers.selector, alice, ISSUE_AMOUNT, 0));
        voucher.redeem(ISSUE_AMOUNT);
    }

    // ============================================
    // NON-TRANSFERABLE TESTS
    // ============================================

    function test_transfer_reverts() public {
        vm.prank(coreContract);
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");

        vm.prank(alice);
        vm.expectRevert("Voucher: non-transferable");
        voucher.transfer(bob, 100e18);
    }

    function test_transferFrom_reverts() public {
        vm.prank(coreContract);
        voucher.issue(alice, ISSUE_AMOUNT, 42, "activation");

        vm.prank(alice);
        voucher.approve(bob, 100e18);

        vm.prank(bob);
        vm.expectRevert("Voucher: non-transferable");
        voucher.transferFrom(alice, bob, 100e18);
    }

    // ============================================
    // ADMIN TESTS
    // ============================================

    function test_setRedemptionRate_success() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RedemptionRateUpdated(INITIAL_REDEMPTION_RATE, 5000);
        voucher.setRedemptionRate(5000);

        assertEq(voucher.redemptionRate(), 5000);
    }

    function test_setRedemptionRate_reverts_invalidRate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVoucher.InvalidRedemptionRate.selector, 0));
        voucher.setRedemptionRate(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IVoucher.InvalidRedemptionRate.selector, 20001));
        voucher.setRedemptionRate(20001);
    }

    function test_setRedemptionRate_reverts_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        voucher.setRedemptionRate(5000);
    }

    function test_setRedemptionPaused_success() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit RedemptionPauseToggled(true);
        voucher.setRedemptionPaused(true);

        assertTrue(voucher.isRedemptionPaused());
    }

    function test_setCore_success() public {
        address newCore = makeAddr("newCore");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit CoreUpdated(coreContract, newCore);
        voucher.setCore(newCore);

        assertEq(voucher.core(), newCore);
    }

    function test_setCore_reverts_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IVoucher.ZeroAddress.selector);
        voucher.setCore(address(0));
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_issue_and_redeem(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint208).max);

        vm.prank(coreContract);
        voucher.issue(alice, amount, 1, "fuzz");

        vm.prank(alice);
        uint256 wtagReceived = voucher.redeem(amount);

        // At 1:1 rate, should get same amount
        assertEq(wtagReceived, amount);
        assertEq(voucher.balanceOf(alice), 0);
        assertEq(wtag.balanceOf(alice), amount);
    }

    function testFuzz_issue_and_burnFrom(uint256 issueAmount, uint256 burnAmount) public {
        issueAmount = bound(issueAmount, 1, type(uint208).max);
        burnAmount = bound(burnAmount, 1, issueAmount);

        vm.prank(coreContract);
        voucher.issue(alice, issueAmount, 1, "fuzz");

        vm.prank(coreContract);
        voucher.burnFrom(alice, burnAmount);

        assertEq(voucher.balanceOf(alice), issueAmount - burnAmount);
    }
}
