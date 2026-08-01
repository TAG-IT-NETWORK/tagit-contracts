// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.t.sol";
import {console2} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title TokenForkTest
 * @notice Fork tests for token interactions on Base Sepolia
 * @dev Verifies real token contracts work as expected
 */
contract TokenForkTest is ForkBase {
    // ============================================
    // INTERFACES
    // ============================================

    IERC20 public weth;
    IERC20 public usdc;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public override {
        super.setUp();

        weth = IERC20(WETH);
        usdc = IERC20(USDC);
    }

    // ============================================
    // TOKEN CONTRACT VERIFICATION
    // ============================================

    /**
     * @notice Verify WETH is deployed on Base Sepolia
     */
    function test_wethIsLive() public view {
        assertTrue(_hasCode(WETH), "WETH should have code");

        // Verify metadata
        IERC20Metadata wethMeta = IERC20Metadata(WETH);
        assertEq(wethMeta.decimals(), 18, "WETH should have 18 decimals");
        assertGt(weth.totalSupply(), 0, "WETH should have supply");
    }

    /**
     * @notice Verify USDC is deployed on Base Sepolia
     */
    function test_usdcIsLive() public view {
        assertTrue(_hasCode(USDC), "USDC should have code");

        // Verify metadata
        IERC20Metadata usdcMeta = IERC20Metadata(USDC);
        assertEq(usdcMeta.decimals(), 6, "USDC should have 6 decimals");
        assertGt(usdc.totalSupply(), 0, "USDC should have supply");
    }

    // ============================================
    // TOKEN METADATA
    // ============================================

    /**
     * @notice Query token names and symbols
     */
    function test_tokenMetadata() public view {
        IERC20Metadata wethMeta = IERC20Metadata(WETH);
        IERC20Metadata usdcMeta = IERC20Metadata(USDC);

        // WETH
        string memory wethName = wethMeta.name();
        string memory wethSymbol = wethMeta.symbol();
        assertTrue(bytes(wethName).length > 0, "WETH should have name");
        assertTrue(bytes(wethSymbol).length > 0, "WETH should have symbol");

        // USDC
        string memory usdcName = usdcMeta.name();
        string memory usdcSymbol = usdcMeta.symbol();
        assertTrue(bytes(usdcName).length > 0, "USDC should have name");
        assertTrue(bytes(usdcSymbol).length > 0, "USDC should have symbol");

        // OP
    }

    // ============================================
    // TOKEN BALANCES
    // ============================================

    /**
     * @notice Query balances without reverting
     */
    function test_queryBalances() public view {
        // Should be able to query balances for any address
        uint256 wethBalance = weth.balanceOf(user1);
        uint256 usdcBalance = usdc.balanceOf(user1);

        // Fresh addresses should have 0 balance
        assertEq(wethBalance, 0, "User1 WETH balance should be 0");
        assertEq(usdcBalance, 0, "User1 USDC balance should be 0");
    }

    /**
     * @notice Query allowances without reverting
     */
    function test_queryAllowances() public view {
        // Should be able to query allowances
        uint256 wethAllowance = weth.allowance(user1, user2);
        uint256 usdcAllowance = usdc.allowance(user1, user2);

        assertEq(wethAllowance, 0, "Initial allowance should be 0");
        assertEq(usdcAllowance, 0, "Initial allowance should be 0");
    }

    // ============================================
    // TOKEN TRANSFERS WITH DEAL
    // ============================================

    /**
     * @notice Deal WETH and transfer
     */
    function test_dealAndTransferWeth() public {
        uint256 amount = 10 ether;

        // Deal WETH to user1
        _dealToken(WETH, user1, amount);
        assertEq(weth.balanceOf(user1), amount, "User1 should have WETH");

        // Transfer to user2
        vm.prank(user1);
        weth.transfer(user2, amount);

        assertEq(weth.balanceOf(user1), 0, "User1 balance should be 0");
        assertEq(weth.balanceOf(user2), amount, "User2 should have WETH");
    }

    /**
     * @notice Deal USDC and transfer
     */
    function test_dealAndTransferUsdc() public {
        uint256 amount = 10_000 * 1e6; // 10k USDC (6 decimals)

        // Deal USDC to user1
        _dealToken(USDC, user1, amount);
        assertEq(usdc.balanceOf(user1), amount, "User1 should have USDC");

        // Transfer to user2
        vm.prank(user1);
        usdc.transfer(user2, amount);

        assertEq(usdc.balanceOf(user1), 0, "User1 balance should be 0");
        assertEq(usdc.balanceOf(user2), amount, "User2 should have USDC");
    }

    // ============================================
    // APPROVE AND TRANSFER FROM
    // ============================================

    /**
     * @notice Approve and transferFrom WETH
     */
    function test_approveAndTransferFrom() public {
        uint256 amount = 5 ether;

        // Deal WETH to user1
        _dealToken(WETH, user1, amount);

        // Approve user2
        vm.prank(user1);
        weth.approve(user2, amount);

        assertEq(weth.allowance(user1, user2), amount, "Allowance set");

        // TransferFrom
        vm.prank(user2);
        weth.transferFrom(user1, deployer, amount);

        assertEq(weth.balanceOf(deployer), amount, "Deployer received WETH");
        assertEq(weth.balanceOf(user1), 0, "User1 balance depleted");
    }

    /**
     * @notice Infinite approval pattern
     */
    function test_infiniteApproval() public {
        uint256 infiniteAmount = type(uint256).max;
        uint256 transferAmount = 1 ether;

        // Deal WETH to user1
        _dealToken(WETH, user1, 100 ether);

        // Infinite approve user2
        vm.prank(user1);
        weth.approve(user2, infiniteAmount);

        // Multiple transfers
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user2);
            weth.transferFrom(user1, deployer, transferAmount);
        }

        assertEq(weth.balanceOf(deployer), 5 ether, "Deployer received 5 WETH");

        // Allowance may or may not decrease (depends on token implementation)
        // For standard ERC20, infinite approval doesn't decrease
        uint256 remainingAllowance = weth.allowance(user1, user2);
        assertTrue(remainingAllowance > 0, "Should still have allowance");
    }

    // ============================================
    // EDGE CASES
    // ============================================

    /**
     * @notice Transfer zero amount
     */
    function test_transferZero() public {
        _dealToken(WETH, user1, 1 ether);

        vm.prank(user1);
        bool success = weth.transfer(user2, 0);
        assertTrue(success, "Zero transfer should succeed");
    }

    /**
     * @notice Transfer to self
     */
    function test_transferToSelf() public {
        uint256 amount = 1 ether;
        _dealToken(WETH, user1, amount);

        vm.prank(user1);
        weth.transfer(user1, amount);

        assertEq(weth.balanceOf(user1), amount, "Balance unchanged");
    }

    /**
     * @notice Insufficient balance reverts
     */
    function test_insufficientBalanceReverts() public {
        // User1 has no WETH
        vm.prank(user1);
        vm.expectRevert();
        weth.transfer(user2, 1 ether);
    }

    /**
     * @notice Insufficient allowance reverts
     */
    function test_insufficientAllowanceReverts() public {
        _dealToken(WETH, user1, 10 ether);

        // Approve only 1 ether
        vm.prank(user1);
        weth.approve(user2, 1 ether);

        // Try to transfer 5 ether
        vm.prank(user2);
        vm.expectRevert();
        weth.transferFrom(user1, deployer, 5 ether);
    }

    // ============================================
    // SUPPLY QUERIES
    // ============================================

    /**
     * @notice Total supply is reasonable
     */
    function test_totalSupplies() public view {
        uint256 wethSupply = weth.totalSupply();
        uint256 usdcSupply = usdc.totalSupply();

        // WETH should have significant supply (wrapped ETH)
        assertGt(wethSupply, 1000 ether, "WETH supply should be significant");

        // USDC should have billions
        assertGt(usdcSupply, 1_000_000 * 1e6, "USDC supply should be > 1M");

        // OP should have significant supply

        // Log supplies for reference
        console2.log("WETH Supply:", wethSupply / 1e18, "ETH");
        console2.log("USDC Supply:", usdcSupply / 1e6, "USDC");
    }

    // ============================================
    // MULTI-TOKEN OPERATIONS
    // ============================================

    /**
     * @notice Hold multiple tokens
     */
    function test_holdMultipleTokens() public {
        // Deal multiple tokens to user1
        _dealToken(WETH, user1, 5 ether);
        _dealToken(USDC, user1, 10_000 * 1e6);

        assertEq(weth.balanceOf(user1), 5 ether, "Has WETH");
        assertEq(usdc.balanceOf(user1), 10_000 * 1e6, "Has USDC");

        // Transfer each to different recipients
        vm.startPrank(user1);
        weth.transfer(deployer, 2 ether);
        usdc.transfer(governor, 5_000 * 1e6);
        vm.stopPrank();

        // Verify final balances
        assertEq(weth.balanceOf(user1), 3 ether, "Remaining WETH");
        assertEq(usdc.balanceOf(user1), 5_000 * 1e6, "Remaining USDC");
    }

    /**
     * @notice Batch approve multiple tokens
     */
    function test_batchApprove() public {
        address spender = makeAddr("spender");

        _dealToken(WETH, user1, 10 ether);
        _dealToken(USDC, user1, 20_000 * 1e6);

        vm.startPrank(user1);
        weth.approve(spender, type(uint256).max);
        usdc.approve(spender, type(uint256).max);
        vm.stopPrank();

        assertEq(weth.allowance(user1, spender), type(uint256).max, "WETH approved");
        assertEq(usdc.allowance(user1, spender), type(uint256).max, "USDC approved");
    }
}
