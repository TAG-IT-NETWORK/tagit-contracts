// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";

/**
 * @title TAGITCore_Reentrancy
 * @notice Security tests proving reentrancy and transfer protections on TAGITCore
 * @dev Tests cover four defense layers:
 *
 *   1. nonReentrant modifier on claim() and resolve()
 *      - Verified by pre-setting the ReentrancyGuard _status to ENTERED (slot 0)
 *        via vm.store, then calling the protected function. The modifier checks
 *        _status == ENTERED and reverts with ReentrancyGuardReentrantCall().
 *
 *   2. _update() override blocking external ERC-721 transfers
 *      - transferFrom, safeTransferFrom, and approved transfers all revert with
 *        TransferDisabled(), making ownership desync through standard ERC-721
 *        methods impossible at every lifecycle stage.
 *
 *   3. State integrity after claim and resolve
 *      - After claim(), asset state is CLAIMED and ERC-721 ownerOf matches.
 *      - After resolve(), asset state returns to CLAIMED with correct owner.
 *      - Double-claim is prevented by state validation.
 *
 *   4. onERC721Received callback not triggered by internal _transfer
 *      - OZ v5 _transfer does NOT call onERC721Received (only safeTransfer does),
 *        so the ERC-721 receive hook is never reachable during claim()/resolve().
 *        Combined with nonReentrant, the attack surface for callback-based
 *        reentrancy is eliminated.
 */
