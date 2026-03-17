// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title VerificationEscrow
 * @author TAG IT Network <dev@tagit.network>
 * @notice Holds USDC in escrow, releases only when an oracle ECDSA proof confirms asset state = BOUND
 * @dev Standalone contract — no modifications to TAGITCore or any existing contracts.
 *
 * Flow:
 * 1. Buyer calls createEscrow() → USDC transferred into contract
 * 2. Anyone with a valid oracle proof calls releaseWithProof() → USDC sent to seller
 * 3. Buyer can cancelEscrow() for refund if not yet released
 *
 * Oracle proof format (must match tagit-services signAssetProof):
 *   messageHash = keccak256(abi.encodePacked(tokenId, state, chainId, timestamp))
 *   signature = EIP-191 personal sign over messageHash
 *
 * @custom:security All state-changing functions follow CEI pattern with ReentrancyGuard
 * @custom:security Oracle address is configurable via owner-only setter
 * @custom:security Proof timestamp is validated against a staleness window to prevent replay
 */
contract VerificationEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice The BOUND state code from TAGITCore.State enum
    uint8 public constant BOUND_STATE = 2;

    /// @notice Maximum age (in seconds) for an oracle proof timestamp to be considered valid
    uint256 public constant PROOF_STALENESS_WINDOW = 1 hours;

    // ============================================
    // DATA STRUCTURES
    // ============================================

    /// @notice Escrow lifecycle status
    enum EscrowStatus {
        ACTIVE, // 0 - Funds held in escrow
        RELEASED, // 1 - Funds sent to seller
        CANCELLED // 2 - Funds refunded to buyer
    }

    /// @notice On-chain escrow record
    /// @dev Packed for storage efficiency
    struct Escrow {
        address buyer;
        address seller;
        uint256 assetId;
        uint256 amount;
        uint64 createdAt;
        EscrowStatus status;
    }

    /// @notice Oracle proof data passed to releaseWithProof
    /// @dev Must match the format produced by tagit-services signAssetProof
    struct OracleProof {
        uint256 tokenId;
        uint8 state;
        uint256 chainId;
        uint256 timestamp;
        bytes signature;
    }

    // ============================================
    // STORAGE
    // ============================================

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice Trusted oracle address for ECDSA verification
    address public trustedOracle;

    /// @notice Monotonically increasing escrow counter
    uint256 public nextEscrowId;

    /// @notice Escrow ID → Escrow data
    mapping(uint256 => Escrow) public escrows;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a new escrow is created
    event EscrowCreated(
        uint256 indexed escrowId, uint256 indexed assetId, address indexed buyer, address seller, uint256 amount
    );

    /// @notice Emitted when escrow funds are released to the seller
    event EscrowReleased(
        uint256 indexed escrowId, uint256 indexed assetId, address indexed seller, uint256 amount, address oracle
    );

    /// @notice Emitted when an escrow is cancelled and buyer refunded
    event EscrowCancelled(uint256 indexed escrowId, uint256 indexed assetId, address indexed buyer, uint256 amount);

    /// @notice Emitted when the trusted oracle address is updated
    event TrustedOracleUpdated(address indexed previousOracle, address indexed newOracle);

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Thrown when a zero address is provided where one is not allowed
    error ZeroAddress();

    /// @notice Thrown when the escrow amount is zero
    error ZeroAmount();

    /// @notice Thrown when the referenced escrow does not exist
    error EscrowNotFound(uint256 escrowId);

    /// @notice Thrown when the escrow is not in the expected status
    error InvalidEscrowStatus(uint256 escrowId, EscrowStatus current, EscrowStatus expected);

    /// @notice Thrown when the caller is not the buyer of the escrow
    error NotBuyer(uint256 escrowId, address caller);

    /// @notice Thrown when the oracle address has not been set
    error OracleNotSet();

    /// @notice Thrown when the oracle ECDSA signature is invalid
    error InvalidOracleSignature();

    /// @notice Thrown when the oracle proof asset ID doesn't match the escrow asset ID
    error AssetIdMismatch(uint256 proofAssetId, uint256 escrowAssetId);

    /// @notice Thrown when the oracle proof chain ID doesn't match the current chain
    error ChainIdMismatch(uint256 proofChainId, uint256 currentChainId);

    /// @notice Thrown when the oracle proof state is not BOUND
    error AssetNotBound(uint8 actualState);

    /// @notice Thrown when the oracle proof timestamp is too old
    error ProofTooStale(uint256 proofTimestamp, uint256 currentTimestamp);

    /// @notice Thrown when the oracle proof timestamp is in the future
    error ProofTimestampInFuture(uint256 proofTimestamp, uint256 currentTimestamp);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the VerificationEscrow contract
     * @param _usdc Address of the USDC token contract
     * @param _trustedOracle Initial trusted oracle address (can be updated later)
     * @custom:security Owner is deployer (msg.sender) via OZ v5 Ownable pattern
     */
    constructor(address _usdc, address _trustedOracle) Ownable(msg.sender) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_trustedOracle == address(0)) revert ZeroAddress();

        usdc = IERC20(_usdc);
        trustedOracle = _trustedOracle;

        emit TrustedOracleUpdated(address(0), _trustedOracle);
    }

    // ============================================
    // ESCROW LIFECYCLE
    // ============================================

    /**
     * @notice Create a new escrow — buyer deposits USDC for a specific asset
     * @param assetId The TAGITCore token ID this escrow is for
     * @param seller Address that will receive USDC upon successful release
     * @param amount USDC amount (6 decimals) to lock in escrow
     * @return escrowId The unique identifier for this escrow
     * @custom:security Follows CEI pattern: checks → effects → interactions (safeTransferFrom last)
     */
    function createEscrow(uint256 assetId, address seller, uint256 amount)
        external
        nonReentrant
        returns (uint256 escrowId)
    {
        // ── Checks ──
        if (seller == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // ── Effects ──
        escrowId = nextEscrowId++;

        escrows[escrowId] = Escrow({
            buyer: msg.sender,
            seller: seller,
            assetId: assetId,
            amount: amount,
            createdAt: uint64(block.timestamp),
            status: EscrowStatus.ACTIVE
        });

        emit EscrowCreated(escrowId, assetId, msg.sender, seller, amount);

        // ── Interactions ──
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Release escrowed funds to seller after oracle proof verification
     * @param escrowId The escrow to release
     * @param proof Oracle proof containing asset state attestation and ECDSA signature
     * @dev Verifies:
     *   1. Escrow exists and is ACTIVE
     *   2. Oracle address is set
     *   3. Proof asset ID matches escrow asset ID
     *   4. Proof chain ID matches current chain
     *   5. Proof timestamp is fresh (within staleness window) and not in the future
     *   6. Proof state is BOUND (state code 2)
     *   7. ECDSA signature recovers to trusted oracle address
     * @custom:security Follows CEI pattern: checks → effects → interactions (safeTransfer last)
     */
    function releaseWithProof(uint256 escrowId, OracleProof calldata proof) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        // ── Checks ──
        if (escrow.buyer == address(0)) revert EscrowNotFound(escrowId);
        if (escrow.status != EscrowStatus.ACTIVE) {
            revert InvalidEscrowStatus(escrowId, escrow.status, EscrowStatus.ACTIVE);
        }
        if (trustedOracle == address(0)) revert OracleNotSet();
        if (proof.tokenId != escrow.assetId) {
            revert AssetIdMismatch(proof.tokenId, escrow.assetId);
        }
        if (proof.chainId != block.chainid) {
            revert ChainIdMismatch(proof.chainId, block.chainid);
        }
        if (proof.timestamp > block.timestamp) {
            revert ProofTimestampInFuture(proof.timestamp, block.timestamp);
        }
        if (block.timestamp - proof.timestamp > PROOF_STALENESS_WINDOW) {
            revert ProofTooStale(proof.timestamp, block.timestamp);
        }
        if (proof.state != BOUND_STATE) {
            revert AssetNotBound(proof.state);
        }

        // Verify oracle ECDSA signature
        // Message format must match tagit-services signAssetProof:
        // keccak256(abi.encodePacked(tokenId, state, chainId, timestamp))
        // with types: [uint256, uint8, uint256, uint256]
        bytes32 messageHash = keccak256(abi.encodePacked(proof.tokenId, proof.state, proof.chainId, proof.timestamp));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recovered = ECDSA.recover(ethSignedHash, proof.signature);

        if (recovered != trustedOracle) revert InvalidOracleSignature();

        // ── Effects ──
        escrow.status = EscrowStatus.RELEASED;

        emit EscrowReleased(escrowId, escrow.assetId, escrow.seller, escrow.amount, trustedOracle);

        // ── Interactions ──
        usdc.safeTransfer(escrow.seller, escrow.amount);
    }

    /**
     * @notice Cancel an escrow and refund the buyer
     * @param escrowId The escrow to cancel
     * @dev Only the original buyer can cancel. Escrow must still be ACTIVE.
     * @custom:security Follows CEI pattern: checks → effects → interactions (safeTransfer last)
     */
    function cancelEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        // ── Checks ──
        if (escrow.buyer == address(0)) revert EscrowNotFound(escrowId);
        if (escrow.status != EscrowStatus.ACTIVE) {
            revert InvalidEscrowStatus(escrowId, escrow.status, EscrowStatus.ACTIVE);
        }
        if (msg.sender != escrow.buyer) revert NotBuyer(escrowId, msg.sender);

        // ── Effects ──
        escrow.status = EscrowStatus.CANCELLED;

        emit EscrowCancelled(escrowId, escrow.assetId, escrow.buyer, escrow.amount);

        // ── Interactions ──
        usdc.safeTransfer(escrow.buyer, escrow.amount);
    }

    // ============================================
    // ADMIN
    // ============================================

    /**
     * @notice Update the trusted oracle address
     * @param _newOracle New oracle address
     * @custom:security Only callable by contract owner
     */
    function setTrustedOracle(address _newOracle) external onlyOwner {
        if (_newOracle == address(0)) revert ZeroAddress();

        address previous = trustedOracle;
        trustedOracle = _newOracle;

        emit TrustedOracleUpdated(previous, _newOracle);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get full escrow details
     * @param escrowId The escrow to query
     * @return buyer The buyer address
     * @return seller The seller address
     * @return assetId The TAGITCore token ID
     * @return amount The USDC amount held
     * @return createdAt Timestamp of escrow creation
     * @return status Current escrow status
     */
    function getEscrow(uint256 escrowId)
        external
        view
        returns (address buyer, address seller, uint256 assetId, uint256 amount, uint64 createdAt, EscrowStatus status)
    {
        Escrow storage e = escrows[escrowId];
        return (e.buyer, e.seller, e.assetId, e.amount, e.createdAt, e.status);
    }
}
