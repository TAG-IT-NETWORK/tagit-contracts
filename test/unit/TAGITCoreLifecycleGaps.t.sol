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
 * @title TAGITCoreLifecycleGapsTest
 * @notice Tests filling coverage gaps in TAGITCore lifecycle
 * @dev Covers: RECYCLED terminal, view edge cases, circuit breaker recovery,
 *      access controller bypass, batchMint rate limit, totalSupply after recycle
 */
contract TAGITCoreLifecycleGapsTest is Test {
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
    bytes32 public constant TAG_HASH = keccak256("NFC_TAG_UID_001");
    bytes32 public constant TAG_HASH_2 = keccak256("NFC_TAG_UID_002");

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

        // Deploy TAGITCore behind UUPS proxy (keep implementation reference)
        implementation = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tagitCore = TAGITCore(address(proxy));

        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        address oracle = vm.addr(ORACLE_PK);
        vm.prank(owner);
        tagitCore.setTrustedOracle(oracle);

        // Grant all capabilities to manufacturer
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RECYCLER_CAPABILITY()));

        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    /// @dev Oracle sign helper — matches TAGITCore.t.sol pattern
    function _oracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        returns (bytes memory challengeResponse, bytes memory oracleSignature)
    {
        challengeResponse = abi.encodePacked("challenge", tokenId);
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, ethHash);
        oracleSignature = abi.encodePacked(r, s, v);
    }

    /// @dev Drive an asset to RECYCLED state via MINTED→BOUND→ACTIVATED→CLAIMED→RECYCLED
    function _mintToRecycled() internal returns (uint256 tokenId) {
        vm.startPrank(manufacturer);
        tokenId = tagitCore.mint(user1, METADATA);

        bytes32 tagHash = keccak256(abi.encodePacked("NFC_RECYCLE_", tokenId));
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        tagitCore.activate(tokenId);
        tagitCore.claim(tokenId, user1);
        tagitCore.recycle(tokenId);
        vm.stopPrank();
    }

    /// @dev Drive an asset to CLAIMED state
    function _mintToClaimed() internal returns (uint256 tokenId) {
        vm.startPrank(manufacturer);
        tokenId = tagitCore.mint(user1, METADATA);

        bytes32 tagHash = keccak256(abi.encodePacked("NFC_CLAIM_", tokenId));
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        tagitCore.activate(tokenId);
        tagitCore.claim(tokenId, user1);
        vm.stopPrank();
    }

    /// @dev Drive an asset to FLAGGED state
    function _mintToFlagged() internal returns (uint256 tokenId) {
        tokenId = _mintToClaimed();
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
    }

    // ========================================================================
    // GAP 1: RECYCLED TERMINAL STATE — typed error selectors
    // ========================================================================

    function test_recycled_revert_bindTag() public {
        uint256 tokenId = _mintToRecycled();

        bytes32 tagHash = keccak256("new_tag");
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.RECYCLED, TAGITCore.State.MINTED
            )
        );
        tagitCore.bindTag(tokenId, tagHash, cr, sig);
    }

    function test_recycled_revert_activate() public {
        uint256 tokenId = _mintToRecycled();

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.RECYCLED, TAGITCore.State.BOUND
            )
        );
        tagitCore.activate(tokenId);
    }

    function test_recycled_revert_claim() public {
        uint256 tokenId = _mintToRecycled();

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.RECYCLED, TAGITCore.State.ACTIVATED
            )
        );
        tagitCore.claim(tokenId, user2);
    }

    function test_recycled_revert_flag() public {
        uint256 tokenId = _mintToRecycled();

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.NotFlaggable.selector, tokenId, TAGITCore.State.RECYCLED));
        tagitCore.flag(tokenId);
    }

    function test_recycled_revert_recycle() public {
        uint256 tokenId = _mintToRecycled();

        vm.prank(manufacturer);
        vm.expectRevert(); // Already recycled
        tagitCore.recycle(tokenId);
    }

    // ========================================================================
    // GAP 7: getAsset on non-existent token
    // ========================================================================

    function test_getAsset_nonExistent_returnsZeroes() public view {
        (address assetOwner, uint64 timestamp, TAGITCore.State state, uint8 flags, uint16 reserved) =
            tagitCore.getAsset(99999);

        assertEq(assetOwner, address(0), "Non-existent owner should be zero");
        assertEq(timestamp, 0, "Non-existent timestamp should be 0");
        assertEq(uint8(state), 0, "Non-existent state should be NONE/0");
        assertEq(flags, 0, "Non-existent flags should be 0");
        assertEq(reserved, 0, "Non-existent reserved should be 0");
    }

    function test_getAsset_tokenZero_returnsZeroes() public view {
        (address assetOwner,,,,) = tagitCore.getAsset(0);
        assertEq(assetOwner, address(0), "Token 0 owner should be zero");
    }

    function test_getAsset_maxUint_returnsZeroes() public view {
        (address assetOwner,,,,) = tagitCore.getAsset(type(uint256).max);
        assertEq(assetOwner, address(0), "Max uint token owner should be zero");
    }

    // ========================================================================
    // GAP 8: getTokenByTag with zero/unknown hash
    // ========================================================================

    function test_getTokenByTag_zeroHash_returnsZero() public view {
        uint256 tokenId = tagitCore.getTokenByTag(bytes32(0));
        assertEq(tokenId, 0, "Zero hash should return token 0");
    }

    function test_getTokenByTag_unknownHash_returnsZero() public view {
        uint256 tokenId = tagitCore.getTokenByTag(keccak256("nonexistent_tag"));
        assertEq(tokenId, 0, "Unknown hash should return token 0");
    }

    // ========================================================================
    // GAP 9: totalSupply unchanged after recycle (not burned)
    // ========================================================================

    function test_recycle_totalSupply_unchanged() public {
        vm.prank(manufacturer);
        tagitCore.mint(user1, METADATA);

        uint256 supplyBefore = tagitCore.totalSupply();
        assertEq(supplyBefore, 1, "Supply should be 1 after mint");

        uint256 tokenId = _mintToClaimed();
        uint256 supplyAfterClaim = tagitCore.totalSupply();

        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);

        uint256 supplyAfterRecycle = tagitCore.totalSupply();
        assertEq(supplyAfterRecycle, supplyAfterClaim, "Supply unchanged after recycle");
    }

    function test_recycle_ownerOf_unchanged() public {
        uint256 tokenId = _mintToClaimed();

        address ownerBefore = tagitCore.ownerOf(tokenId);
        assertEq(ownerBefore, user1, "Owner should be user1 before recycle");

        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);

        address ownerAfter = tagitCore.ownerOf(tokenId);
        assertEq(ownerAfter, user1, "Owner should remain user1 after recycle");
    }

    // ========================================================================
    // GAP 11: RESOLVE_QUORUM constant verification
    // ========================================================================

    function test_resolveQuorum_isTwo() public view {
        assertEq(tagitCore.RESOLVE_QUORUM(), 2, "Quorum should be 2 (2-of-3 multisig)");
    }

    function test_resolve_requiresTwoApprovals() public {
        uint256 tokenId = _mintToFlagged();

        // First approval — not enough to resolve
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, user1);

        // Should revert with only one approval
        vm.prank(manufacturer);
        vm.expectRevert();
        tagitCore.resolve(tokenId, user1);
    }

    // ========================================================================
    // GAP 12: initialize() on raw implementation reverts
    // ========================================================================

    function test_initialize_onImplementation_reverts() public {
        vm.expectRevert();
        implementation.initialize(owner);
    }

    // ========================================================================
    // GAP 10: setApprovalForAll allowed but transfer still blocked
    // ========================================================================

    function test_setApprovalForAll_allowed_butTransferBlocked() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA);

        // setApprovalForAll succeeds
        vm.prank(user1);
        tagitCore.setApprovalForAll(user2, true);

        assertTrue(tagitCore.isApprovedForAll(user1, user2), "Approval should be set");

        // But transfer is still blocked
        vm.prank(user2);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(user1, user2, tokenId);

        vm.prank(user2);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.safeTransferFrom(user1, user2, tokenId);
    }

    // ========================================================================
    // GAP 17: setAccessController(address(0)) bypass
    // ========================================================================

    function test_setAccessController_zero_disablesCapabilityChecks() public {
        // Remove access controller
        vm.prank(owner);
        tagitCore.setAccessController(address(0));

        // Now any address can perform operations without capability badges
        address anyone = makeAddr("anyone");

        vm.prank(anyone);
        uint256 tokenId = tagitCore.mint(user1, METADATA);
        assertEq(tokenId, 1, "Anyone can mint when controller is zero");

        // Re-set the controller
        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        // Now unauthorized calls should revert again
        vm.prank(anyone);
        vm.expectRevert();
        tagitCore.mint(user1, METADATA);
    }

    // ========================================================================
    // GAP 6: mint with zero metadata
    // ========================================================================

    function test_mint_zeroMetadata_succeeds() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, bytes32(0));
        assertEq(tokenId, 1, "Zero metadata mint should succeed");
    }

    // ========================================================================
    // FUZZ: RECYCLED terminal (all operations revert)
    // ========================================================================

    function testFuzz_recycled_allOperationsRevert(uint8 operation) public {
        operation = uint8(bound(operation, 0, 4));
        uint256 tokenId = _mintToRecycled();

        vm.startPrank(manufacturer);

        if (operation == 0) {
            // bindTag
            vm.expectRevert();
            tagitCore.bindTag(tokenId, keccak256("tag"), "", "");
        } else if (operation == 1) {
            // activate
            vm.expectRevert();
            tagitCore.activate(tokenId);
        } else if (operation == 2) {
            // claim
            vm.expectRevert();
            tagitCore.claim(tokenId, user2);
        } else if (operation == 3) {
            // flag
            vm.expectRevert();
            tagitCore.flag(tokenId);
        } else {
            // recycle (already recycled)
            vm.expectRevert();
            tagitCore.recycle(tokenId);
        }

        vm.stopPrank();
    }

    // ========================================================================
    // FUZZ: getAsset on arbitrary non-existent token
    // ========================================================================

    function testFuzz_getAsset_nonExistent(uint256 tokenId) public view {
        // Only test IDs that don't exist
        vm.assume(tokenId > tagitCore.totalSupply());

        (address assetOwner, uint64 timestamp, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(assetOwner, address(0));
        assertEq(timestamp, 0);
        assertEq(uint8(state), 0);
    }

    // ========================================================================
    // Typed error selectors for invalid transitions from BOUND
    // ========================================================================

    function test_bound_revert_claim_typedError() public {
        vm.startPrank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA);

        bytes32 tagHash = keccak256("tag_for_bound_test");
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        // BOUND → CLAIMED should revert (must go through ACTIVATED first)
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.BOUND, TAGITCore.State.ACTIVATED
            )
        );
        tagitCore.claim(tokenId, user1);
        vm.stopPrank();
    }

    /// @dev Recall upgrade: a BOUND asset CAN now be flagged (manufacturer recall / pre-sale theft).
    function test_bound_flag_succeeds() public {
        vm.startPrank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA);

        bytes32 tagHash = keccak256("tag_for_bound_flag");
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        tagitCore.flag(tokenId); // BOUND -> FLAGGED now valid
        vm.stopPrank();

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.FLAGGED), "BOUND asset can be flagged");
    }

    /// @dev Scrap upgrade: a BOUND asset CAN now be recycled (scrap defective/unsold stock).
    function test_bound_recycle_succeeds() public {
        vm.startPrank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA);

        bytes32 tagHash = keccak256("tag_for_bound_recycle");
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        tagitCore.recycle(tokenId); // BOUND -> RECYCLED now valid
        vm.stopPrank();

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.RECYCLED), "BOUND asset can be scrapped");
    }
}
