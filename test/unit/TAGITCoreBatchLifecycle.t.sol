// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {CircuitBreaker} from "../../src/libraries/CircuitBreaker.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title TAGITCoreBatchLifecycleTest
 * @notice Tests for the batch lifecycle functions: batchBind, batchActivate, batchFlag
 * @dev Mirrors the harness in TAGITCoreRecallResale.t.sol / TAGITCoreOracleVerification.t.sol.
 *      Covers: success paths (N=1 / N=3 / N=MAX_BATCH_SIZE), all revert paths, atomicity,
 *      oracle batch-digest domain separation + replay protection, per-item circuit breaker
 *      accounting for batchFlag, and a batch-vs-singles gas sanity comparison.
 */
contract TAGITCoreBatchLifecycleTest is Test {
    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public manufacturer;
    address public resolver2;
    address public user1;
    address public user2;

    bytes32 public constant METADATA = keccak256("ipfs://QmBatchTest");

    uint256 constant ORACLE_PK = 0xA11CE;
    uint256 constant WRONG_ORACLE_PK = 0xBAD;
    address public oracle;

    // Events (redeclare for testing)
    event StateChanged(uint256 indexed tokenId, TAGITCore.State from, TAGITCore.State to, address actor);
    event TagBound(uint256 indexed tokenId, bytes32 indexed tagHash);

    function setUp() public {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        resolver2 = makeAddr("resolver2");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        oracle = vm.addr(ORACLE_PK);

        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        TAGITCore implementation = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tagitCore = TAGITCore(address(proxy));

        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));
        vm.prank(owner);
        tagitCore.setTrustedOracle(oracle);

        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RECYCLER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));
    }

    // ============================================
    // HELPERS
    // ============================================

    function _state(uint256 tokenId) internal view returns (TAGITCore.State s) {
        (,, s,,) = tagitCore.getAsset(tokenId);
    }

    /// @dev Deterministic non-zero tag hash per token (unique across a test).
    function _tagFor(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("NFC_", tokenId));
    }

    /// @dev Deterministic challenge response per token.
    function _responseFor(uint256 tokenId) internal pure returns (bytes memory) {
        return abi.encodePacked("challenge", tokenId);
    }

    /// @dev Batch-mint `n` assets to user1 (all in MINTED state).
    function _mintN(uint256 n) internal returns (uint256[] memory tokenIds) {
        address[] memory recipients = new address[](n);
        bytes32[] memory metadata = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            recipients[i] = user1;
            metadata[i] = keccak256(abi.encodePacked("meta", i));
        }
        vm.prank(manufacturer);
        tokenIds = tagitCore.batchMint(recipients, metadata);
    }

    /// @dev Build default (tagHashes, challengeResponses) arrays for a set of tokens.
    function _defaultBatchInputs(uint256[] memory tokenIds)
        internal
        pure
        returns (bytes32[] memory tagHashes, bytes[] memory challengeResponses)
    {
        tagHashes = new bytes32[](tokenIds.length);
        challengeResponses = new bytes[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            tagHashes[i] = _tagFor(tokenIds[i]);
            challengeResponses[i] = _responseFor(tokenIds[i]);
        }
    }

    /// @dev Sign the batch bind digest with an arbitrary key.
    ///      Digest: keccak256(abi.encode(BATCH_BIND_DOMAIN, block.chainid, address(core),
    ///      tokenIds, tagHashes, responseHashes)) where responseHashes[i] = keccak256(responses[i]).
    function _batchSignWith(
        uint256 pk,
        uint256[] memory tokenIds,
        bytes32[] memory tagHashes,
        bytes[] memory challengeResponses
    ) internal view returns (bytes memory oracleSignature) {
        bytes32[] memory responseHashes = new bytes32[](challengeResponses.length);
        for (uint256 i = 0; i < challengeResponses.length; i++) {
            responseHashes[i] = keccak256(challengeResponses[i]);
        }
        bytes32 messageHash = keccak256(
            abi.encode(
                tagitCore.BATCH_BIND_DOMAIN(), block.chainid, address(tagitCore), tokenIds, tagHashes, responseHashes
            )
        );
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        oracleSignature = abi.encodePacked(r, s, v);
    }

    /// @dev Sign the batch bind digest with the trusted oracle key.
    function _batchSign(uint256[] memory tokenIds, bytes32[] memory tagHashes, bytes[] memory challengeResponses)
        internal
        view
        returns (bytes memory)
    {
        return _batchSignWith(ORACLE_PK, tokenIds, tagHashes, challengeResponses);
    }

    /// @dev Batch-mint `n` assets and bind them all via batchBind. Returns (ids, tags).
    function _boundBatch(uint256 n) internal returns (uint256[] memory tokenIds, bytes32[] memory tagHashes) {
        tokenIds = _mintN(n);
        bytes[] memory challengeResponses;
        (tagHashes, challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);
        vm.prank(manufacturer);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    /// @dev Batch-mint, bind, and activate `n` assets.
    function _activatedBatch(uint256 n) internal returns (uint256[] memory tokenIds) {
        (tokenIds,) = _boundBatch(n);
        vm.prank(manufacturer);
        tagitCore.batchActivate(tokenIds);
    }

    /// @dev Single-token oracle signature for single bindTag (mirrors OracleVerification harness).
    function _oracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        pure
        returns (bytes memory challengeResponse, bytes memory oracleSignature)
    {
        challengeResponse = _responseFor(tokenId);
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, ethHash);
        oracleSignature = abi.encodePacked(r, s, v);
    }

    /// @dev Single-token lifecycle helpers (use single-item functions, not the batch under test).
    function _mintToBound() internal returns (uint256 tokenId) {
        vm.startPrank(manufacturer);
        tokenId = tagitCore.mint(user1, METADATA);
        bytes32 tagHash = _tagFor(tokenId);
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
        tagitCore.claim(tokenId, user2);
    }

    /// @dev 2-of-3 approve then resolve to `newOwner` (used to verify _preFlagState round-trip).
    function _resolveTo(uint256 tokenId, address newOwner) internal {
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, newOwner);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, newOwner);
        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, newOwner);
    }

    // ============================================
    // CONSTANTS
    // ============================================

    function test_batchBindDomainConstant() public view {
        assertEq(
            tagitCore.BATCH_BIND_DOMAIN(), keccak256("TAGIT_BATCH_BIND_V1"), "BATCH_BIND_DOMAIN should be pinned to V1"
        );
        assertEq(tagitCore.MAX_BATCH_SIZE(), 100, "MAX_BATCH_SIZE should be 100");
    }

    // ============================================
    // batchBind — SUCCESS CASES
    // ============================================

    function test_batchBind_success_singleItem() public {
        uint256[] memory tokenIds = _mintN(1);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.expectEmit(true, true, false, true);
        emit TagBound(tokenIds[0], tagHashes[0]);
        vm.expectEmit(true, false, false, true);
        emit StateChanged(tokenIds[0], TAGITCore.State.MINTED, TAGITCore.State.BOUND, manufacturer);

        vm.prank(manufacturer);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);

        assertEq(uint8(_state(tokenIds[0])), uint8(TAGITCore.State.BOUND), "State should be BOUND");
        assertEq(tagitCore.getTokenByTag(tagHashes[0]), tokenIds[0], "Tag should map to token");
        assertEq(tagitCore.getTagByToken(tokenIds[0]), tagHashes[0], "Token should map to tag");
    }

    function test_batchBind_success_threeItems() public {
        uint256[] memory tokenIds = _mintN(3);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        // TagBound + StateChanged emitted per token, in batch order
        for (uint256 i = 0; i < 3; i++) {
            vm.expectEmit(true, true, false, true);
            emit TagBound(tokenIds[i], tagHashes[i]);
            vm.expectEmit(true, false, false, true);
            emit StateChanged(tokenIds[i], TAGITCore.State.MINTED, TAGITCore.State.BOUND, manufacturer);
        }

        vm.prank(manufacturer);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.BOUND), "Each state should be BOUND");
            assertEq(tagitCore.getTokenByTag(tagHashes[i]), tokenIds[i], "Tag should map to token");
            assertEq(tagitCore.getTagByToken(tokenIds[i]), tagHashes[i], "Token should map to tag");
        }
    }

    function test_batchBind_success_maxBatchSize() public {
        uint256 n = tagitCore.MAX_BATCH_SIZE();
        uint256[] memory tokenIds = _mintN(n);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);

        assertEq(tagitCore.totalSupply(), n, "Total supply should equal batch size");
        for (uint256 i = 0; i < n; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.BOUND), "Each state should be BOUND");
            assertEq(tagitCore.getTokenByTag(tagHashes[i]), tokenIds[i], "Tag should map to token");
            assertEq(tagitCore.getTagByToken(tokenIds[i]), tagHashes[i], "Token should map to tag");
        }
    }

    // ============================================
    // batchBind — REVERT CASES (batch-level checks)
    // ============================================

    function test_batchBind_revert_emptyBatch() public {
        uint256[] memory tokenIds = new uint256[](0);
        bytes32[] memory tagHashes = new bytes32[](0);
        bytes[] memory challengeResponses = new bytes[](0);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.EmptyBatch.selector);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, hex"");
    }

    function test_batchBind_revert_batchTooLarge() public {
        // Size check fires before any signature/token validation — garbage inputs suffice
        uint256 oversized = 101;
        uint256[] memory tokenIds = new uint256[](oversized);
        bytes32[] memory tagHashes = new bytes32[](oversized);
        bytes[] memory challengeResponses = new bytes[](oversized);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.BatchTooLarge.selector, 101, 100));
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, hex"");
    }

    function test_batchBind_revert_arrayLengthMismatch_tagHashesShorter() public {
        uint256[] memory tokenIds = _mintN(3);
        bytes32[] memory tagHashes = new bytes32[](2);
        bytes[] memory challengeResponses = new bytes[](3);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.ArrayLengthMismatch.selector, 3, 2));
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, hex"");
    }

    function test_batchBind_revert_arrayLengthMismatch_challengeResponsesShorter() public {
        uint256[] memory tokenIds = _mintN(3);
        bytes32[] memory tagHashes = new bytes32[](3);
        bytes[] memory challengeResponses = new bytes[](2);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.ArrayLengthMismatch.selector, 3, 2));
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, hex"");
    }

    // ============================================
    // batchBind — REVERT CASES (oracle signature)
    // ============================================

    function test_batchBind_revert_invalidOracleSignature_wrongSigner() public {
        uint256[] memory tokenIds = _mintN(2);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSignWith(WRONG_ORACLE_PK, tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_invalidOracleSignature_tamperedTagHash() public {
        uint256[] memory tokenIds = _mintN(3);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        // Swap one tag hash AFTER signing — valid signature over a different batch
        tagHashes[1] = keccak256("SWAPPED_TAG");

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_invalidOracleSignature_tamperedChallengeResponse() public {
        uint256[] memory tokenIds = _mintN(2);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        challengeResponses[0] = abi.encodePacked("tampered-challenge");

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_invalidOracleSignature_reorderedArrays() public {
        uint256[] memory tokenIds = _mintN(2);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        // Reorder all three arrays consistently AFTER signing — items are still
        // individually valid, but the batch encoding (and thus digest) differs
        (tokenIds[0], tokenIds[1]) = (tokenIds[1], tokenIds[0]);
        (tagHashes[0], tagHashes[1]) = (tagHashes[1], tagHashes[0]);
        (challengeResponses[0], challengeResponses[1]) = (challengeResponses[1], challengeResponses[0]);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_oracleNotSet() public {
        // Deploy fresh core without oracle set
        TAGITCore impl2 = new TAGITCore();
        bytes memory initData2 = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData2);
        TAGITCore core2 = TAGITCore(address(proxy2));

        vm.prank(owner);
        core2.setAccessController(address(tagitAccess));
        // NOTE: NOT setting trusted oracle

        address[] memory recipients = new address[](1);
        bytes32[] memory metadata = new bytes32[](1);
        recipients[0] = user1;
        metadata[0] = METADATA;
        vm.prank(manufacturer);
        uint256[] memory tokenIds = core2.batchMint(recipients, metadata);

        bytes32[] memory tagHashes = new bytes32[](1);
        bytes[] memory challengeResponses = new bytes[](1);
        tagHashes[0] = _tagFor(tokenIds[0]);
        challengeResponses[0] = _responseFor(tokenIds[0]);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.OracleNotSet.selector);
        core2.batchBind(tokenIds, tagHashes, challengeResponses, hex"");
    }

    // ============================================
    // batchBind — REVERT CASES (per-item checks)
    // ============================================

    function test_batchBind_revert_tokenNotFound() public {
        uint256[] memory minted = _mintN(1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = minted[0];
        tokenIds[1] = 999; // never minted
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TokenNotFound.selector, 999));
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_invalidState_alreadyBoundItem() public {
        uint256 boundToken = _mintToBound();
        uint256[] memory minted = _mintN(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = minted[0];
        tokenIds[1] = boundToken; // already BOUND
        bytes32[] memory tagHashes = new bytes32[](2);
        tagHashes[0] = _tagFor(minted[0]);
        tagHashes[1] = keccak256("FRESH_TAG_FOR_BOUND_TOKEN");
        bytes[] memory challengeResponses = new bytes[](2);
        challengeResponses[0] = _responseFor(tokenIds[0]);
        challengeResponses[1] = _responseFor(tokenIds[1]);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, boundToken, TAGITCore.State.BOUND, TAGITCore.State.MINTED
            )
        );
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_invalidTagHash_zeroHashItem() public {
        uint256[] memory tokenIds = _mintN(2);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        tagHashes[1] = bytes32(0);
        // Sign over the zero hash so the signature itself is valid — the item check must fire
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidTagHash.selector);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_tagAlreadyBound_inStorage() public {
        uint256 boundToken = _mintToBound(); // binds _tagFor(boundToken)
        uint256[] memory tokenIds = _mintN(1);
        bytes32[] memory tagHashes = new bytes32[](1);
        tagHashes[0] = _tagFor(boundToken); // already bound to another asset
        bytes[] memory challengeResponses = new bytes[](1);
        challengeResponses[0] = _responseFor(tokenIds[0]);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TagAlreadyBound.selector, _tagFor(boundToken)));
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_tagAlreadyBound_duplicateWithinBatch() public {
        uint256[] memory tokenIds = _mintN(2);
        bytes32 dupTag = keccak256("DUP_TAG_IN_BATCH");
        bytes32[] memory tagHashes = new bytes32[](2);
        tagHashes[0] = dupTag;
        tagHashes[1] = dupTag; // duplicate within the same batch
        bytes[] memory challengeResponses = new bytes[](2);
        challengeResponses[0] = _responseFor(tokenIds[0]);
        challengeResponses[1] = _responseFor(tokenIds[1]);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TagAlreadyBound.selector, dupTag));
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_duplicateTokenIdWithinBatch() public {
        uint256[] memory minted = _mintN(1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = minted[0];
        tokenIds[1] = minted[0]; // duplicate token
        bytes32[] memory tagHashes = new bytes32[](2);
        tagHashes[0] = keccak256("DUP_TOKEN_TAG_A");
        tagHashes[1] = keccak256("DUP_TOKEN_TAG_B");
        bytes[] memory challengeResponses = new bytes[](2);
        challengeResponses[0] = _responseFor(tokenIds[0]);
        challengeResponses[1] = _responseFor(tokenIds[1]);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        // Second occurrence is no longer MINTED (bound by the first) → InvalidState
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, minted[0], TAGITCore.State.BOUND, TAGITCore.State.MINTED
            )
        );
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    function test_batchBind_revert_unauthorized() public {
        uint256[] memory tokenIds = _mintN(1);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(user2); // no BINDER capability
        vm.expectRevert();
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    // ============================================
    // batchBind — ATOMICITY + REPLAY
    // ============================================

    function test_batchBind_atomicity_invalidItemRevertsWholeBatch() public {
        uint256[] memory tokenIds = _mintN(5);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        tagHashes[2] = bytes32(0); // item 3 of 5 invalid
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidTagHash.selector);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);

        // Items 1-2 (processed before the invalid item) must be fully rolled back
        for (uint256 i = 0; i < 2; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.MINTED), "Item should remain MINTED");
            assertEq(tagitCore.getTagByToken(tokenIds[i]), bytes32(0), "Token should have no tag");
            assertEq(tagitCore.getTokenByTag(tagHashes[i]), 0, "Tag should map to nothing");
        }
    }

    function test_batchBind_replay_sameSignatureCannotRebind() public {
        uint256[] memory tokenIds = _mintN(3);
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(tokenIds);
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);

        // Replaying the exact same call fails: items are no longer MINTED
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenIds[0], TAGITCore.State.BOUND, TAGITCore.State.MINTED
            )
        );
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);
    }

    // ============================================
    // batchBind — FUZZ
    // ============================================

    /// @dev Repo default is 100K fuzz runs (SEC-005); each run here mints and binds up to
    ///      MAX_BATCH_SIZE tokens (~25M gas per run), so the global default is computationally
    ///      infeasible for batch fuzz. 10K runs (the pre-SEC-005 standard) still exercises
    ///      ~500K per-item bindings across the full 1..100 size range.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_batchBind(uint256 seed, uint256 size) public {
        size = bound(size, 1, tagitCore.MAX_BATCH_SIZE());
        uint256[] memory tokenIds = _mintN(size);

        // Derive unique non-zero tag UID hashes from the bound seed
        bytes32[] memory tagHashes = new bytes32[](size);
        bytes[] memory challengeResponses = new bytes[](size);
        for (uint256 i = 0; i < size; i++) {
            tagHashes[i] = keccak256(abi.encodePacked("UID", seed, i));
            challengeResponses[i] = abi.encodePacked("resp", seed, i);
        }
        bytes memory sig = _batchSign(tokenIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        tagitCore.batchBind(tokenIds, tagHashes, challengeResponses, sig);

        for (uint256 i = 0; i < size; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.BOUND), "Each item should be BOUND");
            assertEq(tagitCore.getTokenByTag(tagHashes[i]), tokenIds[i], "Tag should map to token");
            assertEq(tagitCore.getTagByToken(tokenIds[i]), tagHashes[i], "Token should map to tag");
        }
    }

    // ============================================
    // batchActivate — SUCCESS CASES
    // ============================================

    function test_batchActivate_success_singleItem() public {
        (uint256[] memory tokenIds,) = _boundBatch(1);

        vm.expectEmit(true, false, false, true);
        emit StateChanged(tokenIds[0], TAGITCore.State.BOUND, TAGITCore.State.ACTIVATED, manufacturer);

        vm.prank(manufacturer);
        tagitCore.batchActivate(tokenIds);

        assertEq(uint8(_state(tokenIds[0])), uint8(TAGITCore.State.ACTIVATED), "State should be ACTIVATED");
    }

    function test_batchActivate_success_maxBatchSize() public {
        uint256 n = tagitCore.MAX_BATCH_SIZE();
        (uint256[] memory tokenIds,) = _boundBatch(n);

        vm.prank(manufacturer);
        tagitCore.batchActivate(tokenIds);

        for (uint256 i = 0; i < n; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.ACTIVATED), "Each state should be ACTIVATED");
        }
    }

    function test_batchActivate_success_emitsEventPerToken() public {
        (uint256[] memory tokenIds,) = _boundBatch(3);

        for (uint256 i = 0; i < 3; i++) {
            vm.expectEmit(true, false, false, true);
            emit StateChanged(tokenIds[i], TAGITCore.State.BOUND, TAGITCore.State.ACTIVATED, manufacturer);
        }

        vm.prank(manufacturer);
        tagitCore.batchActivate(tokenIds);
    }

    // ============================================
    // batchActivate — REVERT CASES
    // ============================================

    function test_batchActivate_revert_emptyBatch() public {
        uint256[] memory tokenIds = new uint256[](0);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.EmptyBatch.selector);
        tagitCore.batchActivate(tokenIds);
    }

    function test_batchActivate_revert_batchTooLarge() public {
        uint256[] memory tokenIds = new uint256[](101);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.BatchTooLarge.selector, 101, 100));
        tagitCore.batchActivate(tokenIds);
    }

    function test_batchActivate_revert_tokenNotFound() public {
        (uint256[] memory bound,) = _boundBatch(1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = bound[0];
        tokenIds[1] = 999; // never minted

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TokenNotFound.selector, 999));
        tagitCore.batchActivate(tokenIds);
    }

    function test_batchActivate_revert_invalidState_mintedItem() public {
        uint256[] memory tokenIds = _mintN(1); // MINTED, never bound

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenIds[0], TAGITCore.State.MINTED, TAGITCore.State.BOUND
            )
        );
        tagitCore.batchActivate(tokenIds);
    }

    function test_batchActivate_revert_invalidState_claimedItem() public {
        uint256 claimedToken = _mintToClaimed();
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = claimedToken;

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, claimedToken, TAGITCore.State.CLAIMED, TAGITCore.State.BOUND
            )
        );
        tagitCore.batchActivate(tokenIds);
    }

    function test_batchActivate_revert_duplicateTokenIdWithinBatch() public {
        (uint256[] memory bound,) = _boundBatch(1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = bound[0];
        tokenIds[1] = bound[0]; // duplicate — second occurrence already ACTIVATED

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, bound[0], TAGITCore.State.ACTIVATED, TAGITCore.State.BOUND
            )
        );
        tagitCore.batchActivate(tokenIds);
    }

    function test_batchActivate_revert_unauthorized() public {
        (uint256[] memory tokenIds,) = _boundBatch(1);

        vm.prank(user2); // no ACTIVATOR capability
        vm.expectRevert();
        tagitCore.batchActivate(tokenIds);
    }

    function test_batchActivate_atomicity_invalidItemRevertsWholeBatch() public {
        // 4 BOUND tokens + 1 MINTED token spliced in as item 3 of 5
        (uint256[] memory bound,) = _boundBatch(4);
        uint256[] memory mintedOnly = _mintN(1);

        uint256[] memory tokenIds = new uint256[](5);
        tokenIds[0] = bound[0];
        tokenIds[1] = bound[1];
        tokenIds[2] = mintedOnly[0]; // invalid: MINTED, not BOUND
        tokenIds[3] = bound[2];
        tokenIds[4] = bound[3];

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, mintedOnly[0], TAGITCore.State.MINTED, TAGITCore.State.BOUND
            )
        );
        tagitCore.batchActivate(tokenIds);

        // Items 1-2 (processed before the invalid item) must be rolled back to BOUND
        assertEq(uint8(_state(bound[0])), uint8(TAGITCore.State.BOUND), "Item 1 should remain BOUND");
        assertEq(uint8(_state(bound[1])), uint8(TAGITCore.State.BOUND), "Item 2 should remain BOUND");
    }

    // ============================================
    // batchActivate — FUZZ
    // ============================================

    /// @dev See testFuzz_batchBind for the runs-override rationale (up to 100 mint+bind+activate per run).
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_batchActivate(uint256 size) public {
        size = bound(size, 1, tagitCore.MAX_BATCH_SIZE());
        (uint256[] memory tokenIds,) = _boundBatch(size);

        vm.prank(manufacturer);
        tagitCore.batchActivate(tokenIds);

        for (uint256 i = 0; i < size; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.ACTIVATED), "Each item should be ACTIVATED");
        }
    }

    // ============================================
    // batchFlag — SUCCESS CASES
    // ============================================

    function test_batchFlag_success_mixedStates_preFlagStateRoundTrip() public {
        uint256 boundToken = _mintToBound();
        uint256 activatedToken = _mintToActivated();
        uint256 claimedToken = _mintToClaimed(); // owned by user2

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = boundToken;
        tokenIds[1] = activatedToken;
        tokenIds[2] = claimedToken;

        // StateChanged emitted per token with the correct from-state
        vm.expectEmit(true, false, false, true);
        emit StateChanged(boundToken, TAGITCore.State.BOUND, TAGITCore.State.FLAGGED, manufacturer);
        vm.expectEmit(true, false, false, true);
        emit StateChanged(activatedToken, TAGITCore.State.ACTIVATED, TAGITCore.State.FLAGGED, manufacturer);
        vm.expectEmit(true, false, false, true);
        emit StateChanged(claimedToken, TAGITCore.State.CLAIMED, TAGITCore.State.FLAGGED, manufacturer);

        vm.prank(manufacturer);
        tagitCore.batchFlag(tokenIds);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.FLAGGED), "Each item should be FLAGGED");
        }

        // _preFlagState recorded per item: resolve() must restore the EXACT pre-flag state
        _resolveTo(boundToken, user1);
        assertEq(uint8(_state(boundToken)), uint8(TAGITCore.State.BOUND), "Should restore BOUND");

        _resolveTo(activatedToken, user1);
        assertEq(uint8(_state(activatedToken)), uint8(TAGITCore.State.ACTIVATED), "Should restore ACTIVATED");

        _resolveTo(claimedToken, user2);
        assertEq(uint8(_state(claimedToken)), uint8(TAGITCore.State.CLAIMED), "Should restore CLAIMED");
        assertEq(tagitCore.ownerOf(claimedToken), user2, "Claimed owner should round-trip");
    }

    // ============================================
    // batchFlag — REVERT CASES
    // ============================================

    function test_batchFlag_revert_emptyBatch() public {
        uint256[] memory tokenIds = new uint256[](0);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.EmptyBatch.selector);
        tagitCore.batchFlag(tokenIds);
    }

    function test_batchFlag_revert_batchTooLarge() public {
        uint256[] memory tokenIds = new uint256[](101);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.BatchTooLarge.selector, 101, 100));
        tagitCore.batchFlag(tokenIds);
    }

    function test_batchFlag_revert_tokenNotFound() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 999; // never minted

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TokenNotFound.selector, 999));
        tagitCore.batchFlag(tokenIds);
    }

    function test_batchFlag_revert_notFlaggable_mintedItem() public {
        uint256[] memory tokenIds = _mintN(1); // MINTED — no physical tag yet

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, tokenIds[0], TAGITCore.State.MINTED));
        tagitCore.batchFlag(tokenIds);
    }

    function test_batchFlag_revert_notFlaggable_flaggedItem() public {
        uint256 tokenId = _mintToBound();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, tokenId, TAGITCore.State.FLAGGED));
        tagitCore.batchFlag(tokenIds);
    }

    function test_batchFlag_revert_notFlaggable_recycledItem() public {
        uint256 tokenId = _mintToClaimed();
        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, tokenId, TAGITCore.State.RECYCLED));
        tagitCore.batchFlag(tokenIds);
    }

    function test_batchFlag_revert_duplicateTokenIdWithinBatch() public {
        uint256 tokenId = _mintToBound();
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId;
        tokenIds[1] = tokenId; // duplicate — second occurrence already FLAGGED

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, tokenId, TAGITCore.State.FLAGGED));
        tagitCore.batchFlag(tokenIds);
    }

    function test_batchFlag_revert_unauthorized() public {
        uint256 tokenId = _mintToBound();
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        vm.prank(user2); // no FLAGGER capability
        vm.expectRevert();
        tagitCore.batchFlag(tokenIds);
    }

    function test_batchFlag_atomicity_invalidItemRevertsWholeBatch() public {
        // 4 BOUND tokens + 1 MINTED token spliced in as item 3 of 5
        (uint256[] memory bound,) = _boundBatch(4);
        uint256[] memory mintedOnly = _mintN(1);

        uint256[] memory tokenIds = new uint256[](5);
        tokenIds[0] = bound[0];
        tokenIds[1] = bound[1];
        tokenIds[2] = mintedOnly[0]; // invalid: MINTED is not flaggable
        tokenIds[3] = bound[2];
        tokenIds[4] = bound[3];

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, mintedOnly[0], TAGITCore.State.MINTED));
        tagitCore.batchFlag(tokenIds);

        // Items 1-2 must be rolled back to BOUND — and circuit breaker budget untouched
        assertEq(uint8(_state(bound[0])), uint8(TAGITCore.State.BOUND), "Item 1 should remain BOUND");
        assertEq(uint8(_state(bound[1])), uint8(TAGITCore.State.BOUND), "Item 2 should remain BOUND");
        assertEq(tagitCore.getFlagCircuitBreakerCapacity(), 50, "Breaker count should be rolled back");
    }

    // ============================================
    // batchFlag — CIRCUIT BREAKER (NIST IR-4)
    // ============================================

    function test_batchFlag_circuitBreaker_underThresholdDoesNotTrip() public {
        (uint256[] memory tokenIds,) = _boundBatch(49);

        vm.prank(manufacturer);
        tagitCore.batchFlag(tokenIds);

        (bool isTripped,) = tagitCore.getFlagCircuitBreakerStatus();
        assertFalse(isTripped, "49 flags should not trip the 50/hour breaker");
        assertEq(tagitCore.getFlagCircuitBreakerCapacity(), 1, "One flag of budget should remain");
    }

    function test_batchFlag_circuitBreaker_batchAtThresholdSucceedsThenTrips() public {
        (uint256[] memory tokenIds,) = _boundBatch(51);

        uint256[] memory batch = new uint256[](50);
        for (uint256 i = 0; i < 50; i++) {
            batch[i] = tokenIds[i];
        }

        // A batch of exactly the threshold succeeds (the 50th check trips but does not revert)
        vm.prank(manufacturer);
        tagitCore.batchFlag(batch);

        for (uint256 i = 0; i < 50; i++) {
            assertEq(uint8(_state(batch[i])), uint8(TAGITCore.State.FLAGGED), "All 50 should be FLAGGED");
        }

        (bool isTripped, uint256 cooldownRemaining) = tagitCore.getFlagCircuitBreakerStatus();
        assertTrue(isTripped, "Breaker should be tripped after 50th flag");
        assertEq(cooldownRemaining, 30 minutes, "Cooldown should be 30 minutes");

        // The 51st flag (single) reverts while in cooldown
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.CircuitBreakerCooldown.selector, 30 minutes));
        tagitCore.flag(tokenIds[50]);
    }

    function test_batchFlag_circuitBreaker_sharedBudgetWithSingleFlags() public {
        // batchFlag counts against the SAME budget as single flag() calls:
        // 30 singles consume 30/50; a batch of 25 would need 55 → whole batch reverts
        (uint256[] memory tokenIds,) = _boundBatch(55);

        for (uint256 i = 0; i < 30; i++) {
            vm.prank(manufacturer);
            tagitCore.flag(tokenIds[i]);
        }
        assertEq(tagitCore.getFlagCircuitBreakerCapacity(), 20, "30 singles should leave 20 of budget");

        uint256[] memory batch = new uint256[](25);
        for (uint256 i = 0; i < 25; i++) {
            batch[i] = tokenIds[30 + i];
        }

        // Item 20 of the batch (50th overall) trips; item 21 hits cooldown → atomic revert
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.CircuitBreakerCooldown.selector, 30 minutes));
        tagitCore.batchFlag(batch);

        // Whole batch rolled back: the 30 singles stay FLAGGED, all 25 batch items stay BOUND
        for (uint256 i = 0; i < 30; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.FLAGGED), "Singles should remain FLAGGED");
        }
        for (uint256 i = 0; i < 25; i++) {
            assertEq(uint8(_state(batch[i])), uint8(TAGITCore.State.BOUND), "Batch items should remain BOUND");
        }
        assertEq(tagitCore.getFlagCircuitBreakerCapacity(), 20, "Breaker count should be rolled back to 30/50");

        // A batch that fits the remaining budget still works (20 remaining, flag 20)
        uint256[] memory fits = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            fits[i] = tokenIds[30 + i];
        }
        vm.prank(manufacturer);
        tagitCore.batchFlag(fits);
        for (uint256 i = 0; i < 20; i++) {
            assertEq(uint8(_state(fits[i])), uint8(TAGITCore.State.FLAGGED), "Fitting batch should succeed");
        }
    }

    function test_batchFlag_circuitBreaker_recoversAfterCooldown() public {
        (uint256[] memory tokenIds,) = _boundBatch(55);

        uint256[] memory batch = new uint256[](50);
        for (uint256 i = 0; i < 50; i++) {
            batch[i] = tokenIds[i];
        }
        vm.prank(manufacturer);
        tagitCore.batchFlag(batch); // trips at the 50th flag

        // Still in cooldown — flagging reverts
        uint256[] memory more = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            more[i] = tokenIds[50 + i];
        }
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(CircuitBreaker.CircuitBreakerCooldown.selector, 30 minutes));
        tagitCore.batchFlag(more);

        // Warp past the 30-minute cooldown — breaker resets and flagging works again
        vm.warp(block.timestamp + 30 minutes + 1);

        vm.prank(manufacturer);
        tagitCore.batchFlag(more);

        for (uint256 i = 0; i < 5; i++) {
            assertEq(uint8(_state(more[i])), uint8(TAGITCore.State.FLAGGED), "Post-cooldown batch should succeed");
        }
        (bool isTripped,) = tagitCore.getFlagCircuitBreakerStatus();
        assertFalse(isTripped, "Breaker should be reset after cooldown");
    }

    // ============================================
    // batchFlag — FUZZ
    // ============================================

    /// @dev Size bounded to the breaker threshold (50): a batch above it can never succeed
    ///      in a fresh window by design. See testFuzz_batchBind for the runs-override rationale.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_batchFlag(uint256 size) public {
        size = bound(size, 1, 50);
        (uint256[] memory tokenIds,) = _boundBatch(size);

        vm.prank(manufacturer);
        tagitCore.batchFlag(tokenIds);

        for (uint256 i = 0; i < size; i++) {
            assertEq(uint8(_state(tokenIds[i])), uint8(TAGITCore.State.FLAGGED), "Each item should be FLAGGED");
        }
    }

    // ============================================
    // GAS SANITY — batch vs singles
    // ============================================

    /// @dev Named *gasEfficiency* so coverage CI excludes it (--no-match-test 'gasEfficiency').
    ///      Batch is measured FIRST so it pays the cold-storage costs — a conservative comparison.
    function test_batchBind_gasEfficiency_vsSingleBinds() public {
        uint256[] memory tokenIds = _mintN(100);

        // --- batchBind over tokens[0..49] ---
        uint256[] memory batchIds = new uint256[](50);
        for (uint256 i = 0; i < 50; i++) {
            batchIds[i] = tokenIds[i];
        }
        (bytes32[] memory tagHashes, bytes[] memory challengeResponses) = _defaultBatchInputs(batchIds);
        bytes memory sig = _batchSign(batchIds, tagHashes, challengeResponses);

        vm.prank(manufacturer);
        uint256 gasBefore = gasleft();
        tagitCore.batchBind(batchIds, tagHashes, challengeResponses, sig);
        uint256 batchGas = gasBefore - gasleft();

        // --- 50 single bindTag calls over tokens[50..99] ---
        uint256 singlesGas = 0;
        for (uint256 i = 50; i < 100; i++) {
            bytes32 tagHash = _tagFor(tokenIds[i]);
            (bytes memory cr, bytes memory singleSig) = _oracleSign(tokenIds[i], tagHash);
            vm.prank(manufacturer);
            gasBefore = gasleft();
            tagitCore.bindTag(tokenIds[i], tagHash, cr, singleSig);
            singlesGas += gasBefore - gasleft();
        }

        emit log_named_uint("batchBind(50) total gas", batchGas);
        emit log_named_uint("50x single bindTag total gas", singlesGas);
        emit log_named_uint("gas saved by batching", singlesGas - batchGas);
        emit log_named_uint("batch gas per item", batchGas / 50);
        emit log_named_uint("single gas per item", singlesGas / 50);

        // Batch must be cheaper with a comfortable margin (>= 5%), before even counting
        // the per-transaction intrinsic gas (21k each) that 50 separate txs would add
        assertLt(batchGas * 100, singlesGas * 95, "batchBind(50) should be >=5% cheaper than 50 single binds");
    }
}
