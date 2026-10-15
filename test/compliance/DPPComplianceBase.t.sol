// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ITAGITAccess} from "../../src/interfaces/ITAGITAccess.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title DPPComplianceBase
 * @notice Shared harness for the EU Digital Product Passport (DPP) on-chain conformance suite.
 * @dev Mirrors the canonical `test/unit/TAGITCore.t.sol` setup: real badge stack + TAGITAccess
 *      facade, TAGITCore behind an ERC1967 (UUPS) proxy, access controller wired, all seven
 *      lifecycle capabilities granted to `manufacturer`. Inherit this and add `test_*` functions.
 *
 *      These tests assert machine-checkable DPP invariants only. Passing them is NOT a legal
 *      compliance determination — see docs/compliance/dpp-requirements-to-tests.md §0.
 */
abstract contract DPPComplianceBase is Test {
    TAGITCore internal core;
    TAGITAccess internal access;
    IdentityBadge internal identityBadge;
    CapabilityBadge internal capabilityBadge;

    address internal owner; // == TimelockController in production
    address internal manufacturer; // holds all 7 lifecycle capabilities
    address internal resolver2; // second resolver (quorum)
    address internal consumer1;
    address internal consumer2;
    address internal stranger; // holds no capabilities

    uint256 internal constant ORACLE_PK = 0xA11CE;

    // Canonical test metadata (keccak256 of a passport JSON) and NFC tag hashes.
    bytes32 internal constant META_1 = keccak256("ipfs://QmPassport1");
    bytes32 internal constant TAG_1 = keccak256("NFC_TAG_UID_001");
    bytes32 internal constant TAG_2 = keccak256("NFC_TAG_UID_002");

    function setUp() public virtual {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        resolver2 = makeAddr("resolver2");
        consumer1 = makeAddr("consumer1");
        consumer2 = makeAddr("consumer2");
        stranger = makeAddr("stranger");

        // Badge stack + access facade are deployed by this test contract, so `address(this)`
        // owns them and can grant capabilities directly (no prank).
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        access = new TAGITAccess();
        access.setIdentityBadge(address(identityBadge));
        access.setCapabilityBadge(address(capabilityBadge));

        // TAGITCore behind a UUPS proxy, initialized with `owner` as the Ownable owner.
        TAGITCore impl = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        core = TAGITCore(address(proxy));

        // onlyOwner wiring — must be pranked as `owner`.
        vm.startPrank(owner);
        core.setAccessController(address(access));
        core.setTrustedOracle(vm.addr(ORACLE_PK));
        vm.stopPrank();

        // Grant all seven lifecycle capabilities to the manufacturer actor.
        capabilityBadge.grantCapability(manufacturer, uint256(core.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(core.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(core.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(core.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(core.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(core.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(core.RECYCLER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver2, uint256(core.RESOLVER_CAPABILITY()));
    }

    // ----------------------------------------------------------------------------------------
    // Lifecycle helpers (all performed as `manufacturer`, who holds every capability)
    // ----------------------------------------------------------------------------------------

    function _mint(address to, bytes32 metadata) internal returns (uint256 id) {
        vm.prank(manufacturer);
        id = core.mint(to, metadata);
    }

    function _bind(uint256 id, bytes32 tagHash) internal {
        (bytes memory cr, bytes memory sig) = _oracleSign(id, tagHash);
        vm.prank(manufacturer);
        core.bindTag(id, tagHash, cr, sig);
    }

    function _activate(uint256 id) internal {
        vm.prank(manufacturer);
        core.activate(id);
    }

    function _claim(uint256 id, address newOwner) internal {
        vm.prank(manufacturer);
        core.claim(id, newOwner);
    }

    function _flag(uint256 id) internal {
        vm.prank(manufacturer);
        core.flag(id);
    }

    function _recycle(uint256 id) internal {
        vm.prank(manufacturer);
        core.recycle(id);
    }

    /// @dev Full happy path mint→bind→activate→claim(to consumer1), returns the tokenId.
    function _provisionClaimed(bytes32 metadata, bytes32 tagHash) internal returns (uint256 id) {
        id = _mint(consumer1, metadata);
        _bind(id, tagHash);
        _activate(id);
        _claim(id, consumer1);
    }

    /// @dev Trusted-oracle signature for bindTag (matches TAGITCore's expected message).
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
}
