// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IntegrationBase} from "./IntegrationBase.t.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";

/**
 * @title E2EHappyPathTest
 * @notice End-to-end tests for complete user journeys
 * @dev Tests full workflows from user onboarding to rewards claiming
 */
contract E2EHappyPathTest is IntegrationBase {
    // ============================================
    // CONSUMER JOURNEY
    // ============================================

    /**
     * @notice Full consumer journey: Get tokens → Stake → Own product → Verify → Earn
     * @dev Tests the complete consumer experience
     */
    function test_fullConsumerJourney() public {
        // STEP 1: Consumer receives tokens (simulating purchase/airdrop)
        uint256 initialBalance = token.balanceOf(consumer1);
        assertEq(initialBalance, USER_INITIAL_BALANCE, "Should have initial balance");

        // STEP 2: Consumer stakes tokens for reputation boost
        uint256 stakeAmount = 10_000 ether;
        vm.startPrank(consumer1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        assertTrue(staking.qualifiesForRepBoost(consumer1), "Should qualify for rep boost");

        // STEP 3: Manufacturer creates product for consumer
        vm.prank(manufacturer);
        uint256 tokenId = core.mint(consumer1, keccak256("PREMIUM_WATCH_001"));

        {
            bytes32 tagHash = keccak256("NFC_TAG_WATCH_001");
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
            vm.prank(manufacturer);
            core.bindTag(tokenId, tagHash, cr, sig);
        }

        vm.prank(qaInspector);
        core.activate(tokenId);

        // STEP 4: Consumer's product is claimed/verified
        vm.prank(verifier);
        core.claim(tokenId, consumer1);

        // Verify ownership
        assertEq(core.ownerOf(tokenId), consumer1, "Consumer should own the asset");

        // STEP 5: Time passes, consumer can unstake later
        vm.warp(block.timestamp + 30 days);

        // STEP 6: Consumer verifies staking position is still active
        assertEq(staking.stakedBalance(consumer1), stakeAmount, "Stake should still be recorded");
        assertTrue(staking.qualifiesForRepBoost(consumer1), "Should still qualify for rep boost");
    }

    /**
     * @notice Consumer product verification journey
     */
    function test_productVerificationJourney() public {
        // Setup: Create activated product
        uint256 tokenId = _mintActivatedAsset(consumer1);

        // Consumer verifies product authenticity
        vm.prank(verifier);
        core.claim(tokenId, consumer1);

        // Verify asset is in CLAIMED state (verified)
        (,, TAGITCore.State state,,) = core.getAsset(tokenId);
        assertEq(uint8(state), 4, "Asset should be CLAIMED/verified");

        // Consumer can check verification status
        assertEq(core.ownerOf(tokenId), consumer1, "Consumer owns verified product");
    }

    // ============================================
    // MANUFACTURER JOURNEY
    // ============================================

    /**
     * @notice Full manufacturer journey: Onboard → Mint batch → Track verifications
     */
    function test_fullManufacturerJourney() public {
        // STEP 1: Verify manufacturer has badge (done in setUp)
        assertTrue(capabilityBadge.hasCapability(manufacturer, CAP_MINT), "Manufacturer should have mint capability");
        assertTrue(capabilityBadge.hasCapability(manufacturer, CAP_BIND), "Manufacturer should have bind capability");

        // STEP 2: Manufacturer mints batch of products
        uint256 batchSize = 5;
        uint256[] memory tokenIds = new uint256[](batchSize);
        bytes32[] memory tagHashes = new bytes32[](batchSize);

        vm.startPrank(manufacturer);
        for (uint256 i = 0; i < batchSize; i++) {
            bytes32 metadata = keccak256(abi.encodePacked("PRODUCT_BATCH_", i));
            tokenIds[i] = core.mint(consumer1, metadata);

            tagHashes[i] = keccak256(abi.encodePacked("TAG_BATCH_", i));
            {
                (bytes memory cr, bytes memory sig) = _oracleSign(tokenIds[i], tagHashes[i]);
                core.bindTag(tokenIds[i], tagHashes[i], cr, sig);
            }
        }
        vm.stopPrank();

        // STEP 3: QA activates all products
        for (uint256 i = 0; i < batchSize; i++) {
            vm.prank(qaInspector);
            core.activate(tokenIds[i]);
        }

        // STEP 4: Products get verified/claimed by consumers
        for (uint256 i = 0; i < batchSize; i++) {
            vm.prank(verifier);
            core.claim(tokenIds[i], consumer1);
        }

        // STEP 5: Verify all products tracked
        assertEq(core.totalSupply(), batchSize, "All products should be minted");

        for (uint256 i = 0; i < batchSize; i++) {
            (,, TAGITCore.State state,,) = core.getAsset(tokenIds[i]);
            assertEq(uint8(state), 4, "All products should be CLAIMED");
        }
    }

    /**
     * @notice Manufacturer product recall scenario
     */
    function test_productRecallJourney() public {
        // Setup: Create claimed products
        uint256[] memory tokenIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            tokenIds[i] = _mintClaimedAsset(consumer1);
        }

        // Recall: Law enforcement flags all products
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(lawEnforcement);
            core.flag(tokenIds[i]);
        }

        // Verify all flagged
        for (uint256 i = 0; i < 3; i++) {
            (,, TAGITCore.State state,,) = core.getAsset(tokenIds[i]);
            assertEq(uint8(state), 5, "Product should be FLAGGED");
        }

        // Resolution: Products cleared and returned (with 2-of-3 quorum)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(lawEnforcement);
            core.approveResolve(tokenIds[i], consumer1);
            vm.prank(lawEnforcement2);
            core.approveResolve(tokenIds[i], consumer1);
            vm.prank(lawEnforcement);
            core.resolve(tokenIds[i], consumer1);
        }

        // Verify all resolved
        for (uint256 i = 0; i < 3; i++) {
            (,, TAGITCore.State state,,) = core.getAsset(tokenIds[i]);
            assertEq(uint8(state), 4, "Product should be CLAIMED again");
        }
    }

    // ============================================
    // STAKING JOURNEY
    // ============================================

    /**
     * @notice Full staking journey: Stake → Wait → Unstake
     * @dev Note: Reward claiming requires emissions funding, tested separately
     */
    function test_fullStakingJourney() public {
        uint256 stakeAmount = 50_000 ether;

        // STEP 1: Stake tokens
        vm.startPrank(consumer1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        assertEq(staking.stakedBalance(consumer1), stakeAmount, "Stake recorded");

        // STEP 2: Check reputation boost qualification
        assertTrue(staking.qualifiesForRepBoost(consumer1), "Should qualify for rep boost");

        // STEP 3: Wait some time
        vm.warp(block.timestamp + 7 days);

        // STEP 4: Partial unstake
        vm.prank(consumer1);
        staking.unstake(stakeAmount / 2);

        assertEq(staking.stakedBalance(consumer1), stakeAmount / 2, "Should have half stake");

        // STEP 5: Full unstake
        vm.prank(consumer1);
        staking.unstake(stakeAmount / 2);

        assertEq(staking.stakedBalance(consumer1), 0, "Should have no stake left");
    }

    // ============================================
    // DISPUTE RESOLUTION JOURNEY
    // ============================================

    /**
     * @notice Full dispute journey: Claim → Vote → Resolve
     */
    function test_fullDisputeJourney() public {
        // STEP 1: Setup - Create asset owned by consumer1
        uint256 tokenId = _mintClaimedAsset(consumer1);

        // STEP 2: Consumer2 initiates recovery claim
        uint256 stakeBond = recovery.minimumStake();

        vm.startPrank(consumer2);
        token.approve(address(recovery), stakeBond);
        uint256 caseId = recovery.initiateRecovery(tokenId, keccak256("ownership-proof"));
        vm.stopPrank();

        // STEP 3: Verifier votes in favor of claimant
        vm.prank(verifier);
        recovery.vote(caseId, true, keccak256("verified-evidence"));

        // STEP 4: Additional votes to reach quorum (simplified)
        // In production, would need more voters with different badges

        // STEP 5: Wait for voting period to end
        vm.warp(block.timestamp + 8 days);

        // Note: Full resolution requires quorum to be met
        // This test shows the flow structure
    }

    // ============================================
    // TOKEN ECONOMICS JOURNEY
    // ============================================

    /**
     * @notice Full token economics journey: Fees → Burn → Treasury
     */
    function test_fullTokenEconomicsJourney() public {
        uint256 feeAmount = 10_000 ether;

        // STEP 1: Record initial state
        uint256 initialSupply = token.totalSupply();
        uint256 initialTreasury = token.balanceOf(address(treasury));
        uint256 initialBurned = burner.totalBurned();

        // STEP 2: Route fees through burner
        vm.startPrank(owner);
        token.approve(address(burner), feeAmount);
        burner.routeFee(feeAmount);
        vm.stopPrank();

        // STEP 3: Verify burn occurred
        uint256 burnRate = burner.burnRate();
        uint256 expectedBurn = (feeAmount * burnRate) / 10000;

        assertEq(token.totalSupply(), initialSupply - expectedBurn, "Supply should decrease by burn amount");
        assertEq(burner.totalBurned(), initialBurned + expectedBurn, "Burned counter should increase");

        // STEP 4: Verify treasury received remainder
        uint256 expectedTreasury = feeAmount - expectedBurn;
        assertEq(
            token.balanceOf(address(treasury)), initialTreasury + expectedTreasury, "Treasury should receive remainder"
        );
    }

    // ============================================
    // END-OF-LIFE JOURNEY
    // ============================================

    /**
     * @notice Full product end-of-life journey: Claim → Use → Recycle
     */
    function test_fullEndOfLifeJourney() public {
        // STEP 1: Create and claim product
        uint256 tokenId = _mintClaimedAsset(consumer1);

        // STEP 2: Product is used (time passes)
        vm.warp(block.timestamp + 365 days);

        // STEP 3: Product reaches end of life - recycle
        vm.prank(recycler);
        core.recycle(tokenId);

        // STEP 4: Verify recycled state
        (,, TAGITCore.State state,,) = core.getAsset(tokenId);
        assertEq(uint8(state), 6, "Asset should be RECYCLED");

        // Asset still exists but is in terminal state
        assertEq(core.ownerOf(tokenId), consumer1, "Original owner retained");
    }

    // ============================================
    // MULTI-USER INTERACTIONS
    // ============================================

    /**
     * @notice Multiple users interact with system simultaneously
     */
    function test_multiUserInteraction() public {
        // Consumer1 stakes
        vm.startPrank(consumer1);
        token.approve(address(staking), 20_000 ether);
        staking.stake(20_000 ether);
        vm.stopPrank();

        // Consumer2 stakes
        vm.startPrank(consumer2);
        token.approve(address(staking), 30_000 ether);
        staking.stake(30_000 ether);
        vm.stopPrank();

        // Manufacturer mints products
        vm.startPrank(manufacturer);
        uint256 tokenId1 = core.mint(consumer1, keccak256("product1"));
        uint256 tokenId2 = core.mint(consumer2, keccak256("product2"));
        {
            bytes32 tagHash1 = keccak256("tag1");
            (bytes memory cr1, bytes memory sig1) = _oracleSign(tokenId1, tagHash1);
            core.bindTag(tokenId1, tagHash1, cr1, sig1);
        }
        {
            bytes32 tagHash2 = keccak256("tag2");
            (bytes memory cr2, bytes memory sig2) = _oracleSign(tokenId2, tagHash2);
            core.bindTag(tokenId2, tagHash2, cr2, sig2);
        }
        vm.stopPrank();

        // QA activates both
        vm.prank(qaInspector);
        core.activate(tokenId1);
        vm.prank(qaInspector);
        core.activate(tokenId2);

        // Both products claimed
        vm.prank(verifier);
        core.claim(tokenId1, consumer1);
        vm.prank(verifier);
        core.claim(tokenId2, consumer2);

        // Time passes
        vm.warp(block.timestamp + 7 days);

        // Verify stakes are proportional
        assertEq(staking.stakedBalance(consumer1), 20_000 ether, "Consumer1 stake");
        assertEq(staking.stakedBalance(consumer2), 30_000 ether, "Consumer2 stake");
        assertEq(staking.totalStaked(), 50_000 ether, "Total stake should be sum");

        // Both qualify for rep boost
        assertTrue(staking.qualifiesForRepBoost(consumer1), "Consumer1 should qualify");
        assertTrue(staking.qualifiesForRepBoost(consumer2), "Consumer2 should qualify");
    }
}
