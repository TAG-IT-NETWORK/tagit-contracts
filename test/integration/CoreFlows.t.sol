// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {IRecovery} from "../../src/interfaces/IRecovery.sol";

/**
 * @title CoreFlowsTest
 * @notice Integration tests for asset lifecycle and recovery flows
 * @dev Tests TAGITCore, TAGITRecovery, TAGITAccess interactions
 */
contract CoreFlowsTest is IntegrationBase {

    // ============================================
    // ASSET LIFECYCLE FLOWS
    // ============================================

    /**
     * @notice E2E: Full asset lifecycle: Mint → Bind → Activate → Claim
     */
    function test_fullAssetLifecycle() public {
        bytes32 metadata = keccak256("ipfs://product-metadata");
        bytes32 tagHash = keccak256("NFC_UID_12345");

        // Step 1: Manufacturer mints
        vm.prank(manufacturer);
        uint256 tokenId = core.mint(consumer1, metadata);
        assertEq(core.ownerOf(tokenId), consumer1, "Owner should be consumer1");

        // Verify state is MINTED
        (, , TAGITCore.State state, , ) = core.getAsset(tokenId);
        assertEq(uint8(state), 1, "State should be MINTED (1)");

        // Step 2: Manufacturer binds tag
        vm.prank(manufacturer);
        core.bindTag(tokenId, tagHash);

        // Verify state is BOUND
        (, , TAGITCore.State state2, , ) = core.getAsset(tokenId);
        assertEq(uint8(state2), 2, "State should be BOUND (2)");

        // Step 3: QA Inspector activates
        vm.prank(qaInspector);
        core.activate(tokenId);

        // Verify state is ACTIVATED
        (, , TAGITCore.State state3, , ) = core.getAsset(tokenId);
        assertEq(uint8(state3), 3, "State should be ACTIVATED (3)");

        // Step 4: Verifier claims for consumer
        vm.prank(verifier);
        core.claim(tokenId, consumer1);

        // Verify state is CLAIMED
        (, , TAGITCore.State state4, , ) = core.getAsset(tokenId);
        assertEq(uint8(state4), 4, "State should be CLAIMED (4)");
    }

    /**
     * @notice E2E: Batch minting by manufacturer
     */
    function test_batchMinting() public {
        uint256 batchSize = 10;
        uint256[] memory tokenIds = new uint256[](batchSize);

        vm.startPrank(manufacturer);
        for (uint256 i = 0; i < batchSize; i++) {
            bytes32 metadata = keccak256(abi.encodePacked("batch-", i));
            tokenIds[i] = core.mint(consumer1, metadata);
        }
        vm.stopPrank();

        // Verify all minted
        assertEq(core.totalSupply(), batchSize, "Total supply should match batch size");

        // Verify all owned by consumer1
        for (uint256 i = 0; i < batchSize; i++) {
            assertEq(core.ownerOf(tokenIds[i]), consumer1, "All should be owned by consumer1");
        }
    }

    /**
     * @notice E2E: Tag binding is unique (cannot reuse tag)
     */
    function test_tagBindingUnique() public {
        bytes32 tagHash = keccak256("UNIQUE_TAG");

        // Mint two assets
        vm.startPrank(manufacturer);
        uint256 tokenId1 = core.mint(consumer1, keccak256("asset1"));
        uint256 tokenId2 = core.mint(consumer1, keccak256("asset2"));

        // Bind tag to first asset
        core.bindTag(tokenId1, tagHash);

        // Try to bind same tag to second asset - should fail
        vm.expectRevert();
        core.bindTag(tokenId2, tagHash);
        vm.stopPrank();
    }

    // ============================================
    // FLAGGING AND RECOVERY FLOWS
    // ============================================

    /**
     * @notice E2E: Flag asset as suspicious
     */
    function test_flagAsset() public {
        // Create claimed asset
        uint256 tokenId = _mintClaimedAsset(consumer1);

        // Verify state is CLAIMED
        (, , TAGITCore.State stateBefore, , ) = core.getAsset(tokenId);
        assertEq(uint8(stateBefore), 4, "Should be CLAIMED");

        // Law enforcement flags asset
        vm.prank(lawEnforcement);
        core.flag(tokenId);

        // Verify state is FLAGGED
        (, , TAGITCore.State stateAfter, , ) = core.getAsset(tokenId);
        assertEq(uint8(stateAfter), 5, "Should be FLAGGED");
    }

    /**
     * @notice E2E: Resolve flagged asset back to claimed
     */
    function test_resolveAsset() public {
        // Create claimed asset
        uint256 tokenId = _mintClaimedAsset(consumer1);

        // Flag it
        vm.prank(lawEnforcement);
        core.flag(tokenId);

        // Approve resolve (2-of-3 quorum)
        vm.prank(lawEnforcement);
        core.approveResolve(tokenId, consumer1);
        vm.prank(lawEnforcement2);
        core.approveResolve(tokenId, consumer1);

        // Resolve back to claimed
        vm.prank(lawEnforcement);
        core.resolve(tokenId, consumer1);

        // Verify state is CLAIMED again
        (, , TAGITCore.State state, , ) = core.getAsset(tokenId);
        assertEq(uint8(state), 4, "Should be CLAIMED after resolution");
    }

    /**
     * @notice E2E: Recycle asset (end of life)
     */
    function test_recycleAsset() public {
        // Create claimed asset
        uint256 tokenId = _mintClaimedAsset(consumer1);

        // Recycler recycles
        vm.prank(recycler);
        core.recycle(tokenId);

        // Verify state is RECYCLED
        (, , TAGITCore.State state, , ) = core.getAsset(tokenId);
        assertEq(uint8(state), 6, "Should be RECYCLED");
    }

    // ============================================
    // RECOVERY DISPUTE FLOWS
    // ============================================

    /**
     * @notice E2E: Initiate recovery claim with stake
     */
    function test_initiateRecoveryClaim() public {
        // Create claimed asset owned by consumer1
        uint256 tokenId = _mintClaimedAsset(consumer1);

        // Consumer2 claims they are the rightful owner
        uint256 stakeBond = recovery.minimumStake();

        vm.startPrank(consumer2);
        token.approve(address(recovery), stakeBond);
        bytes32 evidenceHash = keccak256("proof-of-ownership.pdf");
        uint256 caseId = recovery.initiateRecovery(tokenId, evidenceHash);
        vm.stopPrank();

        // Verify case created
        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertEq(recoveryCase.tokenId, tokenId, "Case token ID incorrect");
        assertEq(recoveryCase.claimant, consumer2, "Claimant incorrect");
    }

    /**
     * @notice E2E: Vote on recovery case
     */
    function test_voteOnRecoveryCase() public {
        // Setup: Create case
        uint256 tokenId = _mintClaimedAsset(consumer1);
        uint256 stakeBond = recovery.minimumStake();

        vm.startPrank(consumer2);
        token.approve(address(recovery), stakeBond);
        uint256 caseId = recovery.initiateRecovery(tokenId, keccak256("evidence"));
        vm.stopPrank();

        // Verifier votes (has badge, gets weight)
        vm.prank(verifier);
        recovery.vote(caseId, true, keccak256("verified-genuine-claimant")); // Vote in favor with reason

        // Check vote recorded
        IRecovery.RecoveryCase memory recoveryCase = recovery.getCase(caseId);
        assertGt(recoveryCase.votesFor, 0, "Votes for should be recorded");
    }

    // ============================================
    // ACCESS CONTROL FLOWS
    // ============================================

    /**
     * @notice E2E: Only authorized roles can perform actions
     */
    function test_accessControlEnforced() public {
        bytes32 metadata = keccak256("test-metadata");

        // Unauthorized user cannot mint
        vm.prank(consumer1);
        vm.expectRevert();
        core.mint(consumer1, metadata);

        // Authorized manufacturer can mint
        vm.prank(manufacturer);
        uint256 tokenId = core.mint(consumer1, metadata);
        assertGt(tokenId, 0, "Should mint successfully");

        // Unauthorized user cannot bind
        vm.prank(consumer1);
        vm.expectRevert();
        core.bindTag(tokenId, keccak256("tag"));

        // Authorized manufacturer can bind
        vm.prank(manufacturer);
        core.bindTag(tokenId, keccak256("tag"));
    }

    /**
     * @notice E2E: Badge revocation removes capabilities
     */
    function test_badgeRevocationRemovesAccess() public {
        // Manufacturer can mint
        vm.prank(manufacturer);
        uint256 tokenId1 = core.mint(consumer1, keccak256("test1"));
        assertGt(tokenId1, 0, "Should mint");

        // Revoke manufacturer's mint capability
        vm.prank(owner);
        capabilityBadge.revokeCapability(manufacturer, CAP_MINT);

        // Manufacturer can no longer mint
        vm.prank(manufacturer);
        vm.expectRevert();
        core.mint(consumer1, keccak256("test2"));
    }

    // ============================================
    // CROSS-CONTRACT FLOWS
    // ============================================

    /**
     * @notice E2E: Asset lifecycle triggers program rewards
     */
    function test_assetLifecycleTriggersRewards() public {
        // Create and claim asset
        uint256 tokenId = _mintClaimedAsset(consumer1);

        // Programs should have recorded activity
        // Note: This depends on Programs contract implementation
        // For now, verify asset is in correct state
        (, , TAGITCore.State state, , ) = core.getAsset(tokenId);
        assertEq(uint8(state), 4, "Asset should be CLAIMED");
    }

    /**
     * @notice E2E: Multiple manufacturers operate independently
     */
    function test_multipleManufacturers() public {
        address manufacturer2 = makeAddr("manufacturer2");

        // Grant manufacturer2 capabilities
        vm.startPrank(owner);
        capabilityBadge.grantCapability(manufacturer2, CAP_MINT);
        capabilityBadge.grantCapability(manufacturer2, CAP_BIND);
        vm.stopPrank();

        // Both manufacturers mint
        vm.prank(manufacturer);
        uint256 tokenId1 = core.mint(consumer1, keccak256("mfr1-product"));

        vm.prank(manufacturer2);
        uint256 tokenId2 = core.mint(consumer2, keccak256("mfr2-product"));

        // Verify both minted successfully
        assertEq(core.ownerOf(tokenId1), consumer1, "MFR1 product owner");
        assertEq(core.ownerOf(tokenId2), consumer2, "MFR2 product owner");
        assertEq(core.totalSupply(), 2, "Total supply should be 2");
    }
}