contract TAGITCore_Reentrancy is Test {
    // ============================================
    // CONTRACTS
    // ============================================

    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    /// @dev Address of the ERC1967 proxy (storage lives here)
    address public proxy;

    // ============================================
    // ACTORS
    // ============================================

    address public owner;
    address public manufacturer;
    address public resolver2;
    address public consumer;
    address public attacker;

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 constant ORACLE_PK = 0xA11CE;

    bytes32 public constant METADATA = keccak256("ipfs://QmReentrancyTest");
    bytes32 public constant TAG_HASH = keccak256("NFC_TAG_REENTRY_001");
    bytes32 public constant TAG_HASH_2 = keccak256("NFC_TAG_REENTRY_002");
    bytes32 public constant TAG_HASH_3 = keccak256("NFC_TAG_REENTRY_003");

    /// @dev ReentrancyGuard._status lives at storage slot 0 on the proxy
    ///      (confirmed via `forge inspect TAGITCore storage-layout`)
    bytes32 constant REENTRANCY_SLOT = bytes32(uint256(0));

    /// @dev ReentrancyGuard constants: NOT_ENTERED = 1, ENTERED = 2
    bytes32 constant REENTRANCY_ENTERED = bytes32(uint256(2));
    bytes32 constant REENTRANCY_NOT_ENTERED = bytes32(uint256(1));

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        resolver2 = makeAddr("resolver2");
        consumer = makeAddr("consumer");
        attacker = makeAddr("attacker");

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
        ERC1967Proxy erc1967Proxy = new ERC1967Proxy(address(implementation), initData);
        proxy = address(erc1967Proxy);
        tagitCore = TAGITCore(proxy);

        // Set up access controller
        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        // Set trusted oracle
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

        // Grant RESOLVER_CAPABILITY to resolver2 for quorum
        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));
    }

    // ============================================
    // HELPERS
    // ============================================

    /// @dev Sign an oracle attestation for bindTag
    function _oracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        pure
        returns (bytes memory challengeResponse, bytes memory oracleSignature)
    {
        challengeResponse = abi.encodePacked("challenge", tokenId);
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, ethHash);
        oracleSignature = abi.encodePacked(r, s, v);
    }

    /// @dev Advance an asset through MINTED -> BOUND -> ACTIVATED
    function _mintAndActivate(address to, bytes32 tagHash) internal returns (uint256 tokenId) {
        vm.prank(manufacturer);
        tokenId = tagitCore.mint(to, METADATA);

        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        vm.prank(manufacturer);
        tagitCore.activate(tokenId);
    }

    /// @dev Advance an asset to FLAGGED state
    function _mintToFlagged(address originalOwner, address claimOwner, bytes32 tagHash)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _mintAndActivate(originalOwner, tagHash);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, claimOwner);

        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
    }

    // ============================================
    // TEST 1: claim() nonReentrant guard — storage-level proof
    // ============================================

    /**
     * @notice Prove that claim() has the nonReentrant modifier by manipulating
     *         the ReentrancyGuard lock state before calling claim()
     * @dev Strategy:
     *      1. Mint and activate an asset to ACTIVATED state (normal flow)
     *      2. Use vm.store to set _status = ENTERED (slot 0) on the proxy
     *      3. Call claim() — must revert with ReentrancyGuardReentrantCall
     *      4. Reset _status = NOT_ENTERED and verify claim() succeeds normally
     *
     *      This proves the nonReentrant modifier is present on claim() by simulating
     *      what would happen if an attacker managed to re-enter during execution:
     *      the _status would be ENTERED and the modifier would block the call.
     */
    function test_claim_nonReentrant_reverts_when_guard_entered() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        // Set ReentrancyGuard._status = ENTERED on the proxy
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_ENTERED);

        // Verify the slot is set correctly
        bytes32 stored = vm.load(proxy, REENTRANCY_SLOT);
        assertEq(stored, REENTRANCY_ENTERED, "Guard must be in ENTERED state");

        // claim() must revert because _status == ENTERED
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        tagitCore.claim(tokenId, consumer);

        // Reset guard so normal operations resume
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_NOT_ENTERED);

        // Now claim() succeeds
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        // Verify success
        (address assetOwner,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State must be CLAIMED");
        assertEq(assetOwner, consumer, "Owner must be consumer");
    }

    // ============================================
    // TEST 2: resolve() nonReentrant guard — storage-level proof
    // ============================================

    /**
     * @notice Prove that resolve() has the nonReentrant modifier
     * @dev Same strategy as test 1 but targeting resolve().
     *      Sets _status = ENTERED, calls resolve(), expects revert.
     */
    function test_resolve_nonReentrant_reverts_when_guard_entered() public {
        uint256 tokenId = _mintToFlagged(manufacturer, consumer, TAG_HASH);

        // Build quorum
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);

        // Set ReentrancyGuard._status = ENTERED
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_ENTERED);

        // resolve() must revert because _status == ENTERED
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        tagitCore.resolve(tokenId, consumer);

        // Reset guard
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_NOT_ENTERED);

        // Now resolve() succeeds
        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, consumer);

        // Verify success
        (address assetOwner,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State must be CLAIMED after resolve");
        assertEq(assetOwner, consumer, "Owner must be consumer after resolve");
    }

    // ============================================
    // TEST 3: mint() nonReentrant guard — storage-level proof
    // ============================================

    /**
     * @notice Prove that mint() also has the nonReentrant modifier
     * @dev Additional verification — mint() should also be protected.
     */
    function test_mint_nonReentrant_reverts_when_guard_entered() public {
        // Set ReentrancyGuard._status = ENTERED
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_ENTERED);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        tagitCore.mint(consumer, METADATA);

        // Reset and verify normal mint works
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_NOT_ENTERED);

        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(consumer, METADATA);
        assertEq(tokenId, 1, "Token ID should be 1");
    }

    // ============================================
    // TEST 4: flag() nonReentrant guard — storage-level proof
    // ============================================

    /**
     * @notice Prove that flag() has the nonReentrant modifier
     */
    function test_flag_nonReentrant_reverts_when_guard_entered() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        // Set guard to ENTERED
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_ENTERED);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        tagitCore.flag(tokenId);

        // Reset and verify normal flag works
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_NOT_ENTERED);

        vm.prank(manufacturer);
        tagitCore.flag(tokenId);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.FLAGGED), "State must be FLAGGED");
    }

    // ============================================
    // TEST 5: claim() state integrity
    // ============================================

    /**
     * @notice Verify state integrity after a successful claim
     * @dev After claim(tokenId, consumer):
     *      - Asset state must be CLAIMED (not corrupted)
     *      - Asset owner in struct must be consumer
     *      - ERC-721 ownerOf(tokenId) must be consumer
     */
    function test_claim_state_integrity() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        (address assetOwner, uint64 timestamp, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);

        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State must be CLAIMED after claim()");
        assertEq(assetOwner, consumer, "Asset struct owner must be consumer");
        assertEq(tagitCore.ownerOf(tokenId), consumer, "ERC-721 ownerOf must match consumer");
        assertGt(timestamp, 0, "Timestamp must be set");
    }

    // ============================================
    // TEST 6: External transferFrom blocked
    // ============================================

    /**
     * @notice Prove that transferFrom reverts with TransferDisabled
     * @dev The _update() override blocks all external transfers (auth != address(0)).
     *      This makes it impossible to desync ERC-721 ownership from the asset struct.
     */
    function test_transferFrom_reverts_TransferDisabled() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        vm.prank(consumer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(consumer, attacker, tokenId);
    }

    /**
     * @notice Prove that safeTransferFrom also reverts with TransferDisabled
     */
    function test_safeTransferFrom_reverts_TransferDisabled() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        vm.prank(consumer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.safeTransferFrom(consumer, attacker, tokenId);
    }

    /**
     * @notice Prove that safeTransferFrom(data) also reverts
     */
    function test_safeTransferFromWithData_reverts_TransferDisabled() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        vm.prank(consumer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.safeTransferFrom(consumer, attacker, tokenId, "");
    }

    /**
     * @notice Prove transfer is blocked even with approval
     * @dev An approved operator also cannot transfer because _update() blocks
     *      all external calls regardless of approval status.
     */
    function test_approvedTransfer_reverts_TransferDisabled() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        // Consumer approves attacker
        vm.prank(consumer);
        tagitCore.approve(attacker, tokenId);

        // Attacker tries to use approval — still blocked
        vm.prank(attacker);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(consumer, attacker, tokenId);
    }

    // ============================================
    // TEST 7: External transfer blocked at every lifecycle stage
    // ============================================

    /**
     * @notice Transfer blocked in MINTED state
     */
    function test_transferBlocked_inMintedState() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(manufacturer, attacker, tokenId);
    }

    /**
     * @notice Transfer blocked in BOUND state
     */
    function test_transferBlocked_inBoundState() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA);

        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, TAG_HASH, cr, sig);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(manufacturer, attacker, tokenId);
    }

    /**
     * @notice Transfer blocked in ACTIVATED state
     */
    function test_transferBlocked_inActivatedState() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(manufacturer, attacker, tokenId);
    }

    /**
     * @notice Transfer blocked in FLAGGED state
     */
    function test_transferBlocked_inFlaggedState() public {
        uint256 tokenId = _mintToFlagged(manufacturer, consumer, TAG_HASH);

        vm.prank(consumer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(consumer, attacker, tokenId);
    }

    // ============================================
    // TEST 8: resolve() state integrity
    // ============================================

    /**
     * @notice Verify state integrity after a successful resolve
     * @dev After resolve(tokenId, newOwner):
     *      - Asset state must be CLAIMED (resolved back)
     *      - Asset owner must be the resolution recipient
     *      - ERC-721 ownerOf must match
     *      - Approval state must be cleared
     */
    function test_resolve_state_integrity() public {
        address resolvedOwner = makeAddr("resolvedOwner");

        uint256 tokenId = _mintToFlagged(manufacturer, consumer, TAG_HASH);

        // Build quorum: manufacturer + resolver2 both approve
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, resolvedOwner);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, resolvedOwner);

        // Execute resolve
        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, resolvedOwner);

        // Verify asset state
        (address assetOwner, uint64 timestamp, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);

        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State must be CLAIMED after resolve()");
        assertEq(assetOwner, resolvedOwner, "Asset struct owner must be resolvedOwner");
        assertEq(tagitCore.ownerOf(tokenId), resolvedOwner, "ERC-721 ownerOf must match resolvedOwner");
        assertGt(timestamp, 0, "Timestamp must be set");

        // Verify approval state was cleared
        (uint256 approvalCount, address recipient, bool quorumReached) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(approvalCount, 0, "Approval count must be reset to 0");
        assertEq(recipient, address(0), "Recipient must be cleared");
        assertFalse(quorumReached, "Quorum must not be reached after reset");
    }

    // ============================================
    // TEST 9: Double-claim prevention
    // ============================================

    /**
     * @notice Prove that claiming an already-claimed asset reverts
     * @dev After claim(), state is CLAIMED. A second claim() must revert with
     *      InvalidState because the asset is no longer in ACTIVATED state.
     */
    function test_doubleClaim_reverts() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        // First claim succeeds
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        // Second claim reverts — state is CLAIMED, not ACTIVATED
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector, tokenId, TAGITCore.State.CLAIMED, TAGITCore.State.ACTIVATED
            )
        );
        tagitCore.claim(tokenId, attacker);

        // Ownership unchanged
        assertEq(tagitCore.ownerOf(tokenId), consumer, "Owner must still be consumer");
    }

    // ============================================
    // TEST 10: Ownership desync impossible
    // ============================================

    /**
     * @notice Prove that ERC-721 ownerOf always matches asset struct owner
     * @dev After claim, both the ERC-721 layer and the asset struct reflect
     *      the same owner. Since external transfers are blocked, there is no
     *      way to make them diverge.
     */
    function test_ownershipSync_afterClaim() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        // Before claim: both layers agree on manufacturer
        assertEq(tagitCore.ownerOf(tokenId), manufacturer, "ERC-721 owner before claim");
        (address structOwner,,,,) = tagitCore.getAsset(tokenId);
        assertEq(structOwner, manufacturer, "Struct owner before claim");

        // Claim to consumer
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        // After claim: both layers agree on consumer
        assertEq(tagitCore.ownerOf(tokenId), consumer, "ERC-721 owner after claim");
        (structOwner,,,,) = tagitCore.getAsset(tokenId);
        assertEq(structOwner, consumer, "Struct owner after claim");

        // Attempt external transfer — blocked
        vm.prank(consumer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(consumer, attacker, tokenId);

        // Sync maintained
        assertEq(tagitCore.ownerOf(tokenId), consumer, "ERC-721 owner still consumer");
        (structOwner,,,,) = tagitCore.getAsset(tokenId);
        assertEq(structOwner, consumer, "Struct owner still consumer");
    }

    /**
     * @notice Prove ownership sync through the full resolve cycle
     */
    function test_ownershipSync_afterResolve() public {
        address resolvedOwner = makeAddr("resolvedOwner");
        uint256 tokenId = _mintToFlagged(manufacturer, consumer, TAG_HASH);

        // In FLAGGED state: consumer still owns it
        assertEq(tagitCore.ownerOf(tokenId), consumer, "ERC-721 owner in FLAGGED");
        (address structOwner,,,,) = tagitCore.getAsset(tokenId);
        assertEq(structOwner, consumer, "Struct owner in FLAGGED");

        // Build quorum and resolve
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, resolvedOwner);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, resolvedOwner);

        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, resolvedOwner);

        // Both layers agree on resolvedOwner
        assertEq(tagitCore.ownerOf(tokenId), resolvedOwner, "ERC-721 owner after resolve");
        (structOwner,,,,) = tagitCore.getAsset(tokenId);
        assertEq(structOwner, resolvedOwner, "Struct owner after resolve");
    }

    // ============================================
    // TEST 11: Attacker without capability cannot claim or resolve
    // ============================================

    /**
     * @notice Attacker without CLAIMER_CAPABILITY cannot claim
     */
    function test_claim_reverts_withoutCapability() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        vm.prank(attacker);
        vm.expectRevert(); // MissingCapability from TAGITAccess
        tagitCore.claim(tokenId, attacker);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.ACTIVATED), "State must still be ACTIVATED");
    }

    /**
     * @notice Attacker without RESOLVER_CAPABILITY cannot resolve
     */
    function test_resolve_reverts_withoutCapability() public {
        uint256 tokenId = _mintToFlagged(manufacturer, consumer, TAG_HASH);

        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);

        vm.prank(attacker);
        vm.expectRevert(); // MissingCapability from TAGITAccess
        tagitCore.resolve(tokenId, consumer);

        (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.FLAGGED), "State must still be FLAGGED");
    }

    // ============================================
    // TEST 12: Quorum enforcement on resolve
    // ============================================

    /**
     * @notice Prove that resolve() reverts without quorum
     * @dev resolve() requires RESOLVE_QUORUM (2) approvals. Only 1 approval => revert.
     */
    function test_resolve_reverts_withoutQuorum() public {
        uint256 tokenId = _mintToFlagged(manufacturer, consumer, TAG_HASH);

        // Only one approval
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, consumer);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.QuorumNotReached.selector, tokenId, 1, 2));
        tagitCore.resolve(tokenId, consumer);
    }

    // ============================================
    // TEST 13: Guard resets after successful call
    // ============================================

    /**
     * @notice Verify that the ReentrancyGuard properly resets after claim()
     * @dev After a successful claim(), _status must be back to NOT_ENTERED (1).
     *      This ensures the guard does not permanently lock the contract.
     */
    function test_reentrancyGuard_resets_after_claim() public {
        uint256 tokenId = _mintAndActivate(manufacturer, TAG_HASH);

        // Verify guard starts as NOT_ENTERED
        bytes32 statusBefore = vm.load(proxy, REENTRANCY_SLOT);
        assertEq(statusBefore, REENTRANCY_NOT_ENTERED, "Guard must be NOT_ENTERED before call");

        // Execute claim
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, consumer);

        // Verify guard returned to NOT_ENTERED
        bytes32 statusAfter = vm.load(proxy, REENTRANCY_SLOT);
        assertEq(statusAfter, REENTRANCY_NOT_ENTERED, "Guard must be NOT_ENTERED after call");
    }

    /**
     * @notice Verify that the ReentrancyGuard properly resets after resolve()
     */
    function test_reentrancyGuard_resets_after_resolve() public {
        uint256 tokenId = _mintToFlagged(manufacturer, consumer, TAG_HASH);

        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);

        // Verify guard starts as NOT_ENTERED
        bytes32 statusBefore = vm.load(proxy, REENTRANCY_SLOT);
        assertEq(statusBefore, REENTRANCY_NOT_ENTERED, "Guard must be NOT_ENTERED before call");

        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, consumer);

        // Verify guard returned to NOT_ENTERED
        bytes32 statusAfter = vm.load(proxy, REENTRANCY_SLOT);
        assertEq(statusAfter, REENTRANCY_NOT_ENTERED, "Guard must be NOT_ENTERED after call");
    }

    // ============================================
    // TEST 14: Cross-function reentrancy protection
    // ============================================

    /**
     * @notice Prove that cross-function reentrancy is blocked
     * @dev Since claim(), resolve(), flag(), mint() all share the same
     *      nonReentrant guard, setting _status = ENTERED blocks ALL of them.
     *      An attacker who somehow re-enters via claim() cannot call flag()
     *      or resolve() either.
     */
    function test_crossFunction_reentrancy_blocked() public {
        uint256 tokenId1 = _mintAndActivate(manufacturer, TAG_HASH);

        // Set guard to ENTERED (simulates being inside a nonReentrant call)
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_ENTERED);

        // All nonReentrant functions must revert
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        tagitCore.claim(tokenId1, consumer);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        tagitCore.mint(consumer, METADATA);

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        tagitCore.activate(tokenId1);

        // Reset guard
        vm.store(proxy, REENTRANCY_SLOT, REENTRANCY_NOT_ENTERED);
    }
}
