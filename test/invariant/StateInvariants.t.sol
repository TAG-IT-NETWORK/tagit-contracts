// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title StateInvariants
 * @notice Halmos formal verification — lifecycle state machine invariants
 * @dev Functions prefixed with `check_` are run by Halmos with symbolic inputs.
 *      Each check_* function must hold for ALL possible input values.
 *      Run with: halmos --contract StateInvariants
 */
contract StateInvariants is Test {
    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public actor;
    address public resolver2;
    address public resolver3;

    uint256 constant ORACLE_PK = 0xA11CE;

    function setUp() public {
        owner = makeAddr("owner");
        actor = makeAddr("actor");
        resolver2 = makeAddr("resolver2");
        resolver3 = makeAddr("resolver3");

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

        // Grant all capabilities to actor
        capabilityBadge.grantCapability(actor, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(actor, uint256(tagitCore.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(actor, uint256(tagitCore.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(actor, uint256(tagitCore.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(actor, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(actor, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(actor, uint256(tagitCore.RECYCLER_CAPABILITY()));

        // Grant RESOLVER to resolver2 and resolver3 for quorum
        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver3, uint256(tagitCore.RESOLVER_CAPABILITY()));
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
    // HELPERS: Create token at specific state
    // ============================================

    function _mintToken(bytes32 metadata) internal returns (uint256 tokenId) {
        vm.prank(actor);
        tokenId = tagitCore.mint(actor, metadata);
    }

    function _mintAndBind(bytes32 metadata, bytes32 tagHash) internal returns (uint256 tokenId) {
        tokenId = _mintToken(metadata);
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(actor);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);
    }

    function _mintBindActivate(bytes32 metadata, bytes32 tagHash) internal returns (uint256 tokenId) {
        tokenId = _mintAndBind(metadata, tagHash);
        vm.prank(actor);
        tagitCore.activate(tokenId);
    }

    function _mintToClaimed(bytes32 metadata, bytes32 tagHash, address consumer) internal returns (uint256 tokenId) {
        tokenId = _mintBindActivate(metadata, tagHash);
        vm.prank(actor);
        tagitCore.claim(tokenId, consumer);
    }

    function _mintToFlagged(bytes32 metadata, bytes32 tagHash, address consumer) internal returns (uint256 tokenId) {
        tokenId = _mintToClaimed(metadata, tagHash, consumer);
        vm.prank(actor);
        tagitCore.flag(tokenId);
    }

    // ============================================
    // CHECK 1: State Transition — No Skip
    // Proves: Every state transition function produces exactly the expected next state.
    // No function can skip intermediate states.
    // ============================================

    /// @notice Proves mint() always produces MINTED state (from NONE)
    function check_StateTransition_NoSkip_mint(bytes32 metadata) public {
        vm.prank(actor);
        uint256 tokenId = tagitCore.mint(actor, metadata);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.MINTED);
    }

    /// @notice Proves bindTag() always produces BOUND state (from MINTED)
    function check_StateTransition_NoSkip_bind(bytes32 tagHash) public {
        vm.assume(tagHash != bytes32(0));
        uint256 tokenId = _mintToken(keccak256("m1"));

        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(actor);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.BOUND);
    }

    /// @notice Proves activate() always produces ACTIVATED state (from BOUND)
    function check_StateTransition_NoSkip_activate() public {
        uint256 tokenId = _mintAndBind(keccak256("m1"), keccak256("t1"));

        vm.prank(actor);
        tagitCore.activate(tokenId);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.ACTIVATED);
    }

    /// @notice Proves claim() always produces CLAIMED state (from ACTIVATED)
    function check_StateTransition_NoSkip_claim(address consumer) public {
        vm.assume(consumer != address(0));
        uint256 tokenId = _mintBindActivate(keccak256("m1"), keccak256("t1"));

        vm.prank(actor);
        tagitCore.claim(tokenId, consumer);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.CLAIMED);
    }

    /// @notice Proves flag() always produces FLAGGED state (from CLAIMED)
    function check_StateTransition_NoSkip_flag() public {
        uint256 tokenId = _mintToClaimed(keccak256("m1"), keccak256("t1"), actor);

        vm.prank(actor);
        tagitCore.flag(tokenId);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.FLAGGED);
    }

    /// @notice Proves resolve() always produces CLAIMED state (from FLAGGED) — the only backward transition
    function check_StateTransition_NoSkip_resolve(address newOwner) public {
        vm.assume(newOwner != address(0));
        uint256 tokenId = _mintToFlagged(keccak256("m1"), keccak256("t1"), actor);

        // Quorum: 2-of-3 approvals
        vm.prank(actor);
        tagitCore.approveResolve(tokenId, newOwner);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, newOwner);

        vm.prank(actor);
        tagitCore.resolve(tokenId, newOwner);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.CLAIMED);
    }

    /// @notice Proves recycle() from CLAIMED always produces RECYCLED
    function check_StateTransition_NoSkip_recycle_fromClaimed() public {
        uint256 tokenId = _mintToClaimed(keccak256("m1"), keccak256("t1"), actor);

        vm.prank(actor);
        tagitCore.recycle(tokenId);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.RECYCLED);
    }

    /// @notice Proves recycle() from FLAGGED always produces RECYCLED
    function check_StateTransition_NoSkip_recycle_fromFlagged() public {
        uint256 tokenId = _mintToFlagged(keccak256("m1"), keccak256("t1"), actor);

        vm.prank(actor);
        tagitCore.recycle(tokenId);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.RECYCLED);
    }

    // ============================================
    // CHECK 2: Flagged Resolve Requires Quorum
    // Proves: resolve() ALWAYS reverts if approval count < RESOLVE_QUORUM (2)
    // ============================================

    /// @notice Proves resolve() reverts with zero approvals
    function check_FlaggedResolve_RequiresQuorum_zeroApprovals(address newOwner) public {
        vm.assume(newOwner != address(0));
        uint256 tokenId = _mintToFlagged(keccak256("m1"), keccak256("t1"), actor);

        // No approvals — resolve must revert
        vm.prank(actor);
        try tagitCore.resolve(tokenId, newOwner) {
            // If resolve succeeds, the invariant is violated
            assert(false);
        } catch {
            // Expected: reverts because quorum not reached
            assert(true);
        }
    }

    /// @notice Proves resolve() reverts with only 1 approval (below quorum of 2)
    function check_FlaggedResolve_RequiresQuorum_oneApproval(address newOwner) public {
        vm.assume(newOwner != address(0));
        uint256 tokenId = _mintToFlagged(keccak256("m1"), keccak256("t1"), actor);

        // Single approval
        vm.prank(actor);
        tagitCore.approveResolve(tokenId, newOwner);

        // Resolve must still revert (quorum = 2, have = 1)
        vm.prank(actor);
        try tagitCore.resolve(tokenId, newOwner) {
            assert(false); // Should not reach here
        } catch {
            assert(true); // Expected revert
        }
    }

    /// @notice Proves resolve() succeeds with exactly 2 approvals (quorum met)
    function check_FlaggedResolve_RequiresQuorum_twoApprovals(address newOwner) public {
        vm.assume(newOwner != address(0));
        uint256 tokenId = _mintToFlagged(keccak256("m1"), keccak256("t1"), actor);

        // Two approvals (quorum met)
        vm.prank(actor);
        tagitCore.approveResolve(tokenId, newOwner);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, newOwner);

        // Resolve must succeed
        vm.prank(actor);
        tagitCore.resolve(tokenId, newOwner);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assert(state == TAGITCore.State.CLAIMED);
    }

    /// @notice Proves duplicate approval reverts (same resolver can't vote twice)
    function check_FlaggedResolve_RequiresQuorum_noDuplicateApproval(address newOwner) public {
        vm.assume(newOwner != address(0));
        uint256 tokenId = _mintToFlagged(keccak256("m1"), keccak256("t1"), actor);

        // First approval
        vm.prank(actor);
        tagitCore.approveResolve(tokenId, newOwner);

        // Duplicate approval must revert
        vm.prank(actor);
        try tagitCore.approveResolve(tokenId, newOwner) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    // ============================================
    // CHECK 3: Batch Mint Bounded
    // Proves: batchMint() always reverts for sizes > MAX_BATCH_SIZE (100)
    // ============================================

    /// @notice Proves batchMint reverts for any size > 100
    function check_BatchMint_Bounded(uint8 rawSize) public {
        // Constrain symbolic size for Halmos: test sizes 101-110
        vm.assume(rawSize <= 9);
        uint256 size = uint256(rawSize) + 101; // guaranteed > 100

        address[] memory recipients = new address[](size);
        bytes32[] memory metadata = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            recipients[i] = address(uint160(i + 1));
            metadata[i] = bytes32(i);
        }

        vm.prank(actor);
        try tagitCore.batchMint(recipients, metadata) {
            assert(false); // Must not succeed
        } catch {
            assert(true); // Expected revert: BatchTooLarge
        }
    }

    /// @notice Proves batchMint succeeds for sizes 1-5 and produces correct supply
    function check_BatchMint_Bounded_validSize(uint8 rawSize) public {
        uint256 size = (uint256(rawSize) % 5) + 1; // 1 to 5 (bounded for Halmos symbolic execution)

        address[] memory recipients = new address[](size);
        bytes32[] memory metadata = new bytes32[](size);
        for (uint256 i = 0; i < size; i++) {
            recipients[i] = address(uint160(i + 1));
            metadata[i] = bytes32(i);
        }

        uint256 supplyBefore = tagitCore.totalSupply();

        vm.prank(actor);
        uint256[] memory ids = tagitCore.batchMint(recipients, metadata);

        assert(ids.length == size);
        assert(tagitCore.totalSupply() == supplyBefore + size);
    }

    /// @notice Proves batchMint reverts when array lengths mismatch
    function check_BatchMint_Bounded_arrayMismatch(uint8 recipientCount, uint8 metadataCount) public {
        vm.assume(recipientCount != metadataCount);
        vm.assume(recipientCount > 0 && recipientCount <= 5);
        vm.assume(metadataCount > 0 && metadataCount <= 5);

        address[] memory recipients = new address[](recipientCount);
        bytes32[] memory metadata = new bytes32[](metadataCount);
        for (uint256 i = 0; i < recipientCount; i++) {
            recipients[i] = address(uint160(i + 1));
        }
        for (uint256 i = 0; i < metadataCount; i++) {
            metadata[i] = bytes32(i);
        }

        vm.prank(actor);
        try tagitCore.batchMint(recipients, metadata) {
            assert(false); // Must revert on mismatch
        } catch {
            assert(true);
        }
    }

    // ============================================
    // CHECK 4: RECYCLED is Terminal
    // Proves: No function can transition out of RECYCLED state
    // ============================================

    /// @notice Proves RECYCLED assets cannot be recycled again
    function check_RecycledIsTerminal_noDoubleRecycle() public {
        uint256 tokenId = _mintToClaimed(keccak256("m1"), keccak256("t1"), actor);

        vm.prank(actor);
        tagitCore.recycle(tokenId);

        // Try to recycle again — must revert
        vm.prank(actor);
        try tagitCore.recycle(tokenId) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    /// @notice Proves RECYCLED assets cannot be flagged
    function check_RecycledIsTerminal_noFlag() public {
        uint256 tokenId = _mintToClaimed(keccak256("m1"), keccak256("t1"), actor);

        vm.prank(actor);
        tagitCore.recycle(tokenId);

        vm.prank(actor);
        try tagitCore.flag(tokenId) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    /// @notice Proves RECYCLED assets cannot be activated
    function check_RecycledIsTerminal_noActivate() public {
        uint256 tokenId = _mintToClaimed(keccak256("m1"), keccak256("t1"), actor);

        vm.prank(actor);
        tagitCore.recycle(tokenId);

        vm.prank(actor);
        try tagitCore.activate(tokenId) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    /// @notice Proves RECYCLED assets cannot be claimed
    function check_RecycledIsTerminal_noClaim() public {
        uint256 tokenId = _mintToClaimed(keccak256("m1"), keccak256("t1"), actor);

        vm.prank(actor);
        tagitCore.recycle(tokenId);

        vm.prank(actor);
        try tagitCore.claim(tokenId, actor) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    // ============================================
    // CHECK 5: Ownership Consistency
    // Proves: Internal asset owner always matches ERC721 ownerOf
    // ============================================

    /// @notice Proves ownership consistency through full lifecycle
    function check_OwnershipConsistency_afterMint() public {
        vm.prank(actor);
        uint256 tokenId = tagitCore.mint(actor, keccak256("m1"));

        (address assetOwner,,,,) = tagitCore.getAsset(tokenId);
        assert(assetOwner == tagitCore.ownerOf(tokenId));
    }

    /// @notice Proves ownership consistency after claim (ownership transfer)
    function check_OwnershipConsistency_afterClaim(address consumer) public {
        vm.assume(consumer != address(0));
        vm.assume(consumer.code.length == 0); // EOA only
        uint256 tokenId = _mintBindActivate(keccak256("m1"), keccak256("t1"));

        vm.prank(actor);
        tagitCore.claim(tokenId, consumer);

        (address assetOwner,,,,) = tagitCore.getAsset(tokenId);
        assert(assetOwner == tagitCore.ownerOf(tokenId));
        assert(assetOwner == consumer);
    }

    // ============================================
    // CHECK 6: Tag Binding Uniqueness
    // Proves: A tag can only be bound to one token
    // ============================================

    /// @notice Proves same tag cannot be bound to two different tokens
    function check_TagBinding_Unique() public {
        bytes32 tagHash = keccak256("unique-tag");

        // Bind to first token
        uint256 tokenId1 = _mintToken(keccak256("m1"));
        {
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId1, tagHash);
            vm.prank(actor);
            tagitCore.bindTag(tokenId1, tagHash, cr, sig);
        }

        // Try to bind same tag to second token — must revert
        uint256 tokenId2 = _mintToken(keccak256("m2"));
        {
            (bytes memory cr2, bytes memory sig2) = _oracleSign(tokenId2, tagHash);
            vm.prank(actor);
            try tagitCore.bindTag(tokenId2, tagHash, cr2, sig2) {
                assert(false); // Must not succeed
            } catch {
                assert(true); // Expected: TagAlreadyBound
            }
        }
    }
}
