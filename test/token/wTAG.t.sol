// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {wTAG} from "../../src/token/wTAG.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GENESIS_SUPPLY, BASIS_POINTS} from "../../src/libraries/Constants.sol";

/**
 * @title MockTAGIT
 * @dev Minimal ERC-20 mock for the underlying TAGIT token in tests
 */
contract MockTAGIT is ERC20 {
    constructor() ERC20("TAG IT Token", "TAGIT") {
        _mint(msg.sender, GENESIS_SUPPLY);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title wTAGTest
 * @author TAG IT Network <dev@tagit.network>
 * @notice Comprehensive test suite for the wTAG wrapped token contract
 */
contract wTAGTest is Test {
    // ============================================
    // STATE
    // ============================================

    MockTAGIT public tagToken;
    wTAG public wtag;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant WTAG_CAP = (GENESIS_SUPPLY * 333) / BASIS_POINTS;
    uint256 public tgeTime;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        // Deploy mock TAGIT token (genesis supply goes to this test contract)
        tagToken = new MockTAGIT();

        // Deploy wTAG
        wtag = new wTAG(address(tagToken), admin, minter);

        // Set a future TGE timestamp
        tgeTime = block.timestamp + 1 days;
        vm.prank(admin);
        wtag.setTGE(tgeTime);

        // Fund alice with TAGIT tokens for wrap tests
        tagToken.transfer(alice, 1_000_000 ether);
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function test_constructor_setsCorrectCap() public view {
        assertEq(wtag.cap(), WTAG_CAP, "Cap should be 3.33% of genesis supply");
    }

    function test_constructor_setsTokenName() public view {
        assertEq(wtag.name(), "Wrapped TAGIT");
        assertEq(wtag.symbol(), "wTAG");
    }

    function test_constructor_grantsRoles() public view {
        assertTrue(wtag.hasRole(wtag.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(wtag.hasRole(wtag.MINTER_ROLE(), minter));
    }

    function test_constructor_setsTagToken() public view {
        assertEq(address(wtag.tagToken()), address(tagToken));
    }

    function test_constructor_revert_zeroTagToken() public {
        vm.expectRevert(wTAG.ZeroAddress.selector);
        new wTAG(address(0), admin, minter);
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert(wTAG.ZeroAddress.selector);
        new wTAG(address(tagToken), address(0), minter);
    }

    function test_constructor_revert_zeroMinter() public {
        vm.expectRevert(wTAG.ZeroAddress.selector);
        new wTAG(address(tagToken), admin, address(0));
    }

    // ============================================
    // TGE CONFIGURATION TESTS
    // ============================================

    function test_adminCanSetTGE() public {
        // Deploy fresh wTAG (no TGE set yet)
        wTAG freshWtag = new wTAG(address(tagToken), admin, minter);

        uint256 futureTime = block.timestamp + 30 days;
        vm.prank(admin);
        freshWtag.setTGE(futureTime);

        assertEq(freshWtag.tgeTimestamp(), futureTime);
    }

    function test_setTGE_emitsEvent() public {
        wTAG freshWtag = new wTAG(address(tagToken), admin, minter);
        uint256 futureTime = block.timestamp + 30 days;

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit wTAG.TGESet(futureTime, admin);
        freshWtag.setTGE(futureTime);
    }

    function test_setTGE_revert_alreadySet() public {
        // TGE was set in setUp
        vm.prank(admin);
        vm.expectRevert(wTAG.TGEAlreadySet.selector);
        wtag.setTGE(block.timestamp + 60 days);
    }

    function test_setTGE_revert_timestampInPast() public {
        wTAG freshWtag = new wTAG(address(tagToken), admin, minter);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(wTAG.TGETimestampInPast.selector, block.timestamp - 1, block.timestamp));
        freshWtag.setTGE(block.timestamp - 1);
    }

    function test_setTGE_revert_nonAdmin() public {
        wTAG freshWtag = new wTAG(address(tagToken), admin, minter);

        vm.prank(alice);
        vm.expectRevert();
        freshWtag.setTGE(block.timestamp + 30 days);
    }

    // ============================================
    // CAP ENFORCEMENT TESTS
    // ============================================

    function test_capEnforced_mintBeyondCapReverts() public {
        // Warp past lockout so minting works
        vm.warp(tgeTime + 7 days + 1);

        // Mint up to the cap
        vm.prank(minter);
        wtag.mint(alice, WTAG_CAP);

        // Attempting to mint 1 more wei should revert
        vm.prank(minter);
        vm.expectRevert();
        wtag.mint(alice, 1);
    }

    function test_capEnforced_mintExactCap() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(minter);
        wtag.mint(alice, WTAG_CAP);

        assertEq(wtag.totalSupply(), WTAG_CAP);
    }

    // ============================================
    // MINTER ROLE GATING TESTS
    // ============================================

    function test_minterRoleGating_authorizedMintSucceeds() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(minter);
        wtag.mint(alice, 1000 ether);

        assertEq(wtag.balanceOf(alice), 1000 ether);
    }

    function test_minterRoleGating_unauthorizedMintReverts() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(alice);
        vm.expectRevert();
        wtag.mint(alice, 1000 ether);
    }

    function test_mint_revert_zeroAddress() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(minter);
        vm.expectRevert(wTAG.ZeroAddress.selector);
        wtag.mint(address(0), 1000 ether);
    }

    function test_mint_revert_zeroAmount() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(minter);
        vm.expectRevert(wTAG.ZeroAmount.selector);
        wtag.mint(alice, 0);
    }

    function test_mint_emitsEvent() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit wTAG.Minted(alice, 1000 ether);
        wtag.mint(alice, 1000 ether);
    }

    // ============================================
    // WRAP / UNWRAP 1:1 TESTS
    // ============================================

    function test_wrapUnwrap1to1_checkExactBalances() public {
        uint256 wrapAmount = 500 ether;

        // Warp past lockout
        vm.warp(tgeTime + 7 days + 1);

        // Alice approves wTAG contract to spend her TAGIT
        vm.prank(alice);
        tagToken.approve(address(wtag), wrapAmount);

        uint256 aliceTagBefore = tagToken.balanceOf(alice);

        // Alice wraps
        vm.prank(alice);
        wtag.wrap(wrapAmount);

        // Check balances after wrap
        assertEq(wtag.balanceOf(alice), wrapAmount, "Alice should have wTAG equal to wrap amount");
        assertEq(tagToken.balanceOf(alice), aliceTagBefore - wrapAmount, "Alice TAGIT should decrease");
        assertEq(tagToken.balanceOf(address(wtag)), wrapAmount, "wTAG contract should hold TAGIT");

        // Alice unwraps
        vm.prank(alice);
        wtag.unwrap(wrapAmount);

        // Check balances after unwrap
        assertEq(wtag.balanceOf(alice), 0, "Alice wTAG should be zero after unwrap");
        assertEq(tagToken.balanceOf(alice), aliceTagBefore, "Alice TAGIT should be restored");
        assertEq(tagToken.balanceOf(address(wtag)), 0, "wTAG contract TAGIT should be zero");
    }

    function test_wrap_emitsEvent() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(alice);
        tagToken.approve(address(wtag), 100 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit wTAG.Wrapped(alice, 100 ether);
        wtag.wrap(100 ether);
    }

    function test_unwrap_emitsEvent() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(alice);
        tagToken.approve(address(wtag), 100 ether);
        vm.prank(alice);
        wtag.wrap(100 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit wTAG.Unwrapped(alice, 100 ether);
        wtag.unwrap(100 ether);
    }

    function test_wrap_revert_zeroAmount() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(alice);
        vm.expectRevert(wTAG.ZeroAmount.selector);
        wtag.wrap(0);
    }

    function test_unwrap_revert_zeroAmount() public {
        vm.warp(tgeTime + 7 days + 1);

        vm.prank(alice);
        vm.expectRevert(wTAG.ZeroAmount.selector);
        wtag.unwrap(0);
    }

    function test_wrap_revert_tgeNotSet() public {
        // Deploy fresh wTAG without setting TGE
        wTAG freshWtag = new wTAG(address(tagToken), admin, minter);

        vm.prank(alice);
        vm.expectRevert(wTAG.TGENotSet.selector);
        freshWtag.wrap(100 ether);
    }

    function test_unwrap_revert_tgeNotSet() public {
        wTAG freshWtag = new wTAG(address(tagToken), admin, minter);

        vm.prank(alice);
        vm.expectRevert(wTAG.TGENotSet.selector);
        freshWtag.unwrap(100 ether);
    }

    // ============================================
    // LOCKOUT PERIOD TESTS
    // ============================================

    function test_lockoutBlocksTransfer() public {
        // Mint some wTAG to alice (minting is allowed during lockout)
        vm.prank(minter);
        wtag.mint(alice, 1000 ether);

        // Warp to just before lockout ends
        vm.warp(tgeTime + 7 days - 1);

        // Transfer should revert during lockout
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(wTAG.TransfersDuringLockout.selector, block.timestamp, tgeTime + 7 days));
        wtag.transfer(bob, 100 ether);
    }

    function test_lockoutBlocksTransferFrom() public {
        vm.prank(minter);
        wtag.mint(alice, 1000 ether);

        // Warp to during lockout
        vm.warp(tgeTime + 3 days);

        // Approve bob
        vm.prank(alice);
        wtag.approve(bob, 100 ether);

        // TransferFrom should also revert during lockout
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(wTAG.TransfersDuringLockout.selector, block.timestamp, tgeTime + 7 days));
        wtag.transferFrom(alice, bob, 100 ether);
    }

    function test_postLockoutTransferSucceeds() public {
        // Mint wTAG to alice
        vm.prank(minter);
        wtag.mint(alice, 1000 ether);

        // Warp past lockout period (TGE + 7 days + 1 second)
        vm.warp(tgeTime + 7 days + 1);

        // Transfer should succeed
        vm.prank(alice);
        wtag.transfer(bob, 100 ether);

        assertEq(wtag.balanceOf(bob), 100 ether);
        assertEq(wtag.balanceOf(alice), 900 ether);
    }

    function test_lockoutExactBoundary() public {
        vm.prank(minter);
        wtag.mint(alice, 1000 ether);

        // At exactly TGE + 7 days, should still be locked (< is strict)
        vm.warp(tgeTime + 7 days);

        // At exactly the boundary, block.timestamp < tgeTimestamp + LOCKOUT_PERIOD is false
        // so transfer should succeed
        vm.prank(alice);
        wtag.transfer(bob, 100 ether);

        assertEq(wtag.balanceOf(bob), 100 ether);
    }

    function test_mintAllowedDuringLockout() public {
        // Ensure we are within the lockout period
        vm.warp(tgeTime + 1);
        assertTrue(wtag.isLocked());

        // Minting should still work during lockout (mint is from=address(0))
        vm.prank(minter);
        wtag.mint(alice, 500 ether);

        assertEq(wtag.balanceOf(alice), 500 ether);
    }

    function test_burnAllowedDuringLockout() public {
        // Mint some tokens first
        vm.prank(minter);
        wtag.mint(alice, 500 ether);

        // Ensure lockout is active
        vm.warp(tgeTime + 1);
        assertTrue(wtag.isLocked());

        // Burning should still work during lockout (burn is to=address(0))
        vm.prank(alice);
        wtag.burn(200 ether);

        assertEq(wtag.balanceOf(alice), 300 ether);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_isLocked_trueBeforeLockoutEnd() public {
        vm.warp(tgeTime + 3 days);
        assertTrue(wtag.isLocked());
    }

    function test_isLocked_falseAfterLockoutEnd() public {
        vm.warp(tgeTime + 7 days);
        assertFalse(wtag.isLocked());
    }

    function test_isLocked_trueWhenTGENotSet() public {
        wTAG freshWtag = new wTAG(address(tagToken), admin, minter);
        assertTrue(freshWtag.isLocked());
    }

    function test_lockoutEnd_returnsCorrectValue() public view {
        assertEq(wtag.lockoutEnd(), tgeTime + 7 days);
    }

    function test_lockoutEnd_zeroWhenTGENotSet() public {
        wTAG freshWtag = new wTAG(address(tagToken), admin, minter);
        assertEq(freshWtag.lockoutEnd(), 0);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_wrapUnwrap(uint256 amount) public {
        // Bound amount to reasonable range (1 wei to cap)
        amount = bound(amount, 1, WTAG_CAP);

        // Fund alice with enough TAGIT
        tagToken.mint(alice, amount);

        // Warp past lockout
        vm.warp(tgeTime + 7 days + 1);

        vm.startPrank(alice);
        tagToken.approve(address(wtag), amount);
        wtag.wrap(amount);

        assertEq(wtag.balanceOf(alice), amount);

        wtag.unwrap(amount);
        assertEq(wtag.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function testFuzz_mintCapped(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.warp(tgeTime + 7 days + 1);

        if (amount > WTAG_CAP) {
            vm.prank(minter);
            vm.expectRevert();
            wtag.mint(alice, amount);
        } else {
            vm.prank(minter);
            wtag.mint(alice, amount);
            assertEq(wtag.balanceOf(alice), amount);
        }
    }
}
