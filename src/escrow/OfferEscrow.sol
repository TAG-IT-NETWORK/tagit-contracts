// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title OfferEscrow
/// @notice Atomic NFT/USDC settlement triggered by an owner accept or a SUN-signed tap-on-receive.
///         Buyer signs an EIP-712 offer + funds USDC into escrow. Owner accepts (or buyer's tap on
///         delivery accepts via the chip's monotonic SUN counter), and NFT + USDC swap atomically.
///         Stuck escrows are refunded after `timeoutSeconds` via `timeoutRefund`.
contract OfferEscrow is EIP712, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    bytes32 private constant OFFER_TYPEHASH = keccak256(
        "Offer(address buyer,address nft,uint256 tokenId,address paymentToken,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    struct Offer {
        address buyer;
        address nft;
        uint256 tokenId;
        address paymentToken;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    enum OfferStatus {
        None,
        Funded,
        Accepted,
        Refunded,
        Cancelled
    }

    struct OfferState {
        OfferStatus status;
        uint64 fundedAt;
        address buyer;
        address nft;
        uint256 tokenId;
        address paymentToken;
        uint256 amount;
    }

    /// @dev offerHash => state
    mapping(bytes32 => OfferState) public offers;

    /// @dev buyer => nonce => used (replay protection across offers)
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /// @dev chip pubkey => last seen monotonic counter (SUN replay protection for tap-accept)
    mapping(address => uint32) public chipCounter;

    uint256 public immutable timeoutSeconds;

    event OfferFunded(
        bytes32 indexed offerHash,
        address indexed buyer,
        address indexed nft,
        uint256 tokenId,
        address paymentToken,
        uint256 amount
    );
    event OfferAccepted(bytes32 indexed offerHash, address indexed seller, address indexed buyer);
    event OfferRefunded(bytes32 indexed offerHash, address indexed buyer);
    event OfferCancelled(bytes32 indexed offerHash, address indexed buyer);
    event TapAccepted(address indexed chipPubkey, uint32 counter, bytes32 indexed offerHash);

    error InvalidSignature();
    error OfferExpired();
    error OfferNotFunded();
    error AlreadyFunded();
    error NotBuyer();
    error NotOwnerOfToken();
    error TimeoutNotReached();
    error NonceUsed();
    error ChipCounterReplay();
    error ZeroAddress();
    error ZeroAmount();

    constructor(uint256 _timeoutSeconds) EIP712("TagItOfferEscrow", "1") {
        timeoutSeconds = _timeoutSeconds;
    }

    /// @notice Buyer pulls USDC into escrow against a typed-data offer they signed.
    /// @dev    Caller must be the buyer named in the offer. Signature is verified via EIP-1271
    ///         to support smart-contract wallets (Coinbase Smart Wallet).
    function fundOffer(Offer calldata offer, bytes calldata signature) external nonReentrant returns (bytes32) {
        if (msg.sender != offer.buyer) revert NotBuyer();
        if (offer.buyer == address(0) || offer.nft == address(0) || offer.paymentToken == address(0)) {
            revert ZeroAddress();
        }
        if (offer.amount == 0) revert ZeroAmount();
        if (block.timestamp > offer.deadline) revert OfferExpired();
        if (usedNonces[offer.buyer][offer.nonce]) revert NonceUsed();

        bytes32 digest = _hashOffer(offer);
        if (!SignatureChecker.isValidSignatureNow(offer.buyer, digest, signature)) revert InvalidSignature();

        OfferState storage st = offers[digest];
        if (st.status != OfferStatus.None) revert AlreadyFunded();

        usedNonces[offer.buyer][offer.nonce] = true;

        st.status = OfferStatus.Funded;
        st.fundedAt = uint64(block.timestamp);
        st.buyer = offer.buyer;
        st.nft = offer.nft;
        st.tokenId = offer.tokenId;
        st.paymentToken = offer.paymentToken;
        st.amount = offer.amount;

        // Pull USDC from buyer (effects already written; safe under nonReentrant)
        IERC20(offer.paymentToken).safeTransferFrom(offer.buyer, address(this), offer.amount);

        emit OfferFunded(digest, offer.buyer, offer.nft, offer.tokenId, offer.paymentToken, offer.amount);
        return digest;
    }

    /// @notice Owner of the NFT accepts a funded offer. NFT and USDC swap atomically.
    /// @dev    Owner must have approved this contract to transfer the NFT.
    function acceptOffer(bytes32 offerHash) external nonReentrant {
        OfferState storage st = offers[offerHash];
        if (st.status != OfferStatus.Funded) revert OfferNotFunded();

        address currentOwner = IERC721(st.nft).ownerOf(st.tokenId);
        if (currentOwner != msg.sender) revert NotOwnerOfToken();

        st.status = OfferStatus.Accepted;
        _settle(offerHash, currentOwner, st);
    }

    /// @notice Tap-on-receive accept: chip-signed monotonic counter unlocks settlement.
    /// @dev    Off-chain SUN verifier produces (chipPubkey, counter, signature over offerHash||counter).
    ///         Settlement pays USDC to the seller currently registered on the NFT (i.e. ownerOf at
    ///         execution time). This is the buyer's cryptographic proof of physical receipt.
    function acceptOfferByTap(bytes32 offerHash, address chipPubkey, uint32 counter, bytes calldata chipSignature)
        external
        nonReentrant
    {
        OfferState storage st = offers[offerHash];
        if (st.status != OfferStatus.Funded) revert OfferNotFunded();

        if (counter <= chipCounter[chipPubkey]) revert ChipCounterReplay();

        bytes32 tapDigest = keccak256(abi.encodePacked(offerHash, chipPubkey, counter));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", tapDigest));
        address recovered = ECDSA.recover(ethSigned, chipSignature);
        if (recovered != chipPubkey) revert InvalidSignature();

        chipCounter[chipPubkey] = counter;
        st.status = OfferStatus.Accepted;

        address currentOwner = IERC721(st.nft).ownerOf(st.tokenId);
        emit TapAccepted(chipPubkey, counter, offerHash);
        _settle(offerHash, currentOwner, st);
    }

    /// @notice Buyer reclaims USDC after timeout if owner never accepted.
    function timeoutRefund(bytes32 offerHash) external nonReentrant {
        OfferState storage st = offers[offerHash];
        if (st.status != OfferStatus.Funded) revert OfferNotFunded();
        if (block.timestamp < st.fundedAt + timeoutSeconds) revert TimeoutNotReached();

        st.status = OfferStatus.Refunded;
        address buyer = st.buyer;
        uint256 amount = st.amount;
        address paymentToken = st.paymentToken;

        emit OfferRefunded(offerHash, buyer);
        IERC20(paymentToken).safeTransfer(buyer, amount);
    }

    /// @notice Buyer voluntarily cancels an offer that hasn't been accepted.
    function cancelOffer(bytes32 offerHash) external nonReentrant {
        OfferState storage st = offers[offerHash];
        if (st.status != OfferStatus.Funded) revert OfferNotFunded();
        if (msg.sender != st.buyer) revert NotBuyer();

        st.status = OfferStatus.Cancelled;
        address buyer = st.buyer;
        uint256 amount = st.amount;
        address paymentToken = st.paymentToken;

        emit OfferCancelled(offerHash, buyer);
        IERC20(paymentToken).safeTransfer(buyer, amount);
    }

    function hashOffer(Offer calldata offer) external view returns (bytes32) {
        return _hashOffer(offer);
    }

    function _hashOffer(Offer calldata offer) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OFFER_TYPEHASH,
                    offer.buyer,
                    offer.nft,
                    offer.tokenId,
                    offer.paymentToken,
                    offer.amount,
                    offer.nonce,
                    offer.deadline
                )
            )
        );
    }

    function _settle(bytes32 offerHash, address seller, OfferState storage st) internal {
        // Effects already written (status flipped to Accepted). External calls below.
        emit OfferAccepted(offerHash, seller, st.buyer);

        // Move NFT from seller to buyer (requires prior approval)
        IERC721(st.nft).safeTransferFrom(seller, st.buyer, st.tokenId);

        // Release USDC to seller
        IERC20(st.paymentToken).safeTransfer(seller, st.amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
