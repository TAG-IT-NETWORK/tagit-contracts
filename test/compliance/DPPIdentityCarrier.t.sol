// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DPPComplianceBase} from "./DPPComplianceBase.t.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";

/**
 * @title DPPIdentityCarrier
 * @notice DPP conformance: unique identifier, carrier↔twin binding, and uniform passport resolution.
 * @dev Covers DPP-C-01, DPP-C-02, DPP-C-03 (docs/compliance/dpp-requirements-to-tests.md §4).
 */
contract DPPIdentityCarrier is DPPComplianceBase {
    // ============================================================
    // DPP-C-01 — unique, non-reused product identifier (req A1)
    // ============================================================
    function test_C01_identifiersAreUniqueAndSequential() public {
        uint256 id1 = _mint(consumer1, META_1);
        uint256 id2 = _mint(consumer2, META_1);
        uint256 id3 = _mint(consumer1, META_1);

        // Sequential from 1, strictly increasing — no collisions, no reuse.
        assertEq(id1, 1, "first tokenId must be 1");
        assertEq(id2, 2, "tokenIds must increment");
        assertEq(id3, 3, "tokenIds must increment");
        assertTrue(id1 != id2 && id2 != id3 && id1 != id3, "ids must be unique");

        // Supply accounting matches the number of twins in existence.
        assertEq(core.totalSupply(), 3, "totalSupply must track minted twins");

        // Each identifier resolves to exactly one owner (ERC-721 uniqueness).
        assertEq(core.ownerOf(id1), consumer1);
        assertEq(core.ownerOf(id2), consumer2);
        assertEq(core.ownerOf(id3), consumer1);
    }

    function test_C01_tokenIdZeroIsReserved() public {
        // id 0 is the "none" sentinel: unminted, no owner.
        vm.expectRevert(); // OZ ERC721NonexistentToken
        core.ownerOf(0);
        (address a,,,,) = core.getAsset(0);
        assertEq(a, address(0), "token 0 must never be an asset");
    }

    // ============================================================
    // DPP-C-02 — one physical carrier ↔ one digital twin (req A2)
    // ============================================================
    function test_C02_tagBindsBijectivelyToOneTwin() public {
        uint256 id = _mint(consumer1, META_1);

        // Before binding, the carrier maps to nothing and the twin has no carrier.
        assertEq(core.getTokenByTag(TAG_1), 0, "unbound tag must resolve to 0");
        assertEq(core.getTagByToken(id), bytes32(0), "unbound twin must have no tag");

        _bind(id, TAG_1);

        // Round-trip: tag -> twin and twin -> tag are consistent.
        assertEq(core.getTokenByTag(TAG_1), id, "tag must resolve to its twin");
        assertEq(core.getTagByToken(id), TAG_1, "twin must resolve to its tag");
    }

    function test_C02_oneTagCannotBindTwoTwins() public {
        uint256 id1 = _mint(consumer1, META_1);
        _bind(id1, TAG_1);

        // A second twin cannot claim a carrier already in use — prevents cloning one
        // physical item into two passports.
        uint256 id2 = _mint(consumer2, META_1);
        (bytes memory cr, bytes memory sig) = _oracleSign(id2, TAG_1);
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TagAlreadyBound.selector, TAG_1));
        core.bindTag(id2, TAG_1, cr, sig);

        // The first binding is untouched.
        assertEq(core.getTokenByTag(TAG_1), id1, "original binding must stand");
    }

    // ============================================================
    // DPP-C-03 — passport pointer resolves uniformly to every caller (reqs B2, E1)
    //            (regression guard for #47 — PATCH-04 caller gate retired)
    // ============================================================
    function test_C03_tokenURIResolvesUniformlyForEveryCaller() public {
        vm.prank(owner);
        core.setBaseURI("https://api.tagit.network/v1/assets/");

        uint256 id = _mint(consumer1, META_1);
        string memory expected = string.concat("https://api.tagit.network/v1/assets/", vm.toString(id));

        // The passport pointer must be the SAME for the owner, an arbitrary wallet, and an
        // indexer/explorer — public DPP fields are openly accessible (ESPR Arts. 13–14).
        vm.prank(consumer1);
        assertEq(core.tokenURI(id), expected, "owner view");
        vm.prank(stranger);
        assertEq(core.tokenURI(id), expected, "arbitrary caller view");
        vm.prank(owner);
        assertEq(core.tokenURI(id), expected, "owner (contract) view");
    }

    function test_C03_tokenURIRevertsForNonexistentTwin() public {
        vm.expectRevert(); // OZ ERC721NonexistentToken — no passport for an unminted id
        core.tokenURI(999);
    }
}
