// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DPPComplianceBase} from "./DPPComplianceBase.t.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {ITAGITAccess} from "../../src/interfaces/ITAGITAccess.sol";

/**
 * @title DPPAccessDataProtection
 * @notice DPP conformance: operator write-authorisation, on-chain data minimisation (GDPR),
 *         and the product token being bound to the good rather than a freely tradable asset.
 * @dev Covers DPP-C-07, DPP-C-08, DPP-C-09 (docs/compliance/dpp-requirements-to-tests.md §4).
 */
contract DPPAccessDataProtection is DPPComplianceBase {
    // ============================================================
    // DPP-C-07 — only authorised economic operators can write the passport (req H1)
    // ============================================================
    function test_C07_passportWritesRequireCapabilities() public {
        // Precompute capability ids BEFORE pranking. A `core.*CAPABILITY()` view call sitting
        // between vm.prank and the target call would consume the prank (Foundry semantics), so
        // the reverting call would run as the test contract instead of `stranger`.
        uint256 capMinter = uint256(core.MINTER_CAPABILITY());
        uint256 capBinder = uint256(core.BINDER_CAPABILITY());
        uint256 capActivator = uint256(core.ACTIVATOR_CAPABILITY());
        uint256 capClaimer = uint256(core.CLAIMER_CAPABILITY());
        uint256 capFlagger = uint256(core.FLAGGER_CAPABILITY());
        uint256 capRecycler = uint256(core.RECYCLER_CAPABILITY());

        // MINT — a wallet with no capability is rejected by the access controller.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingCapability.selector, stranger, capMinter));
        core.mint(consumer1, META_1);

        uint256 id = _mint(consumer1, META_1); // authorised path works

        // BIND — capability is checked before the oracle signature, so a dummy sig is fine.
        (bytes memory cr, bytes memory sig) = _oracleSign(id, TAG_1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingCapability.selector, stranger, capBinder));
        core.bindTag(id, TAG_1, cr, sig);
        _bind(id, TAG_1);

        // ACTIVATE
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingCapability.selector, stranger, capActivator));
        core.activate(id);
        _activate(id);

        // CLAIM
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingCapability.selector, stranger, capClaimer));
        core.claim(id, consumer1);

        // FLAG
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingCapability.selector, stranger, capFlagger));
        core.flag(id);

        // RECYCLE
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccess.MissingCapability.selector, stranger, capRecycler));
        core.recycle(id);
    }

    // ============================================================
    // DPP-C-08 — no personal data on-chain; identity minimised (reqs G1, G2, G3)
    //            NOTE: proves the on-chain half of GDPR minimisation only. Off-chain erasure
    //            and the PII-key block (`scanForbiddenKeys`) are a tagit-services concern.
    // ============================================================
    function test_C08_noPersonalDataIsStoredOnChain() public {
        bytes memory passport = bytes('{"name":"Acme Diver 300","serial":"SN0000123"}');
        uint256 id = _mint(consumer1, keccak256(passport));

        // Only a 32-byte hash of the passport is anchored — never the content. There is nothing
        // personal on-chain to erase under GDPR Art. 17; human-readable data stays off-chain.
        assertEq(core.metadataHash(id), keccak256(passport), "only the hash is anchored on-chain");

        // The on-chain asset record is minimal: a pseudonymous wallet address, a timestamp, a
        // lifecycle state and reserved flags — no name/email/address/owner-name fields exist.
        (address assetOwner, uint64 ts, TAGITCore.State s, uint8 flags, uint16 reserved) = core.getAsset(id);
        assertEq(assetOwner, consumer1, "owner identity is a bare wallet address");
        assertEq(core.ownerOf(id), consumer1, "ERC-721 owner matches the asset record");
        assertGt(ts, 0, "only a timestamp is recorded");
        assertEq(uint256(s), uint256(TAGITCore.State.MINTED));
        assertEq(uint256(flags), 0);
        assertEq(uint256(reserved), 0);
    }

    // ============================================================
    // DPP-C-09 — the token is soulbound to the physical good, not a freely tradable asset (req I1)
    // ============================================================
    function test_C09_tokenIsSoulboundToTheGood() public {
        uint256 id = _provisionClaimed(META_1, TAG_1); // consumer1 owns it, state CLAIMED

        // Holder-initiated ERC-721 transfers are disabled.
        vm.prank(consumer1);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        core.transferFrom(consumer1, stranger, id);

        vm.prank(consumer1);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        core.safeTransferFrom(consumer1, stranger, id);

        // Even a granted operator approval cannot move it.
        vm.prank(consumer1);
        core.approve(stranger, id);
        vm.prank(stranger);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        core.transferFrom(consumer1, stranger, id);

        assertEq(core.ownerOf(id), consumer1, "token must not be transferable off the good");
    }

    function test_C09_ownershipMovesOnlyThroughSanctionedResale() public {
        uint256 id = _provisionClaimed(META_1, TAG_1); // consumer1 owns it, CLAIMED

        // The sanctioned owner-gated resale path moves ownership and keeps lifecycle state.
        vm.prank(consumer1);
        core.transferAsset(id, consumer2);
        assertEq(core.ownerOf(id), consumer2, "resale transfers ownership");
        (,, TAGITCore.State s,,) = core.getAsset(id);
        assertEq(uint256(s), uint256(TAGITCore.State.CLAIMED), "resale keeps the CLAIMED state");

        // A non-owner cannot force a resale.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotAssetOwner.selector, id, stranger, consumer2));
        core.transferAsset(id, stranger);
    }
}
