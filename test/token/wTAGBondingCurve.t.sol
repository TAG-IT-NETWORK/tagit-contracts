// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {wTAGBondingCurve} from "../../src/token/wTAGBondingCurve.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BASIS_POINTS} from "../../src/libraries/Constants.sol";

/**
 * @title MockWTAG
 * @dev Minimal ERC-20 mock for the wTAG token in bonding curve tests
 */
contract MockWTAG is ERC20 {
    constructor() ERC20("Wrapped TAGIT", "wTAG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title ETHRejecter
 * @dev Contract that rejects ETH transfers — used to test ETHTransferFailed paths
 */
contract ETHRejecter {
    wTAGBondingCurve public curve;
    IERC20 public wtag;

    constructor(wTAGBondingCurve _curve, IERC20 _wtag) {
        curve = _curve;
        wtag = _wtag;
    }

    function doBuy(uint256 amount, uint256 maxCost) external payable {
        curve.buy{value: msg.value}(amount, maxCost);
    }

    function doSell(uint256 amount, uint256 minReturn) external {
        wtag.approve(address(curve), amount);
        curve.sell(amount, minReturn);
    }

    // Deliberately reject ETH transfers
    receive() external payable {
        revert("rejected");
    }
}

/**
 * @title wTAGBondingCurveTest
 * @author TAG IT Network <dev@tagit.network>
 * @notice Comprehensive test suite for the wTAGBondingCurve contract
 * @dev Covers math, buy/sell, admin, pause, slippage, fee accrual
 */
contract wTAGBondingCurveTest is Test {
    // ============================================
    // STATE
    // ============================================

    MockWTAG public wtag;
    wTAGBondingCurve public curve;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /// @dev Artemus parameters: 0.001 ETH initial price, 1e6 slope, 333 bps (3.33%) fee
    uint256 public constant INITIAL_PRICE = 0.001 ether;
    uint256 public constant SLOPE = 1e6; // wei per token-unit
    uint256 public constant FEE_BPS = 333; // 3.33%
    uint256 public constant PRECISION = 1e18;

    // Curve supply for testing
    uint256 public constant CURVE_WTAG_SUPPLY = 1_000_000 ether; // 1M wTAG available

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        // Deploy mock wTAG
        wtag = new MockWTAG();

        // Deploy bonding curve
        curve = new wTAGBondingCurve(address(wtag), owner, INITIAL_PRICE, SLOPE, FEE_BPS);

        // Fund the bonding curve with wTAG tokens for sale
        wtag.mint(address(curve), CURVE_WTAG_SUPPLY);

        // Fund alice and bob with ETH
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function test_constructor_setsParameters() public view {
        assertEq(address(curve.wtagToken()), address(wtag));
        assertEq(curve.initialPrice(), INITIAL_PRICE);
        assertEq(curve.slope(), SLOPE);
        assertEq(curve.feeBps(), FEE_BPS);
        assertEq(curve.curveSupply(), 0);
        assertEq(curve.reserve(), 0);
        assertEq(curve.accruedFees(), 0);
    }

    function test_constructor_setsOwner() public view {
        assertEq(curve.owner(), owner);
    }

    function test_constructor_revert_zeroWtagToken() public {
        vm.expectRevert(wTAGBondingCurve.ZeroAddress.selector);
        new wTAGBondingCurve(address(0), owner, INITIAL_PRICE, SLOPE, FEE_BPS);
    }

    function test_constructor_revert_zeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OwnableInvalidOwner(address)")), address(0)));
        new wTAGBondingCurve(address(wtag), address(0), INITIAL_PRICE, SLOPE, FEE_BPS);
    }

    function test_constructor_revert_zeroInitialPrice() public {
        vm.expectRevert(wTAGBondingCurve.ZeroInitialPrice.selector);
        new wTAGBondingCurve(address(wtag), owner, 0, SLOPE, FEE_BPS);
    }

    function test_constructor_revert_zeroSlope() public {
        vm.expectRevert(wTAGBondingCurve.ZeroSlope.selector);
        new wTAGBondingCurve(address(wtag), owner, INITIAL_PRICE, 0, FEE_BPS);
    }

    function test_constructor_revert_feeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.FeeTooHigh.selector, 1001, 1000));
        new wTAGBondingCurve(address(wtag), owner, INITIAL_PRICE, SLOPE, 1001);
    }

    function test_constructor_revert_slopeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.SlopeTooHigh.selector, 1e12 + 1, 1e12));
        new wTAGBondingCurve(address(wtag), owner, INITIAL_PRICE, 1e12 + 1, FEE_BPS);
    }

    // ============================================
    // MATH UNIT TESTS
    // ============================================

    function test_buyPriceZero_curveSupplyZero() public view {
        // At supply=0, spot price = initialPrice = 0.001 ETH
        uint256 spotPrice = curve.currentPrice();
        assertEq(spotPrice, INITIAL_PRICE, "Spot price at supply=0 should be initialPrice");
    }

    function test_buyPriceIncreases() public {
        // Buy some tokens, then check that the next quote is higher
        uint256 amount = 100 ether; // 100 tokens

        (uint256 cost1,) = curve.getBuyQuote(amount);

        // Buy the first batch
        vm.prank(alice);
        curve.buy{value: cost1}(amount, cost1);

        // Now the next batch should cost more
        (uint256 cost2,) = curve.getBuyQuote(amount);
        assertGt(cost2, cost1, "Buy price should increase as supply grows");
    }

    function test_sellPriceDecreases() public {
        // Buy tokens, then check sell prices at different supply levels
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);

        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        (uint256 sellReturn1,) = curve.getSellQuote(50 ether);

        // Buy more to increase supply
        (uint256 buyCost2,) = curve.getBuyQuote(amount);
        vm.prank(bob);
        curve.buy{value: buyCost2}(amount, buyCost2);

        // Sell at higher supply gives more return
        (uint256 sellReturn2,) = curve.getSellQuote(50 ether);
        assertGt(sellReturn2, sellReturn1, "Sell return should increase with higher supply");
    }

    function test_roundTripNoFee() public {
        // Deploy a zero-fee curve to test round-trip invariant
        wTAGBondingCurve noFeeCurve = new wTAGBondingCurve(
            address(wtag),
            owner,
            INITIAL_PRICE,
            SLOPE,
            0 // zero fee
        );
        wtag.mint(address(noFeeCurve), CURVE_WTAG_SUPPLY);

        uint256 amount = 100 ether;
        (uint256 buyCost,) = noFeeCurve.getBuyQuote(amount);

        // Alice buys
        vm.prank(alice);
        noFeeCurve.buy{value: buyCost}(amount, buyCost);

        // Alice approves and sells
        vm.startPrank(alice);
        wtag.approve(address(noFeeCurve), amount);
        (uint256 sellReturn,) = noFeeCurve.getSellQuote(amount);

        uint256 aliceEthBefore = alice.balance;
        noFeeCurve.sell(amount, sellReturn);
        uint256 aliceEthAfter = alice.balance;
        vm.stopPrank();

        // With zero fee, selling the exact same amount should return exact buy cost
        assertEq(aliceEthAfter - aliceEthBefore, buyCost, "Round-trip with zero fee should be lossless");
        assertEq(noFeeCurve.reserve(), 0, "Reserve should be zero after full round-trip");
        assertEq(noFeeCurve.curveSupply(), 0, "Curve supply should be zero after full round-trip");
    }

    function test_feeAccrual() public {
        uint256 amount = 100 ether;
        (uint256 totalCost, uint256 buyFee) = curve.getBuyQuote(amount);

        // Alice buys
        vm.prank(alice);
        curve.buy{value: totalCost}(amount, totalCost);

        // Fee should have accrued
        assertEq(curve.accruedFees(), buyFee, "Fees should accrue on buy");
        assertGt(buyFee, 0, "Fee should be non-zero");

        // Now sell and check more fees accrue
        vm.startPrank(alice);
        wtag.approve(address(curve), amount);
        (uint256 netReturn, uint256 sellFee) = curve.getSellQuote(amount);
        curve.sell(amount, netReturn);
        vm.stopPrank();

        assertEq(curve.accruedFees(), buyFee + sellFee, "Fees should accrue on both buy and sell");
    }

    function test_currentPrice_increasesWithSupply() public {
        uint256 priceBefore = curve.currentPrice();
        assertEq(priceBefore, INITIAL_PRICE);

        // Buy tokens
        uint256 amount = 1000 ether;
        (uint256 cost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: cost}(amount, cost);

        uint256 priceAfter = curve.currentPrice();
        assertGt(priceAfter, priceBefore, "Spot price should increase after buy");

        // Verify the exact formula: initialPrice + slope * curveSupply / PRECISION
        uint256 expectedPrice = INITIAL_PRICE + (SLOPE * curve.curveSupply() / PRECISION);
        assertEq(priceAfter, expectedPrice, "Spot price should match formula");
    }

    // ============================================
    // BUY TESTS
    // ============================================

    function test_buy_success() public {
        uint256 amount = 100 ether;
        (uint256 totalCost,) = curve.getBuyQuote(amount);

        uint256 aliceWtagBefore = wtag.balanceOf(alice);

        vm.prank(alice);
        curve.buy{value: totalCost}(amount, totalCost);

        assertEq(wtag.balanceOf(alice), aliceWtagBefore + amount, "Alice should receive wTAG");
        assertEq(curve.curveSupply(), amount, "Curve supply should increase");
    }

    function test_buy_refundsExcessETH() public {
        uint256 amount = 100 ether;
        (uint256 totalCost,) = curve.getBuyQuote(amount);
        uint256 overpay = 1 ether;

        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        curve.buy{value: totalCost + overpay}(amount, totalCost + overpay);

        // Alice should get the overpay refunded
        uint256 aliceEthAfter = alice.balance;
        assertEq(aliceEthBefore - aliceEthAfter, totalCost, "Only exact cost should be deducted");
    }

    function test_buy_emitsEvent() public {
        uint256 amount = 100 ether;
        (uint256 totalCost, uint256 fee) = curve.getBuyQuote(amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit wTAGBondingCurve.Buy(alice, amount, totalCost, fee);
        curve.buy{value: totalCost}(amount, totalCost);
    }

    function test_buy_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(wTAGBondingCurve.ZeroAmount.selector);
        curve.buy{value: 1 ether}(0, 1 ether);
    }

    function test_buy_revert_insufficientPayment() public {
        uint256 amount = 100 ether;
        (uint256 totalCost,) = curve.getBuyQuote(amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.InsufficientPayment.selector, totalCost, totalCost - 1));
        curve.buy{value: totalCost - 1}(amount, totalCost);
    }

    function test_buy_revert_slippageExceeded() public {
        uint256 amount = 100 ether;
        (uint256 totalCost,) = curve.getBuyQuote(amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.SlippageExceeded.selector, totalCost, totalCost - 1));
        curve.buy{value: totalCost}(amount, totalCost - 1);
    }

    // ============================================
    // SELL TESTS
    // ============================================

    function test_sell_success() public {
        // First buy tokens
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        // Approve and sell
        vm.startPrank(alice);
        wtag.approve(address(curve), amount);
        (uint256 netReturn,) = curve.getSellQuote(amount);

        uint256 aliceEthBefore = alice.balance;
        curve.sell(amount, netReturn);
        uint256 aliceEthAfter = alice.balance;
        vm.stopPrank();

        assertEq(aliceEthAfter - aliceEthBefore, netReturn, "Alice should receive ETH");
        assertEq(curve.curveSupply(), 0, "Curve supply should decrease to 0");
    }

    function test_sell_emitsEvent() public {
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        vm.startPrank(alice);
        wtag.approve(address(curve), amount);
        (uint256 netReturn, uint256 fee) = curve.getSellQuote(amount);

        vm.expectEmit(true, true, true, true);
        emit wTAGBondingCurve.Sell(alice, amount, netReturn, fee);
        curve.sell(amount, netReturn);
        vm.stopPrank();
    }

    function test_sell_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(wTAGBondingCurve.ZeroAmount.selector);
        curve.sell(0, 0);
    }

    function test_sell_revert_exceedsCurveSupply() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.ExceedsCurveSupply.selector, 1 ether, 0));
        curve.sell(1 ether, 0);
    }

    function test_sell_revert_slippageExceeded() public {
        // Buy first
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        // Try to sell with unrealistic minReturn
        vm.startPrank(alice);
        wtag.approve(address(curve), amount);
        (uint256 netReturn,) = curve.getSellQuote(amount);

        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.SlippageExceeded.selector, netReturn, netReturn + 1));
        curve.sell(amount, netReturn + 1);
        vm.stopPrank();
    }

    // ============================================
    // INTEGRATION TESTS
    // ============================================

    function test_buyThenSell_fullRoundTripReserve() public {
        uint256 amount = 500 ether;

        // Buy
        (uint256 buyCost, uint256 buyFee) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        uint256 reserveAfterBuy = curve.reserve();
        assertEq(reserveAfterBuy, buyCost - buyFee, "Reserve should equal buy cost minus fee");

        // Sell
        vm.startPrank(alice);
        wtag.approve(address(curve), amount);
        (uint256 netReturn, uint256 sellFee) = curve.getSellQuote(amount);
        curve.sell(amount, netReturn);
        vm.stopPrank();

        // After full round-trip: reserve = 0, supply = 0
        assertEq(curve.curveSupply(), 0, "Supply should be zero after round-trip");
        assertEq(curve.reserve(), 0, "Reserve should be zero after round-trip");

        // Total fees collected = buyFee + sellFee
        assertEq(curve.accruedFees(), buyFee + sellFee, "All fees should be accounted for");
    }

    function test_maxSlippage_buyProtection() public {
        uint256 amount = 100 ether;
        (uint256 totalCost,) = curve.getBuyQuote(amount);

        // Set max cost slightly above actual — should succeed
        vm.prank(alice);
        curve.buy{value: totalCost + 1}(amount, totalCost + 1);

        assertEq(wtag.balanceOf(alice), amount);
    }

    function test_maxSlippage_sellProtection() public {
        // Buy first
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        // Sell with exact minReturn — should succeed
        vm.startPrank(alice);
        wtag.approve(address(curve), amount);
        (uint256 netReturn,) = curve.getSellQuote(amount);
        curve.sell(amount, netReturn);
        vm.stopPrank();

        assertEq(wtag.balanceOf(alice), 0);
    }

    function test_pauseBlocking_buyReverts() public {
        vm.prank(owner);
        curve.pause();

        uint256 amount = 100 ether;
        vm.prank(alice);
        vm.expectRevert();
        curve.buy{value: 1 ether}(amount, 1 ether);
    }

    function test_pauseBlocking_sellReverts() public {
        // Buy some tokens first
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        // Pause
        vm.prank(owner);
        curve.pause();

        // Sell should revert
        vm.startPrank(alice);
        wtag.approve(address(curve), amount);
        vm.expectRevert();
        curve.sell(amount, 0);
        vm.stopPrank();
    }

    function test_pauseUnpause_resumesTrading() public {
        vm.prank(owner);
        curve.pause();

        vm.prank(owner);
        curve.unpause();

        // Should work now
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        assertEq(wtag.balanceOf(alice), amount);
    }

    function test_ownerWithdrawFees() public {
        // Generate fees via a buy
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        uint256 fees = curve.accruedFees();
        assertGt(fees, 0, "Should have accrued fees");

        uint256 ownerBalBefore = owner.balance;

        vm.prank(owner);
        curve.withdrawFees();

        assertEq(owner.balance, ownerBalBefore + fees, "Owner should receive fees");
        assertEq(curve.accruedFees(), 0, "Accrued fees should be zero after withdrawal");
    }

    function test_withdrawFees_emitsEvent() public {
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        uint256 fees = curve.accruedFees();

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit wTAGBondingCurve.FeesWithdrawn(owner, fees);
        curve.withdrawFees();
    }

    function test_withdrawFees_revert_noFees() public {
        vm.prank(owner);
        vm.expectRevert(wTAGBondingCurve.NoFeesToWithdraw.selector);
        curve.withdrawFees();
    }

    function test_withdrawFees_revert_nonOwner() public {
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        vm.prank(alice);
        vm.expectRevert();
        curve.withdrawFees();
    }

    // ============================================
    // ADMIN TESTS
    // ============================================

    function test_updateParams_success() public {
        uint256 newPrice = 0.002 ether;
        uint256 newSlope = 2e6;
        uint256 newFee = 500;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit wTAGBondingCurve.ParamsUpdated(newPrice, newSlope, newFee);
        curve.updateParams(newPrice, newSlope, newFee);

        assertEq(curve.initialPrice(), newPrice);
        assertEq(curve.slope(), newSlope);
        assertEq(curve.feeBps(), newFee);
    }

    function test_updateParams_revert_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        curve.updateParams(0.002 ether, 2e6, 500);
    }

    function test_updateParams_revert_zeroPrice() public {
        vm.prank(owner);
        vm.expectRevert(wTAGBondingCurve.ZeroInitialPrice.selector);
        curve.updateParams(0, SLOPE, FEE_BPS);
    }

    function test_updateParams_revert_zeroSlope() public {
        vm.prank(owner);
        vm.expectRevert(wTAGBondingCurve.ZeroSlope.selector);
        curve.updateParams(INITIAL_PRICE, 0, FEE_BPS);
    }

    function test_pause_revert_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        curve.pause();
    }

    function test_unpause_revert_nonOwner() public {
        vm.prank(owner);
        curve.pause();

        vm.prank(alice);
        vm.expectRevert();
        curve.unpause();
    }

    // ============================================
    // MULTIPLE PARTICIPANTS TEST
    // ============================================

    function test_multipleParticipants_priceRises() public {
        uint256 amount = 100 ether;

        // Alice buys
        (uint256 aliceCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: aliceCost}(amount, aliceCost);

        // Bob buys at higher price
        (uint256 bobCost,) = curve.getBuyQuote(amount);
        vm.prank(bob);
        curve.buy{value: bobCost}(amount, bobCost);

        assertGt(bobCost, aliceCost, "Bob should pay more than Alice (price increased)");
        assertEq(curve.curveSupply(), 2 * amount);
    }

    // ============================================
    // RECEIVE ETH TEST
    // ============================================

    function test_receiveETH() public {
        vm.prank(alice);
        (bool success,) = address(curve).call{value: 1 ether}("");
        assertTrue(success, "Should accept ETH via receive()");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_buyAndSellRoundTrip(uint256 amount) public {
        // Bound to avoid overflow and stay within available supply
        amount = bound(amount, 1 ether, 10_000 ether);

        // Deploy zero-fee curve for clean round-trip
        wTAGBondingCurve noFeeCurve = new wTAGBondingCurve(address(wtag), owner, INITIAL_PRICE, SLOPE, 0);
        wtag.mint(address(noFeeCurve), CURVE_WTAG_SUPPLY);

        (uint256 buyCost,) = noFeeCurve.getBuyQuote(amount);
        vm.assume(buyCost <= alice.balance);

        // Buy
        vm.prank(alice);
        noFeeCurve.buy{value: buyCost}(amount, buyCost);

        assertEq(wtag.balanceOf(alice), amount);

        // Sell
        vm.startPrank(alice);
        wtag.approve(address(noFeeCurve), amount);
        (uint256 sellReturn,) = noFeeCurve.getSellQuote(amount);
        noFeeCurve.sell(amount, sellReturn);
        vm.stopPrank();

        // Round-trip with zero fee should return exact ETH
        assertEq(sellReturn, buyCost, "Zero-fee round-trip should be lossless");
        assertEq(noFeeCurve.curveSupply(), 0);
        assertEq(noFeeCurve.reserve(), 0);
    }

    function testFuzz_feeAlwaysLessThanCost(uint256 amount) public {
        amount = bound(amount, 1 ether, 100_000 ether);

        (uint256 totalCost, uint256 fee) = curve.getBuyQuote(amount);
        assertLt(fee, totalCost, "Fee should always be less than total cost");
        assertGt(fee, 0, "Fee should be non-zero with non-zero fee bps");
    }

    function testFuzz_priceMonotonicallyIncreases(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1 ether, 5000 ether);
        amount2 = bound(amount2, 1 ether, 5000 ether);

        (uint256 cost1,) = curve.getBuyQuote(amount1);
        vm.assume(cost1 <= alice.balance);

        uint256 priceBefore = curve.currentPrice();

        vm.prank(alice);
        curve.buy{value: cost1}(amount1, cost1);

        uint256 priceAfter = curve.currentPrice();
        assertGt(priceAfter, priceBefore, "Price should increase after buy");
    }

    // ============================================
    // QUOTE VIEW EDGE CASES
    // ============================================

    function test_getBuyQuote_revert_zeroAmount() public {
        vm.expectRevert(wTAGBondingCurve.ZeroAmount.selector);
        curve.getBuyQuote(0);
    }

    function test_getSellQuote_revert_zeroAmount() public {
        vm.expectRevert(wTAGBondingCurve.ZeroAmount.selector);
        curve.getSellQuote(0);
    }

    function test_getSellQuote_revert_exceedsCurveSupply() public {
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.ExceedsCurveSupply.selector, 1 ether, 0));
        curve.getSellQuote(1 ether);
    }

    function test_getSellQuote_exactCurveSupply() public {
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        // Should not revert when querying exactly curveSupply
        (uint256 netReturn, uint256 fee) = curve.getSellQuote(amount);
        assertGt(netReturn, 0, "Net return should be positive");
        assertGt(fee, 0, "Fee should be positive");
    }

    // ============================================
    // BUY — INSUFFICIENT wTAG BALANCE
    // ============================================

    function test_buy_revert_insufficientWtagBalance() public {
        // Deploy a curve with NO wTAG tokens
        wTAGBondingCurve emptyCurve = new wTAGBondingCurve(address(wtag), owner, INITIAL_PRICE, SLOPE, FEE_BPS);
        // Do NOT fund it with wTAG

        uint256 amount = 100 ether;
        (uint256 totalCost,) = emptyCurve.getBuyQuote(amount);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.InsufficientBalance.selector, amount, 0));
        emptyCurve.buy{value: totalCost}(amount, totalCost);
    }

    // ============================================
    // UPDATEPARAMS — FEE & SLOPE TOO HIGH
    // ============================================

    function test_updateParams_revert_feeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.FeeTooHigh.selector, 1001, 1000));
        curve.updateParams(INITIAL_PRICE, SLOPE, 1001);
    }

    function test_updateParams_revert_slopeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.SlopeTooHigh.selector, 1e12 + 1, 1e12));
        curve.updateParams(INITIAL_PRICE, 1e12 + 1, FEE_BPS);
    }

    function test_updateParams_maxBoundaryValues() public {
        vm.prank(owner);
        curve.updateParams(1, 1e12, 1000);

        assertEq(curve.initialPrice(), 1);
        assertEq(curve.slope(), 1e12);
        assertEq(curve.feeBps(), 1000);
    }

    // ============================================
    // ETH TRANSFER FAILURE TESTS
    // ============================================

    function test_buy_revert_ethRefundFails() public {
        // Use ETHRejecter contract as buyer so refund is rejected
        ETHRejecter rejecter = new ETHRejecter(curve, IERC20(address(wtag)));
        vm.deal(address(rejecter), 100 ether);

        uint256 amount = 10 ether;
        (uint256 totalCost,) = curve.getBuyQuote(amount);

        // Send more than needed to trigger a refund, which will fail
        vm.expectRevert(abi.encodeWithSelector(wTAGBondingCurve.ETHTransferFailed.selector, address(rejecter), 1 ether));
        rejecter.doBuy{value: totalCost + 1 ether}(amount, totalCost + 1 ether);
    }

    function test_sell_revert_ethTransferFails() public {
        // First, buy tokens to an EOA, then transfer them to the rejecter
        uint256 amount = 10 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        // Transfer wTAG to the rejecter
        ETHRejecter rejecter = new ETHRejecter(curve, IERC20(address(wtag)));
        vm.prank(alice);
        wtag.transfer(address(rejecter), amount);

        // Rejecter tries to sell — ETH send back will fail
        (uint256 netReturn,) = curve.getSellQuote(amount);
        vm.expectRevert(
            abi.encodeWithSelector(wTAGBondingCurve.ETHTransferFailed.selector, address(rejecter), netReturn)
        );
        rejecter.doSell(amount, netReturn);
    }

    function test_withdrawFees_revert_ethTransferFails() public {
        // Generate fees
        uint256 amount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        uint256 fees = curve.accruedFees();
        assertGt(fees, 0);

        // Deploy a new curve owned by a contract that rejects ETH
        ETHRejecter rejecterOwner = new ETHRejecter(curve, IERC20(address(wtag)));
        wTAGBondingCurve ownedCurve =
            new wTAGBondingCurve(address(wtag), address(rejecterOwner), INITIAL_PRICE, SLOPE, FEE_BPS);
        wtag.mint(address(ownedCurve), CURVE_WTAG_SUPPLY);

        // Generate fees on the new curve
        (uint256 cost2,) = ownedCurve.getBuyQuote(amount);
        vm.prank(alice);
        ownedCurve.buy{value: cost2}(amount, cost2);

        uint256 ownedFees = ownedCurve.accruedFees();
        assertGt(ownedFees, 0);

        // Withdraw as the rejecter owner — ETH transfer will fail
        vm.prank(address(rejecterOwner));
        vm.expectRevert(
            abi.encodeWithSelector(wTAGBondingCurve.ETHTransferFailed.selector, address(rejecterOwner), ownedFees)
        );
        ownedCurve.withdrawFees();
    }

    // ============================================
    // SINGLE-WEI PRECISION TESTS
    // ============================================

    function test_buy_singleWeiPrecision() public {
        // Buy exactly 1 wei of tokens (smallest possible amount)
        uint256 amount = 1;
        (uint256 totalCost, uint256 fee) = curve.getBuyQuote(amount);

        // Cost may round down to 0 for very tiny amounts; verify no revert
        vm.prank(alice);
        curve.buy{value: totalCost + 1}(amount, totalCost + 1);

        assertEq(wtag.balanceOf(alice), amount);
        assertEq(curve.curveSupply(), amount);
    }

    function test_sell_partialAmount() public {
        // Buy 100 tokens, sell only 50
        uint256 buyAmount = 100 ether;
        (uint256 buyCost,) = curve.getBuyQuote(buyAmount);
        vm.prank(alice);
        curve.buy{value: buyCost}(buyAmount, buyCost);

        uint256 sellAmount = 50 ether;
        vm.startPrank(alice);
        wtag.approve(address(curve), sellAmount);
        (uint256 netReturn,) = curve.getSellQuote(sellAmount);
        curve.sell(sellAmount, netReturn);
        vm.stopPrank();

        assertEq(curve.curveSupply(), 50 ether, "Supply should reflect partial sell");
        assertEq(wtag.balanceOf(alice), 50 ether, "Alice should have remaining tokens");
    }

    // ============================================
    // ADDITIONAL FUZZ TESTS
    // ============================================

    function testFuzz_buy(uint256 amount) public {
        amount = bound(amount, 1e15, 50_000 ether); // min 0.001 tokens, max 50K

        (uint256 totalCost, uint256 fee) = curve.getBuyQuote(amount);
        vm.assume(totalCost <= alice.balance);
        vm.assume(totalCost > 0);

        vm.prank(alice);
        curve.buy{value: totalCost}(amount, totalCost);

        assertEq(wtag.balanceOf(alice), amount, "Should receive exact token amount");
        assertEq(curve.curveSupply(), amount, "Curve supply should match");
        assertEq(curve.accruedFees(), fee, "Fees should match quote");
    }

    function testFuzz_sell(uint256 buyAmount, uint256 sellPct) public {
        buyAmount = bound(buyAmount, 1 ether, 10_000 ether);
        sellPct = bound(sellPct, 1, 100);
        uint256 sellAmount = (buyAmount * sellPct) / 100;
        vm.assume(sellAmount >= 1);

        (uint256 buyCost,) = curve.getBuyQuote(buyAmount);
        vm.assume(buyCost <= alice.balance);

        vm.prank(alice);
        curve.buy{value: buyCost}(buyAmount, buyCost);

        vm.startPrank(alice);
        wtag.approve(address(curve), sellAmount);
        (uint256 netReturn,) = curve.getSellQuote(sellAmount);
        curve.sell(sellAmount, netReturn);
        vm.stopPrank();

        assertEq(curve.curveSupply(), buyAmount - sellAmount, "Supply should decrease by sell amount");
        assertEq(wtag.balanceOf(alice), buyAmount - sellAmount, "Token balance should reflect sell");
    }

    function testFuzz_sellReturnLessThanBuyCostWithFees(uint256 amount) public {
        amount = bound(amount, 1 ether, 10_000 ether);

        (uint256 buyCost,) = curve.getBuyQuote(amount);
        vm.assume(buyCost <= alice.balance);

        vm.prank(alice);
        curve.buy{value: buyCost}(amount, buyCost);

        vm.startPrank(alice);
        wtag.approve(address(curve), amount);
        (uint256 netReturn,) = curve.getSellQuote(amount);
        vm.stopPrank();

        // With non-zero fees, selling should always return less than buying cost
        assertLt(netReturn, buyCost, "Sell return with fees should be less than buy cost");
    }

    // ============================================
    // OWNERSHIP TRANSFER TEST
    // ============================================

    function test_ownershipTransfer() public {
        vm.prank(owner);
        curve.transferOwnership(alice);

        assertEq(curve.owner(), alice, "Ownership should transfer");

        // Alice should now be able to pause
        vm.prank(alice);
        curve.pause();
        assertTrue(curve.paused(), "New owner should be able to pause");
    }

    // ============================================
    // CONSTANTS VERIFICATION
    // ============================================

    function test_constantValues() public view {
        assertEq(curve.PRECISION(), 1e18, "PRECISION should be 1e18");
        assertEq(curve.MAX_FEE_BPS(), 1000, "MAX_FEE_BPS should be 1000");
        assertEq(curve.MAX_SLOPE(), 1e12, "MAX_SLOPE should be 1e12");
    }
}
