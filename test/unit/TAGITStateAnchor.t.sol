// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITStateAnchor} from "../../src/mirror/TAGITStateAnchor.sol";

contract TAGITStateAnchorTest is Test {
    TAGITStateAnchor public stateAnchor;

    address public owner = makeAddr("owner");
    address public anchorKey = makeAddr("anchor");
    address public attacker = makeAddr("attacker");
    address public assetOwner = makeAddr("assetOwner");

    uint256 public constant TOKEN_ID = 1;
    uint256 public constant STATE_ACTIVATED = 3;

    event StateRootPosted(uint256 indexed tokenId, bytes32 root, uint256 timestamp);
    event HeartbeatPosted(uint256 timestamp);
    event AnchorRotated(address indexed oldAnchor, address indexed newAnchor);

    function setUp() public {
        vm.prank(owner);
        stateAnchor = new TAGITStateAnchor(anchorKey);
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructor_setsAnchor() public view {
        assertEq(stateAnchor.anchor(), anchorKey);
        assertEq(stateAnchor.owner(), owner);
    }

    function test_constructor_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TAGITStateAnchor.ZeroAddress.selector);
        new TAGITStateAnchor(address(0));
    }

    // ──────────────────────────────────────────────
    // postStateRoot
    // ──────────────────────────────────────────────

    function test_postStateRoot_storesRoot() public {
        bytes32 root = _computeRoot(STATE_ACTIVATED, assetOwner, block.timestamp);

        vm.prank(anchorKey);
        stateAnchor.postStateRoot(TOKEN_ID, root);

        assertEq(stateAnchor.stateRoots(TOKEN_ID), root);
        assertEq(stateAnchor.lastUpdated(TOKEN_ID), block.timestamp);
    }

    function test_postStateRoot_emitsEvent() public {
        bytes32 root = _computeRoot(STATE_ACTIVATED, assetOwner, block.timestamp);

        vm.expectEmit(true, false, false, true);
        emit StateRootPosted(TOKEN_ID, root, block.timestamp);

        vm.prank(anchorKey);
        stateAnchor.postStateRoot(TOKEN_ID, root);
    }

    function test_postStateRoot_updatesHeartbeat() public {
        uint256 ts = block.timestamp + 100;
        vm.warp(ts);

        bytes32 root = _computeRoot(STATE_ACTIVATED, assetOwner, ts);
        vm.prank(anchorKey);
        stateAnchor.postStateRoot(TOKEN_ID, root);

        assertEq(stateAnchor.lastHeartbeat(), ts);
    }

    function test_postStateRoot_revertsInvalidRoot() public {
        vm.prank(anchorKey);
        vm.expectRevert(TAGITStateAnchor.InvalidRoot.selector);
        stateAnchor.postStateRoot(TOKEN_ID, bytes32(0));
    }

    function test_postStateRoot_revertsNotAnchor() public {
        bytes32 root = _computeRoot(STATE_ACTIVATED, assetOwner, block.timestamp);

        vm.prank(attacker);
        vm.expectRevert(TAGITStateAnchor.NotAnchor.selector);
        stateAnchor.postStateRoot(TOKEN_ID, root);
    }

    // ──────────────────────────────────────────────
    // verifyState
    // ──────────────────────────────────────────────

    function test_verifyState_valid() public {
        uint256 ts = block.timestamp;
        bytes32 root = _computeRoot(STATE_ACTIVATED, assetOwner, ts);

        vm.prank(anchorKey);
        stateAnchor.postStateRoot(TOKEN_ID, root);

        bool valid = stateAnchor.verifyState(TOKEN_ID, STATE_ACTIVATED, assetOwner, ts);
        assertTrue(valid);
    }

    function test_verifyState_invalid() public {
        uint256 ts = block.timestamp;
        bytes32 root = _computeRoot(STATE_ACTIVATED, assetOwner, ts);

        vm.prank(anchorKey);
        stateAnchor.postStateRoot(TOKEN_ID, root);

        // Wrong state
        bool valid = stateAnchor.verifyState(TOKEN_ID, 1, assetOwner, ts);
        assertFalse(valid);

        // Wrong owner
        valid = stateAnchor.verifyState(TOKEN_ID, STATE_ACTIVATED, attacker, ts);
        assertFalse(valid);

        // Wrong timestamp
        valid = stateAnchor.verifyState(TOKEN_ID, STATE_ACTIVATED, assetOwner, ts + 1);
        assertFalse(valid);
    }

    function test_verifyState_noRootStored() public view {
        bool valid = stateAnchor.verifyState(TOKEN_ID, STATE_ACTIVATED, assetOwner, block.timestamp);
        assertFalse(valid);
    }

    // ──────────────────────────────────────────────
    // syncAge
    // ──────────────────────────────────────────────

    function test_syncAge_neverUpdated() public view {
        uint256 age = stateAnchor.syncAge(TOKEN_ID);
        assertEq(age, type(uint256).max);
    }

    function test_syncAge_returnsElapsed() public {
        bytes32 root = _computeRoot(STATE_ACTIVATED, assetOwner, block.timestamp);
        vm.prank(anchorKey);
        stateAnchor.postStateRoot(TOKEN_ID, root);

        vm.warp(block.timestamp + 60);
        uint256 age = stateAnchor.syncAge(TOKEN_ID);
        assertEq(age, 60);
    }

    // ──────────────────────────────────────────────
    // systemSyncAge
    // ──────────────────────────────────────────────

    function test_systemSyncAge_returnsElapsed() public {
        vm.warp(block.timestamp + 300);
        uint256 age = stateAnchor.systemSyncAge();
        assertEq(age, 300);
    }

    // ──────────────────────────────────────────────
    // postHeartbeat
    // ──────────────────────────────────────────────

    function test_postHeartbeat_updatesTimestamp() public {
        uint256 ts = block.timestamp + 500;
        vm.warp(ts);

        vm.expectEmit(false, false, false, true);
        emit HeartbeatPosted(ts);

        vm.prank(anchorKey);
        stateAnchor.postHeartbeat();

        assertEq(stateAnchor.lastHeartbeat(), ts);
    }

    function test_postHeartbeat_revertsNotAnchor() public {
        vm.prank(attacker);
        vm.expectRevert(TAGITStateAnchor.NotAnchor.selector);
        stateAnchor.postHeartbeat();
    }

    // ──────────────────────────────────────────────
    // rotateAnchor
    // ──────────────────────────────────────────────

    function test_rotateAnchor_success() public {
        address newAnchor = makeAddr("newAnchor");

        vm.expectEmit(true, true, false, false);
        emit AnchorRotated(anchorKey, newAnchor);

        vm.prank(owner);
        stateAnchor.rotateAnchor(newAnchor);

        assertEq(stateAnchor.anchor(), newAnchor);
    }

    function test_rotateAnchor_revertsNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        stateAnchor.rotateAnchor(makeAddr("newAnchor"));
    }

    function test_rotateAnchor_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TAGITStateAnchor.ZeroAddress.selector);
        stateAnchor.rotateAnchor(address(0));
    }

    // ──────────────────────────────────────────────
    // Fuzz
    // ──────────────────────────────────────────────

    function testFuzz_postAndVerify(uint256 state, address assetOwnerFuzz, uint256 ts) public {
        vm.assume(assetOwnerFuzz != address(0));
        vm.assume(ts > 0 && ts < type(uint128).max);

        bytes32 root = keccak256(abi.encodePacked(state, assetOwnerFuzz, ts));
        vm.assume(root != bytes32(0));

        vm.prank(anchorKey);
        stateAnchor.postStateRoot(TOKEN_ID, root);

        assertTrue(stateAnchor.verifyState(TOKEN_ID, state, assetOwnerFuzz, ts));
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _computeRoot(uint256 state, address _owner, uint256 ts) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(state, _owner, ts));
    }
}
