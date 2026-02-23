// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";

// Treasury
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {ITAGITTreasury} from "../../src/interfaces/ITAGITTreasury.sol";

// Emissions
import {TAGITEmissions} from "../../src/token/TAGITEmissions.sol";
import {ITAGITEmissions} from "../../src/interfaces/ITAGITEmissions.sol";

// Token
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Constants
import {
    INFLATION_RATE,
    EPOCHS_PER_YEAR,
    EPOCH_DURATION,
    BASIS_POINTS
} from "../../src/libraries/Constants.sol";

/**
 * @title EVMbenchFixes Tests
 * @notice Tests for PATCH-07 through PATCH-10 (EVMbench security findings)
 */
contract EVMbenchFixesTest is Test {
    // ============================================
    // SHARED STATE
    // ============================================

    address public owner;
    address public governor;
    address public tokenTreasury;
    address public recipient1;
    address public alice;
    address public manufacturer;
    address public resolver2;

    // ============================================
    // PATCH-07 & PATCH-08: Treasury
    // ============================================

    TAGITTreasury public treasury;
    TAGITToken public token;

    address[8] public signers;
    uint256[8] public signerKeys;

    uint256 public constant INITIAL_BALANCE = 10_000_000e18;
    bytes32 public constant ECOSYSTEM_GRANTS = keccak256("ECOSYSTEM_GRANTS");

    // ============================================
    // PATCH-09: Core
    // ============================================

    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    bytes32 public constant METADATA_1 = keccak256("ipfs://QmTest1");
    bytes32 public constant TAG_HASH_1 = keccak256("NFC_TAG_UID_001");
    bytes32 public constant TAG_HASH_2 = keccak256("NFC_TAG_UID_002");
    uint256 constant ORACLE_PK = 0xA11CE;

    // ============================================
    // PATCH-10: Emissions
    // ============================================

    TAGITToken public emissionsToken;
    TAGITEmissions public emissions;
    address public ecosystem;
    address public staking;
    address public devFund;

    // Events
    event EpochDistributed(uint256 indexed epoch, uint256 amount, uint256 timestamp);

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        tokenTreasury = makeAddr("tokenTreasury");
        recipient1 = makeAddr("recipient1");
        alice = makeAddr("alice");
        manufacturer = makeAddr("manufacturer");
        resolver2 = makeAddr("resolver2");
        ecosystem = makeAddr("ecosystem");
        staking = makeAddr("staking");
        devFund = makeAddr("devFund");

        // --- Treasury setup (PATCH-07, PATCH-08) ---
        for (uint256 i = 0; i < 8; i++) {
            signerKeys[i] = uint256(keccak256(abi.encodePacked("signer", i)));
            signers[i] = vm.addr(signerKeys[i]);
        }

        vm.startPrank(owner);

        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(TAGITToken.initialize, (owner, tokenTreasury));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        address[] memory signerArray = new address[](8);
        for (uint256 i = 0; i < 8; i++) {
            signerArray[i] = signers[i];
        }

        TAGITTreasury treasuryImpl = new TAGITTreasury();
        treasury = TAGITTreasury(payable(address(new ERC1967Proxy(
            address(treasuryImpl),
            abi.encodeCall(TAGITTreasury.initialize, (governor, address(token), signerArray))
        ))));

        token.transfer(address(treasury), INITIAL_BALANCE);

        vm.stopPrank();

        // --- Core setup (PATCH-09) ---
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        TAGITCore coreImpl = new TAGITCore();
        bytes memory coreInitData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), coreInitData);
        tagitCore = TAGITCore(address(coreProxy));

        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        address oracle = vm.addr(ORACLE_PK);
        vm.prank(owner);
        tagitCore.setTrustedOracle(oracle);

        // Grant capabilities to manufacturer
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RECYCLER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));

        // --- Emissions setup (PATCH-10) ---
        vm.startPrank(owner);

        TAGITToken emissionsTokenImpl = new TAGITToken();
        bytes memory etData = abi.encodeCall(TAGITToken.initialize, (owner, owner));
        ERC1967Proxy etProxy = new ERC1967Proxy(address(emissionsTokenImpl), etData);
        emissionsToken = TAGITToken(address(etProxy));

        TAGITEmissions emissionsImpl = new TAGITEmissions();
        bytes memory emInitData = abi.encodeCall(TAGITEmissions.initialize, (address(emissionsToken), governor, owner));
        ERC1967Proxy emProxy = new ERC1967Proxy(address(emissionsImpl), emInitData);
        emissions = TAGITEmissions(address(emProxy));

        emissionsToken.setEmissionsAddress(address(emissions));

        vm.stopPrank();
    }

    // ============================================
    // PATCH-07 TESTS: Allocation expiry in executeWithdrawal
    // ============================================

    function test_PATCH07_executeWithdrawal_revert_allocationExpired() public {
        uint48 duration = 3 days;
        uint256 allocAmount = 40_000e18;
        uint256 withdrawAmount = 10_000e18;

        // Create allocation with short duration
        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, duration);

        // Queue withdrawal
        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), withdrawAmount, alice);

        // Advance past both timelock (48h) AND allocation expiry (3 days)
        vm.warp(block.timestamp + 4 days);

        // Should revert because allocation expired
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITTreasury.AllocationExpired.selector,
            allocationId,
            uint48(block.timestamp - 4 days) + duration // expiresAt
        ));
        treasury.executeWithdrawal(withdrawalId);
    }

    function test_PATCH07_executeWithdrawal_succeeds_beforeExpiry() public {
        uint48 duration = 30 days;
        uint256 allocAmount = 40_000e18;
        uint256 withdrawAmount = 10_000e18;

        vm.prank(governor);
        uint256 allocationId = treasury.createAllocation(ECOSYSTEM_GRANTS, allocAmount, recipient1, duration);

        vm.prank(recipient1);
        uint256 withdrawalId = treasury.queueWithdrawal(allocationId, address(token), withdrawAmount, alice);

        // Advance past timelock but before expiry
        vm.warp(block.timestamp + 48 hours + 1);

        uint256 aliceBefore = token.balanceOf(alice);
        treasury.executeWithdrawal(withdrawalId);
        assertEq(token.balanceOf(alice), aliceBefore + withdrawAmount);
    }

    // ============================================
    // PATCH-08 TESTS: Counter-based sweep nonce
    // ============================================

    function test_PATCH08_sweepNonce_startsAtZero() public view {
        assertEq(treasury.sweepNonce(), 0);
    }

    function test_PATCH08_emergencySweep_incrementsNonce() public {
        vm.deal(address(treasury), 100 ether);

        // Sign with nonce=0
        bytes[] memory sigs = _signSweep(address(0), alice, 0);

        treasury.emergencySweep(address(0), alice, sigs);

        assertEq(treasury.sweepNonce(), 1);
    }

    function test_PATCH08_emergencySweep_revert_replayWithOldNonce() public {
        vm.deal(address(treasury), 200 ether);

        // First sweep succeeds with nonce=0
        bytes[] memory sigs = _signSweep(address(0), alice, 0);
        treasury.emergencySweep(address(0), alice, sigs);

        // Fund treasury again
        vm.deal(address(treasury), 100 ether);

        // Replay same signatures (nonce=0) should fail — nonce is now 1
        // Signatures will recover to wrong addresses since hash changed
        vm.expectRevert(); // InvalidSignature or similar
        treasury.emergencySweep(address(0), alice, sigs);
    }

    function test_PATCH08_emergencySweep_succeedsWithNewNonce() public {
        vm.deal(address(treasury), 200 ether);

        // First sweep with nonce=0
        bytes[] memory sigs0 = _signSweep(address(0), alice, 0);
        treasury.emergencySweep(address(0), alice, sigs0);

        // Fund treasury again
        vm.deal(address(treasury), 100 ether);

        // Second sweep with nonce=1
        bytes[] memory sigs1 = _signSweep(address(0), alice, 1);
        treasury.emergencySweep(address(0), alice, sigs1);

        assertEq(treasury.sweepNonce(), 2);
    }

    // ============================================
    // PATCH-09 TESTS: Block external ERC721 transfers
    // ============================================

    function test_PATCH09_transferFrom_reverts() public {
        // Mint an asset
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(alice, METADATA_1);

        // Try direct transferFrom — should revert
        vm.prank(alice);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(alice, manufacturer, tokenId);
    }

    function test_PATCH09_safeTransferFrom_reverts() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(alice, METADATA_1);

        vm.prank(alice);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.safeTransferFrom(alice, manufacturer, tokenId);
    }

    function test_PATCH09_approve_and_transferFrom_reverts() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(alice, METADATA_1);

        // Alice approves manufacturer
        vm.prank(alice);
        tagitCore.approve(manufacturer, tokenId);

        // Manufacturer tries to transfer — should still revert
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.TransferDisabled.selector);
        tagitCore.transferFrom(alice, manufacturer, tokenId);
    }

    function test_PATCH09_mint_stillWorks() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(alice, METADATA_1);

        assertEq(tagitCore.ownerOf(tokenId), alice);
        assertEq(tagitCore.totalSupply(), 1);
    }

    function test_PATCH09_claim_stillWorks() public {
        // Full lifecycle: mint → bind → activate → claim
        uint256 tokenId = _mintBoundActivatedAsset(alice);

        // Claim (internal _transfer) should work
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, manufacturer);

        assertEq(tagitCore.ownerOf(tokenId), manufacturer);
    }

    function test_PATCH09_resolve_stillWorks() public {
        // mint → bind → activate → claim → flag → approveResolve x2 → resolve
        uint256 tokenId = _mintBoundActivatedAsset(alice);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, alice);

        vm.prank(manufacturer);
        tagitCore.flag(tokenId);

        // Two resolvers approve
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, manufacturer);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, manufacturer);

        // Resolve transfers ownership
        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, manufacturer);

        assertEq(tagitCore.ownerOf(tokenId), manufacturer);
    }

    function test_PATCH09_fullLifecycle_regression() public {
        // mint → bind → activate → claim → flag → resolve → recycle
        uint256 tokenId = _mintBoundActivatedAsset(alice);

        vm.prank(manufacturer);
        tagitCore.claim(tokenId, alice);

        (, , TAGITCore.State state1, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state1), uint8(TAGITCore.State.CLAIMED));

        vm.prank(manufacturer);
        tagitCore.flag(tokenId);

        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, alice);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, alice);

        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, alice);

        (, , TAGITCore.State state2, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state2), uint8(TAGITCore.State.CLAIMED));

        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);

        (, , TAGITCore.State state3, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state3), uint8(TAGITCore.State.RECYCLED));
    }

    // ============================================
    // PATCH-10 TESTS: Epoch catch-up loop
    // ============================================

    function test_PATCH10_catchUpMultipleEpochs() public {
        // Skip 3 weeks
        vm.warp(block.timestamp + 3 weeks);

        uint256 supplyBefore = emissionsToken.totalSupply();
        emissions.distributeEpoch();

        // Should have distributed epochs 1, 2, 3
        assertEq(emissions.lastDistributedEpoch(), 3);
        assertGt(emissionsToken.totalSupply(), supplyBefore);

        // Each epoch should have a recorded distribution
        assertGt(emissions.epochDistribution(1), 0);
        assertGt(emissions.epochDistribution(2), 0);
        assertGt(emissions.epochDistribution(3), 0);
    }

    function test_PATCH10_compoundingEffect() public {
        // Skip 2 weeks
        vm.warp(block.timestamp + 2 weeks);

        emissions.distributeEpoch();

        uint256 epoch1Amount = emissions.epochDistribution(1);
        uint256 epoch2Amount = emissions.epochDistribution(2);

        // Epoch 2 should be slightly larger than epoch 1 (compounding)
        assertGt(epoch2Amount, epoch1Amount, "Epoch 2 should compound on epoch 1");
    }

    function test_PATCH10_cappedAtMaxCatchUpEpochs() public {
        // Skip 20 weeks (beyond MAX_CATCH_UP_EPOCHS = 12)
        vm.warp(block.timestamp + 20 weeks);

        emissions.distributeEpoch();

        // Should only have caught up 12 epochs
        assertEq(emissions.lastDistributedEpoch(), 12);

        // Epoch 13 should not have been distributed
        assertEq(emissions.epochDistribution(13), 0);
    }

    function test_PATCH10_multiCallCatchUp() public {
        // Skip 20 weeks
        vm.warp(block.timestamp + 20 weeks);

        // First call: catches up epochs 1-12
        emissions.distributeEpoch();
        assertEq(emissions.lastDistributedEpoch(), 12);

        // Second call: catches up epochs 13-20
        emissions.distributeEpoch();
        assertEq(emissions.lastDistributedEpoch(), 20);
    }

    function test_PATCH10_singleEpochStillWorks() public {
        // Skip exactly 1 week
        vm.warp(block.timestamp + 1 weeks);

        uint256 supplyBefore = emissionsToken.totalSupply();
        uint256 expectedAmount = (supplyBefore * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

        emissions.distributeEpoch();

        assertEq(emissions.lastDistributedEpoch(), 1);
        assertEq(emissions.epochDistribution(1), expectedAmount);
    }

    function test_PATCH10_revert_alreadyDistributed() public {
        vm.warp(block.timestamp + 1 weeks);
        emissions.distributeEpoch();

        vm.expectRevert(abi.encodeWithSelector(
            ITAGITEmissions.EpochAlreadyDistributed.selector,
            1
        ));
        emissions.distributeEpoch();
    }

    function test_PATCH10_pendingDistribution_multipleEpochs() public {
        vm.warp(block.timestamp + 3 weeks);

        uint256 pending = emissions.pendingDistribution();

        // Should account for 3 epochs with compounding
        uint256 supply = emissionsToken.totalSupply();
        uint256 epoch1 = (supply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);
        supply += epoch1;
        uint256 epoch2 = (supply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);
        supply += epoch2;
        uint256 epoch3 = (supply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);
        uint256 expectedTotal = epoch1 + epoch2 + epoch3;

        assertEq(pending, expectedTotal);
    }

    function test_PATCH10_pendingDistribution_cappedAtMax() public {
        vm.warp(block.timestamp + 20 weeks);

        uint256 pending = emissions.pendingDistribution();

        // Should only estimate MAX_CATCH_UP_EPOCHS (12), not all 20
        uint256 supply = emissionsToken.totalSupply();
        uint256 total = 0;
        for (uint256 i = 0; i < 12; i++) {
            uint256 amount = (supply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);
            total += amount;
            supply += amount;
        }

        assertEq(pending, total);
    }

    function test_PATCH10_emitsEventPerEpoch() public {
        vm.warp(block.timestamp + 3 weeks);

        // We expect 3 events — check the first one
        uint256 supply = emissionsToken.totalSupply();
        uint256 expectedAmount1 = (supply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

        vm.expectEmit(true, false, false, true);
        emit EpochDistributed(1, expectedAmount1, block.timestamp);
        emissions.distributeEpoch();
    }

    function test_PATCH10_totalDistributed_sumsAllEpochs() public {
        vm.warp(block.timestamp + 3 weeks);

        emissions.distributeEpoch();

        uint256 e1 = emissions.epochDistribution(1);
        uint256 e2 = emissions.epochDistribution(2);
        uint256 e3 = emissions.epochDistribution(3);

        assertEq(emissions.totalDistributed(), e1 + e2 + e3);
    }

    // ============================================
    // HELPERS
    // ============================================

    function _signSweep(address sweepToken, address to, uint256 nonce)
        internal
        view
        returns (bytes[] memory sigs)
    {
        bytes32 messageHash = keccak256(abi.encodePacked(
            "TAGIT_EMERGENCY_SWEEP",
            block.chainid,
            address(treasury),
            sweepToken,
            to,
            nonce
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        sigs = new bytes[](6);
        for (uint256 i = 0; i < 6; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKeys[i], ethSignedHash);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function _mintBoundActivatedAsset(address to) internal returns (uint256 tokenId) {
        vm.prank(manufacturer);
        tokenId = tagitCore.mint(to, METADATA_1);

        bytes32 tagHash = keccak256(abi.encodePacked("TAG_", tokenId));

        // Create oracle signature
        bytes memory challengeResponse = abi.encodePacked("challenge_response_", tokenId);
        bytes32 msgHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, ethHash);
        bytes memory oracleSig = abi.encodePacked(r, s, v);

        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, challengeResponse, oracleSig);

        vm.prank(manufacturer);
        tagitCore.activate(tokenId);
    }
}
