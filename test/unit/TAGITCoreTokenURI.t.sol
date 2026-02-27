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
 * @title TAGITCoreTokenURITest
 * @notice Tests for PATCH-04: tokenURI authorization gate
 * @dev Verifies ITAR-compliant metadata access control
 */
contract TAGITCoreTokenURITest is Test {
    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public manufacturer;
    address public viewer;
    address public auditor;
    address public consumer;
    address public unauthorized;

    uint256 constant ORACLE_PK = 0xA11CE;

    uint256 constant CAP_MINT = uint256(keccak256("MINTER"));
    uint256 constant CAP_VIEWER = uint256(keccak256("VIEWER"));
    uint256 constant CAP_AUDITOR = uint256(keccak256("AUDITOR"));

    string constant REDACTED_URI = "ipfs://redacted-metadata";

    function setUp() public {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        viewer = makeAddr("viewer");
        auditor = makeAddr("auditor");
        consumer = makeAddr("consumer");
        unauthorized = makeAddr("unauthorized");

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

        // Set trusted oracle
        address oracle = vm.addr(ORACLE_PK);
        vm.prank(owner);
        tagitCore.setTrustedOracle(oracle);

        // Set redacted URI
        vm.prank(owner);
        tagitCore.setRedactedURI(REDACTED_URI);

        // Grant capabilities
        capabilityBadge.grantCapability(manufacturer, CAP_MINT);
        capabilityBadge.grantCapability(viewer, CAP_VIEWER);
        capabilityBadge.grantCapability(auditor, CAP_AUDITOR);

        // Mint a token to consumer
        vm.prank(manufacturer);
        tagitCore.mint(consumer, keccak256("metadata-1"));
    }

    // ============================================
    // ORACLE HELPER
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

    // ============================================
    // AUTHORIZATION CHECKS
    // ============================================

    function test_tokenURI_ownerGetsFullURI() public {
        vm.prank(consumer);
        string memory uri = tagitCore.tokenURI(1);
        // ERC721 default tokenURI returns empty when no base URI is set
        // The key test is that it does NOT return _redactedURI
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes(REDACTED_URI)), "Owner should get full URI, not redacted");
    }

    function test_tokenURI_viewerGetsFullURI() public {
        vm.prank(viewer);
        string memory uri = tagitCore.tokenURI(1);
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes(REDACTED_URI)), "Viewer should get full URI, not redacted");
    }

    function test_tokenURI_auditorGetsFullURI() public {
        vm.prank(auditor);
        string memory uri = tagitCore.tokenURI(1);
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes(REDACTED_URI)), "Auditor should get full URI, not redacted");
    }

    function test_tokenURI_unauthorizedGetsRedactedURI() public {
        vm.prank(unauthorized);
        string memory uri = tagitCore.tokenURI(1);
        assertEq(uri, REDACTED_URI, "Unauthorized caller should get redacted URI");
    }

    function test_tokenURI_manufacturerWithoutViewerGetsRedacted() public {
        // Manufacturer has MINTER capability but not VIEWER or AUDITOR
        vm.prank(manufacturer);
        string memory uri = tagitCore.tokenURI(1);
        assertEq(uri, REDACTED_URI, "Manufacturer without viewer cap should get redacted URI");
    }

    // ============================================
    // setRedactedURI
    // ============================================

    function test_setRedactedURI_byOwner() public {
        string memory newRedacted = "ipfs://new-redacted";
        vm.prank(owner);
        tagitCore.setRedactedURI(newRedacted);

        vm.prank(unauthorized);
        string memory uri = tagitCore.tokenURI(1);
        assertEq(uri, newRedacted, "Should return updated redacted URI");
    }

    function test_setRedactedURI_revert_byNonOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        tagitCore.setRedactedURI("should-fail");
    }

    // ============================================
    // EDGE CASES
    // ============================================

    function test_tokenURI_revert_nonExistentToken() public {
        vm.prank(consumer);
        vm.expectRevert();
        tagitCore.tokenURI(999);
    }

    function test_tokenURI_noAccessControllerBypasses() public {
        // When accessController is address(0), only owner check applies
        vm.prank(owner);
        tagitCore.setAccessController(address(0));

        // Non-owner, non-viewer should get redacted (since they are not asset owner)
        vm.prank(unauthorized);
        string memory uri = tagitCore.tokenURI(1);
        assertEq(uri, REDACTED_URI, "Without controller, non-owner gets redacted");

        // Asset owner still gets full URI
        vm.prank(consumer);
        string memory ownerUri = tagitCore.tokenURI(1);
        assertTrue(
            keccak256(bytes(ownerUri)) != keccak256(bytes(REDACTED_URI)),
            "Asset owner should still get full URI without controller"
        );
    }

    function test_tokenURI_emptyRedactedURI() public {
        // Set empty redacted URI
        vm.prank(owner);
        tagitCore.setRedactedURI("");

        vm.prank(unauthorized);
        string memory uri = tagitCore.tokenURI(1);
        assertEq(bytes(uri).length, 0, "Should return empty string as redacted URI");
    }

    // ============================================
    // CAPABILITY CONSTANTS
    // ============================================

    function test_viewerCapabilityConstant() public view {
        assertEq(tagitCore.VIEWER_CAPABILITY(), keccak256("VIEWER"), "VIEWER_CAPABILITY should match");
    }

    function test_auditorCapabilityConstant() public view {
        assertEq(tagitCore.AUDITOR_CAPABILITY(), keccak256("AUDITOR"), "AUDITOR_CAPABILITY should match");
    }
}
