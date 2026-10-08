// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title TAGITCoreTokenURITest
 * @notice tokenURI is uniform: every caller receives `baseURI + tokenId`.
 * @dev Replaces the PATCH-04 suite. The on-chain caller gate (asset owner / VIEWER /
 *      AUDITOR else `_redactedURI`) hid every product from block explorers and
 *      marketplaces, which read tokenURI from arbitrary addresses, while the metadata
 *      service behind the base URI already enforces per-item redaction. These tests pin
 *      the new contract: no caller-dependent output, no redacted branch, the legacy
 *      setter still owner-only and inert.
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
    string constant BASE_URI = "https://api.tagit.network/v1/meta/";

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

        address oracle = vm.addr(ORACLE_PK);
        vm.prank(owner);
        tagitCore.setTrustedOracle(oracle);

        // The legacy redacted URI is still settable; it must never surface.
        vm.prank(owner);
        tagitCore.setRedactedURI(REDACTED_URI);

        vm.prank(owner);
        tagitCore.setBaseURI(BASE_URI);

        capabilityBadge.grantCapability(manufacturer, CAP_MINT);
        capabilityBadge.grantCapability(viewer, CAP_VIEWER);
        capabilityBadge.grantCapability(auditor, CAP_AUDITOR);

        vm.prank(manufacturer);
        tagitCore.mint(consumer, keccak256("metadata-1"));
    }

    function _expected(uint256 tokenId) internal pure returns (string memory) {
        return string.concat(BASE_URI, vm.toString(tokenId));
    }

    // ============================================
    // UNIFORM OUTPUT — the property that puts products on explorers
    // ============================================

    function test_tokenURI_isIdenticalForEveryCaller() public {
        address[6] memory callers = [consumer, viewer, auditor, manufacturer, unauthorized, address(0)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            assertEq(tagitCore.tokenURI(1), _expected(1), "tokenURI must not depend on msg.sender");
        }
    }

    function test_tokenURI_neverReturnsTheRedactedURI() public {
        vm.prank(unauthorized);
        string memory uri = tagitCore.tokenURI(1);
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes(REDACTED_URI)), "redacted branch must be gone");
        assertEq(uri, _expected(1));
    }

    function test_tokenURI_followsBaseURIChanges() public {
        vm.prank(owner);
        tagitCore.setBaseURI("https://example.invalid/meta/");
        vm.prank(unauthorized);
        assertEq(tagitCore.tokenURI(1), "https://example.invalid/meta/1");
    }

    function test_tokenURI_emptyBaseURIReturnsEmpty() public {
        vm.prank(owner);
        tagitCore.setBaseURI("");
        vm.prank(unauthorized);
        assertEq(bytes(tagitCore.tokenURI(1)).length, 0, "ERC-721 default: empty base => empty URI");
    }

    function test_tokenURI_withoutAccessControllerIsStillUniform() public {
        vm.prank(owner);
        tagitCore.setAccessController(address(0));

        vm.prank(unauthorized);
        string memory a = tagitCore.tokenURI(1);
        vm.prank(consumer);
        string memory b = tagitCore.tokenURI(1);
        assertEq(a, b);
        assertEq(a, _expected(1));
    }

    // ============================================
    // LEGACY SETTER — owner-only, inert
    // ============================================

    function test_setRedactedURI_byOwner_hasNoEffectOnTokenURI() public {
        vm.prank(owner);
        tagitCore.setRedactedURI("ipfs://new-redacted");

        vm.prank(unauthorized);
        assertEq(tagitCore.tokenURI(1), _expected(1), "legacy redacted URI must not surface");
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

    // ============================================
    // CAPABILITY CONSTANTS (still exported for other consumers)
    // ============================================

    function test_viewerCapabilityConstant() public view {
        assertEq(tagitCore.VIEWER_CAPABILITY(), keccak256("VIEWER"), "VIEWER_CAPABILITY should match");
    }

    function test_auditorCapabilityConstant() public view {
        assertEq(tagitCore.AUDITOR_CAPABILITY(), keccak256("AUDITOR"), "AUDITOR_CAPABILITY should match");
    }
}
