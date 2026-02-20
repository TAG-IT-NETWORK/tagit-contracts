// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title TAGITCoreResolveQuorumTest
 * @notice Unit tests for 2-of-3 multisig quorum on resolve() [PATCH-02]
 * @dev Tests approveResolve(), quorum enforcement, and edge cases
 */
contract TAGITCoreResolveQuorumTest is Test {
    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    // Test accounts
    address public owner;
    address public manufacturer;
    address public resolver1;
    address public resolver2;
    address public resolver3;
    address public consumer;
    address public unauthorizedUser;

    // Test data
    bytes32 public constant METADATA = keccak256("ipfs://QmTestQuorum");
    bytes32 public constant TAG_HASH = keccak256("NFC_TAG_QUORUM_001");

    // Events
    event ResolveApproved(uint256 indexed tokenId, address indexed approver, uint256 approvalCount);
    event StateChanged(uint256 indexed tokenId, TAGITCore.State from, TAGITCore.State to, address actor);

    function setUp() public {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        resolver1 = makeAddr("resolver1");
        resolver2 = makeAddr("resolver2");
        resolver3 = makeAddr("resolver3");
        consumer = makeAddr("consumer");
        unauthorizedUser = makeAddr("unauthorizedUser");

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

        // Set up access controller
        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        // Grant manufacturer all lifecycle capabilities
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RECYCLER_CAPABILITY()));

        // Grant RESOLVER_CAPABILITY to 3 independent resolvers
        capabilityBadge.grantCapability(resolver1, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver3, uint256(tagitCore.RESOLVER_CAPABILITY()));
    }

    // ============================================
    // HELPERS
    // ============================================

    /// @dev Mint → Bind → Activate → Claim → Flag an asset, returns tokenId
    function _setupFlaggedAsset() internal returns (uint256 tokenId) {
        vm.startPrank(manufacturer);
        tokenId = tagitCore.mint(manufacturer, METADATA);
        tagitCore.bindTag(tokenId, TAG_HASH);
        tagitCore.activate(tokenId);
        tagitCore.claim(tokenId, consumer);
        tagitCore.flag(tokenId);
        vm.stopPrank();
    }

    // ============================================
    // QUORUM CONSTANT
    // ============================================

    function test_resolveQuorum_isTwo() public view {
        assertEq(tagitCore.RESOLVE_QUORUM(), 2, "Quorum should be 2");
    }

    // ============================================
    // APPROVE RESOLVE TESTS
    // ============================================

    function test_approveResolve_firstApproval() public {
        uint256 tokenId = _setupFlaggedAsset();

        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);

        (uint256 count, address recipient, bool quorumReached) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(count, 1, "Approval count should be 1");
        assertEq(recipient, consumer, "Recipient should be consumer");
        assertFalse(quorumReached, "Quorum should not be reached yet");
    }

    function test_approveResolve_emitsEvent() public {
        uint256 tokenId = _setupFlaggedAsset();

        vm.expectEmit(true, true, false, true);
        emit ResolveApproved(tokenId, resolver1, 1);

        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);
    }

    function test_approveResolve_secondApproval_reachesQuorum() public {
        uint256 tokenId = _setupFlaggedAsset();

        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);

        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);

        (uint256 count, address recipient, bool quorumReached) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(count, 2, "Approval count should be 2");
        assertEq(recipient, consumer, "Recipient should be consumer");
        assertTrue(quorumReached, "Quorum should be reached");
    }

    // ============================================
    // RESOLVE WITH QUORUM TESTS
    // ============================================

    function test_resolve_succeedsWithQuorum() public {
        uint256 tokenId = _setupFlaggedAsset();

        // Two approvals
        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);

        // Any resolver can now execute resolve
        vm.prank(resolver3);
        tagitCore.resolve(tokenId, consumer);

        // Verify state
        (address assetOwner, , TAGITCore.State state, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State should be CLAIMED");
        assertEq(assetOwner, consumer, "Owner should be consumer");
        assertEq(tagitCore.ownerOf(tokenId), consumer, "ERC721 owner should be consumer");
    }

    function test_resolve_revertsWithSingleApproval() public {
        uint256 tokenId = _setupFlaggedAsset();

        // Only one approval
        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);

        // Resolve should revert
        vm.prank(resolver2);
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.QuorumNotReached.selector, tokenId, 1, 2)
        );
        tagitCore.resolve(tokenId, consumer);
    }

    function test_resolve_revertsWithNoApprovals() public {
        uint256 tokenId = _setupFlaggedAsset();

        vm.prank(resolver1);
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.QuorumNotReached.selector, tokenId, 0, 2)
        );
        tagitCore.resolve(tokenId, consumer);
    }

    function test_resolve_clearsApprovalState() public {
        uint256 tokenId = _setupFlaggedAsset();

        // Approve and resolve
        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver1);
        tagitCore.resolve(tokenId, consumer);

        // Verify approval state is cleared
        (uint256 count, address recipient, bool quorumReached) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(count, 0, "Approval count should be reset");
        assertEq(recipient, address(0), "Recipient should be cleared");
        assertFalse(quorumReached, "Quorum should not be reached");
    }

    function test_resolve_approverCanAlsoExecute() public {
        uint256 tokenId = _setupFlaggedAsset();

        // resolver1 approves and later executes
        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);

        // resolver1 (who approved) can also execute resolve
        vm.prank(resolver1);
        tagitCore.resolve(tokenId, consumer);

        (address assetOwner, , TAGITCore.State state, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State should be CLAIMED");
        assertEq(assetOwner, consumer, "Owner should be consumer");
    }

    // ============================================
    // DUPLICATE APPROVAL TESTS
    // ============================================

    function test_approveResolve_revertsDuplicateApproval() public {
        uint256 tokenId = _setupFlaggedAsset();

        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);

        // Same resolver tries to approve again
        vm.prank(resolver1);
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.AlreadyApproved.selector, tokenId, resolver1)
        );
        tagitCore.approveResolve(tokenId, consumer);
    }

    // ============================================
    // RECIPIENT MISMATCH TESTS
    // ============================================

    function test_approveResolve_revertsRecipientMismatch() public {
        uint256 tokenId = _setupFlaggedAsset();

        address differentRecipient = makeAddr("differentRecipient");

        // First approval sets consumer as recipient
        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);

        // Second approval with different recipient should revert
        vm.prank(resolver2);
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.RecipientMismatch.selector, tokenId, consumer, differentRecipient)
        );
        tagitCore.approveResolve(tokenId, differentRecipient);
    }

    function test_resolve_revertsRecipientMismatch() public {
        uint256 tokenId = _setupFlaggedAsset();

        address differentRecipient = makeAddr("differentRecipient");

        // Approve with consumer as recipient
        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);

        // Resolve with different recipient should revert
        vm.prank(resolver3);
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.RecipientMismatch.selector, tokenId, consumer, differentRecipient)
        );
        tagitCore.resolve(tokenId, differentRecipient);
    }

    // ============================================
    // ACCESS CONTROL TESTS
    // ============================================

    function test_approveResolve_revertsUnauthorized() public {
        uint256 tokenId = _setupFlaggedAsset();

        // Unauthorized user cannot approve
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        tagitCore.approveResolve(tokenId, consumer);
    }

    // ============================================
    // STATE VALIDATION TESTS
    // ============================================

    function test_approveResolve_revertsNonFlagged() public {
        // Create asset in CLAIMED state (not FLAGGED)
        vm.startPrank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA);
        tagitCore.bindTag(tokenId, TAG_HASH);
        tagitCore.activate(tokenId);
        tagitCore.claim(tokenId, consumer);
        vm.stopPrank();

        vm.prank(resolver1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector,
                tokenId,
                TAGITCore.State.CLAIMED,
                TAGITCore.State.FLAGGED
            )
        );
        tagitCore.approveResolve(tokenId, consumer);
    }

    function test_approveResolve_revertsTokenNotFound() public {
        uint256 nonExistentTokenId = 999;

        vm.prank(resolver1);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TokenNotFound.selector, nonExistentTokenId));
        tagitCore.approveResolve(nonExistentTokenId, consumer);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_getResolveApprovalStatus_noApprovals() public view {
        // Non-existent token should return zero state
        (uint256 count, address recipient, bool quorumReached) = tagitCore.getResolveApprovalStatus(999);
        assertEq(count, 0, "Count should be 0");
        assertEq(recipient, address(0), "Recipient should be zero");
        assertFalse(quorumReached, "Quorum should not be reached");
    }

    function test_getResolveApprovalStatus_afterApprovals() public {
        uint256 tokenId = _setupFlaggedAsset();

        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);

        (uint256 count, address recipient, bool quorumReached) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(count, 1, "Count should be 1");
        assertEq(recipient, consumer, "Recipient should be consumer");
        assertFalse(quorumReached, "Quorum should not be reached with 1 approval");

        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);

        (count, recipient, quorumReached) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(count, 2, "Count should be 2");
        assertEq(recipient, consumer, "Recipient should still be consumer");
        assertTrue(quorumReached, "Quorum should be reached with 2 approvals");
    }

    // ============================================
    // MULTI-CYCLE TESTS
    // ============================================

    function test_resolve_quorumWorksAcrossMultipleFlagResolveCycles() public {
        uint256 tokenId = _setupFlaggedAsset();

        address newOwner1 = makeAddr("newOwner1");
        address newOwner2 = makeAddr("newOwner2");

        // First cycle
        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, newOwner1);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, newOwner1);
        vm.prank(resolver1);
        tagitCore.resolve(tokenId, newOwner1);

        assertEq(tagitCore.ownerOf(tokenId), newOwner1, "First resolution owner");

        // Flag again
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);

        // Second cycle — approval state was cleared, must re-approve
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, newOwner2);
        vm.prank(resolver3);
        tagitCore.approveResolve(tokenId, newOwner2);
        vm.prank(resolver1);
        tagitCore.resolve(tokenId, newOwner2);

        assertEq(tagitCore.ownerOf(tokenId), newOwner2, "Second resolution owner");
    }

    // ============================================
    // THREE APPROVALS TEST
    // ============================================

    function test_approveResolve_threeApprovals() public {
        uint256 tokenId = _setupFlaggedAsset();

        vm.prank(resolver1);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, consumer);
        vm.prank(resolver3);
        tagitCore.approveResolve(tokenId, consumer);

        (uint256 count, , bool quorumReached) = tagitCore.getResolveApprovalStatus(tokenId);
        assertEq(count, 3, "Count should be 3");
        assertTrue(quorumReached, "Quorum should be reached with 3 approvals");

        // Resolve should still work
        vm.prank(resolver1);
        tagitCore.resolve(tokenId, consumer);

        (, , TAGITCore.State state, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED), "State should be CLAIMED");
    }
}
