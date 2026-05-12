// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {OfferEscrow} from "../../../src/escrow/OfferEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockNFT is ERC721 {
    constructor() ERC721("TagItDemo", "TAG") {}

    function mint(address to, uint256 id) external {
        _safeMint(to, id);
    }
}

/// @dev Reentrant USDC: tries to call back into escrow on transfer.
contract ReentrantUSDC is ERC20 {
    OfferEscrow public escrow;
    bytes32 public attackHash;
    bool public attacking;

    constructor() ERC20("Reentrant", "REE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAttack(OfferEscrow e, bytes32 h) external {
        escrow = e;
        attackHash = h;
        attacking = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (attacking && from != address(0) && to != address(0)) {
            attacking = false; // only try once
            // Try to re-enter timeoutRefund mid-transfer
            try escrow.timeoutRefund(attackHash) {} catch {}
        }
        super._update(from, to, value);
    }
}

contract OfferEscrowTest is Test {
    OfferEscrow internal escrow;
    MockUSDC internal usdc;
    MockNFT internal nft;

    uint256 internal constant TOKEN_ID = 18;
    uint256 internal constant TIMEOUT = 24 hours;
    uint256 internal constant OFFER_AMOUNT = 30e6; // 30 USDC

    uint256 internal sellerKey = 0xA11CE;
    uint256 internal buyerKey = 0xB0B;
    address internal seller;
    address internal buyer;

    function setUp() public {
        seller = vm.addr(sellerKey);
        buyer = vm.addr(buyerKey);

        escrow = new OfferEscrow(TIMEOUT);
        usdc = new MockUSDC();
        nft = new MockNFT();

        nft.mint(seller, TOKEN_ID);
        usdc.mint(buyer, 1000e6);

        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);

        vm.prank(seller);
        nft.setApprovalForAll(address(escrow), true);
    }

    function _signOffer(OfferEscrow.Offer memory offer, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = escrow.hashOffer(offer);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signTap(uint256 chipKey, bytes32 offerHash, address chipPubkey, uint32 counter)
        internal
        returns (bytes memory)
    {
        bytes32 tapDigest = keccak256(abi.encodePacked(offerHash, chipPubkey, counter));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", tapDigest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(chipKey, ethSigned);
        return abi.encodePacked(r, s, v);
    }

    function _baseOffer() internal view returns (OfferEscrow.Offer memory) {
        return OfferEscrow.Offer({
            buyer: buyer,
            seller: seller,
            chipPubkey: address(0), // tap-accept disabled by default; tap tests override
            nft: address(nft),
            tokenId: TOKEN_ID,
            paymentToken: address(usdc),
            amount: OFFER_AMOUNT,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
    }

    function test_happyPath_fund_then_accept_settles_atomically() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        assertEq(usdc.balanceOf(address(escrow)), OFFER_AMOUNT);
        assertEq(usdc.balanceOf(buyer), 1000e6 - OFFER_AMOUNT);
        assertEq(nft.ownerOf(TOKEN_ID), seller);

        vm.prank(seller);
        escrow.acceptOffer(h);

        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(seller), OFFER_AMOUNT);
        assertEq(nft.ownerOf(TOKEN_ID), buyer);
    }

    function test_revert_when_nonBuyer_funds() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(seller);
        vm.expectRevert(OfferEscrow.NotBuyer.selector);
        escrow.fundOffer(offer, sig);
    }

    function test_revert_when_signature_forged() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, sellerKey); // wrong key

        vm.prank(buyer);
        vm.expectRevert(OfferEscrow.InvalidSignature.selector);
        escrow.fundOffer(offer, sig);
    }

    function test_revert_when_offer_expired() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        offer.deadline = block.timestamp - 1;
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        vm.expectRevert(OfferEscrow.OfferExpired.selector);
        escrow.fundOffer(offer, sig);
    }

    function test_revert_on_double_fund_same_nonce() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.startPrank(buyer);
        escrow.fundOffer(offer, sig);
        vm.expectRevert(OfferEscrow.NonceUsed.selector);
        escrow.fundOffer(offer, sig);
        vm.stopPrank();
    }

    function test_revert_on_double_accept() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        vm.prank(seller);
        escrow.acceptOffer(h);

        vm.prank(seller);
        vm.expectRevert(OfferEscrow.OfferNotFunded.selector);
        escrow.acceptOffer(h);
    }

    function test_revert_when_nonSeller_accepts() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        vm.prank(buyer);
        vm.expectRevert(OfferEscrow.NotSeller.selector);
        escrow.acceptOffer(h);
    }

    function test_timeoutRefund_returns_USDC_to_buyer_after_timeout() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        // Before timeout: revert
        vm.expectRevert(OfferEscrow.TimeoutNotReached.selector);
        escrow.timeoutRefund(h);

        vm.warp(block.timestamp + TIMEOUT + 1);

        escrow.timeoutRefund(h);

        assertEq(usdc.balanceOf(buyer), 1000e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    function test_cancelOffer_returns_USDC_to_buyer() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        vm.prank(buyer);
        escrow.cancelOffer(h);

        assertEq(usdc.balanceOf(buyer), 1000e6);
    }

    function test_revert_when_nonBuyer_cancels() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        vm.prank(seller);
        vm.expectRevert(OfferEscrow.NotBuyer.selector);
        escrow.cancelOffer(h);
    }

    function test_acceptOfferByTap_with_monotonic_counter() public {
        uint256 chipKey = 0xC417;
        address chipPubkey = vm.addr(chipKey);

        OfferEscrow.Offer memory offer = _baseOffer();
        offer.chipPubkey = chipPubkey;
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        uint32 counter = 7;
        bytes memory chipSig = _signTap(chipKey, h, chipPubkey, counter);

        escrow.acceptOfferByTap(h, chipPubkey, counter, chipSig);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(usdc.balanceOf(seller), OFFER_AMOUNT);
        assertEq(escrow.chipCounter(chipPubkey), counter);
    }

    function test_revert_tap_replay_with_stale_counter() public {
        uint256 chipKey = 0xC417;
        address chipPubkey = vm.addr(chipKey);

        // First, bump the chip counter via a successful tap on token 19
        nft.mint(seller, 19);
        OfferEscrow.Offer memory offer2 = _baseOffer();
        offer2.tokenId = 19;
        offer2.nonce = 2;
        offer2.chipPubkey = chipPubkey;
        bytes memory sig2 = _signOffer(offer2, buyerKey);
        vm.prank(buyer);
        bytes32 h2 = escrow.fundOffer(offer2, sig2);

        bytes memory tapSig = _signTap(chipKey, h2, chipPubkey, 10);
        escrow.acceptOfferByTap(h2, chipPubkey, 10, tapSig);
        assertEq(escrow.chipCounter(chipPubkey), 10);

        // Now fund original offer and try to replay a stale counter (5)
        OfferEscrow.Offer memory offer = _baseOffer();
        offer.chipPubkey = chipPubkey;
        bytes memory sig = _signOffer(offer, buyerKey);
        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        bytes memory replaySig = _signTap(chipKey, h, chipPubkey, 5);
        vm.expectRevert(OfferEscrow.ChipCounterReplay.selector);
        escrow.acceptOfferByTap(h, chipPubkey, 5, replaySig);
    }

    /// @dev Audit finding (CRITICAL): caller cannot substitute an attacker-controlled chip key.
    function test_revert_tap_with_wrong_chip_key() public {
        uint256 realChipKey = 0xC417;
        address realChipPubkey = vm.addr(realChipKey);
        uint256 attackerKey = 0xBADBAD;
        address attackerPubkey = vm.addr(attackerKey);

        OfferEscrow.Offer memory offer = _baseOffer();
        offer.chipPubkey = realChipPubkey; // offer commits to the real chip
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        // Attacker signs the tap digest with their own key, claims it's the chip
        bytes memory attackerSig = _signTap(attackerKey, h, attackerPubkey, 7);

        vm.expectRevert(OfferEscrow.ChipMismatch.selector);
        escrow.acceptOfferByTap(h, attackerPubkey, 7, attackerSig);

        // NFT and USDC remain locked, not redirected
        assertEq(nft.ownerOf(TOKEN_ID), seller);
        assertEq(usdc.balanceOf(address(escrow)), OFFER_AMOUNT);
    }

    /// @dev When the buyer didn't commit to a chip (chipPubkey = address(0)), the tap path is disabled.
    function test_revert_tap_when_disabled() public {
        OfferEscrow.Offer memory offer = _baseOffer(); // chipPubkey = address(0)
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        uint256 chipKey = 0xC417;
        address chipPubkey = vm.addr(chipKey);
        bytes memory chipSig = _signTap(chipKey, h, chipPubkey, 7);

        vm.expectRevert(OfferEscrow.TapDisabled.selector);
        escrow.acceptOfferByTap(h, chipPubkey, 7, chipSig);
    }

    /// @dev Audit finding (HIGH): seller cannot redirect proceeds by transferring the NFT mid-flight.
    function test_revert_acceptOffer_after_seller_transferred_nft() public {
        OfferEscrow.Offer memory offer = _baseOffer();
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        // Seller moves the NFT to a third party before accepting
        address thirdParty = address(0xC0FFEE);
        vm.prank(seller);
        nft.transferFrom(seller, thirdParty, TOKEN_ID);

        // Original seller can no longer accept — they no longer own the NFT
        vm.prank(seller);
        vm.expectRevert(OfferEscrow.SellerNoLongerOwner.selector);
        escrow.acceptOffer(h);

        // Third party (new owner) is not the named seller — cannot accept either
        vm.prank(thirdParty);
        vm.expectRevert(OfferEscrow.NotSeller.selector);
        escrow.acceptOffer(h);

        // USDC remains in escrow; buyer can timeout-refund
        assertEq(usdc.balanceOf(address(escrow)), OFFER_AMOUNT);
    }

    /// @dev Audit finding (HIGH): same protection on the tap-accept path.
    function test_revert_acceptOfferByTap_after_seller_transferred_nft() public {
        uint256 chipKey = 0xC417;
        address chipPubkey = vm.addr(chipKey);

        OfferEscrow.Offer memory offer = _baseOffer();
        offer.chipPubkey = chipPubkey;
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        // Seller moves the NFT away after the buyer funded
        vm.prank(seller);
        nft.transferFrom(seller, address(0xC0FFEE), TOKEN_ID);

        // Even a legitimate chip tap cannot settle if the seller no longer owns the NFT
        bytes memory chipSig = _signTap(chipKey, h, chipPubkey, 7);
        vm.expectRevert(OfferEscrow.SellerNoLongerOwner.selector);
        escrow.acceptOfferByTap(h, chipPubkey, 7, chipSig);
    }

    function test_reentrancy_during_refund_is_blocked() public {
        // Deploy reentrant token, mint to buyer, set up offer paying with it
        ReentrantUSDC ree = new ReentrantUSDC();
        ree.mint(buyer, 1000e6);
        vm.prank(buyer);
        ree.approve(address(escrow), type(uint256).max);

        OfferEscrow.Offer memory offer = _baseOffer();
        offer.paymentToken = address(ree);
        bytes memory sig = _signOffer(offer, buyerKey);

        vm.prank(buyer);
        bytes32 h = escrow.fundOffer(offer, sig);

        vm.warp(block.timestamp + TIMEOUT + 1);

        // Arm the reentrancy: the token's _update will call timeoutRefund again mid-transfer
        ree.setAttack(escrow, h);

        // The outer call succeeds, the inner reentrant call is silently blocked (try/catch in token)
        // and does NOT result in double payout.
        escrow.timeoutRefund(h);

        assertEq(ree.balanceOf(buyer), 1000e6);
        assertEq(ree.balanceOf(address(escrow)), 0);
    }
}
