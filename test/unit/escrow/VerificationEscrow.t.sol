// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {VerificationEscrow} from "../../../src/escrow/VerificationEscrow.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Minimal ERC20 mock with 6 decimals for testing
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title VerificationEscrowTest
 * @notice Unit tests for VerificationEscrow contract
 * @dev Tests cover escrow lifecycle, oracle verification, access control, and edge cases
 */
contract VerificationEscrowTest is Test {
    VerificationEscrow public escrow;
    MockUSDC public usdc;

    // Test accounts
    address public owner;
    address public buyer;
    address public seller;
    address public stranger;

    // Oracle keys
    uint256 constant ORACLE_PK = 0xA11CE;
    address public oracle;

    uint256 constant WRONG_ORACLE_PK = 0xBAD;
    address public wrongOracle;

    // Test constants
    uint256 constant ASSET_ID = 42;
    uint256 constant ESCROW_AMOUNT = 100e6; // 100 USDC

    // Events (must match contract)
    event EscrowCreated(
        uint256 indexed escrowId, uint256 indexed assetId, address indexed buyer, address seller, uint256 amount
    );
    event EscrowReleased(
        uint256 indexed escrowId, uint256 indexed assetId, address indexed seller, uint256 amount, address oracle
    );
    event EscrowCancelled(uint256 indexed escrowId, uint256 indexed assetId, address indexed buyer, uint256 amount);
    event TrustedOracleUpdated(address indexed previousOracle, address indexed newOracle);

    function setUp() public {
        owner = makeAddr("owner");
        buyer = makeAddr("buyer");
        seller = makeAddr("seller");
        stranger = makeAddr("stranger");
        oracle = vm.addr(ORACLE_PK);
        wrongOracle = vm.addr(WRONG_ORACLE_PK);

        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy escrow as owner
        vm.prank(owner);
        escrow = new VerificationEscrow(address(usdc), oracle);

        // Fund buyer with USDC
        usdc.mint(buyer, 1_000_000e6); // 1M USDC

        // Approve escrow contract
        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // ============================================
    // HELPER: ORACLE SIGNING
    // ============================================

    function _signAssetProof(uint256 pk, uint256 tokenId, uint8 state, uint256 chainId, uint256 timestamp)
        internal
        pure
        returns (bytes memory signature)
    {
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, state, chainId, timestamp));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _buildValidProof(uint256 tokenId) internal view returns (VerificationEscrow.OracleProof memory) {
        uint8 boundState = 2;
        uint256 timestamp = block.timestamp;
        bytes memory sig = _signAssetProof(ORACLE_PK, tokenId, boundState, block.chainid, timestamp);

        return VerificationEscrow.OracleProof({
            tokenId: tokenId, state: boundState, chainId: block.chainid, timestamp: timestamp, signature: sig
        });
    }

    function _createDefaultEscrow() internal returns (uint256 escrowId) {
        vm.prank(buyer);
        escrowId = escrow.createEscrow(ASSET_ID, seller, ESCROW_AMOUNT);
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function test_constructor_setsState() public view {
        assertEq(address(escrow.usdc()), address(usdc), "USDC address");
        assertEq(escrow.trustedOracle(), oracle, "Oracle address");
        assertEq(escrow.owner(), owner, "Owner address");
        assertEq(escrow.nextEscrowId(), 0, "Initial escrow counter");
    }

    function test_constructor_revert_zeroUsdc() public {
        vm.expectRevert(VerificationEscrow.ZeroAddress.selector);
        new VerificationEscrow(address(0), oracle);
    }

    function test_constructor_revert_zeroOracle() public {
        vm.expectRevert(VerificationEscrow.ZeroAddress.selector);
        new VerificationEscrow(address(usdc), address(0));
    }

    // ============================================
    // CREATE ESCROW TESTS
    // ============================================

    function test_createEscrow_success() public {
        vm.expectEmit(true, true, true, true);
        emit EscrowCreated(0, ASSET_ID, buyer, seller, ESCROW_AMOUNT);

        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(ASSET_ID, seller, ESCROW_AMOUNT);

        assertEq(escrowId, 0, "First escrow ID should be 0");
        assertEq(usdc.balanceOf(address(escrow)), ESCROW_AMOUNT, "Contract should hold USDC");
        assertEq(escrow.nextEscrowId(), 1, "Counter should increment");

        (address b, address s, uint256 aid, uint256 amt, uint64 createdAt, VerificationEscrow.EscrowStatus status) =
            escrow.getEscrow(escrowId);

        assertEq(b, buyer, "Buyer");
        assertEq(s, seller, "Seller");
        assertEq(aid, ASSET_ID, "Asset ID");
        assertEq(amt, ESCROW_AMOUNT, "Amount");
        assertGt(createdAt, 0, "Created timestamp");
        assertEq(uint8(status), uint8(VerificationEscrow.EscrowStatus.ACTIVE), "Status should be ACTIVE");
    }

    function test_createEscrow_multipleEscrows() public {
        vm.prank(buyer);
        uint256 id0 = escrow.createEscrow(ASSET_ID, seller, ESCROW_AMOUNT);

        vm.prank(buyer);
        uint256 id1 = escrow.createEscrow(ASSET_ID + 1, seller, 50e6);

        assertEq(id0, 0, "First ID");
        assertEq(id1, 1, "Second ID");
        assertEq(usdc.balanceOf(address(escrow)), ESCROW_AMOUNT + 50e6, "Total held");
    }

    function test_createEscrow_revert_zeroSeller() public {
        vm.prank(buyer);
        vm.expectRevert(VerificationEscrow.ZeroAddress.selector);
        escrow.createEscrow(ASSET_ID, address(0), ESCROW_AMOUNT);
    }

    function test_createEscrow_revert_zeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(VerificationEscrow.ZeroAmount.selector);
        escrow.createEscrow(ASSET_ID, seller, 0);
    }

    function test_createEscrow_revert_insufficientBalance() public {
        address poorBuyer = makeAddr("poorBuyer");
        vm.prank(poorBuyer);
        usdc.approve(address(escrow), type(uint256).max);

        vm.prank(poorBuyer);
        vm.expectRevert(); // ERC20 insufficient balance
        escrow.createEscrow(ASSET_ID, seller, ESCROW_AMOUNT);
    }

    // ============================================
    // RELEASE WITH PROOF TESTS
    // ============================================

    function test_releaseWithProof_success() public {
        uint256 escrowId = _createDefaultEscrow();
        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID);

        uint256 sellerBalBefore = usdc.balanceOf(seller);

        vm.expectEmit(true, true, true, true);
        emit EscrowReleased(escrowId, ASSET_ID, seller, ESCROW_AMOUNT, oracle);

        escrow.releaseWithProof(escrowId, proof);

        assertEq(usdc.balanceOf(seller), sellerBalBefore + ESCROW_AMOUNT, "Seller should receive USDC");
        assertEq(usdc.balanceOf(address(escrow)), 0, "Contract should be empty");

        (,,,,, VerificationEscrow.EscrowStatus status) = escrow.getEscrow(escrowId);
        assertEq(uint8(status), uint8(VerificationEscrow.EscrowStatus.RELEASED), "Status should be RELEASED");
    }

    function test_releaseWithProof_anyoneCanCall() public {
        uint256 escrowId = _createDefaultEscrow();
        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID);

        // Stranger triggers release — this is fine, funds go to seller
        vm.prank(stranger);
        escrow.releaseWithProof(escrowId, proof);

        assertEq(usdc.balanceOf(seller), ESCROW_AMOUNT, "Seller should receive USDC");
    }

    function test_releaseWithProof_revert_escrowNotFound() public {
        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID);

        vm.expectRevert(abi.encodeWithSelector(VerificationEscrow.EscrowNotFound.selector, 999));
        escrow.releaseWithProof(999, proof);
    }

    function test_releaseWithProof_revert_alreadyReleased() public {
        uint256 escrowId = _createDefaultEscrow();
        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID);

        escrow.releaseWithProof(escrowId, proof);

        // Try again
        VerificationEscrow.OracleProof memory proof2 = _buildValidProof(ASSET_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerificationEscrow.InvalidEscrowStatus.selector,
                escrowId,
                VerificationEscrow.EscrowStatus.RELEASED,
                VerificationEscrow.EscrowStatus.ACTIVE
            )
        );
        escrow.releaseWithProof(escrowId, proof2);
    }

    function test_releaseWithProof_revert_alreadyCancelled() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.prank(buyer);
        escrow.cancelEscrow(escrowId);

        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerificationEscrow.InvalidEscrowStatus.selector,
                escrowId,
                VerificationEscrow.EscrowStatus.CANCELLED,
                VerificationEscrow.EscrowStatus.ACTIVE
            )
        );
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_assetIdMismatch() public {
        uint256 escrowId = _createDefaultEscrow();

        // Build proof for wrong asset
        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID + 1);

        vm.expectRevert(abi.encodeWithSelector(VerificationEscrow.AssetIdMismatch.selector, ASSET_ID + 1, ASSET_ID));
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_chainIdMismatch() public {
        uint256 escrowId = _createDefaultEscrow();

        uint256 wrongChainId = 999;
        bytes memory sig = _signAssetProof(ORACLE_PK, ASSET_ID, 2, wrongChainId, block.timestamp);

        VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: 2, chainId: wrongChainId, timestamp: block.timestamp, signature: sig
        });

        vm.expectRevert(
            abi.encodeWithSelector(VerificationEscrow.ChainIdMismatch.selector, wrongChainId, block.chainid)
        );
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_stateNotBound() public {
        uint256 escrowId = _createDefaultEscrow();

        // State 1 = MINTED (not BOUND)
        uint8 mintedState = 1;
        bytes memory sig = _signAssetProof(ORACLE_PK, ASSET_ID, mintedState, block.chainid, block.timestamp);

        VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: mintedState, chainId: block.chainid, timestamp: block.timestamp, signature: sig
        });

        vm.expectRevert(abi.encodeWithSelector(VerificationEscrow.AssetNotBound.selector, mintedState));
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_stateFlagged() public {
        uint256 escrowId = _createDefaultEscrow();

        uint8 flaggedState = 5;
        bytes memory sig = _signAssetProof(ORACLE_PK, ASSET_ID, flaggedState, block.chainid, block.timestamp);

        VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: flaggedState, chainId: block.chainid, timestamp: block.timestamp, signature: sig
        });

        vm.expectRevert(abi.encodeWithSelector(VerificationEscrow.AssetNotBound.selector, flaggedState));
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_proofTooStale() public {
        vm.warp(10_000_000); // Ensure block.timestamp is large enough for subtraction
        uint256 escrowId = _createDefaultEscrow();

        uint256 staleTimestamp = block.timestamp - 2 hours;
        bytes memory sig = _signAssetProof(ORACLE_PK, ASSET_ID, 2, block.chainid, staleTimestamp);

        VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: 2, chainId: block.chainid, timestamp: staleTimestamp, signature: sig
        });

        vm.expectRevert(
            abi.encodeWithSelector(VerificationEscrow.ProofTooStale.selector, staleTimestamp, block.timestamp)
        );
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_proofTimestampInFuture() public {
        uint256 escrowId = _createDefaultEscrow();

        uint256 futureTimestamp = block.timestamp + 1 hours;
        bytes memory sig = _signAssetProof(ORACLE_PK, ASSET_ID, 2, block.chainid, futureTimestamp);

        VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: 2, chainId: block.chainid, timestamp: futureTimestamp, signature: sig
        });

        vm.expectRevert(
            abi.encodeWithSelector(VerificationEscrow.ProofTimestampInFuture.selector, futureTimestamp, block.timestamp)
        );
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_wrongOracleSignature() public {
        uint256 escrowId = _createDefaultEscrow();

        bytes memory wrongSig = _signAssetProof(WRONG_ORACLE_PK, ASSET_ID, 2, block.chainid, block.timestamp);

        VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: 2, chainId: block.chainid, timestamp: block.timestamp, signature: wrongSig
        });

        vm.expectRevert(VerificationEscrow.InvalidOracleSignature.selector);
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_tamperedSignature() public {
        uint256 escrowId = _createDefaultEscrow();
        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID);

        // Tamper with signature
        proof.signature[0] = bytes1(uint8(proof.signature[0]) ^ 0xFF);

        vm.expectRevert(); // ECDSA error or wrong signer
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_releaseWithProof_revert_oracleNotSet() public {
        // Deploy escrow without oracle (set then unset is impossible, so deploy fresh with owner as oracle,
        // then transfer ownership and set oracle to 0 — but our contract doesn't allow zero. So we test
        // a different way: we'd need to test the OracleNotSet path. Since constructor requires non-zero,
        // this path can only be reached if we ever add a way to clear the oracle. For completeness,
        // we skip this edge case as the contract prevents it by construction.)
    }

    // ============================================
    // CANCEL ESCROW TESTS
    // ============================================

    function test_cancelEscrow_success() public {
        uint256 escrowId = _createDefaultEscrow();
        uint256 buyerBalBefore = usdc.balanceOf(buyer);

        vm.expectEmit(true, true, true, true);
        emit EscrowCancelled(escrowId, ASSET_ID, buyer, ESCROW_AMOUNT);

        vm.prank(buyer);
        escrow.cancelEscrow(escrowId);

        assertEq(usdc.balanceOf(buyer), buyerBalBefore + ESCROW_AMOUNT, "Buyer should be refunded");
        assertEq(usdc.balanceOf(address(escrow)), 0, "Contract should be empty");

        (,,,,, VerificationEscrow.EscrowStatus status) = escrow.getEscrow(escrowId);
        assertEq(uint8(status), uint8(VerificationEscrow.EscrowStatus.CANCELLED), "Status should be CANCELLED");
    }

    function test_cancelEscrow_revert_notBuyer() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(VerificationEscrow.NotBuyer.selector, escrowId, stranger));
        escrow.cancelEscrow(escrowId);
    }

    function test_cancelEscrow_revert_sellerCannotCancel() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(VerificationEscrow.NotBuyer.selector, escrowId, seller));
        escrow.cancelEscrow(escrowId);
    }

    function test_cancelEscrow_revert_escrowNotFound() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(VerificationEscrow.EscrowNotFound.selector, 999));
        escrow.cancelEscrow(999);
    }

    function test_cancelEscrow_revert_alreadyReleased() public {
        uint256 escrowId = _createDefaultEscrow();
        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID);
        escrow.releaseWithProof(escrowId, proof);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerificationEscrow.InvalidEscrowStatus.selector,
                escrowId,
                VerificationEscrow.EscrowStatus.RELEASED,
                VerificationEscrow.EscrowStatus.ACTIVE
            )
        );
        escrow.cancelEscrow(escrowId);
    }

    function test_cancelEscrow_revert_alreadyCancelled() public {
        uint256 escrowId = _createDefaultEscrow();

        vm.prank(buyer);
        escrow.cancelEscrow(escrowId);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerificationEscrow.InvalidEscrowStatus.selector,
                escrowId,
                VerificationEscrow.EscrowStatus.CANCELLED,
                VerificationEscrow.EscrowStatus.ACTIVE
            )
        );
        escrow.cancelEscrow(escrowId);
    }

    // ============================================
    // SET TRUSTED ORACLE TESTS
    // ============================================

    function test_setTrustedOracle_success() public {
        address newOracle = makeAddr("newOracle");

        vm.expectEmit(true, true, false, false);
        emit TrustedOracleUpdated(oracle, newOracle);

        vm.prank(owner);
        escrow.setTrustedOracle(newOracle);

        assertEq(escrow.trustedOracle(), newOracle, "Oracle should be updated");
    }

    function test_setTrustedOracle_revert_nonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setTrustedOracle(makeAddr("rogue"));
    }

    function test_setTrustedOracle_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(VerificationEscrow.ZeroAddress.selector);
        escrow.setTrustedOracle(address(0));
    }

    function test_setTrustedOracle_releaseUsesNewOracle() public {
        uint256 escrowId = _createDefaultEscrow();

        // Change oracle to wrongOracle
        vm.prank(owner);
        escrow.setTrustedOracle(wrongOracle);

        // Old oracle signature should fail
        VerificationEscrow.OracleProof memory oldProof = _buildValidProof(ASSET_ID);
        vm.expectRevert(VerificationEscrow.InvalidOracleSignature.selector);
        escrow.releaseWithProof(escrowId, oldProof);

        // New oracle signature should succeed
        bytes memory newSig = _signAssetProof(WRONG_ORACLE_PK, ASSET_ID, 2, block.chainid, block.timestamp);

        VerificationEscrow.OracleProof memory newProof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: 2, chainId: block.chainid, timestamp: block.timestamp, signature: newSig
        });

        escrow.releaseWithProof(escrowId, newProof);

        (,,,,, VerificationEscrow.EscrowStatus status) = escrow.getEscrow(escrowId);
        assertEq(uint8(status), uint8(VerificationEscrow.EscrowStatus.RELEASED), "Should be RELEASED");
    }

    // ============================================
    // FULL FLOW TESTS
    // ============================================

    function test_fullFlow_createAndRelease() public {
        // 1. Create escrow
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(ASSET_ID, seller, ESCROW_AMOUNT);

        // 2. Oracle attests asset is BOUND
        VerificationEscrow.OracleProof memory proof = _buildValidProof(ASSET_ID);

        // 3. Release
        uint256 sellerBalBefore = usdc.balanceOf(seller);
        escrow.releaseWithProof(escrowId, proof);

        // 4. Verify
        assertEq(usdc.balanceOf(seller), sellerBalBefore + ESCROW_AMOUNT, "Seller paid");
        (,,,,, VerificationEscrow.EscrowStatus status) = escrow.getEscrow(escrowId);
        assertEq(uint8(status), uint8(VerificationEscrow.EscrowStatus.RELEASED), "RELEASED");
    }

    function test_fullFlow_createAndCancel() public {
        // 1. Create escrow
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(ASSET_ID, seller, ESCROW_AMOUNT);
        uint256 buyerBalAfterCreate = usdc.balanceOf(buyer);

        // 2. Buyer changes mind
        vm.prank(buyer);
        escrow.cancelEscrow(escrowId);

        // 3. Verify refund
        assertEq(usdc.balanceOf(buyer), buyerBalAfterCreate + ESCROW_AMOUNT, "Buyer refunded");
        (,,,,, VerificationEscrow.EscrowStatus status) = escrow.getEscrow(escrowId);
        assertEq(uint8(status), uint8(VerificationEscrow.EscrowStatus.CANCELLED), "CANCELLED");
    }

    function test_fullFlow_releaseBlockedWhenNotBound() public {
        // Create escrow
        vm.prank(buyer);
        uint256 escrowId = escrow.createEscrow(ASSET_ID, seller, ESCROW_AMOUNT);

        // Try each non-BOUND state
        uint8[6] memory nonBoundStates = [uint8(0), 1, 3, 4, 5, 6];

        for (uint256 i = 0; i < nonBoundStates.length; i++) {
            uint8 state = nonBoundStates[i];
            bytes memory sig = _signAssetProof(ORACLE_PK, ASSET_ID, state, block.chainid, block.timestamp);

            VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
                tokenId: ASSET_ID, state: state, chainId: block.chainid, timestamp: block.timestamp, signature: sig
            });

            vm.expectRevert(abi.encodeWithSelector(VerificationEscrow.AssetNotBound.selector, state));
            escrow.releaseWithProof(escrowId, proof);
        }

        // Confirm escrow is still active
        (,,,,, VerificationEscrow.EscrowStatus status) = escrow.getEscrow(escrowId);
        assertEq(uint8(status), uint8(VerificationEscrow.EscrowStatus.ACTIVE), "Still ACTIVE");
    }

    // ============================================
    // EDGE CASES
    // ============================================

    function test_proofAtExactStalenessWindow() public {
        vm.warp(10_000_000); // Ensure block.timestamp is large enough for subtraction
        uint256 escrowId = _createDefaultEscrow();

        // Proof exactly at the staleness boundary (should still be valid)
        uint256 borderTimestamp = block.timestamp - 1 hours;
        bytes memory sig = _signAssetProof(ORACLE_PK, ASSET_ID, 2, block.chainid, borderTimestamp);

        VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: 2, chainId: block.chainid, timestamp: borderTimestamp, signature: sig
        });

        // Exactly 1 hour old: block.timestamp - borderTimestamp == 3600 == PROOF_STALENESS_WINDOW
        // The check is `>`, so exactly at the boundary is still valid
        escrow.releaseWithProof(escrowId, proof);

        (,,,,, VerificationEscrow.EscrowStatus status) = escrow.getEscrow(escrowId);
        assertEq(uint8(status), uint8(VerificationEscrow.EscrowStatus.RELEASED), "Should release at exact boundary");
    }

    function test_proofOneSecondPastStaleness() public {
        vm.warp(10_000_000); // Ensure block.timestamp is large enough for subtraction
        uint256 escrowId = _createDefaultEscrow();

        uint256 staleTimestamp = block.timestamp - 1 hours - 1;
        bytes memory sig = _signAssetProof(ORACLE_PK, ASSET_ID, 2, block.chainid, staleTimestamp);

        VerificationEscrow.OracleProof memory proof = VerificationEscrow.OracleProof({
            tokenId: ASSET_ID, state: 2, chainId: block.chainid, timestamp: staleTimestamp, signature: sig
        });

        vm.expectRevert(
            abi.encodeWithSelector(VerificationEscrow.ProofTooStale.selector, staleTimestamp, block.timestamp)
        );
        escrow.releaseWithProof(escrowId, proof);
    }

    function test_getEscrow_viewFunction() public {
        uint256 escrowId = _createDefaultEscrow();

        (address b, address s, uint256 aid, uint256 amt, uint64 ts, VerificationEscrow.EscrowStatus status) =
            escrow.getEscrow(escrowId);

        assertEq(b, buyer);
        assertEq(s, seller);
        assertEq(aid, ASSET_ID);
        assertEq(amt, ESCROW_AMOUNT);
        assertEq(ts, uint64(block.timestamp));
        assertEq(uint8(status), 0);
    }
}
