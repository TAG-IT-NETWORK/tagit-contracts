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
 * @title TAGITCoreFuzzTest
 * @notice Comprehensive fuzz tests for TAGITCore lifecycle state machine
 * @dev Covers all state transitions, access control, oracle verification, batch minting,
 *      and invalid state transition rejection with randomized inputs.
 */
contract TAGITCoreFuzzTest is Test {
    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    // Test accounts
    address public owner;
    address public manufacturer;
    address public resolver2;
    address public resolver3;

    // Oracle private key for signing
    uint256 constant ORACLE_PK = 0xA11CE;

    // Pre-computed constants for test data
    bytes32 public constant DEFAULT_METADATA = keccak256("ipfs://QmFuzzTest");
    bytes32 public constant DEFAULT_TAG = keccak256("NFC_TAG_FUZZ_001");

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        resolver2 = makeAddr("resolver2");
        resolver3 = makeAddr("resolver3");

        // Deploy badge contracts
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();

        // Deploy TAGITAccess facade
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Deploy TAGITCore behind UUPS proxy
        TAGITCore implementation = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tagitCore = TAGITCore(address(proxy));

        // Set up access controller (as owner)
        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        // Set trusted oracle
        address oracle = vm.addr(ORACLE_PK);
        vm.prank(owner);
        tagitCore.setTrustedOracle(oracle);

        // Grant all 7 capabilities to manufacturer
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RECYCLER_CAPABILITY()));

        // Grant RESOLVER_CAPABILITY to resolver2 and resolver3 (for quorum)
        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver3, uint256(tagitCore.RESOLVER_CAPABILITY()));
    }

    // ============================================
    // ORACLE SIGNING HELPER
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
    // LIFECYCLE HELPERS
    // ============================================

    /// @dev Mint a token to `to` with `metadata`, returns tokenId
    function _mintToken(address to, bytes32 metadata) internal returns (uint256 tokenId) {
        vm.prank(manufacturer);
        tokenId = tagitCore.mint(to, metadata);
    }

    /// @dev Mint and bind a tag, returns tokenId
    function _mintAndBind(address to, bytes32 metadata, bytes32 tagHash) internal returns (uint256 tokenId) {
        tokenId = _mintToken(to, metadata);
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);
    }

    /// @dev Mint, bind, and activate, returns tokenId
    function _mintBindActivate(address to, bytes32 metadata, bytes32 tagHash) internal returns (uint256 tokenId) {
        tokenId = _mintAndBind(to, metadata, tagHash);
        vm.prank(manufacturer);
        tagitCore.activate(tokenId);
    }

    /// @dev Full lifecycle to CLAIMED state, returns tokenId
    function _fullLifecycleToClaimed(address mintTo, address claimTo, bytes32 metadata, bytes32 tagHash)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _mintBindActivate(mintTo, metadata, tagHash);
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, claimTo);
    }

    /// @dev Full lifecycle to FLAGGED state, returns tokenId
    function _fullLifecycleToFlagged(address mintTo, address claimTo, bytes32 metadata, bytes32 tagHash)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _fullLifecycleToClaimed(mintTo, claimTo, metadata, tagHash);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
    }

    // ============================================
    // 1. testFuzz_mint_randomRecipient
    // ============================================

    /**
     * @notice Fuzz: mint to any non-zero address with any metadata
     * @dev Verifies that mint succeeds for all valid recipients, that the resulting
     *      token is in MINTED state, the ERC721 owner is correct, total supply increments,
     *      and the asset metadata matches.
     */
    function testFuzz_mint_randomRecipient(address recipient, bytes32 metadata) public {
        // Preconditions: recipient must be non-zero and not a contract (ERC721 safety)
        vm.assume(recipient != address(0));
        vm.assume(recipient.code.length == 0);

        // Capture state before
        uint256 supplyBefore = tagitCore.totalSupply();

        // Act
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(recipient, metadata);

        // Assert: token ID is sequential
        assertEq(tokenId, supplyBefore + 1, "Token ID should be sequential");

        // Assert: total supply incremented
        assertEq(tagitCore.totalSupply(), supplyBefore + 1, "Total supply should increment by 1");

        // Assert: ERC721 owner matches recipient
        assertEq(tagitCore.ownerOf(tokenId), recipient, "ERC721 owner should be recipient");

        // Assert: asset state is MINTED
        (address assetOwner, uint64 timestamp, TAGITCore.State state, uint8 flags, uint16 reserved) =
            tagitCore.getAsset(tokenId);
        assertEq(assetOwner, recipient, "Asset owner should be recipient");
        assertEq(uint8(state), uint8(TAGITCore.State.MINTED), "State should be MINTED");
        assertGt(timestamp, 0, "Timestamp should be set");
        assertEq(flags, 0, "Flags should be zero");
        assertEq(reserved, 0, "Reserved should be zero");

        // Assert: no tag bound yet
        assertEq(tagitCore.getTagByToken(tokenId), bytes32(0), "No tag should be bound yet");
    }

    // ============================================
    // 2. testFuzz_bindTag_randomTag
    // ============================================

    /**
     * @notice Fuzz: bind any non-zero tag hash to a minted asset
     * @dev Verifies that bindTag transitions from MINTED to BOUND for any valid
     *      tag hash, that bidirectional tag mappings are correct, and that the
     *      oracle signature is properly verified.
     */
    function testFuzz_bindTag_randomTag(bytes32 tagHash) public {
        // Preconditions: tag hash must be non-zero
        vm.assume(tagHash != bytes32(0));

        // Setup: mint a token
        address recipient = makeAddr("bindRecipient");
        uint256 tokenId = _mintToken(recipient, DEFAULT_METADATA);

        // Generate valid oracle signature
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);

        // Act
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        // Assert: state transitioned to BOUND
        (, uint64 timestamp, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.BOUND), "State should be BOUND");
        assertGt(timestamp, 0, "Timestamp should be updated");

        // Assert: bidirectional tag mapping
        assertEq(tagitCore.getTokenByTag(tagHash), tokenId, "Tag should map to token");
        assertEq(tagitCore.getTagByToken(tokenId), tagHash, "Token should map to tag");
    }

    // ============================================
    // 3. testFuzz_fullLifecycle
    // ============================================

    /**
     * @notice Fuzz: complete lifecycle (MINTED -> BOUND -> ACTIVATED -> CLAIMED) with random values
     * @dev End-to-end test verifying the full happy-path lifecycle works for any
     *      valid combination of consumer address, metadata, and tag hash.
     */
    function testFuzz_fullLifecycle(address consumer, bytes32 metadata, bytes32 tagHash) public {
        // Preconditions
        vm.assume(consumer != address(0));
        vm.assume(consumer.code.length == 0);
        vm.assume(tagHash != bytes32(0));

        // Step 1: Mint
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, metadata);

        (,, TAGITCore.State stateAfterMint,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(stateAfterMint), uint8(TAGITCore.State.MINTED), "After mint: state should be MINTED");

        // Step 2: Bind tag
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        (,, TAGITCore.State stateAfterBind,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(stateAfterBind), uint8(TAGITCore.State.BOUND), "After bind: state should be BOUND");
        assertEq(tagitCore.getTokenByTag(tagHash), tokenId, "Tag mapping should be set");

        // Step 3: Activate
        vm.prank(manufacturer);
        tagitCore.activate(tokenId);

        (,, TAGITCore.State stateAfterActivate,,) = tagitCore.getAsset(tokenId);
        assertEq(
            uint8(stateAfterActivate), uint8(TAGITCore.State.ACTIVATED), "After activate: state should be ACTIVATED"
        );

        // Step 4: Claim
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        (address assetOwner,, TAGITCore.State stateAfterClaim,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(stateAfterClaim), uint8(TAGITCore.State.CLAIMED), "After claim: state should be CLAIMED");
        assertEq(assetOwner, consumer, "Asset owner should be consumer");
        assertEq(tagitCore.ownerOf(tokenId), consumer, "ERC721 owner should be consumer");

        // Verify tag mapping persists through lifecycle
        assertEq(tagitCore.getTokenByTag(tagHash), tokenId, "Tag mapping should persist after claim");
        assertEq(tagitCore.getTagByToken(tokenId), tagHash, "Token-to-tag mapping should persist after claim");
    }

    // ============================================
    // 4. testFuzz_invalidStateTransitions
    // ============================================

    /**
     * @notice Fuzz: attempt all invalid state transitions and verify they revert
     * @dev Exhaustively tests that invalid state transitions are rejected. Valid transitions are:
     *      NONE->MINTED (via mint), MINTED->BOUND (via bindTag), BOUND->ACTIVATED (via activate),
     *      ACTIVATED->CLAIMED (via claim), CLAIMED->FLAGGED (via flag), FLAGGED->CLAIMED (via resolve),
     *      CLAIMED->RECYCLED (via recycle), FLAGGED->RECYCLED (via recycle).
     *      All other transitions must revert.
     */
    function testFuzz_invalidStateTransitions(uint8 fromState, uint8 toState) public {
        // Bound state values to valid enum range (0-6)
        fromState = uint8(bound(fromState, 0, 6));
        toState = uint8(bound(toState, 0, 6));

        // Define valid transitions (fromState -> toState):
        // (0->1) NONE->MINTED: via mint
        // (1->2) MINTED->BOUND: via bindTag
        // (2->3) BOUND->ACTIVATED: via activate
        // (3->4) ACTIVATED->CLAIMED: via claim
        // (4->5) CLAIMED->FLAGGED: via flag
        // (5->4) FLAGGED->CLAIMED: via resolve (only backward transition)
        // (4->6) CLAIMED->RECYCLED: via recycle
        // (5->6) FLAGGED->RECYCLED: via recycle
        bool isValidTransition = (fromState == 0 && toState == 1) || (fromState == 1 && toState == 2)
            || (fromState == 2 && toState == 3) || (fromState == 3 && toState == 4) || (fromState == 4 && toState == 5)
            || (fromState == 5 && toState == 4) || (fromState == 4 && toState == 6) || (fromState == 5 && toState == 6);

        // Skip valid transitions (tested by other fuzz tests)
        if (isValidTransition) return;

        // Skip identity transition (same state)
        if (fromState == toState) return;

        // Create a token and advance it to `fromState`
        address recipient = makeAddr("stateTestRecipient");
        bytes32 metadata = keccak256(abi.encodePacked("stateTest", fromState));
        bytes32 tagHash = keccak256(abi.encodePacked("stateTag", fromState));

        // We can only set up tokens to states reachable through the normal lifecycle
        // States 0 (NONE) cannot be directly tested since unminted tokens have no entry
        if (fromState == 0) {
            // NONE state: try calling functions on non-existent token
            uint256 fakeTokenId = 99999;
            if (toState == 2) {
                // NONE->BOUND: bindTag on non-existent
                (bytes memory cr, bytes memory sig) = _oracleSign(fakeTokenId, tagHash);
                vm.prank(manufacturer);
                vm.expectRevert();
                tagitCore.bindTag(fakeTokenId, tagHash, cr, sig);
            } else if (toState == 3) {
                // NONE->ACTIVATED: activate non-existent
                vm.prank(manufacturer);
                vm.expectRevert();
                tagitCore.activate(fakeTokenId);
            } else if (toState == 4) {
                // NONE->CLAIMED: claim non-existent
                vm.prank(manufacturer);
                vm.expectRevert();
                tagitCore.claim(fakeTokenId, recipient);
            } else if (toState == 5) {
                // NONE->FLAGGED: flag non-existent
                vm.prank(manufacturer);
                vm.expectRevert();
                tagitCore.flag(fakeTokenId);
            } else if (toState == 6) {
                // NONE->RECYCLED: recycle non-existent
                vm.prank(manufacturer);
                vm.expectRevert();
                tagitCore.recycle(fakeTokenId);
            }
            return;
        }

        // For states 1-6, create token and advance to fromState
        uint256 tokenId;

        if (fromState == 1) {
            // MINTED
            tokenId = _mintToken(recipient, metadata);
        } else if (fromState == 2) {
            // BOUND
            tokenId = _mintAndBind(recipient, metadata, tagHash);
        } else if (fromState == 3) {
            // ACTIVATED
            tokenId = _mintBindActivate(recipient, metadata, tagHash);
        } else if (fromState == 4) {
            // CLAIMED
            tokenId = _fullLifecycleToClaimed(manufacturer, recipient, metadata, tagHash);
        } else if (fromState == 5) {
            // FLAGGED
            tokenId = _fullLifecycleToFlagged(manufacturer, recipient, metadata, tagHash);
        } else if (fromState == 6) {
            // RECYCLED
            tokenId = _fullLifecycleToClaimed(manufacturer, recipient, metadata, tagHash);
            vm.prank(manufacturer);
            tagitCore.recycle(tokenId);
        }

        // Now attempt the invalid transition
        // For each possible toState, call the function that would produce that transition
        if (toState == 1) {
            // Trying to go to MINTED: no function transitions *to* MINTED from an existing token
            // mint() creates new tokens, it doesn't transition existing ones
            // This transition is inherently impossible through the API
            return;
        } else if (toState == 2) {
            // Trying to go to BOUND via bindTag
            bytes32 newTag = keccak256(abi.encodePacked("invalidTag", fromState, toState));
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, newTag);
            vm.prank(manufacturer);
            vm.expectRevert();
            tagitCore.bindTag(tokenId, newTag, cr, sig);
        } else if (toState == 3) {
            // Trying to go to ACTIVATED via activate
            vm.prank(manufacturer);
            vm.expectRevert();
            tagitCore.activate(tokenId);
        } else if (toState == 4) {
            // Trying to go to CLAIMED via claim
            if (fromState == 5) {
                // FLAGGED->CLAIMED via resolve is valid, but claim() from FLAGGED is invalid
                vm.prank(manufacturer);
                vm.expectRevert();
                tagitCore.claim(tokenId, recipient);
            } else {
                vm.prank(manufacturer);
                vm.expectRevert();
                tagitCore.claim(tokenId, recipient);
            }
        } else if (toState == 5) {
            // Trying to go to FLAGGED via flag
            vm.prank(manufacturer);
            vm.expectRevert();
            tagitCore.flag(tokenId);
        } else if (toState == 6) {
            // Trying to go to RECYCLED via recycle
            vm.prank(manufacturer);
            vm.expectRevert();
            tagitCore.recycle(tokenId);
        }
    }

    // ============================================
    // 5. testFuzz_batchMint_randomSize
    // ============================================

    /**
     * @notice Fuzz: batch mint with random sizes bounded to 1-100
     * @dev Verifies that batchMint works correctly for any valid batch size,
     *      that all tokens are created in MINTED state with correct owners,
     *      and that total supply increments correctly.
     */
    function testFuzz_batchMint_randomSize(uint8 size) public {
        // Bound size to valid range (1-100 = MAX_BATCH_SIZE)
        uint256 batchSize = bound(uint256(size), 1, 100);

        // Build recipient and metadata arrays
        address[] memory recipients = new address[](batchSize);
        bytes32[] memory metadata = new bytes32[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            // Generate distinct addresses for each slot to avoid collisions
            recipients[i] = address(uint160(uint256(keccak256(abi.encodePacked("batchRecipient", i)))));
            metadata[i] = keccak256(abi.encodePacked("batchMeta", i));

            // Make sure none of the generated addresses are zero or contracts
            vm.assume(recipients[i] != address(0));
        }

        // Capture state before
        uint256 supplyBefore = tagitCore.totalSupply();

        // Act
        vm.prank(manufacturer);
        uint256[] memory tokenIds = tagitCore.batchMint(recipients, metadata);

        // Assert: correct number of tokens minted
        assertEq(tokenIds.length, batchSize, "Should return correct number of token IDs");

        // Assert: total supply incremented correctly
        assertEq(tagitCore.totalSupply(), supplyBefore + batchSize, "Total supply should increment by batch size");

        // Assert: each token is correctly initialized
        for (uint256 i = 0; i < batchSize; i++) {
            uint256 tokenId = tokenIds[i];

            // Token IDs should be sequential
            assertEq(tokenId, supplyBefore + i + 1, "Token IDs should be sequential");

            // ERC721 owner should match
            assertEq(tagitCore.ownerOf(tokenId), recipients[i], "ERC721 owner should match recipient");

            // Asset state should be MINTED
            (address assetOwner, uint64 timestamp, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
            assertEq(assetOwner, recipients[i], "Asset owner should match recipient");
            assertEq(uint8(state), uint8(TAGITCore.State.MINTED), "State should be MINTED");
            assertGt(timestamp, 0, "Timestamp should be set");
        }
    }

    // ============================================
    // 6. testFuzz_claim_randomOwner
    // ============================================

    /**
     * @notice Fuzz: claim to random non-zero addresses
     * @dev Verifies that claim correctly transfers both internal asset ownership
     *      and ERC721 token ownership to any valid address, and that state
     *      transitions to CLAIMED.
     */
    function testFuzz_claim_randomOwner(address newOwner) public {
        // Preconditions
        vm.assume(newOwner != address(0));
        vm.assume(newOwner.code.length == 0);

        // Setup: create an ACTIVATED asset
        bytes32 tagHash = keccak256(abi.encodePacked("claimTag", newOwner));
        uint256 tokenId = _mintBindActivate(manufacturer, DEFAULT_METADATA, tagHash);

        // Verify pre-claim state
        assertEq(tagitCore.ownerOf(tokenId), manufacturer, "Pre-claim: ERC721 owner should be manufacturer");
        (,, TAGITCore.State preState,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(preState), uint8(TAGITCore.State.ACTIVATED), "Pre-claim: state should be ACTIVATED");

        // Act
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, newOwner);

        // Assert: state transitioned to CLAIMED
        (address assetOwner, uint64 timestamp, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State should be CLAIMED");
        assertEq(assetOwner, newOwner, "Asset owner should be newOwner");
        assertGt(timestamp, 0, "Timestamp should be updated");

        // Assert: ERC721 ownership transferred
        assertEq(tagitCore.ownerOf(tokenId), newOwner, "ERC721 owner should be newOwner");
    }

    // ============================================
    // 7. testFuzz_resolve_randomRecipient
    // ============================================

    /**
     * @notice Fuzz: resolve a flagged asset to random non-zero recipient with quorum
     * @dev Verifies that the 2-of-3 quorum resolve mechanism works for any valid
     *      recipient address, transferring ownership and reverting state to CLAIMED.
     */
    function testFuzz_resolve_randomRecipient(address newOwner) public {
        // Preconditions
        vm.assume(newOwner != address(0));
        vm.assume(newOwner.code.length == 0);

        // Setup: create a FLAGGED asset
        address originalClaimer = makeAddr("originalClaimer");
        bytes32 tagHash = keccak256(abi.encodePacked("resolveTag", newOwner));
        uint256 tokenId = _fullLifecycleToFlagged(manufacturer, originalClaimer, DEFAULT_METADATA, tagHash);

        // Verify pre-resolve state
        (,, TAGITCore.State preState,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(preState), uint8(TAGITCore.State.FLAGGED), "Pre-resolve: state should be FLAGGED");

        // Approve resolve: 2-of-3 quorum (manufacturer + resolver2)
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, newOwner);

        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, newOwner);

        // Verify quorum status
        (uint256 approvalCount, address recipient, bool quorumReached) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(approvalCount, 2, "Should have 2 approvals");
        assertEq(recipient, newOwner, "Recipient should match");
        assertTrue(quorumReached, "Quorum should be reached");

        // Act
        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, newOwner);

        // Assert: state reverted to CLAIMED (the only backward transition)
        (address assetOwner, uint64 timestamp, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State should be CLAIMED after resolve");
        assertEq(assetOwner, newOwner, "Asset owner should be newOwner");
        assertGt(timestamp, 0, "Timestamp should be updated");

        // Assert: ERC721 ownership transferred to new owner
        assertEq(tagitCore.ownerOf(tokenId), newOwner, "ERC721 owner should be newOwner");

        // Assert: resolve approval state is cleared (nonce incremented)
        (uint256 postApprovalCount,, bool postQuorum) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(postApprovalCount, 0, "Approval count should be reset after resolve");
        assertFalse(postQuorum, "Quorum should not be reached after reset");
    }

    // ============================================
    // 8. testFuzz_recycle_fromBothStates
    // ============================================

    /**
     * @notice Fuzz: recycle from either CLAIMED or FLAGGED state
     * @dev Verifies that recycle transitions to the terminal RECYCLED state from
     *      both valid source states, and that ownership is NOT transferred.
     */
    function testFuzz_recycle_fromBothStates(bool fromFlagged) public {
        address claimRecipient = makeAddr("recycleRecipient");
        bytes32 tagHash = keccak256(abi.encodePacked("recycleTag", fromFlagged));
        uint256 tokenId;

        if (fromFlagged) {
            // Setup: advance to FLAGGED
            tokenId = _fullLifecycleToFlagged(manufacturer, claimRecipient, DEFAULT_METADATA, tagHash);

            // Verify pre-recycle state
            (,, TAGITCore.State preState,,) = tagitCore.getAsset(tokenId);
            assertEq(uint8(preState), uint8(TAGITCore.State.FLAGGED), "Pre-recycle: state should be FLAGGED");
        } else {
            // Setup: advance to CLAIMED
            tokenId = _fullLifecycleToClaimed(manufacturer, claimRecipient, DEFAULT_METADATA, tagHash);

            // Verify pre-recycle state
            (,, TAGITCore.State preState,,) = tagitCore.getAsset(tokenId);
            assertEq(uint8(preState), uint8(TAGITCore.State.CLAIMED), "Pre-recycle: state should be CLAIMED");
        }

        // Capture owner before recycle
        (address ownerBefore,,,,) = tagitCore.getAsset(tokenId);

        // Act
        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);

        // Assert: state is RECYCLED (terminal)
        (address assetOwner, uint64 timestamp, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.RECYCLED), "State should be RECYCLED");
        assertGt(timestamp, 0, "Timestamp should be updated");

        // Assert: ownership is NOT transferred during recycle
        assertEq(assetOwner, ownerBefore, "Owner should remain unchanged after recycle");

        // Assert: recycled asset cannot be recycled again
        vm.prank(manufacturer);
        vm.expectRevert();
        tagitCore.recycle(tokenId);

        // Assert: recycled asset cannot transition to any other state
        vm.prank(manufacturer);
        vm.expectRevert();
        tagitCore.flag(tokenId);

        vm.prank(manufacturer);
        vm.expectRevert();
        tagitCore.activate(tokenId);
    }

    // ============================================
    // 9. testFuzz_oracleSignature_wrongKey
    // ============================================

    /**
     * @notice Fuzz: verify that a wrong oracle private key always causes bindTag to revert
     * @dev Signs the correct message with a random wrong key and ensures the contract
     *      rejects the signature, since only the trusted oracle's key is accepted.
     */
    function testFuzz_oracleSignature_wrongKey(uint256 wrongKey) public {
        // Preconditions: key must be valid for ECDSA (non-zero, within secp256k1 order)
        vm.assume(wrongKey != 0);
        vm.assume(wrongKey != ORACLE_PK); // Must be different from the real oracle key
        // secp256k1 order
        vm.assume(wrongKey < 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141);

        // Setup: mint a token
        address recipient = makeAddr("oracleTestRecipient");
        uint256 tokenId = _mintToken(recipient, DEFAULT_METADATA);
        bytes32 tagHash = keccak256(abi.encodePacked("oracleTag", wrongKey));

        // Generate signature with WRONG key
        bytes memory challengeResponse = abi.encodePacked("challenge", tokenId);
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethHash);
        bytes memory wrongSignature = abi.encodePacked(r, s, v);

        // Act: attempt to bind with wrong oracle signature
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId, tagHash, challengeResponse, wrongSignature);

        // Verify token state unchanged
        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.MINTED), "State should remain MINTED after failed bind");

        // Verify no tag was bound
        assertEq(tagitCore.getTagByToken(tokenId), bytes32(0), "No tag should be bound");
        assertEq(tagitCore.getTokenByTag(tagHash), 0, "Tag mapping should be empty");
    }

    // ============================================
    // 10. testFuzz_unauthorizedCaller
    // ============================================

    /**
     * @notice Fuzz: verify that random non-authorized callers revert on all lifecycle functions
     * @dev For any random address that has not been granted capabilities, every
     *      state-changing function on TAGITCore must revert.
     */
    function testFuzz_unauthorizedCaller(address caller) public {
        // Preconditions: caller must not be any of the authorized addresses
        vm.assume(caller != address(0));
        vm.assume(caller != manufacturer);
        vm.assume(caller != resolver2);
        vm.assume(caller != resolver3);
        vm.assume(caller != owner);
        vm.assume(caller != address(tagitCore));
        vm.assume(caller != address(tagitAccess));
        vm.assume(caller != address(capabilityBadge));
        vm.assume(caller != address(identityBadge));
        vm.assume(caller.code.length == 0);

        // Setup: create tokens at various lifecycle stages using a fixed array to reduce stack depth
        // tokens[0]=MINTED, tokens[1]=BOUND, tokens[2]=ACTIVATED, tokens[3]=CLAIMED, tokens[4]=FLAGGED
        uint256[5] memory tokens;
        address recipient = makeAddr("authTestRecipient");

        {
            tokens[0] = _mintToken(recipient, DEFAULT_METADATA);
        }
        {
            bytes32 th2 = keccak256(abi.encodePacked("authTag2", caller));
            tokens[1] = _mintAndBind(recipient, DEFAULT_METADATA, th2);
        }
        {
            bytes32 th3 = keccak256(abi.encodePacked("authTag3", caller));
            tokens[2] = _mintBindActivate(manufacturer, DEFAULT_METADATA, th3);
        }
        {
            bytes32 th4 = keccak256(abi.encodePacked("authTag4", caller));
            tokens[3] = _fullLifecycleToClaimed(manufacturer, recipient, DEFAULT_METADATA, th4);
        }
        {
            bytes32 th5 = keccak256(abi.encodePacked("authTag5", caller));
            tokens[4] = _fullLifecycleToFlagged(manufacturer, recipient, DEFAULT_METADATA, th5);
        }

        // Test 1: Unauthorized mint
        vm.prank(caller);
        vm.expectRevert();
        tagitCore.mint(caller, DEFAULT_METADATA);

        // Test 2: Unauthorized bindTag
        {
            bytes32 th1 = keccak256(abi.encodePacked("authTag1", caller));
            (bytes memory cr, bytes memory sig) = _oracleSign(tokens[0], th1);
            vm.prank(caller);
            vm.expectRevert();
            tagitCore.bindTag(tokens[0], th1, cr, sig);
        }

        // Test 3: Unauthorized activate
        vm.prank(caller);
        vm.expectRevert();
        tagitCore.activate(tokens[1]);

        // Test 4: Unauthorized claim
        vm.prank(caller);
        vm.expectRevert();
        tagitCore.claim(tokens[2], caller);

        // Test 5: Unauthorized flag
        vm.prank(caller);
        vm.expectRevert();
        tagitCore.flag(tokens[3]);

        // Test 6: Unauthorized approveResolve
        vm.prank(caller);
        vm.expectRevert();
        tagitCore.approveResolve(tokens[4], caller);

        // Test 7: Unauthorized resolve
        vm.prank(caller);
        vm.expectRevert();
        tagitCore.resolve(tokens[4], caller);

        // Test 8: Unauthorized recycle (from CLAIMED)
        vm.prank(caller);
        vm.expectRevert();
        tagitCore.recycle(tokens[3]);

        // Test 9: Unauthorized recycle (from FLAGGED)
        vm.prank(caller);
        vm.expectRevert();
        tagitCore.recycle(tokens[4]);

        // Test 10: Unauthorized batchMint
        {
            address[] memory recipients = new address[](1);
            recipients[0] = caller;
            bytes32[] memory metadataArr = new bytes32[](1);
            metadataArr[0] = DEFAULT_METADATA;
            vm.prank(caller);
            vm.expectRevert();
            tagitCore.batchMint(recipients, metadataArr);
        }

        // Verify: none of the token states changed
        _assertState(tokens[0], TAGITCore.State.MINTED, "Minted token state unchanged");
        _assertState(tokens[1], TAGITCore.State.BOUND, "Bound token state unchanged");
        _assertState(tokens[2], TAGITCore.State.ACTIVATED, "Activated token state unchanged");
        _assertState(tokens[3], TAGITCore.State.CLAIMED, "Claimed token state unchanged");
        _assertState(tokens[4], TAGITCore.State.FLAGGED, "Flagged token state unchanged");
    }

    /// @dev Helper to assert a token is in the expected state (reduces stack depth in callers)
    function _assertState(uint256 tokenId, TAGITCore.State expected, string memory message) internal view {
        (,, TAGITCore.State actual,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(actual), uint8(expected), message);
    }
}
