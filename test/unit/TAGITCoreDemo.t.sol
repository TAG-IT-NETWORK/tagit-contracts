// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {TAGITCoreDemo} from "../../src/core/TAGITCoreDemo.sol";

/**
 * @title TAGITCoreDemoTest
 * @notice Comprehensive unit tests for TAGITCoreDemo contract
 * @dev Tests cover minting, state changes, access control, lifecycle transitions,
 *      event emissions, and view functions
 */
contract TAGITCoreDemoTest is Test {
    TAGITCoreDemo public demo;

    address public admin;
    address public attacker;

    uint256 public constant TOKEN_1 = 1;
    uint256 public constant TOKEN_2 = 2;
    uint256 public constant TOKEN_3 = 3;
    string public constant NAME_1 = "Luxury Watch #001";
    string public constant NAME_2 = "Designer Bag #042";

    // Events (re-declared for expectEmit)
    event AssetMinted(uint256 indexed tokenId, string name, address owner);
    event StateChanged(
        uint256 indexed tokenId, TAGITCoreDemo.State oldState, TAGITCoreDemo.State newState, address changedBy
    );

    function setUp() public {
        admin = makeAddr("admin");
        attacker = makeAddr("attacker");

        vm.prank(admin);
        demo = new TAGITCoreDemo();
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructor_setsAdmin() public view {
        assertEq(demo.admin(), admin);
    }

    function test_constructor_startsWithZeroAssets() public view {
        assertEq(demo.totalAssets(), 0);
    }

    // ──────────────────────────────────────────────
    // Mint
    // ──────────────────────────────────────────────

    function test_mint_success() public {
        vm.prank(admin);
        demo.mint(TOKEN_1, NAME_1);

        TAGITCoreDemo.Asset memory asset = demo.getAsset(TOKEN_1);
        assertEq(asset.name, NAME_1);
        assertTrue(asset.state == TAGITCoreDemo.State.MINTED);
        assertEq(asset.owner, admin);
        assertEq(asset.mintedAt, block.timestamp);
        assertEq(asset.lastUpdated, block.timestamp);
    }

    function test_mint_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit AssetMinted(TOKEN_1, NAME_1, admin);

        vm.prank(admin);
        demo.mint(TOKEN_1, NAME_1);
    }

    function test_mint_incrementsTotalAssets() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);
        assertEq(demo.totalAssets(), 1);

        demo.mint(TOKEN_2, NAME_2);
        assertEq(demo.totalAssets(), 2);
        vm.stopPrank();
    }

    function test_mint_addsToTokenIds() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);
        demo.mint(TOKEN_2, NAME_2);
        vm.stopPrank();

        uint256[] memory ids = demo.getTokenIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], TOKEN_1);
        assertEq(ids[1], TOKEN_2);
    }

    function test_mint_revertsNotAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(TAGITCoreDemo.NotAdmin.selector);
        demo.mint(TOKEN_1, NAME_1);
    }

    function test_mint_revertsAlreadyExists() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);

        vm.expectRevert(TAGITCoreDemo.AlreadyExists.selector);
        demo.mint(TOKEN_1, "Duplicate");
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // changeState
    // ──────────────────────────────────────────────

    function test_changeState_success() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);

        demo.changeState(TOKEN_1, TAGITCoreDemo.State.BOUND);
        vm.stopPrank();

        TAGITCoreDemo.Asset memory asset = demo.getAsset(TOKEN_1);
        assertTrue(asset.state == TAGITCoreDemo.State.BOUND);
    }

    function test_changeState_emitsEvent() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);

        vm.expectEmit(true, false, false, true);
        emit StateChanged(TOKEN_1, TAGITCoreDemo.State.MINTED, TAGITCoreDemo.State.BOUND, admin);

        demo.changeState(TOKEN_1, TAGITCoreDemo.State.BOUND);
        vm.stopPrank();
    }

    function test_changeState_updatesLastUpdated() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);

        uint256 mintTime = block.timestamp;

        vm.warp(mintTime + 100);
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.BOUND);
        vm.stopPrank();

        TAGITCoreDemo.Asset memory asset = demo.getAsset(TOKEN_1);
        assertEq(asset.lastUpdated, mintTime + 100);
        assertEq(asset.mintedAt, mintTime); // mintedAt should not change
    }

    function test_changeState_revertsNotAdmin() public {
        vm.prank(admin);
        demo.mint(TOKEN_1, NAME_1);

        vm.prank(attacker);
        vm.expectRevert(TAGITCoreDemo.NotAdmin.selector);
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.BOUND);
    }

    function test_changeState_revertsDoesNotExist() public {
        vm.prank(admin);
        vm.expectRevert(TAGITCoreDemo.DoesNotExist.selector);
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.BOUND);
    }

    // ──────────────────────────────────────────────
    // Full Lifecycle
    // ──────────────────────────────────────────────

    function test_fullLifecycle_mintThroughRecycled() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);

        // MINTED -> BOUND
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.BOUND);
        assertTrue(demo.getAsset(TOKEN_1).state == TAGITCoreDemo.State.BOUND);

        // BOUND -> ACTIVATED
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.ACTIVATED);
        assertTrue(demo.getAsset(TOKEN_1).state == TAGITCoreDemo.State.ACTIVATED);

        // ACTIVATED -> CLAIMED
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.CLAIMED);
        assertTrue(demo.getAsset(TOKEN_1).state == TAGITCoreDemo.State.CLAIMED);

        // CLAIMED -> FLAGGED
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.FLAGGED);
        assertTrue(demo.getAsset(TOKEN_1).state == TAGITCoreDemo.State.FLAGGED);

        // FLAGGED -> RECYCLED
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.RECYCLED);
        assertTrue(demo.getAsset(TOKEN_1).state == TAGITCoreDemo.State.RECYCLED);

        vm.stopPrank();
    }

    function test_lifecycle_flaggedToClaimedRecovery() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.BOUND);
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.ACTIVATED);
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.CLAIMED);
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.FLAGGED);

        // Recovery: FLAGGED -> CLAIMED
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.CLAIMED);
        assertTrue(demo.getAsset(TOKEN_1).state == TAGITCoreDemo.State.CLAIMED);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    function test_getAsset_returnsDefaultForNonExistent() public view {
        TAGITCoreDemo.Asset memory asset = demo.getAsset(999);
        assertTrue(asset.state == TAGITCoreDemo.State.NONE);
        assertEq(asset.owner, address(0));
        assertEq(bytes(asset.name).length, 0);
    }

    function test_getTokenIds_emptyInitially() public view {
        uint256[] memory ids = demo.getTokenIds();
        assertEq(ids.length, 0);
    }

    function test_totalAssets_matchesTokenIds() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);
        demo.mint(TOKEN_2, NAME_2);
        demo.mint(TOKEN_3, "Item #3");
        vm.stopPrank();

        assertEq(demo.totalAssets(), 3);
        assertEq(demo.getTokenIds().length, 3);
    }

    function test_assets_publicGetter() public {
        vm.prank(admin);
        demo.mint(TOKEN_1, NAME_1);

        // Test the auto-generated public getter (returns tuple)
        (string memory name, TAGITCoreDemo.State state, address owner, uint256 mintedAt, uint256 lastUpdated) =
            demo.assets(TOKEN_1);
        assertEq(name, NAME_1);
        assertTrue(state == TAGITCoreDemo.State.MINTED);
        assertEq(owner, admin);
        assertEq(mintedAt, block.timestamp);
        assertEq(lastUpdated, block.timestamp);
    }

    function test_tokenIds_publicGetter() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);
        demo.mint(TOKEN_2, NAME_2);
        vm.stopPrank();

        assertEq(demo.tokenIds(0), TOKEN_1);
        assertEq(demo.tokenIds(1), TOKEN_2);
    }

    // ──────────────────────────────────────────────
    // Edge Cases
    // ──────────────────────────────────────────────

    function test_mint_withTokenIdZero() public {
        vm.prank(admin);
        demo.mint(0, "Zero Token");

        TAGITCoreDemo.Asset memory asset = demo.getAsset(0);
        assertEq(asset.name, "Zero Token");
        assertTrue(asset.state == TAGITCoreDemo.State.MINTED);
    }

    function test_mint_withEmptyName() public {
        vm.prank(admin);
        demo.mint(TOKEN_1, "");

        TAGITCoreDemo.Asset memory asset = demo.getAsset(TOKEN_1);
        assertEq(bytes(asset.name).length, 0);
    }

    function test_changeState_toSameState() public {
        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);

        // Changing to same state should work (demo contract doesn't restrict)
        demo.changeState(TOKEN_1, TAGITCoreDemo.State.MINTED);
        assertTrue(demo.getAsset(TOKEN_1).state == TAGITCoreDemo.State.MINTED);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Fuzz Tests
    // ──────────────────────────────────────────────

    function testFuzz_mint_arbitraryTokenId(uint256 tokenId) public {
        vm.prank(admin);
        demo.mint(tokenId, "Fuzzed");

        TAGITCoreDemo.Asset memory asset = demo.getAsset(tokenId);
        assertTrue(asset.state == TAGITCoreDemo.State.MINTED);
        assertEq(asset.owner, admin);
    }

    function testFuzz_changeState_allValidStates(uint8 stateRaw) public {
        // Bound state to valid enum range (1-6, skip NONE since we start at MINTED)
        stateRaw = uint8(bound(stateRaw, 1, 6));
        TAGITCoreDemo.State newState = TAGITCoreDemo.State(stateRaw);

        vm.startPrank(admin);
        demo.mint(TOKEN_1, NAME_1);
        demo.changeState(TOKEN_1, newState);
        vm.stopPrank();

        assertTrue(demo.getAsset(TOKEN_1).state == newState);
    }
}
