// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title TAGITCoreRecallResaleTest
 * @notice Tests the lifecycle upgrade: flag from BOUND/ACTIVATED (recall + pre-sale theft),
 *         pre-flag-state restoration on resolve (no forward-skip), owner-preserving recovery
 *         for manufacturing-phase assets, widened recycle (scrap/void), and secondary-market
 *         resale via transferAsset().
 * @dev Mirrors the harness in TAGITCoreLifecycleGaps.t.sol.
 */
contract TAGITCoreRecallResaleTest is Test {
    TAGITCore public tagitCore;
    TAGITCore public implementation;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public manufacturer;
    address public resolver2;
    address public user1;
    address public user2;

    bytes32 public constant METADATA = keccak256("ipfs://QmTest");
    uint256 constant ORACLE_PK = 0xA11CE;

    function setUp() public {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        resolver2 = makeAddr("resolver2");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        implementation = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tagitCore = TAGITCore(address(proxy));

        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));
        vm.prank(owner);
        tagitCore.setTrustedOracle(vm.addr(ORACLE_PK));

        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RECYCLER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _oracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        view
        returns (bytes memory challengeResponse, bytes memory oracleSignature)
    {
        challengeResponse = abi.encodePacked("challenge", tokenId);
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, ethHash);
        oracleSignature = abi.encodePacked(r, s, v);
    }

    function _mintToBound() internal returns (uint256 tokenId) {
        vm.startPrank(manufacturer);
        tokenId = tagitCore.mint(user1, METADATA);
        bytes32 tagHash = keccak256(abi.encodePacked("NFC_", tokenId));
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);
        vm.stopPrank();
    }

    function _mintToActivated() internal returns (uint256 tokenId) {
        tokenId = _mintToBound();
        vm.prank(manufacturer);
        tagitCore.activate(tokenId);
    }

    function _mintToClaimed() internal returns (uint256 tokenId) {
        tokenId = _mintToActivated();
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, user1);
    }

    /// @dev 2-of-3 approve then resolve to `newOwner`.
    function _resolveTo(uint256 tokenId, address newOwner) internal {
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, newOwner);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, newOwner);
        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, newOwner);
    }

    function _state(uint256 tokenId) internal view returns (TAGITCore.State s) {
        (,, s,,) = tagitCore.getAsset(tokenId);
    }

    // ── A. flag() valid-from set ──────────────────────────────────────────────

    function test_flag_fromBound_succeeds() public {
        uint256 tokenId = _mintToBound();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.FLAGGED), "BOUND -> FLAGGED");
    }

    function test_flag_fromActivated_succeeds() public {
        uint256 tokenId = _mintToActivated();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.FLAGGED), "ACTIVATED -> FLAGGED");
    }

    function test_flag_fromClaimed_succeeds() public {
        uint256 tokenId = _mintToClaimed();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.FLAGGED), "CLAIMED -> FLAGGED (regression)");
    }

    function test_flag_fromMinted_reverts() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA);
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, tokenId, TAGITCore.State.MINTED));
        tagitCore.flag(tokenId);
    }

    function test_flag_fromFlagged_reverts() public {
        uint256 tokenId = _mintToClaimed();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, tokenId, TAGITCore.State.FLAGGED));
        tagitCore.flag(tokenId);
    }

    // ── B. resolve() restores the EXACT pre-flag state (no forward-skip) ───────

    function test_resolve_restoresBound_ownerUnchanged() public {
        uint256 tokenId = _mintToBound();
        address ownerBefore = tagitCore.ownerOf(tokenId);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        _resolveTo(tokenId, ownerBefore); // manufacturing-phase: must return to current owner
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.BOUND), "restored to BOUND");
        assertEq(tagitCore.ownerOf(tokenId), ownerBefore, "owner unchanged on recall recovery");
    }

    function test_resolve_restoresActivated_ownerUnchanged() public {
        uint256 tokenId = _mintToActivated();
        address ownerBefore = tagitCore.ownerOf(tokenId);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        _resolveTo(tokenId, ownerBefore);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.ACTIVATED), "restored to ACTIVATED");
        assertEq(tagitCore.ownerOf(tokenId), ownerBefore, "owner unchanged");
    }

    function test_resolve_restoresClaimed_reassignsOwner() public {
        uint256 tokenId = _mintToClaimed();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        _resolveTo(tokenId, user2); // consumer recovery: reassign to rightful owner
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.CLAIMED), "restored to CLAIMED");
        assertEq(tagitCore.ownerOf(tokenId), user2, "owner reassigned to approved recipient");
    }

    /// THE critical property: flag+resolve can never be used to skip a forward transition.
    function test_resolve_noForwardSkip_fromActivated() public {
        uint256 tokenId = _mintToActivated();
        address ownerBefore = tagitCore.ownerOf(tokenId);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        _resolveTo(tokenId, ownerBefore);
        // Must be ACTIVATED, NOT CLAIMED — proves no bypass of claim()
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.ACTIVATED), "no teleport to CLAIMED");
    }

    /// Manufacturing-phase recovery cannot be redirected to an arbitrary address.
    function test_resolve_nonClaimed_rejectsOwnerRedirect() public {
        uint256 tokenId = _mintToActivated();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, user2); // attempt to redirect to user2 (not the owner)
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, user2);
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.RecipientMismatch.selector, tokenId, user1, user2));
        tagitCore.resolve(tokenId, user2);
    }

    // ── C. recycle() widened (scrap / void) ───────────────────────────────────

    function test_recycle_fromMinted_void() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA);
        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.RECYCLED), "MINTED voided");
    }

    function test_recycle_fromBound_scrap() public {
        uint256 tokenId = _mintToBound();
        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.RECYCLED), "BOUND scrapped");
    }

    function test_recycle_fromActivated_scrap() public {
        uint256 tokenId = _mintToActivated();
        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.RECYCLED), "ACTIVATED scrapped");
    }

    function test_recycle_fromFlagged_thatWasBound() public {
        uint256 tokenId = _mintToBound();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.RECYCLED), "FLAGGED(BOUND) recycled");
    }

    function test_recycle_fromRecycled_reverts() public {
        uint256 tokenId = _mintToBound();
        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.RECYCLED, TAGITCore.State.CLAIMED
            )
        );
        tagitCore.recycle(tokenId);
    }

    // ── D. transferAsset() secondary-market resale ────────────────────────────

    function test_transferAsset_succeeds() public {
        uint256 tokenId = _mintToClaimed();
        assertEq(tagitCore.ownerOf(tokenId), user1, "initial owner");
        vm.prank(user1);
        tagitCore.transferAsset(tokenId, user2);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.CLAIMED), "stays CLAIMED");
        assertEq(tagitCore.ownerOf(tokenId), user2, "resold to user2");
    }

    function test_transferAsset_emitsAssetResold() public {
        uint256 tokenId = _mintToClaimed();
        vm.expectEmit(true, true, true, false);
        emit TAGITCore.AssetResold(tokenId, user1, user2);
        vm.prank(user1);
        tagitCore.transferAsset(tokenId, user2);
    }

    function test_transferAsset_onlyOwner_reverts() public {
        uint256 tokenId = _mintToClaimed();
        vm.prank(user2); // not the owner
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotAssetOwner.selector, tokenId, user2, user1));
        tagitCore.transferAsset(tokenId, user2);
    }

    function test_transferAsset_notClaimed_reverts() public {
        uint256 tokenId = _mintToBound();
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.BOUND, TAGITCore.State.CLAIMED
            )
        );
        tagitCore.transferAsset(tokenId, user2);
    }

    function test_transferAsset_zeroAddress_reverts() public {
        uint256 tokenId = _mintToClaimed();
        vm.prank(user1);
        vm.expectRevert(TAGITCore.ZeroAddress.selector);
        tagitCore.transferAsset(tokenId, address(0));
    }

    function test_transferAsset_self_reverts() public {
        uint256 tokenId = _mintToClaimed();
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidTransition.selector, TAGITCore.State.CLAIMED, TAGITCore.State.CLAIMED
            )
        );
        tagitCore.transferAsset(tokenId, user1);
    }

    function test_transferAsset_thenStillFlaggable() public {
        uint256 tokenId = _mintToClaimed();
        vm.prank(user1);
        tagitCore.transferAsset(tokenId, user2);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId); // resold asset can still be flagged
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.FLAGGED), "resold asset flaggable");
    }

    // ── E. capability gating still enforced ────────────────────────────────────

    function test_flag_fromBound_requiresCapability() public {
        uint256 tokenId = _mintToBound();
        vm.prank(user2); // no FLAGGER capability
        vm.expectRevert();
        tagitCore.flag(tokenId);
    }

    // ── F. re-flag cycle (idempotent pre-flag marker) ──────────────────────────

    function test_reflag_afterResolve_restoresAgain() public {
        uint256 tokenId = _mintToActivated();
        address o = tagitCore.ownerOf(tokenId);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        _resolveTo(tokenId, o);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.ACTIVATED), "1st restore");
        // flag + resolve again
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        _resolveTo(tokenId, o);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.ACTIVATED), "2nd restore (idempotent)");
    }

    // ── G. events carry the real from-state ────────────────────────────────────

    function test_flag_fromBound_emitsBoundFrom() public {
        uint256 tokenId = _mintToBound();
        vm.expectEmit(true, false, false, true);
        emit TAGITCore.StateChanged(tokenId, TAGITCore.State.BOUND, TAGITCore.State.FLAGGED, manufacturer);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
    }

    // ── H. fuzz: flag+resolve round-trip preserves (state, owner) ──────────────

    function testFuzz_flagResolve_roundTrip(uint8 stage) public {
        stage = uint8(bound(stage, 0, 2)); // 0=BOUND, 1=ACTIVATED, 2=CLAIMED
        uint256 tokenId;
        if (stage == 0) tokenId = _mintToBound();
        else if (stage == 1) tokenId = _mintToActivated();
        else tokenId = _mintToClaimed();

        TAGITCore.State before = _state(tokenId);
        address ownerBefore = tagitCore.ownerOf(tokenId);

        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
        assertEq(uint8(_state(tokenId)), uint8(TAGITCore.State.FLAGGED), "flagged");

        _resolveTo(tokenId, ownerBefore); // resolve back to the same owner (valid for all stages)

        assertEq(uint8(_state(tokenId)), uint8(before), "state round-trips exactly");
        assertEq(tagitCore.ownerOf(tokenId), ownerBefore, "owner round-trips exactly");
    }
}
