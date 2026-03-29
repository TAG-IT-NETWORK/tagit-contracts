// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TAGITToken} from "../src/token/TAGITToken.sol";
import {TGEConverter} from "../src/token/TGEConverter.sol";
import {GENESIS_SUPPLY} from "../src/libraries/Constants.sol";

import {MockWTAG} from "./mocks/MockWTAG.sol";

/**
 * @title TGE Conversion End-to-End Tests
 * @author TAG IT Network <dev@tagit.network>
 * @notice Tests the full wTAG burn → TAG mint/transfer conversion flow
 * @dev Covers happy path, negative paths, event emissions, and edge cases
 *
 * Test Architecture:
 *   - MockWTAG: ERC20Burnable mock simulating WrappedTAGIT
 *   - TAGITToken: Real upgradeable TAG token via ERC1967Proxy
 *   - TGEConverter: Converter contract that burns wTAG, transfers TAG 1:1
 *
 * Flow under test:
 *   Treasury funds Converter with TAG → User approves wTAG → User calls convert()
 *   → wTAG burned from user → TAG transferred to user
 */
contract TGEConversionTest is Test {
    // ============================================
    // STATE
    // ============================================

    TAGITToken public tag;
    TAGITToken public tagImpl;
    MockWTAG public wtag;
    TGEConverter public converter;

    address public owner;
    address public treasury;
    address public alice;
    address public bob;
    address public attacker;

    uint256 public constant CONVERSION_POOL = 1_000_000 * 1e18;
    uint256 public constant ALICE_WTAG = 500_000 * 1e18;
    uint256 public constant BOB_WTAG = 300_000 * 1e18;
    uint256 public constant CONVERSION_DURATION = 30 days;

    // Events to verify
    event Converted(address indexed holder, uint256 amount, uint256 wtagBurnedTotal, uint256 tagRemainingBalance);
    event ConversionWindowOpened(uint256 startTime, uint256 endTime);
    event RemainingWithdrawn(address indexed to, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");

        // Deploy MockWTAG (simulates WrappedTAGIT from tagit-bridge)
        wtag = new MockWTAG(owner);

        // Deploy TAGITToken via proxy (real contract)
        tagImpl = new TAGITToken();
        bytes memory initData = abi.encodeWithSelector(TAGITToken.initialize.selector, treasury, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(tagImpl), initData);
        tag = TAGITToken(address(proxy));

        // Deploy TGEConverter
        converter = new TGEConverter(address(wtag), address(tag), owner);

        // Fund: Mint wTAG to alice and bob (simulating presale distribution)
        vm.startPrank(owner);
        wtag.mint(alice, ALICE_WTAG);
        wtag.mint(bob, BOB_WTAG);
        vm.stopPrank();

        // Fund: Transfer TAG from treasury to converter (presale allocation)
        vm.prank(treasury);
        tag.transfer(address(converter), CONVERSION_POOL);

        // Open conversion window
        vm.prank(owner);
        converter.openConversionWindow(CONVERSION_DURATION);
    }

    // ============================================
    // HAPPY PATH: FULL E2E CONVERSION
    // ============================================

    function test_e2e_aliceConvertsFullBalance() public {
        uint256 aliceWtagBefore = wtag.balanceOf(alice);
        uint256 aliceTagBefore = tag.balanceOf(alice);
        uint256 wtagSupplyBefore = wtag.totalSupply();
        uint256 converterTagBefore = tag.balanceOf(address(converter));

        // Alice approves and converts
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        // Verify wTAG burned from alice
        assertEq(wtag.balanceOf(alice), 0, "Alice should have 0 wTAG after conversion");
        assertEq(
            wtag.totalSupply(), wtagSupplyBefore - ALICE_WTAG, "wTAG total supply should decrease by converted amount"
        );

        // Verify TAG received by alice (1:1)
        assertEq(tag.balanceOf(alice), aliceTagBefore + ALICE_WTAG, "Alice should receive TAG equal to wTAG burned");

        // Verify converter state
        assertEq(
            tag.balanceOf(address(converter)), converterTagBefore - ALICE_WTAG, "Converter TAG balance should decrease"
        );
        assertEq(converter.totalConverted(), ALICE_WTAG, "Total converted should track");
        assertEq(converter.convertedBy(alice), ALICE_WTAG, "Per-user tracking should match");
    }

    function test_e2e_multipleUsersConvert() public {
        // Alice converts
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        // Bob converts
        vm.startPrank(bob);
        wtag.approve(address(converter), BOB_WTAG);
        converter.convert(BOB_WTAG);
        vm.stopPrank();

        // Verify both received TAG
        assertEq(tag.balanceOf(alice), ALICE_WTAG);
        assertEq(tag.balanceOf(bob), BOB_WTAG);

        // Verify total tracking
        assertEq(converter.totalConverted(), ALICE_WTAG + BOB_WTAG);
        assertEq(converter.convertedBy(alice), ALICE_WTAG);
        assertEq(converter.convertedBy(bob), BOB_WTAG);

        // Verify all wTAG burned
        assertEq(wtag.balanceOf(alice), 0);
        assertEq(wtag.balanceOf(bob), 0);
    }

    function test_e2e_partialConversion() public {
        uint256 partialAmount = ALICE_WTAG / 4;

        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);

        // Convert in 4 tranches
        converter.convert(partialAmount);
        converter.convert(partialAmount);
        converter.convert(partialAmount);
        converter.convert(partialAmount);
        vm.stopPrank();

        assertEq(wtag.balanceOf(alice), 0, "All wTAG should be converted");
        assertEq(tag.balanceOf(alice), ALICE_WTAG, "Should receive full TAG amount");
        assertEq(converter.convertedBy(alice), ALICE_WTAG, "Cumulative tracking correct");
    }

    // ============================================
    // NEGATIVE PATHS
    // ============================================

    function test_revert_convertZeroAmount() public {
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);

        vm.expectRevert(TGEConverter.ZeroAmount.selector);
        converter.convert(0);
        vm.stopPrank();
    }

    function test_revert_convertMoreThanBalance() public {
        uint256 excessAmount = ALICE_WTAG + 1;

        vm.startPrank(alice);
        wtag.approve(address(converter), excessAmount);

        // Should revert in safeTransferFrom (insufficient balance)
        vm.expectRevert();
        converter.convert(excessAmount);
        vm.stopPrank();
    }

    function test_revert_convertWithoutApproval() public {
        vm.prank(alice);

        // Should revert in safeTransferFrom (no approval)
        vm.expectRevert();
        converter.convert(ALICE_WTAG);
    }

    function test_revert_convertExceedsConverterTAGBalance() public {
        // Give alice more wTAG than the converter has TAG
        vm.prank(owner);
        wtag.mint(alice, CONVERSION_POOL + 1);

        vm.startPrank(alice);
        wtag.approve(address(converter), CONVERSION_POOL + 1 + ALICE_WTAG);

        // First, drain with normal balance
        converter.convert(ALICE_WTAG);

        // Try to convert more than remaining TAG in converter
        uint256 remaining = tag.balanceOf(address(converter));
        uint256 excessAmount = remaining + 1;

        vm.expectRevert(abi.encodeWithSelector(TGEConverter.InsufficientTAGBalance.selector, excessAmount, remaining));
        converter.convert(excessAmount);
        vm.stopPrank();
    }

    function test_revert_convertAfterWindowClosed() public {
        // Warp past conversion window
        vm.warp(block.timestamp + CONVERSION_DURATION + 1);

        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);

        vm.expectRevert(TGEConverter.ConversionWindowClosed.selector);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();
    }

    function test_revert_convertBeforeWindowOpened() public {
        // Deploy a new converter without opening the window
        TGEConverter freshConverter = new TGEConverter(address(wtag), address(tag), owner);

        vm.startPrank(alice);
        wtag.approve(address(freshConverter), ALICE_WTAG);

        vm.expectRevert(TGEConverter.ConversionWindowClosed.selector);
        freshConverter.convert(ALICE_WTAG);
        vm.stopPrank();
    }

    function test_revert_nonOwnerCallsMintDirectly() public {
        // Attacker tries to mint TAG directly on TAGITToken
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITToken.OnlyEmissionsCanMint.selector,
                attacker,
                address(0) // emissions not set
            )
        );
        tag.mint(attacker, 1000 * 1e18);
    }

    function test_revert_converterCannotMintTAG() public {
        // Converter contract itself cannot mint TAG (it only transfers pre-funded)
        vm.prank(address(converter));
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITToken.OnlyEmissionsCanMint.selector,
                address(converter),
                address(0) // emissions not set
            )
        );
        tag.mint(address(converter), 1000 * 1e18);
    }

    function test_revert_convertWhenPaused() public {
        vm.prank(owner);
        converter.pause();

        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);

        vm.expectRevert();
        converter.convert(ALICE_WTAG);
        vm.stopPrank();
    }

    function test_revert_openConversionWindowTwice() public {
        vm.prank(owner);
        vm.expectRevert(TGEConverter.ConversionWindowAlreadyStarted.selector);
        converter.openConversionWindow(30 days);
    }

    function test_revert_withdrawWhileWindowOpen() public {
        vm.prank(owner);
        vm.expectRevert(TGEConverter.ConversionWindowStillOpen.selector);
        converter.withdrawRemaining(treasury);
    }

    function test_revert_withdrawToZeroAddress() public {
        vm.warp(block.timestamp + CONVERSION_DURATION + 1);

        vm.prank(owner);
        vm.expectRevert(TGEConverter.ZeroAddress.selector);
        converter.withdrawRemaining(address(0));
    }

    // ============================================
    // EVENT EMISSION TESTS
    // ============================================

    function test_event_convertedEmitsCorrectArgs() public {
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);

        vm.expectEmit(true, false, false, true);
        emit Converted(
            alice,
            ALICE_WTAG,
            ALICE_WTAG, // first conversion, so total = amount
            CONVERSION_POOL - ALICE_WTAG // remaining TAG
        );
        converter.convert(ALICE_WTAG);
        vm.stopPrank();
    }

    function test_event_convertedIndexedFieldMatchesCaller() public {
        // Verify indexed address field matches the actual caller
        vm.startPrank(bob);
        wtag.approve(address(converter), BOB_WTAG);

        vm.expectEmit(true, false, false, true);
        emit Converted(bob, BOB_WTAG, BOB_WTAG, CONVERSION_POOL - BOB_WTAG);
        converter.convert(BOB_WTAG);
        vm.stopPrank();
    }

    function test_event_conversionWindowOpened() public {
        // Deploy fresh converter for this test
        TGEConverter freshConverter = new TGEConverter(address(wtag), address(tag), owner);

        uint256 expectedStart = block.timestamp;
        uint256 expectedEnd = block.timestamp + 7 days;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ConversionWindowOpened(expectedStart, expectedEnd);
        freshConverter.openConversionWindow(7 days);
    }

    function test_event_remainingWithdrawn() public {
        // Warp past window
        vm.warp(block.timestamp + CONVERSION_DURATION + 1);

        uint256 remaining = tag.balanceOf(address(converter));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RemainingWithdrawn(treasury, remaining);
        converter.withdrawRemaining(treasury);
    }

    function test_event_wtagTransferDuringConversion() public {
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);

        // Expect TAG Transfer from converter → alice
        vm.expectEmit(true, true, false, true, address(tag));
        emit Transfer(address(converter), alice, ALICE_WTAG);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        // Verify final state confirms all transfers occurred
        assertEq(wtag.balanceOf(alice), 0, "wTAG transferred and burned");
        assertEq(tag.balanceOf(alice), ALICE_WTAG, "TAG transferred to alice");
    }

    // ============================================
    // SUPPLY INVARIANT TESTS
    // ============================================

    function test_invariant_tagTotalSupplyUnchanged() public {
        uint256 tagSupplyBefore = tag.totalSupply();

        // Alice converts
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        // TAG total supply should NOT change (it's a transfer, not a mint)
        assertEq(tag.totalSupply(), tagSupplyBefore, "TAG total supply must remain unchanged (transfer, not mint)");
    }

    function test_invariant_wtagSupplyDecreases() public {
        uint256 wtagSupplyBefore = wtag.totalSupply();

        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        assertEq(wtag.totalSupply(), wtagSupplyBefore - ALICE_WTAG, "wTAG total supply must decrease by burned amount");
    }

    function test_invariant_oneToOneRatio() public {
        uint256 convertAmount = 123_456 * 1e18;

        vm.prank(owner);
        wtag.mint(alice, convertAmount);

        vm.startPrank(alice);
        wtag.approve(address(converter), type(uint256).max);

        uint256 tagBefore = tag.balanceOf(alice);
        uint256 wtagBefore = wtag.balanceOf(alice);

        converter.convert(convertAmount);
        vm.stopPrank();

        uint256 tagGained = tag.balanceOf(alice) - tagBefore;
        uint256 wtagLost = wtagBefore - wtag.balanceOf(alice);

        assertEq(tagGained, wtagLost, "TAG gained must equal wTAG burned (1:1)");
        assertEq(tagGained, convertAmount, "Exact amount must be converted");
    }

    // ============================================
    // WINDOW MANAGEMENT TESTS
    // ============================================

    function test_conversionAtWindowBoundary() public {
        // Convert at exact end timestamp (should succeed)
        vm.warp(block.timestamp + CONVERSION_DURATION);

        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        assertEq(tag.balanceOf(alice), ALICE_WTAG);
    }

    function test_conversionOneSecondAfterWindowFails() public {
        vm.warp(block.timestamp + CONVERSION_DURATION + 1);

        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);

        vm.expectRevert(TGEConverter.ConversionWindowClosed.selector);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();
    }

    function test_withdrawAfterWindowAndConversion() public {
        // Alice converts
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        // Warp past window
        vm.warp(block.timestamp + CONVERSION_DURATION + 1);

        uint256 remaining = tag.balanceOf(address(converter));
        uint256 treasuryBefore = tag.balanceOf(treasury);

        vm.prank(owner);
        converter.withdrawRemaining(treasury);

        assertEq(tag.balanceOf(treasury), treasuryBefore + remaining, "Treasury should receive remaining TAG");
        assertEq(tag.balanceOf(address(converter)), 0, "Converter should be empty");
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_isWindowOpen() public view {
        assertTrue(converter.isWindowOpen(), "Window should be open in setUp");
    }

    function test_isWindowOpenFalseAfterEnd() public {
        vm.warp(block.timestamp + CONVERSION_DURATION + 1);
        assertFalse(converter.isWindowOpen(), "Window should be closed");
    }

    function test_remainingTAG() public view {
        assertEq(converter.remainingTAG(), CONVERSION_POOL);
    }

    function test_remainingTAGAfterConversion() public {
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        assertEq(converter.remainingTAG(), CONVERSION_POOL - ALICE_WTAG);
    }

    // ============================================
    // CONSTRUCTOR VALIDATION
    // ============================================

    function test_revert_constructorZeroWtag() public {
        vm.expectRevert(TGEConverter.ZeroAddress.selector);
        new TGEConverter(address(0), address(tag), owner);
    }

    function test_revert_constructorZeroTag() public {
        vm.expectRevert(TGEConverter.ZeroAddress.selector);
        new TGEConverter(address(wtag), address(0), owner);
    }

    function test_revert_constructorZeroOwner() public {
        // Ownable reverts with OwnableInvalidOwner before our ZeroAddress check
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new TGEConverter(address(wtag), address(tag), address(0));
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_convertArbitraryAmount(uint256 amount) public {
        // Bound to valid range: 1 wei to ALICE_WTAG
        amount = bound(amount, 1, ALICE_WTAG);

        vm.startPrank(alice);
        wtag.approve(address(converter), amount);

        uint256 tagBefore = tag.balanceOf(alice);
        converter.convert(amount);
        vm.stopPrank();

        assertEq(tag.balanceOf(alice), tagBefore + amount, "1:1 ratio for any amount");
        assertEq(converter.convertedBy(alice), amount, "Tracking accurate for any amount");
    }

    function testFuzz_multipleConversions(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, ALICE_WTAG / 2);
        amount2 = bound(amount2, 1, ALICE_WTAG / 2);

        vm.startPrank(alice);
        wtag.approve(address(converter), amount1 + amount2);
        converter.convert(amount1);
        converter.convert(amount2);
        vm.stopPrank();

        assertEq(tag.balanceOf(alice), amount1 + amount2);
        assertEq(converter.totalConverted(), amount1 + amount2);
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function test_pauseAndUnpause() public {
        vm.prank(owner);
        converter.pause();

        // Cannot convert while paused
        vm.startPrank(alice);
        wtag.approve(address(converter), ALICE_WTAG);
        vm.expectRevert();
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        // Unpause
        vm.prank(owner);
        converter.unpause();

        // Can convert again
        vm.startPrank(alice);
        converter.convert(ALICE_WTAG);
        vm.stopPrank();

        assertEq(tag.balanceOf(alice), ALICE_WTAG);
    }
}
