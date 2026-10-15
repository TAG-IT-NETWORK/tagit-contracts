// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DPPComplianceBase} from "./DPPComplianceBase.t.sol";
import {Vm} from "@forge-std/Vm.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";

/**
 * @title DPPProvenanceIntegrity
 * @notice DPP conformance: immutable provenance/custody chain, tamper-evident metadata anchor,
 *         and terminal end-of-life.
 * @dev Covers DPP-C-04, DPP-C-05, DPP-C-06 (docs/compliance/dpp-requirements-to-tests.md §4).
 */
contract DPPProvenanceIntegrity is DPPComplianceBase {
    // Redeclared for vm.expectEmit.
    event MetadataHashUpdated(uint256 indexed tokenId, bytes32 previousHash, bytes32 newHash, address indexed updater);

    bytes32 private constant CUSTODY_SIG =
        keccak256("CustodyTransfer(uint256,uint8,uint8,address,address,uint256,bytes32)");

    // ============================================================
    // DPP-C-04 — every lifecycle transition emits an immutable, hash-linked custody record
    //            (reqs C1, C2 — ESPR traceability / NIST AU-9 chain-of-custody)
    // ============================================================
    function test_C04_everyTransitionEmitsAHashLinkedCustodyRecord() public {
        vm.recordLogs();

        // Full lifecycle, with a real ownership move on claim (consumer1 -> consumer2).
        uint256 id = _mint(consumer1, META_1);
        _bind(id, TAG_1);
        _activate(id);
        _claim(id, consumer2);
        _recycle(id);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint8[5] memory expFrom = [
            uint8(TAGITCore.State.NONE),
            uint8(TAGITCore.State.MINTED),
            uint8(TAGITCore.State.BOUND),
            uint8(TAGITCore.State.ACTIVATED),
            uint8(TAGITCore.State.CLAIMED)
        ];
        uint8[5] memory expTo = [
            uint8(TAGITCore.State.MINTED),
            uint8(TAGITCore.State.BOUND),
            uint8(TAGITCore.State.ACTIVATED),
            uint8(TAGITCore.State.CLAIMED),
            uint8(TAGITCore.State.RECYCLED)
        ];

        uint256 seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != CUSTODY_SIG) continue;

            assertEq(uint256(logs[i].topics[1]), id, "custody record must reference the twin");
            address fromOwner = address(uint160(uint256(logs[i].topics[2])));
            address toOwner = address(uint160(uint256(logs[i].topics[3])));
            (uint8 fromState, uint8 toState, uint256 ts, bytes32 prevHash) =
                abi.decode(logs[i].data, (uint8, uint8, uint256, bytes32));

            assertEq(uint256(fromState), uint256(expFrom[seen]), "custody fromState sequence");
            assertEq(uint256(toState), uint256(expTo[seen]), "custody toState sequence");
            assertTrue(prevHash != bytes32(0), "custody prevStateHash (hash-link) must be set");
            assertEq(ts, block.timestamp, "custody record must be timestamped");

            if (seen == 3) {
                // The claim transition is the ownership hand-off to the end consumer.
                assertEq(fromOwner, consumer1, "claim custody fromOwner");
                assertEq(toOwner, consumer2, "claim custody toOwner");
            }
            seen++;
        }
        assertEq(seen, 5, "exactly one custody record per lifecycle transition");
    }

    // ============================================================
    // DPP-C-05 — the metadata hash is a tamper-evident, write-restricted anchor (reqs D1, D2)
    // ============================================================
    function test_C05_metadataHashIsTheTamperEvidentAnchor() public {
        bytes memory canonical = bytes('{"name":"Acme Diver 300","gtin":"09506000134376","serial":"SN0000123"}');
        bytes memory tampered = bytes('{"name":"Acme Diver 300","gtin":"09506000134376","serial":"SN0000999"}');

        uint256 id = _mint(consumer1, keccak256(canonical));

        // The on-chain anchor is exactly keccak256(canonical passport JSON)...
        assertEq(core.metadataHash(id), keccak256(canonical), "anchor must equal the canonical hash");
        // ...so flipping a single field off-chain no longer matches the anchor (tamper detected).
        assertTrue(core.metadataHash(id) != keccak256(tampered), "any change must break the anchor");
    }

    function test_C05_anchorUpdateIsAuthorizedAndAudited() public {
        uint256 id = _mint(consumer1, META_1);
        bytes32 newHash = keccak256("ipfs://QmPassport1-v2");

        // The token owner may re-anchor (e.g. a corrected passport), and it is audited.
        vm.expectEmit(true, true, false, true, address(core));
        emit MetadataHashUpdated(id, META_1, newHash, consumer1);
        vm.prank(consumer1);
        core.updateMetadataHash(id, newHash);
        assertEq(core.metadataHash(id), newHash, "anchor must update");
    }

    function test_C05_unauthorizedCannotMoveTheAnchor() public {
        uint256 id = _mint(consumer1, META_1);

        // Precompute the capability id BEFORE pranking: a `core.*CAPABILITY()` view call placed
        // between vm.prank and the target call would consume the prank (Foundry semantics).
        uint256 capMinter = uint256(core.MINTER_CAPABILITY());

        // A random party cannot repoint the anchor (would let a counterfeit pass integrity).
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.Unauthorized.selector, stranger, capMinter));
        core.updateMetadataHash(id, keccak256("counterfeit"));

        // A zero hash is rejected — the anchor can never be blanked.
        vm.prank(consumer1);
        vm.expectRevert(TAGITCore.InvalidMetadataHash.selector);
        core.updateMetadataHash(id, bytes32(0));
    }

    // ============================================================
    // DPP-C-06 — end-of-life is terminal: a retired passport cannot be resurrected (req C3)
    // ============================================================
    function test_C06_recycleIsTerminal() public {
        uint256 id = _provisionClaimed(META_1, TAG_1);

        _recycle(id);
        (,, TAGITCore.State s,,) = core.getAsset(id);
        assertEq(uint256(s), uint256(TAGITCore.State.RECYCLED), "twin must be RECYCLED");

        // Cannot recycle again...
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, id, TAGITCore.State.RECYCLED, TAGITCore.State.CLAIMED
            )
        );
        core.recycle(id);

        // ...and cannot be flagged back into an active lifecycle.
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, id, TAGITCore.State.RECYCLED));
        core.flag(id);
    }
}
