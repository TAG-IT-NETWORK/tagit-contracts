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
 * @title TAGITCoreOracleVerificationTest
 * @notice Tests for PATCH-06: NFC Oracle ECDSA signature verification on bindTag
 * @dev Verifies that bindTag requires a valid oracle ECDSA signature
 */
contract TAGITCoreOracleVerificationTest is Test {
    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public manufacturer;
    address public consumer;

    uint256 constant ORACLE_PK = 0xA11CE;
    address public oracle;

    uint256 constant WRONG_ORACLE_PK = 0xBAD;
    address public wrongOracle;

    uint256 constant CAP_MINT = uint256(keccak256("MINTER"));
    uint256 constant CAP_BIND = uint256(keccak256("BINDER"));

    event TrustedOracleUpdated(address indexed previousOracle, address indexed newOracle);

    function setUp() public {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        consumer = makeAddr("consumer");
        oracle = vm.addr(ORACLE_PK);
        wrongOracle = vm.addr(WRONG_ORACLE_PK);

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

        capabilityBadge.grantCapability(manufacturer, CAP_MINT);
        capabilityBadge.grantCapability(manufacturer, CAP_BIND);
    }

    // ============================================
    // ORACLE SIGNING HELPERS
    // ============================================

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

    function _wrongOracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        returns (bytes memory challengeResponse, bytes memory oracleSignature)
    {
        challengeResponse = abi.encodePacked("challenge", tokenId);
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_ORACLE_PK, ethHash);
        oracleSignature = abi.encodePacked(r, s, v);
    }

    // ============================================
    // SUCCESS CASES
    // ============================================

    function test_bindTag_withValidOracleSignature() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata-1"));

        bytes32 tagHash = keccak256("NFC_TAG_001");
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);

        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        // Verify binding succeeded
        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.BOUND), "Should be BOUND");
        assertEq(tagitCore.getTokenByTag(tagHash), tokenId, "Tag should map to token");
        assertEq(tagitCore.getTagByToken(tokenId), tagHash, "Token should map to tag");
    }

    function test_bindTag_messageHashDeterministic() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata-det"));

        bytes32 tagHash = keccak256("DET_TAG");

        // Generate two signatures for same data — should both work
        (bytes memory cr1, bytes memory sig1) = _oracleSign(tokenId, tagHash);
        (bytes memory cr2, bytes memory sig2) = _oracleSign(tokenId, tagHash);

        // Both signatures should be identical (same inputs, same key)
        assertEq(keccak256(sig1), keccak256(sig2), "Same inputs should produce same signature");

        // Use first signature to bind
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr1, sig1);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.BOUND), "Should be BOUND");
    }

    // ============================================
    // REVERT CASES - ORACLE SIGNATURE
    // ============================================

    function test_bindTag_revert_invalidSignature() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata-bad"));

        bytes32 tagHash = keccak256("BAD_SIG_TAG");
        bytes memory challengeResponse = abi.encodePacked("challenge", tokenId);
        bytes memory invalidSig = hex"deadbeef";

        vm.prank(manufacturer);
        vm.expectRevert();
        tagitCore.bindTag(tokenId, tagHash, challengeResponse, invalidSig);
    }

    function test_bindTag_revert_wrongOracleSignature() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata-wrong"));

        bytes32 tagHash = keccak256("WRONG_ORACLE_TAG");
        (bytes memory cr, bytes memory sig) = _wrongOracleSign(tokenId, tagHash);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);
    }

    function test_bindTag_revert_oracleNotSet() public {
        // Deploy fresh core without oracle set
        TAGITCore impl2 = new TAGITCore();
        bytes memory initData2 = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData2);
        TAGITCore core2 = TAGITCore(address(proxy2));

        vm.prank(owner);
        core2.setAccessController(address(tagitAccess));
        // NOTE: NOT setting trusted oracle

        vm.prank(manufacturer);
        uint256 tokenId = core2.mint(consumer, keccak256("no-oracle"));

        bytes32 tagHash = keccak256("NO_ORACLE_TAG");
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.OracleNotSet.selector);
        core2.bindTag(tokenId, tagHash, cr, sig);
    }

    function test_bindTag_revert_tampered_challengeResponse() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata-tamper"));

        bytes32 tagHash = keccak256("TAMPER_TAG");
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);

        // Tamper with challenge response
        bytes memory tamperedCr = abi.encodePacked("tampered-challenge");

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId, tagHash, tamperedCr, sig);
    }

    function test_bindTag_revert_signatureForDifferentToken() public {
        vm.prank(manufacturer);
        uint256 tokenId1 = tagitCore.mint(consumer, keccak256("metadata-1"));
        vm.prank(manufacturer);
        uint256 tokenId2 = tagitCore.mint(consumer, keccak256("metadata-2"));

        bytes32 tagHash = keccak256("CROSS_TOKEN_TAG");
        // Sign for tokenId1
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId1, tagHash);

        // Try to use on tokenId2
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId2, tagHash, cr, sig);
    }

    function test_bindTag_revert_signatureForDifferentTag() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata-tag-swap"));

        bytes32 tagHash1 = keccak256("TAG_A");
        bytes32 tagHash2 = keccak256("TAG_B");
        // Sign for tagHash1
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash1);

        // Try to use with tagHash2
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId, tagHash2, cr, sig);
    }

    // ============================================
    // setTrustedOracle
    // ============================================

    function test_setTrustedOracle_success() public {
        address newOracle = makeAddr("newOracle");

        vm.expectEmit(true, true, false, false);
        emit TrustedOracleUpdated(oracle, newOracle);

        vm.prank(owner);
        tagitCore.setTrustedOracle(newOracle);

        assertEq(tagitCore.trustedOracle(), newOracle, "Oracle should be updated");
    }

    function test_setTrustedOracle_revert_nonOwner() public {
        vm.prank(manufacturer);
        vm.expectRevert();
        tagitCore.setTrustedOracle(makeAddr("rogue"));
    }

    function test_setTrustedOracle_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TAGITCore.ZeroAddress.selector);
        tagitCore.setTrustedOracle(address(0));
    }

    function test_setTrustedOracle_bindWorksWithNewOracle() public {
        // Change oracle to wrongOracle
        vm.prank(owner);
        tagitCore.setTrustedOracle(wrongOracle);

        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("new-oracle-test"));

        bytes32 tagHash = keccak256("NEW_ORACLE_TAG");

        // Old oracle signature should fail
        (bytes memory cr1, bytes memory sig1) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId, tagHash, cr1, sig1);

        // New oracle (wrongOracle) signature should succeed
        (bytes memory cr2, bytes memory sig2) = _wrongOracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr2, sig2);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.BOUND), "Should be BOUND");
    }

    // ============================================
    // EXISTING CHECKS STILL WORK
    // ============================================

    function test_bindTag_revert_nonExistentToken_beforeOracleCheck() public {
        uint256 fakeTokenId = 999;
        bytes32 tagHash = keccak256("FAKE_TAG");
        (bytes memory cr, bytes memory sig) = _oracleSign(fakeTokenId, tagHash);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TokenNotFound.selector, fakeTokenId));
        tagitCore.bindTag(fakeTokenId, tagHash, cr, sig);
    }

    function test_bindTag_revert_wrongState_beforeOracleCheck() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata-state"));

        bytes32 tag1 = keccak256("TAG_STATE_1");
        (bytes memory cr1, bytes memory sig1) = _oracleSign(tokenId, tag1);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tag1, cr1, sig1);

        // Now in BOUND state — try to bind again
        bytes32 tag2 = keccak256("TAG_STATE_2");
        (bytes memory cr2, bytes memory sig2) = _oracleSign(tokenId, tag2);

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.BOUND, TAGITCore.State.MINTED
            )
        );
        tagitCore.bindTag(tokenId, tag2, cr2, sig2);
    }

    function test_bindTag_revert_zeroTagHash_beforeOracleCheck() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata-zero"));

        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, bytes32(0));

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidTagHash.selector);
        tagitCore.bindTag(tokenId, bytes32(0), cr, sig);
    }

    function test_bindTag_revert_tagAlreadyBound_beforeOracleCheck() public {
        vm.prank(manufacturer);
        uint256 tokenId1 = tagitCore.mint(consumer, keccak256("metadata-dup1"));
        vm.prank(manufacturer);
        uint256 tokenId2 = tagitCore.mint(consumer, keccak256("metadata-dup2"));

        bytes32 tagHash = keccak256("DUPLICATE_TAG");

        // Bind to first token
        (bytes memory cr1, bytes memory sig1) = _oracleSign(tokenId1, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId1, tagHash, cr1, sig1);

        // Try to bind same tag to second token
        (bytes memory cr2, bytes memory sig2) = _oracleSign(tokenId2, tagHash);
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TagAlreadyBound.selector, tagHash));
        tagitCore.bindTag(tokenId2, tagHash, cr2, sig2);
    }

    // ============================================
    // FULL FLOW
    // ============================================

    function test_fullFlow_oracleSignBindActivateClaim() public {
        // 1. Mint
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("full-flow"));

        // 2. Oracle attests NFC scan, manufacturer binds
        bytes32 tagHash = keccak256("NFC_FULL_FLOW");
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        // 3. Verify binding
        assertEq(tagitCore.getTokenByTag(tagHash), tokenId, "Tag bound");
        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.BOUND), "BOUND state");
    }
}
