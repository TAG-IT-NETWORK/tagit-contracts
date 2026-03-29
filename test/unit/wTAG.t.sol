// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {wTAG} from "../../src/token/wTAG.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {IwTAG} from "../../src/interfaces/IwTAG.sol";

/**
 * @title wTAGTest
 * @notice Unit tests for wTAG: MINTER_ROLE grant, mint via minter, burn, revert on unauthorized
 */
contract wTAGTest is Test {
    wTAG public wtag;
    TAGITToken public tagitToken;

    address public owner;
    address public treasury;
    address public coreContract; // simulates TAGITCore
    address public voucherContract; // simulates Voucher
    address public alice;
    address public bob;
    address public unauthorized;

    uint256 public constant WRAP_AMOUNT = 1000e18;

    // Events
    event Wrapped(address indexed account, uint256 amount);
    event Unwrapped(address indexed account, uint256 amount);
    event MinterMinted(address indexed to, uint256 amount, address indexed minter);
    event MinterGranted(address indexed minter, address indexed grantedBy);
    event MinterRevoked(address indexed minter, address indexed revokedBy);
    event GovernanceCapUpdated(uint256 oldCap, uint256 newCap);

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        coreContract = makeAddr("coreContract");
        voucherContract = makeAddr("voucherContract");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        unauthorized = makeAddr("unauthorized");

        vm.startPrank(owner);

        // Deploy TAGIT token (upgradeable)
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenInitData = abi.encodeCall(TAGITToken.initialize, (treasury, owner));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        tagitToken = TAGITToken(address(tokenProxy));

        // Deploy wTAG (upgradeable)
        wTAG wtagImpl = new wTAG();
        bytes memory wtagInitData = abi.encodeCall(wTAG.initialize, (address(tagitToken), owner));
        ERC1967Proxy wtagProxy = new ERC1967Proxy(address(wtagImpl), wtagInitData);
        wtag = wTAG(address(wtagProxy));

        // Grant MINTER_ROLE to coreContract and voucherContract
        wtag.grantMinter(coreContract);
        wtag.grantMinter(voucherContract);

        vm.stopPrank();

        // Give alice some TAGIT tokens for wrapping
        vm.prank(treasury);
        tagitToken.transfer(alice, WRAP_AMOUNT * 10);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialization() public view {
        assertEq(wtag.name(), "Wrapped TAG");
        assertEq(wtag.symbol(), "wTAG");
        assertEq(wtag.underlyingToken(), address(tagitToken));
        assertEq(wtag.owner(), owner);
        assertEq(wtag.version(), "1.0.0");
    }

    function test_initialize_reverts_zeroToken() public {
        wTAG impl = new wTAG();
        vm.expectRevert(IwTAG.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(wTAG.initialize, (address(0), owner)));
    }

    function test_initialize_reverts_zeroOwner() public {
        wTAG impl = new wTAG();
        vm.expectRevert(IwTAG.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(wTAG.initialize, (address(tagitToken), address(0))));
    }

    // ============================================
    // MINTER_ROLE TESTS
    // ============================================

    function test_grantMinter_success() public {
        address newMinter = makeAddr("newMinter");
        assertFalse(wtag.isMinter(newMinter));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit MinterGranted(newMinter, owner);
        wtag.grantMinter(newMinter);

        assertTrue(wtag.isMinter(newMinter));
    }

    function test_grantMinter_reverts_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        wtag.grantMinter(makeAddr("minter"));
    }

    function test_grantMinter_reverts_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IwTAG.ZeroAddress.selector);
        wtag.grantMinter(address(0));
    }

    function test_revokeMinter_success() public {
        assertTrue(wtag.isMinter(coreContract));

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit MinterRevoked(coreContract, owner);
        wtag.revokeMinter(coreContract);

        assertFalse(wtag.isMinter(coreContract));
    }

    function test_revokeMinter_reverts_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        wtag.revokeMinter(coreContract);
    }

    // ============================================
    // MINT VIA MINTER (TAGITCore) TESTS
    // ============================================

    function test_mint_viaCoreContract_success() public {
        uint256 mintAmount = 500e18;

        vm.prank(coreContract);
        vm.expectEmit(true, true, false, true);
        emit MinterMinted(alice, mintAmount, coreContract);
        wtag.mint(alice, mintAmount);

        assertEq(wtag.balanceOf(alice), mintAmount);
    }

    function test_mint_viaVoucherContract_success() public {
        uint256 mintAmount = 300e18;

        vm.prank(voucherContract);
        wtag.mint(bob, mintAmount);

        assertEq(wtag.balanceOf(bob), mintAmount);
    }

    function test_mint_reverts_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IwTAG.OnlyMinter.selector, unauthorized));
        wtag.mint(alice, 100e18);
    }

    function test_mint_reverts_zeroAddress() public {
        vm.prank(coreContract);
        vm.expectRevert(IwTAG.ZeroAddress.selector);
        wtag.mint(address(0), 100e18);
    }

    function test_mint_reverts_zeroAmount() public {
        vm.prank(coreContract);
        vm.expectRevert(IwTAG.ZeroAmount.selector);
        wtag.mint(alice, 0);
    }

    // ============================================
    // WRAP / UNWRAP TESTS
    // ============================================

    function test_wrap_success() public {
        vm.startPrank(alice);
        tagitToken.approve(address(wtag), WRAP_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit Wrapped(alice, WRAP_AMOUNT);
        wtag.wrap(WRAP_AMOUNT);

        assertEq(wtag.balanceOf(alice), WRAP_AMOUNT);
        assertEq(tagitToken.balanceOf(address(wtag)), WRAP_AMOUNT);
        vm.stopPrank();
    }

    function test_wrap_reverts_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IwTAG.ZeroAmount.selector);
        wtag.wrap(0);
    }

    function test_unwrap_success() public {
        // First wrap
        vm.startPrank(alice);
        tagitToken.approve(address(wtag), WRAP_AMOUNT);
        wtag.wrap(WRAP_AMOUNT);

        uint256 balanceBefore = tagitToken.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit Unwrapped(alice, WRAP_AMOUNT);
        wtag.unwrap(WRAP_AMOUNT);

        assertEq(wtag.balanceOf(alice), 0);
        assertEq(tagitToken.balanceOf(alice), balanceBefore + WRAP_AMOUNT);
        vm.stopPrank();
    }

    function test_unwrap_reverts_insufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IwTAG.InsufficientBalance.selector, alice, WRAP_AMOUNT, 0));
        wtag.unwrap(WRAP_AMOUNT);
    }

    function test_unwrap_reverts_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IwTAG.ZeroAmount.selector);
        wtag.unwrap(0);
    }

    // ============================================
    // BURN TESTS
    // ============================================

    function test_burn_success() public {
        // Mint via minter first
        vm.prank(coreContract);
        wtag.mint(alice, 500e18);

        vm.prank(alice);
        wtag.burn(200e18);

        assertEq(wtag.balanceOf(alice), 300e18);
    }

    // ============================================
    // VOTES / DELEGATION TESTS
    // ============================================

    function test_delegate_and_getVotes() public {
        // Mint wTAG to alice
        vm.prank(coreContract);
        wtag.mint(alice, 1000e18);

        // Alice delegates to herself
        vm.prank(alice);
        wtag.delegate(alice);

        assertEq(wtag.getVotes(alice), 1000e18);
    }

    function test_delegate_to_another() public {
        vm.prank(coreContract);
        wtag.mint(alice, 1000e18);

        vm.prank(alice);
        wtag.delegate(bob);

        assertEq(wtag.getVotes(bob), 1000e18);
        assertEq(wtag.getVotes(alice), 0);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_mint_viaMinter(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to.code.length == 0);
        vm.assume(amount > 0 && amount < type(uint208).max);

        vm.prank(coreContract);
        wtag.mint(to, amount);

        assertEq(wtag.balanceOf(to), amount);
    }

    function testFuzz_wrap_unwrap_roundtrip(uint256 amount) public {
        amount = bound(amount, 1, WRAP_AMOUNT * 10);

        vm.startPrank(alice);
        tagitToken.approve(address(wtag), amount);
        wtag.wrap(amount);
        assertEq(wtag.balanceOf(alice), amount);

        wtag.unwrap(amount);
        assertEq(wtag.balanceOf(alice), 0);
        vm.stopPrank();
    }

    // ============================================
    // GOVERNANCE CAP TESTS
    // ============================================

    function test_governanceCap_defaultsToZero() public view {
        assertEq(wtag.governanceCap(), 0);
    }

    function test_setGovernanceCap_success() public {
        uint256 newCap = 1_000_000e18;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit GovernanceCapUpdated(0, newCap);
        wtag.setGovernanceCap(newCap);

        assertEq(wtag.governanceCap(), newCap);
    }

    function test_setGovernanceCap_updateEmitsOldAndNew() public {
        uint256 firstCap = 500_000e18;
        uint256 secondCap = 1_000_000e18;

        vm.startPrank(owner);
        wtag.setGovernanceCap(firstCap);

        vm.expectEmit(false, false, false, true);
        emit GovernanceCapUpdated(firstCap, secondCap);
        wtag.setGovernanceCap(secondCap);
        vm.stopPrank();

        assertEq(wtag.governanceCap(), secondCap);
    }

    function test_setGovernanceCap_reverts_notOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        wtag.setGovernanceCap(1_000_000e18);
    }

    function test_wrap_succeedsBelowCap() public {
        uint256 cap = 5000e18;
        vm.prank(owner);
        wtag.setGovernanceCap(cap);

        vm.startPrank(alice);
        tagitToken.approve(address(wtag), WRAP_AMOUNT);
        wtag.wrap(WRAP_AMOUNT); // 1000e18 < 5000e18
        vm.stopPrank();

        assertEq(wtag.balanceOf(alice), WRAP_AMOUNT);
    }

    function test_wrap_revertsAboveCap() public {
        uint256 cap = 500e18;
        vm.prank(owner);
        wtag.setGovernanceCap(cap);

        vm.startPrank(alice);
        tagitToken.approve(address(wtag), WRAP_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IwTAG.GovernanceCapExceeded.selector, WRAP_AMOUNT, cap));
        wtag.wrap(WRAP_AMOUNT); // 1000e18 > 500e18
        vm.stopPrank();
    }

    function test_wrap_revertsAtExactCapPlusOne() public {
        uint256 cap = WRAP_AMOUNT;
        vm.prank(owner);
        wtag.setGovernanceCap(cap);

        vm.startPrank(alice);
        tagitToken.approve(address(wtag), WRAP_AMOUNT + 1);

        // First wrap at exact cap succeeds
        wtag.wrap(WRAP_AMOUNT);

        // One more wei reverts
        vm.expectRevert(abi.encodeWithSelector(IwTAG.GovernanceCapExceeded.selector, 1, 0));
        wtag.wrap(1);
        vm.stopPrank();
    }

    function test_mint_revertsAboveCap() public {
        uint256 cap = 500e18;
        vm.prank(owner);
        wtag.setGovernanceCap(cap);

        vm.prank(coreContract);
        vm.expectRevert(abi.encodeWithSelector(IwTAG.GovernanceCapExceeded.selector, WRAP_AMOUNT, cap));
        wtag.mint(alice, WRAP_AMOUNT);
    }

    function test_mint_succeedsBelowCap() public {
        uint256 cap = 5000e18;
        vm.prank(owner);
        wtag.setGovernanceCap(cap);

        vm.prank(coreContract);
        wtag.mint(alice, WRAP_AMOUNT);

        assertEq(wtag.balanceOf(alice), WRAP_AMOUNT);
    }

    function test_wrap_succeedsWhenCapIsZero_uncapped() public {
        // Cap = 0 means no limit
        assertEq(wtag.governanceCap(), 0);

        vm.startPrank(alice);
        tagitToken.approve(address(wtag), WRAP_AMOUNT);
        wtag.wrap(WRAP_AMOUNT);
        vm.stopPrank();

        assertEq(wtag.balanceOf(alice), WRAP_AMOUNT);
    }

    function test_setGovernanceCap_canDisableBySettingZero() public {
        vm.startPrank(owner);
        wtag.setGovernanceCap(500e18);
        wtag.setGovernanceCap(0); // disable cap
        vm.stopPrank();

        // Now wrapping any amount should succeed
        vm.startPrank(alice);
        tagitToken.approve(address(wtag), WRAP_AMOUNT);
        wtag.wrap(WRAP_AMOUNT);
        vm.stopPrank();

        assertEq(wtag.balanceOf(alice), WRAP_AMOUNT);
    }

    function testFuzz_governanceCap_enforcement(uint256 cap, uint256 amount) public {
        cap = bound(cap, 1, type(uint208).max);
        amount = bound(amount, 1, type(uint208).max);

        vm.prank(owner);
        wtag.setGovernanceCap(cap);

        if (amount <= cap) {
            vm.prank(coreContract);
            wtag.mint(alice, amount);
            assertEq(wtag.balanceOf(alice), amount);
        } else {
            vm.prank(coreContract);
            vm.expectRevert(abi.encodeWithSelector(IwTAG.GovernanceCapExceeded.selector, amount, cap));
            wtag.mint(alice, amount);
        }
    }
}
