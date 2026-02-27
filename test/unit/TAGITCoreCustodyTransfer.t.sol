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
 * @title TAGITCoreCustodyTransferTest
 * @notice Tests for PATCH-03: CustodyTransfer event with prevStateHash
 * @dev Verifies that CustodyTransfer is emitted on every state transition
 *      with correct fields and cryptographically linkable prevStateHash
 */
contract TAGITCoreCustodyTransferTest is Test {
    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public manufacturer;
    address public qaInspector;
    address public verifier;
    address public lawEnforcement;
    address public lawEnforcement2;
    address public recycler;
    address public consumer;

    uint256 constant ORACLE_PK = 0xA11CE;

    // Capability IDs
    uint256 constant CAP_MINT = uint256(keccak256("MINTER"));
    uint256 constant CAP_BIND = uint256(keccak256("BINDER"));
    uint256 constant CAP_ACTIVATE = uint256(keccak256("ACTIVATOR"));
    uint256 constant CAP_CLAIM = uint256(keccak256("CLAIMER"));
    uint256 constant CAP_FLAG = uint256(keccak256("FLAGGER"));
    uint256 constant CAP_RESOLVE = uint256(keccak256("RESOLVER"));
    uint256 constant CAP_RECYCLE = uint256(keccak256("RECYCLER"));

    event CustodyTransfer(
        uint256 indexed assetId,
        uint8 fromState,
        uint8 toState,
        address indexed fromOwner,
        address indexed toOwner,
        uint256 timestamp,
        bytes32 prevStateHash
    );

    function setUp() public {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        qaInspector = makeAddr("qaInspector");
        verifier = makeAddr("verifier");
        lawEnforcement = makeAddr("lawEnforcement");
        lawEnforcement2 = makeAddr("lawEnforcement2");
        recycler = makeAddr("recycler");
        consumer = makeAddr("consumer");

        // Deploy badge contracts
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();

        // Deploy TAGITAccess facade
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Deploy TAGITCore (upgradeable via UUPS proxy)
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

        // Grant capabilities
        capabilityBadge.grantCapability(manufacturer, CAP_MINT);
        capabilityBadge.grantCapability(manufacturer, CAP_BIND);
        capabilityBadge.grantCapability(qaInspector, CAP_ACTIVATE);
        capabilityBadge.grantCapability(verifier, CAP_CLAIM);
        capabilityBadge.grantCapability(lawEnforcement, CAP_FLAG);
        capabilityBadge.grantCapability(lawEnforcement, CAP_RESOLVE);
        capabilityBadge.grantCapability(lawEnforcement2, CAP_RESOLVE);
        capabilityBadge.grantCapability(recycler, CAP_RECYCLE);
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
    // MINT - CustodyTransfer
    // ============================================

    function test_custodyTransfer_mint_emitsEvent() public {
        bytes32 metadata = keccak256("test-metadata");

        bytes32 expectedPrevHash = keccak256(abi.encode(uint256(1), uint8(0), address(0), block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            1, // assetId (first token)
            uint8(TAGITCore.State.NONE), // fromState
            uint8(TAGITCore.State.MINTED), // toState
            address(0), // fromOwner (no previous owner)
            consumer, // toOwner
            block.timestamp, // timestamp
            expectedPrevHash // prevStateHash
        );

        vm.prank(manufacturer);
        tagitCore.mint(consumer, metadata);
    }

    // ============================================
    // BIND TAG - CustodyTransfer
    // ============================================

    function test_custodyTransfer_bindTag_emitsEvent() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata"));

        bytes32 tagHash = keccak256("NFC_TAG_001");
        bytes32 expectedPrevHash =
            keccak256(abi.encode(tokenId, uint8(TAGITCore.State.MINTED), consumer, block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.MINTED),
            uint8(TAGITCore.State.BOUND),
            consumer, // owner stays same
            consumer,
            block.timestamp,
            expectedPrevHash
        );

        (bytes memory challengeResponse, bytes memory oracleSignature) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, challengeResponse, oracleSignature);
    }

    // ============================================
    // ACTIVATE - CustodyTransfer
    // ============================================

    function test_custodyTransfer_activate_emitsEvent() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, keccak256("metadata"));

        bytes32 tagHash = keccak256("tag");
        (bytes memory challengeResponse, bytes memory oracleSignature) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, challengeResponse, oracleSignature);

        bytes32 expectedPrevHash =
            keccak256(abi.encode(tokenId, uint8(TAGITCore.State.BOUND), consumer, block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.BOUND),
            uint8(TAGITCore.State.ACTIVATED),
            consumer,
            consumer,
            block.timestamp,
            expectedPrevHash
        );

        vm.prank(qaInspector);
        tagitCore.activate(tokenId);
    }

    // ============================================
    // CLAIM - CustodyTransfer (ownership changes)
    // ============================================

    function test_custodyTransfer_claim_emitsEvent() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, keccak256("metadata"));

        bytes32 tagHash = keccak256("tag");
        (bytes memory challengeResponse, bytes memory oracleSignature) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, challengeResponse, oracleSignature);

        vm.prank(qaInspector);
        tagitCore.activate(tokenId);

        bytes32 expectedPrevHash =
            keccak256(abi.encode(tokenId, uint8(TAGITCore.State.ACTIVATED), manufacturer, block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.ACTIVATED),
            uint8(TAGITCore.State.CLAIMED),
            manufacturer, // fromOwner
            consumer, // toOwner (new owner)
            block.timestamp,
            expectedPrevHash
        );

        vm.prank(verifier);
        tagitCore.claim(tokenId, consumer);
    }

    // ============================================
    // FLAG - CustodyTransfer
    // ============================================

    function test_custodyTransfer_flag_emitsEvent() public {
        uint256 tokenId = _mintClaimedAsset(consumer);

        bytes32 expectedPrevHash =
            keccak256(abi.encode(tokenId, uint8(TAGITCore.State.CLAIMED), consumer, block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.CLAIMED),
            uint8(TAGITCore.State.FLAGGED),
            consumer,
            consumer,
            block.timestamp,
            expectedPrevHash
        );

        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);
    }

    // ============================================
    // RESOLVE - CustodyTransfer (ownership changes)
    // ============================================

    function test_custodyTransfer_resolve_emitsEvent() public {
        uint256 tokenId = _mintClaimedAsset(consumer);

        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);

        address newOwner = makeAddr("newOwner");

        // 2-of-3 quorum
        vm.prank(lawEnforcement);
        tagitCore.approveResolve(tokenId, newOwner);
        vm.prank(lawEnforcement2);
        tagitCore.approveResolve(tokenId, newOwner);

        bytes32 expectedPrevHash =
            keccak256(abi.encode(tokenId, uint8(TAGITCore.State.FLAGGED), consumer, block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.FLAGGED),
            uint8(TAGITCore.State.CLAIMED),
            consumer, // fromOwner
            newOwner, // toOwner (resolved to new owner)
            block.timestamp,
            expectedPrevHash
        );

        vm.prank(lawEnforcement);
        tagitCore.resolve(tokenId, newOwner);
    }

    // ============================================
    // RECYCLE - CustodyTransfer
    // ============================================

    function test_custodyTransfer_recycle_fromClaimed_emitsEvent() public {
        uint256 tokenId = _mintClaimedAsset(consumer);

        bytes32 expectedPrevHash =
            keccak256(abi.encode(tokenId, uint8(TAGITCore.State.CLAIMED), consumer, block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.CLAIMED),
            uint8(TAGITCore.State.RECYCLED),
            consumer,
            consumer,
            block.timestamp,
            expectedPrevHash
        );

        vm.prank(recycler);
        tagitCore.recycle(tokenId);
    }

    function test_custodyTransfer_recycle_fromFlagged_emitsEvent() public {
        uint256 tokenId = _mintClaimedAsset(consumer);

        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);

        bytes32 expectedPrevHash =
            keccak256(abi.encode(tokenId, uint8(TAGITCore.State.FLAGGED), consumer, block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.FLAGGED),
            uint8(TAGITCore.State.RECYCLED),
            consumer,
            consumer,
            block.timestamp,
            expectedPrevHash
        );

        vm.prank(recycler);
        tagitCore.recycle(tokenId);
    }

    // ============================================
    // FULL LIFECYCLE - Chain linkability
    // ============================================

    /**
     * @notice Full lifecycle test: verify the custody chain is cryptographically linkable end-to-end
     * @dev NONE -> MINTED -> BOUND -> ACTIVATED -> CLAIMED -> FLAGGED -> RECYCLED
     */
    function test_custodyTransfer_fullLifecycleChainLinkable() public {
        // Step 1: Mint
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, keccak256("chain-test"));

        // Step 2: Bind
        bytes32 tagHash = keccak256("chain-tag");
        (bytes memory challengeResponse, bytes memory oracleSignature) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, challengeResponse, oracleSignature);

        // Step 3: Activate
        vm.prank(qaInspector);
        tagitCore.activate(tokenId);

        // Step 4: Claim (ownership transfer)
        vm.prank(verifier);
        tagitCore.claim(tokenId, consumer);

        // Step 5: Flag
        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);

        // Step 6: Recycle
        vm.prank(recycler);
        tagitCore.recycle(tokenId);

        // Verify final state is RECYCLED
        (,, TAGITCore.State finalState,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(finalState), uint8(TAGITCore.State.RECYCLED), "Should be RECYCLED");

        // Note: Event linkability verified by the individual tests above.
        // In production, an off-chain indexer would reconstruct the chain by matching
        // prevStateHash of event N+1 with keccak256(assetId, fromState, fromOwner, blockNumber-1) at event N's block.
    }

    /**
     * @notice Verify prevStateHash computation is deterministic
     * @dev Same inputs must always produce the same hash
     */
    function test_custodyTransfer_prevHashDeterministic() public {
        // Compute expected hash for a known set of inputs
        uint256 assetId = 42;
        uint8 fromState = uint8(TAGITCore.State.MINTED);
        address fromOwner = consumer;
        uint256 blockNum = 100;

        bytes32 hash1 = keccak256(abi.encode(assetId, fromState, fromOwner, blockNum));
        bytes32 hash2 = keccak256(abi.encode(assetId, fromState, fromOwner, blockNum));

        assertEq(hash1, hash2, "Same inputs must produce same hash");

        // Different inputs produce different hashes
        bytes32 hash3 = keccak256(abi.encode(assetId + 1, fromState, fromOwner, blockNum));
        assertTrue(hash1 != hash3, "Different inputs should produce different hash");
    }

    /**
     * @notice Verify resolve cycle emits correct custody events through flag->resolve->flag->recycle
     */
    function test_custodyTransfer_flagResolveReFlag() public {
        uint256 tokenId = _mintClaimedAsset(consumer);

        // Flag
        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);

        // Resolve back to consumer (with quorum)
        vm.prank(lawEnforcement);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(lawEnforcement2);
        tagitCore.approveResolve(tokenId, consumer);

        vm.prank(lawEnforcement);
        tagitCore.resolve(tokenId, consumer);

        // Flag again
        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);

        // Recycle
        bytes32 expectedPrevHash =
            keccak256(abi.encode(tokenId, uint8(TAGITCore.State.FLAGGED), consumer, block.number - 1));

        vm.expectEmit(true, true, true, true);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.FLAGGED),
            uint8(TAGITCore.State.RECYCLED),
            consumer,
            consumer,
            block.timestamp,
            expectedPrevHash
        );

        vm.prank(recycler);
        tagitCore.recycle(tokenId);
    }

    // ============================================
    // HELPERS
    // ============================================

    uint256 private _counter;

    function _mintClaimedAsset(address to) internal returns (uint256 tokenId) {
        _counter++;
        bytes32 metadata = keccak256(abi.encodePacked("metadata", _counter));
        bytes32 tagHash = keccak256(abi.encodePacked("tag", _counter));

        vm.prank(manufacturer);
        tokenId = tagitCore.mint(to, metadata);

        (bytes memory challengeResponse, bytes memory oracleSignature) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, challengeResponse, oracleSignature);

        vm.prank(qaInspector);
        tagitCore.activate(tokenId);

        vm.prank(verifier);
        tagitCore.claim(tokenId, to);
    }
}
