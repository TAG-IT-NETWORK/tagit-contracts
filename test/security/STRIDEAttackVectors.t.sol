// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {ITAGITTreasury} from "../../src/interfaces/ITAGITTreasury.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {CircuitBreaker} from "../../src/libraries/CircuitBreaker.sol";
import {RateLimiter} from "../../src/libraries/RateLimiter.sol";

/**
 * @title STRIDEAttackVectors
 * @notice Comprehensive STRIDE threat model integration tests for TAGITCore and TAGITTreasury
 * @dev Tests all 6 STRIDE categories:
 *      S — Spoofing (Identity)
 *      T — Tampering (Data Integrity)
 *      R — Repudiation (Audit Trail)
 *      I — Information Disclosure
 *      D — Denial of Service
 *      E — Elevation of Privilege
 */
contract STRIDEAttackVectors is Test {
    // ============================================
    // CONTRACTS
    // ============================================

    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;
    TAGITTreasury public treasury;
    TAGITToken public token;

    // ============================================
    // ACTORS
    // ============================================

    address public coreOwner;
    address public treasuryOwner;
    address public governor;
    address public tokenTreasury;
    address public manufacturer;
    address public resolver2;
    address public resolver3;
    address public attacker;
    address public user1;
    address public user2;

    // ============================================
    // TREASURY SIGNERS
    // ============================================

    uint256[8] public signerKeys;
    address[8] public signerAddresses;

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 constant ORACLE_PK = 0xA11CE;
    uint256 constant FAKE_ORACLE_PK = 0xDEAD;

    bytes32 public constant METADATA_1 = keccak256("ipfs://QmTest1");
    bytes32 public constant METADATA_2 = keccak256("ipfs://QmTest2");
    bytes32 public constant TAG_HASH_1 = keccak256("NFC_TAG_UID_001");
    bytes32 public constant TAG_HASH_2 = keccak256("NFC_TAG_UID_002");

    // ============================================
    // EVENTS (redeclare for testing)
    // ============================================

    event AssetMinted(uint256 indexed tokenId, address indexed to, bytes32 metadata);
    event StateChanged(uint256 indexed tokenId, TAGITCore.State from, TAGITCore.State to, address actor);
    event TagBound(uint256 indexed tokenId, bytes32 indexed tagHash);
    event CustodyTransfer(
        uint256 indexed assetId,
        uint8 fromState,
        uint8 toState,
        address indexed fromOwner,
        address indexed toOwner,
        uint256 timestamp,
        bytes32 prevStateHash
    );
    event ResolveApproved(
        uint256 indexed tokenId,
        address indexed approver,
        uint256 approvalCount
    );

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        // Create test accounts
        coreOwner = makeAddr("coreOwner");
        treasuryOwner = makeAddr("treasuryOwner");
        governor = makeAddr("governor");
        tokenTreasury = makeAddr("tokenTreasury");
        manufacturer = makeAddr("manufacturer");
        resolver2 = makeAddr("resolver2");
        resolver3 = makeAddr("resolver3");
        attacker = makeAddr("attacker");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // ---- Deploy TAGITCore + Access Control ----

        // Deploy badge contracts (deployer = test contract = owner of badges)
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();

        // Deploy TAGITAccess facade
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Deploy TAGITCore behind UUPS proxy
        TAGITCore coreImpl = new TAGITCore();
        bytes memory coreInitData = abi.encodeCall(TAGITCore.initialize, (coreOwner));
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), coreInitData);
        tagitCore = TAGITCore(address(coreProxy));

        // Set up access controller and oracle
        vm.startPrank(coreOwner);
        tagitCore.setAccessController(address(tagitAccess));
        tagitCore.setTrustedOracle(vm.addr(ORACLE_PK));
        tagitCore.setRedactedURI("ipfs://REDACTED");
        vm.stopPrank();

        // Grant all capabilities to manufacturer
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.RECYCLER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.VIEWER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.AUDITOR_CAPABILITY()));

        // Grant RESOLVER_CAPABILITY to resolver2 and resolver3
        capabilityBadge.grantCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(resolver3, uint256(tagitCore.RESOLVER_CAPABILITY()));

        // ---- Deploy TAGITTreasury + Token ----

        for (uint256 i = 0; i < 8; i++) {
            signerKeys[i] = uint256(keccak256(abi.encodePacked("signer", i)));
            signerAddresses[i] = vm.addr(signerKeys[i]);
        }

        vm.startPrank(treasuryOwner);

        // Deploy TAGITToken behind proxy
        TAGITToken tokenImpl = new TAGITToken();
        token = TAGITToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeCall(TAGITToken.initialize, (treasuryOwner, tokenTreasury))
                )
            )
        );

        // Deploy TAGITTreasury behind proxy
        address[] memory sa = new address[](8);
        for (uint256 i = 0; i < 8; i++) sa[i] = signerAddresses[i];
        TAGITTreasury treasuryImpl = new TAGITTreasury();
        treasury = TAGITTreasury(
            payable(
                address(
                    new ERC1967Proxy(
                        address(treasuryImpl),
                        abi.encodeCall(TAGITTreasury.initialize, (governor, address(token), sa))
                    )
                )
            )
        );

        // Fund the treasury
        token.transfer(address(treasury), 10_000_000e18);

        vm.stopPrank();
    }

    // ============================================
    // HELPERS
    // ============================================

    function _oracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        returns (bytes memory cr, bytes memory sig)
    {
        cr = abi.encodePacked("challenge", tokenId);
        bytes32 mh = keccak256(abi.encodePacked(tokenId, tagHash, cr));
        bytes32 eh = MessageHashUtils.toEthSignedMessageHash(mh);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, eh);
        sig = abi.encodePacked(r, s, v);
    }

    function _fakeOracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        returns (bytes memory cr, bytes memory sig)
    {
        cr = abi.encodePacked("challenge", tokenId);
        bytes32 mh = keccak256(abi.encodePacked(tokenId, tagHash, cr));
        bytes32 eh = MessageHashUtils.toEthSignedMessageHash(mh);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FAKE_ORACLE_PK, eh);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Mint, bind, activate, claim a token in a single flow
    function _mintToClaimed(address recipient, uint256 tagSeed)
        internal
        returns (uint256 tokenId)
    {
        bytes32 tagHash = keccak256(abi.encodePacked("tag", tagSeed));

        vm.startPrank(manufacturer);
        tokenId = tagitCore.mint(manufacturer, METADATA_1);
        {
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
            tagitCore.bindTag(tokenId, tagHash, cr, sig);
        }
        tagitCore.activate(tokenId);
        tagitCore.claim(tokenId, recipient);
        vm.stopPrank();
    }

    /// @dev Mint, bind, activate, claim, flag a token in a single flow
    function _mintToFlagged(address recipient, uint256 tagSeed)
        internal
        returns (uint256 tokenId)
    {
        tokenId = _mintToClaimed(recipient, tagSeed);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);
    }

    // ================================================================
    //  S — SPOOFING (Identity)
    // ================================================================

    /**
     * @notice S01: Random address without MINTER capability cannot mint
     * @dev Verifies that capability checks prevent identity spoofing on mint
     */
    function test_S01_spoofCapability_unauthorizedMint() public {
        vm.prank(attacker);
        vm.expectRevert(); // MissingCapability
        tagitCore.mint(attacker, METADATA_1);
    }

    /**
     * @notice S02: Unauthorized caller is blocked from every lifecycle function
     * @dev Matrix test: attacker tries mint, bindTag, activate, claim, flag,
     *      approveResolve, resolve, recycle -- all must revert
     */
    function test_S02_spoofCapability_allFunctions() public {
        // Prepare an asset at each required state via the legitimate manufacturer
        vm.startPrank(manufacturer);
        uint256 mintedId = tagitCore.mint(manufacturer, METADATA_1);
        uint256 boundId;
        {
            uint256 tid = tagitCore.mint(manufacturer, METADATA_1);
            bytes32 th = keccak256("tag_for_bound");
            (bytes memory cr, bytes memory sig) = _oracleSign(tid, th);
            tagitCore.bindTag(tid, th, cr, sig);
            boundId = tid;
        }
        uint256 activatedId;
        {
            uint256 tid = tagitCore.mint(manufacturer, METADATA_1);
            bytes32 th = keccak256("tag_for_activated");
            (bytes memory cr, bytes memory sig) = _oracleSign(tid, th);
            tagitCore.bindTag(tid, th, cr, sig);
            tagitCore.activate(tid);
            activatedId = tid;
        }
        uint256 claimedId;
        {
            uint256 tid = tagitCore.mint(manufacturer, METADATA_1);
            bytes32 th = keccak256("tag_for_claimed");
            (bytes memory cr, bytes memory sig) = _oracleSign(tid, th);
            tagitCore.bindTag(tid, th, cr, sig);
            tagitCore.activate(tid);
            tagitCore.claim(tid, user1);
            claimedId = tid;
        }
        uint256 flaggedId;
        {
            uint256 tid = tagitCore.mint(manufacturer, METADATA_1);
            bytes32 th = keccak256("tag_for_flagged");
            (bytes memory cr, bytes memory sig) = _oracleSign(tid, th);
            tagitCore.bindTag(tid, th, cr, sig);
            tagitCore.activate(tid);
            tagitCore.claim(tid, user1);
            tagitCore.flag(tid);
            flaggedId = tid;
        }
        vm.stopPrank();

        // Attacker tries every function — all should revert
        vm.startPrank(attacker);

        // mint
        vm.expectRevert();
        tagitCore.mint(attacker, METADATA_1);

        // bindTag
        {
            (bytes memory cr, bytes memory sig) = _oracleSign(mintedId, TAG_HASH_1);
            vm.expectRevert();
            tagitCore.bindTag(mintedId, TAG_HASH_1, cr, sig);
        }

        // activate
        vm.expectRevert();
        tagitCore.activate(boundId);

        // claim
        vm.expectRevert();
        tagitCore.claim(activatedId, attacker);

        // flag
        vm.expectRevert();
        tagitCore.flag(claimedId);

        // approveResolve
        vm.expectRevert();
        tagitCore.approveResolve(flaggedId, attacker);

        // resolve
        vm.expectRevert();
        tagitCore.resolve(flaggedId, attacker);

        // recycle
        vm.expectRevert();
        tagitCore.recycle(claimedId);

        vm.stopPrank();
    }

    /**
     * @notice S03: Attacker generates valid-looking signature with wrong oracle key
     * @dev A signature from a non-oracle private key must be rejected by bindTag
     */
    function test_S03_spoofOracleSignature() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA_1);

        // Sign with the FAKE oracle key
        (bytes memory cr, bytes memory sig) = _fakeOracleSign(tokenId, TAG_HASH_1);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId, TAG_HASH_1, cr, sig);
    }

    /**
     * @notice S04: Non-resolver tries to approve/resolve a flagged asset
     * @dev Attacker without RESOLVER_CAPABILITY cannot participate in quorum
     */
    function test_S04_spoofResolverIdentity() public {
        uint256 flaggedId = _mintToFlagged(user1, 100);

        // Attacker (no RESOLVER_CAPABILITY) tries approveResolve
        vm.prank(attacker);
        vm.expectRevert(); // MissingCapability
        tagitCore.approveResolve(flaggedId, attacker);

        // Attacker (no RESOLVER_CAPABILITY) tries resolve
        vm.prank(attacker);
        vm.expectRevert(); // MissingCapability
        tagitCore.resolve(flaggedId, attacker);
    }

    /**
     * @notice S05: Non-governor tries treasury governance actions
     * @dev createAllocation, pause, setSigner, setGovernor must all revert for non-governor
     */
    function test_S05_spoofGovernor() public {
        // Attacker tries createAllocation
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, attacker));
        treasury.createAllocation(keccak256("GRANT"), 1000e18, attacker, 365 days);

        // Attacker tries pause
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, attacker));
        treasury.pause();

        // Attacker tries setSigner
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, attacker));
        treasury.setSigner(attacker, true);

        // Attacker tries setGovernor
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, attacker));
        treasury.setGovernor(attacker);

        // Attacker tries to reset drain detector
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, attacker));
        treasury.resetDrainDetector();

        // Attacker tries unpause
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITTreasury.NotGovernor.selector, attacker));
        treasury.unpause();
    }

    // ================================================================
    //  T — TAMPERING (Data Integrity)
    // ================================================================

    /**
     * @notice T01: Try to jump MINTED directly to CLAIMED (skip BOUND + ACTIVATED)
     * @dev The state machine must enforce linear progression
     */
    function test_T01_skipState_mintToClaimed() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA_1);

        // Asset is MINTED. Try to claim directly (requires ACTIVATED).
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector,
                tokenId,
                TAGITCore.State.MINTED,
                TAGITCore.State.ACTIVATED
            )
        );
        tagitCore.claim(tokenId, user1);
    }

    /**
     * @notice T02: Matrix test of every invalid state transition
     * @dev Creates assets at every non-terminal state and tries every invalid forward/backward jump
     */
    function test_T02_skipState_allInvalid() public {
        // Create assets at each state
        vm.startPrank(manufacturer);

        // MINTED (tokenId = 1)
        uint256 mintedId = tagitCore.mint(manufacturer, METADATA_1);

        // BOUND (tokenId = 2)
        uint256 boundId = tagitCore.mint(manufacturer, METADATA_1);
        {
            bytes32 th = keccak256("tag_t02_bound");
            (bytes memory cr, bytes memory sig) = _oracleSign(boundId, th);
            tagitCore.bindTag(boundId, th, cr, sig);
        }

        // ACTIVATED (tokenId = 3)
        uint256 activatedId = tagitCore.mint(manufacturer, METADATA_1);
        {
            bytes32 th = keccak256("tag_t02_act");
            (bytes memory cr, bytes memory sig) = _oracleSign(activatedId, th);
            tagitCore.bindTag(activatedId, th, cr, sig);
            tagitCore.activate(activatedId);
        }

        // CLAIMED (tokenId = 4)
        uint256 claimedId = tagitCore.mint(manufacturer, METADATA_1);
        {
            bytes32 th = keccak256("tag_t02_claimed");
            (bytes memory cr, bytes memory sig) = _oracleSign(claimedId, th);
            tagitCore.bindTag(claimedId, th, cr, sig);
            tagitCore.activate(claimedId);
            tagitCore.claim(claimedId, user1);
        }

        // FLAGGED (tokenId = 5)
        uint256 flaggedId = tagitCore.mint(manufacturer, METADATA_1);
        {
            bytes32 th = keccak256("tag_t02_flagged");
            (bytes memory cr, bytes memory sig) = _oracleSign(flaggedId, th);
            tagitCore.bindTag(flaggedId, th, cr, sig);
            tagitCore.activate(flaggedId);
            tagitCore.claim(flaggedId, user1);
            tagitCore.flag(flaggedId);
        }

        vm.stopPrank();

        vm.startPrank(manufacturer);

        // ---- MINTED: can only bindTag; everything else should fail ----
        // activate on MINTED -> revert (requires BOUND)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, mintedId, TAGITCore.State.MINTED, TAGITCore.State.BOUND)
        );
        tagitCore.activate(mintedId);

        // claim on MINTED -> revert (requires ACTIVATED)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, mintedId, TAGITCore.State.MINTED, TAGITCore.State.ACTIVATED)
        );
        tagitCore.claim(mintedId, user1);

        // flag on MINTED -> revert (requires CLAIMED)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, mintedId, TAGITCore.State.MINTED, TAGITCore.State.CLAIMED)
        );
        tagitCore.flag(mintedId);

        // recycle on MINTED -> revert (requires CLAIMED or FLAGGED)
        vm.expectRevert();
        tagitCore.recycle(mintedId);

        // ---- BOUND: can only activate; everything else should fail ----
        // claim on BOUND -> revert (requires ACTIVATED)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, boundId, TAGITCore.State.BOUND, TAGITCore.State.ACTIVATED)
        );
        tagitCore.claim(boundId, user1);

        // flag on BOUND -> revert (requires CLAIMED)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, boundId, TAGITCore.State.BOUND, TAGITCore.State.CLAIMED)
        );
        tagitCore.flag(boundId);

        // recycle on BOUND -> revert
        vm.expectRevert();
        tagitCore.recycle(boundId);

        // ---- ACTIVATED: can only claim; everything else should fail ----
        // flag on ACTIVATED -> revert (requires CLAIMED)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, activatedId, TAGITCore.State.ACTIVATED, TAGITCore.State.CLAIMED)
        );
        tagitCore.flag(activatedId);

        // recycle on ACTIVATED -> revert
        vm.expectRevert();
        tagitCore.recycle(activatedId);

        // activate on ACTIVATED -> revert (requires BOUND)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, activatedId, TAGITCore.State.ACTIVATED, TAGITCore.State.BOUND)
        );
        tagitCore.activate(activatedId);

        // ---- CLAIMED: can only flag or recycle; everything else should fail ----
        // activate on CLAIMED -> revert (requires BOUND)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, claimedId, TAGITCore.State.CLAIMED, TAGITCore.State.BOUND)
        );
        tagitCore.activate(claimedId);

        // claim on CLAIMED -> revert (requires ACTIVATED)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, claimedId, TAGITCore.State.CLAIMED, TAGITCore.State.ACTIVATED)
        );
        tagitCore.claim(claimedId, user2);

        // ---- FLAGGED: can only resolve (with quorum) or recycle ----
        // activate on FLAGGED -> revert (requires BOUND)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, flaggedId, TAGITCore.State.FLAGGED, TAGITCore.State.BOUND)
        );
        tagitCore.activate(flaggedId);

        // claim on FLAGGED -> revert (requires ACTIVATED)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, flaggedId, TAGITCore.State.FLAGGED, TAGITCore.State.ACTIVATED)
        );
        tagitCore.claim(flaggedId, user2);

        // flag on FLAGGED -> revert (requires CLAIMED)
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.InvalidState.selector, flaggedId, TAGITCore.State.FLAGGED, TAGITCore.State.CLAIMED)
        );
        tagitCore.flag(flaggedId);

        vm.stopPrank();
    }

    /**
     * @notice T03: Modify any field in oracle-signed message and verify rejection
     * @dev Tests that changing tokenId, tagHash, or challengeResponse in the signed payload
     *      causes the oracle signature to be rejected
     */
    function test_T03_tamperOracleMessage() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA_1);

        // Get a valid oracle signature for tokenId + TAG_HASH_1
        (bytes memory validCr, bytes memory validSig) = _oracleSign(tokenId, TAG_HASH_1);

        // Tamper 1: Use the signature with a different tagHash
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId, TAG_HASH_2, validCr, validSig);

        // Tamper 2: Use the signature with a different challengeResponse
        bytes memory tamperedCr = abi.encodePacked("tampered_challenge", tokenId);
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId, TAG_HASH_1, tamperedCr, validSig);

        // Tamper 3: Use the signature for a different tokenId (mint a second token)
        vm.prank(manufacturer);
        uint256 tokenId2 = tagitCore.mint(manufacturer, METADATA_2);

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenId2, TAG_HASH_1, validCr, validSig);
    }

    /**
     * @notice T04: Replay a valid oracle signature on a different token
     * @dev A signature valid for token A must not work for token B
     */
    function test_T04_replayOracleSignature() public {
        // Mint two tokens
        vm.startPrank(manufacturer);
        uint256 tokenA = tagitCore.mint(manufacturer, METADATA_1);
        uint256 tokenB = tagitCore.mint(manufacturer, METADATA_2);
        vm.stopPrank();

        // Get valid oracle signature for tokenA + TAG_HASH_1
        (bytes memory crA, bytes memory sigA) = _oracleSign(tokenA, TAG_HASH_1);

        // Bind token A successfully
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenA, TAG_HASH_1, crA, sigA);

        // Now try to replay the same signature on tokenB (with a different tag hash)
        bytes32 tagHashB = keccak256("NFC_TAG_UID_REPLAY");
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidOracleSignature.selector);
        tagitCore.bindTag(tokenB, tagHashB, crA, sigA);

        // Also try to replay with same tag hash (should fail on TagAlreadyBound even if sig matched)
        // But the oracle sig check happens first for a different tokenId
        (bytes memory crB, bytes memory sigB) = _oracleSign(tokenB, TAG_HASH_1);
        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TagAlreadyBound.selector, TAG_HASH_1));
        tagitCore.bindTag(tokenB, TAG_HASH_1, crB, sigB);
    }

    /**
     * @notice T05: First resolver proposes recipient A, second resolver proposes different recipient B
     * @dev The system must reject mismatching recipients in the resolve quorum
     */
    function test_T05_tamperResolveRecipient() public {
        uint256 flaggedId = _mintToFlagged(user1, 200);

        // Resolver 1 (manufacturer) proposes user1 as recipient
        vm.prank(manufacturer);
        tagitCore.approveResolve(flaggedId, user1);

        // Resolver 2 proposes user2 (different recipient) — must revert with RecipientMismatch
        vm.prank(resolver2);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.RecipientMismatch.selector,
                flaggedId,
                user1,
                user2
            )
        );
        tagitCore.approveResolve(flaggedId, user2);
    }

    // ================================================================
    //  R — REPUDIATION (Audit Trail)
    // ================================================================

    /**
     * @notice R01: CustodyTransfer event is emitted on every state transition
     * @dev Verifies CustodyTransfer for mint, bind, activate, claim, flag, resolve, recycle
     */
    function test_R01_custodyTransferEmitted() public {
        // --- MINT (NONE -> MINTED) ---
        vm.prank(manufacturer);
        vm.expectEmit(true, true, true, false); // check indexed fields
        emit CustodyTransfer(
            1,                                    // tokenId (first mint)
            uint8(TAGITCore.State.NONE),
            uint8(TAGITCore.State.MINTED),
            address(0),                           // fromOwner
            manufacturer,                         // toOwner
            block.timestamp,
            bytes32(0)                            // prevStateHash — we don't check non-indexed data strictly
        );
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA_1);

        // --- BIND (MINTED -> BOUND) ---
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH_1);
        vm.prank(manufacturer);
        vm.expectEmit(true, true, true, false);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.MINTED),
            uint8(TAGITCore.State.BOUND),
            manufacturer,
            manufacturer,
            block.timestamp,
            bytes32(0)
        );
        tagitCore.bindTag(tokenId, TAG_HASH_1, cr, sig);

        // --- ACTIVATE (BOUND -> ACTIVATED) ---
        vm.prank(manufacturer);
        vm.expectEmit(true, true, true, false);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.BOUND),
            uint8(TAGITCore.State.ACTIVATED),
            manufacturer,
            manufacturer,
            block.timestamp,
            bytes32(0)
        );
        tagitCore.activate(tokenId);

        // --- CLAIM (ACTIVATED -> CLAIMED) ---
        vm.prank(manufacturer);
        vm.expectEmit(true, true, true, false);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.ACTIVATED),
            uint8(TAGITCore.State.CLAIMED),
            manufacturer,
            user1,
            block.timestamp,
            bytes32(0)
        );
        tagitCore.claim(tokenId, user1);

        // --- FLAG (CLAIMED -> FLAGGED) ---
        vm.prank(manufacturer);
        vm.expectEmit(true, true, true, false);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.CLAIMED),
            uint8(TAGITCore.State.FLAGGED),
            user1,
            user1,
            block.timestamp,
            bytes32(0)
        );
        tagitCore.flag(tokenId);

        // --- RESOLVE (FLAGGED -> CLAIMED) ---
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, user2);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, user2);

        vm.prank(manufacturer);
        vm.expectEmit(true, true, true, false);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.FLAGGED),
            uint8(TAGITCore.State.CLAIMED),
            user1,
            user2,
            block.timestamp,
            bytes32(0)
        );
        tagitCore.resolve(tokenId, user2);

        // --- RECYCLE (CLAIMED -> RECYCLED) ---
        vm.prank(manufacturer);
        vm.expectEmit(true, true, true, false);
        emit CustodyTransfer(
            tokenId,
            uint8(TAGITCore.State.CLAIMED),
            uint8(TAGITCore.State.RECYCLED),
            user2,
            user2,
            block.timestamp,
            bytes32(0)
        );
        tagitCore.recycle(tokenId);
    }

    /**
     * @notice R02: StateChanged event is emitted on every state transition
     * @dev Verifies StateChanged for the full lifecycle including resolve
     */
    function test_R02_stateChangedEmitted() public {
        // MINT
        vm.expectEmit(true, false, false, true);
        emit StateChanged(1, TAGITCore.State.NONE, TAGITCore.State.MINTED, manufacturer);
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA_1);

        // BIND
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH_1);
        vm.expectEmit(true, false, false, true);
        emit StateChanged(tokenId, TAGITCore.State.MINTED, TAGITCore.State.BOUND, manufacturer);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, TAG_HASH_1, cr, sig);

        // ACTIVATE
        vm.expectEmit(true, false, false, true);
        emit StateChanged(tokenId, TAGITCore.State.BOUND, TAGITCore.State.ACTIVATED, manufacturer);
        vm.prank(manufacturer);
        tagitCore.activate(tokenId);

        // CLAIM
        vm.expectEmit(true, false, false, true);
        emit StateChanged(tokenId, TAGITCore.State.ACTIVATED, TAGITCore.State.CLAIMED, manufacturer);
        vm.prank(manufacturer);
        tagitCore.claim(tokenId, user1);

        // FLAG
        vm.expectEmit(true, false, false, true);
        emit StateChanged(tokenId, TAGITCore.State.CLAIMED, TAGITCore.State.FLAGGED, manufacturer);
        vm.prank(manufacturer);
        tagitCore.flag(tokenId);

        // RESOLVE (quorum first)
        vm.prank(manufacturer);
        tagitCore.approveResolve(tokenId, user2);
        vm.prank(resolver2);
        tagitCore.approveResolve(tokenId, user2);

        vm.expectEmit(true, false, false, true);
        emit StateChanged(tokenId, TAGITCore.State.FLAGGED, TAGITCore.State.CLAIMED, manufacturer);
        vm.prank(manufacturer);
        tagitCore.resolve(tokenId, user2);

        // RECYCLE
        vm.expectEmit(true, false, false, true);
        emit StateChanged(tokenId, TAGITCore.State.CLAIMED, TAGITCore.State.RECYCLED, manufacturer);
        vm.prank(manufacturer);
        tagitCore.recycle(tokenId);
    }

    /**
     * @notice R03: ResolveApproved events during quorum accumulation
     * @dev Each approveResolve must emit ResolveApproved with correct approvalCount
     */
    function test_R03_resolveApprovalEmitted() public {
        uint256 flaggedId = _mintToFlagged(user1, 300);

        // First approval — count = 1
        vm.expectEmit(true, true, false, true);
        emit ResolveApproved(flaggedId, manufacturer, 1);
        vm.prank(manufacturer);
        tagitCore.approveResolve(flaggedId, user2);

        // Second approval — count = 2
        vm.expectEmit(true, true, false, true);
        emit ResolveApproved(flaggedId, resolver2, 2);
        vm.prank(resolver2);
        tagitCore.approveResolve(flaggedId, user2);

        // Verify quorum state
        (uint256 count, address recipient, bool quorumReached) = tagitCore.getResolveApprovalStatus(flaggedId);
        assertEq(count, 2, "Should have 2 approvals");
        assertEq(recipient, user2, "Recipient should be user2");
        assertTrue(quorumReached, "Quorum should be reached");
    }

    // ================================================================
    //  I — INFORMATION DISCLOSURE
    // ================================================================

    /**
     * @notice I01: Unauthorized caller gets redacted URI
     * @dev An address that is not the owner, VIEWER, or AUDITOR receives the redacted URI
     */
    function test_I01_tokenURI_unauthorizedRedacted() public {
        // Mint an asset to user1
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);

        // Attacker (no role) calls tokenURI — should get redacted
        vm.prank(attacker);
        string memory uri = tagitCore.tokenURI(tokenId);
        assertEq(uri, "ipfs://REDACTED", "Unauthorized caller should receive redacted URI");
    }

    /**
     * @notice I02: Each role type gets the correct tokenURI response
     * @dev Owner gets full URI, VIEWER gets full, AUDITOR gets full, random gets redacted
     */
    function test_I02_tokenURI_allRolesChecked() public {
        // Mint an asset to user1
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);

        // Grant VIEWER to user2
        capabilityBadge.grantCapability(user2, uint256(tagitCore.VIEWER_CAPABILITY()));

        // Grant AUDITOR to resolver3 (reusing address for convenience)
        capabilityBadge.grantCapability(resolver3, uint256(tagitCore.AUDITOR_CAPABILITY()));

        // Owner (user1) — should get full URI (ERC721 default baseURI is empty, so returns "")
        vm.prank(user1);
        string memory ownerUri = tagitCore.tokenURI(tokenId);
        // Full URI is the super.tokenURI() which is empty string for default ERC721
        // The key point: it is NOT the redacted URI
        assertTrue(
            keccak256(bytes(ownerUri)) != keccak256(bytes("ipfs://REDACTED")),
            "Owner should NOT get redacted URI"
        );

        // VIEWER (user2) — should get full URI
        vm.prank(user2);
        string memory viewerUri = tagitCore.tokenURI(tokenId);
        assertTrue(
            keccak256(bytes(viewerUri)) != keccak256(bytes("ipfs://REDACTED")),
            "VIEWER should NOT get redacted URI"
        );

        // AUDITOR (resolver3) — should get full URI
        vm.prank(resolver3);
        string memory auditorUri = tagitCore.tokenURI(tokenId);
        assertTrue(
            keccak256(bytes(auditorUri)) != keccak256(bytes("ipfs://REDACTED")),
            "AUDITOR should NOT get redacted URI"
        );

        // Manufacturer with all capabilities but who is NOT the owner — should get full URI via VIEWER/AUDITOR cap
        vm.prank(manufacturer);
        string memory mfgUri = tagitCore.tokenURI(tokenId);
        assertTrue(
            keccak256(bytes(mfgUri)) != keccak256(bytes("ipfs://REDACTED")),
            "Manufacturer with VIEWER cap should NOT get redacted URI"
        );

        // Attacker with no role — should get redacted
        vm.prank(attacker);
        string memory attackerUri = tagitCore.tokenURI(tokenId);
        assertEq(attackerUri, "ipfs://REDACTED", "Attacker should get redacted URI");
    }

    // ================================================================
    //  D — DENIAL OF SERVICE
    // ================================================================

    /**
     * @notice D01: Batch of 101 items reverts with BatchTooLarge
     * @dev MAX_BATCH_SIZE is 100; 101 must be rejected
     */
    function test_D01_batchMint_oversized() public {
        uint256 batchSize = 101;
        address[] memory recipients = new address[](batchSize);
        bytes32[] memory metadata = new bytes32[](batchSize);
        for (uint256 i = 0; i < batchSize; i++) {
            recipients[i] = user1;
            metadata[i] = METADATA_1;
        }

        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(TAGITCore.BatchTooLarge.selector, batchSize, 100)
        );
        tagitCore.batchMint(recipients, metadata);
    }

    /**
     * @notice D02: Rapid flagging trips the circuit breaker
     * @dev Mint 50 assets to CLAIMED, flag them all in one block. The 50th flag
     *      should trip the circuit breaker (threshold = 50), and the 51st should revert.
     */
    function test_D02_flagCircuitBreaker() public {
        uint256 count = 51;

        // Mint and process assets to CLAIMED state
        uint256[] memory tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = _mintToClaimed(user1, 1000 + i);
        }

        // Flag rapidly — all in same block (same timestamp)
        vm.startPrank(manufacturer);

        // Flag 49 should succeed (count goes 1..49, under threshold of 50)
        for (uint256 i = 0; i < 49; i++) {
            tagitCore.flag(tokenIds[i]);
        }

        // The 50th flag should trip the circuit breaker (count hits threshold)
        // The check() increments THEN checks >= threshold, so the 50th flag trips it
        // but the flag itself still executes (trip happens after increment)
        tagitCore.flag(tokenIds[49]);

        // The 51st flag should be blocked by circuit breaker cooldown
        vm.expectRevert(); // CircuitBreakerCooldown
        tagitCore.flag(tokenIds[50]);

        vm.stopPrank();

        // Verify circuit breaker is tripped
        (bool isTripped, ) = tagitCore.getFlagCircuitBreakerStatus();
        assertTrue(isTripped, "Circuit breaker should be tripped");
    }

    /**
     * @notice D03: Rapid minting hits rate limit
     * @dev Rate limiter is configured for 100 mints per user per hour.
     *      The 100th mint should set the lock, and the 101st should revert.
     */
    function test_D03_mintRateLimiter() public {
        vm.startPrank(manufacturer);

        // Mint 100 tokens successfully (the 100th triggers lock for next action)
        for (uint256 i = 0; i < 100; i++) {
            tagitCore.mint(user1, METADATA_1);
        }

        // The 101st mint should be rate limited
        vm.expectRevert(); // RateLimitExceeded or UserLocked
        tagitCore.mint(user1, METADATA_1);

        vm.stopPrank();
    }

    /**
     * @notice D04: Paused treasury blocks withdrawals
     * @dev Governor pauses treasury; queuing and executing withdrawals should be blocked
     */
    function test_D04_treasuryPause() public {
        // Create an allocation first
        vm.prank(governor);
        uint256 allocId = treasury.createAllocation(
            keccak256("TEST_PROGRAM"),
            100_000e18,
            user1,
            365 days
        );

        // Queue a withdrawal before pausing
        vm.prank(user1);
        uint256 wdId = treasury.queueWithdrawal(allocId, address(token), 1000e18, user1);

        // Governor pauses
        vm.prank(governor);
        treasury.pause();

        // Queuing new withdrawal should fail when paused
        vm.prank(user1);
        vm.expectRevert(); // EnforcedPause
        treasury.queueWithdrawal(allocId, address(token), 1000e18, user1);

        // Executing existing withdrawal should also fail when paused
        // Fast-forward past timelock
        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(user1);
        vm.expectRevert(); // EnforcedPause
        treasury.executeWithdrawal(wdId);

        // Unpause and verify withdrawal works again
        vm.prank(governor);
        treasury.unpause();

        // After unpausing, execute should work (but may hit drain detector depending on amount)
        // We'll just verify queueing works again
        vm.prank(user1);
        treasury.queueWithdrawal(allocId, address(token), 1000e18, user1);
    }

    // ================================================================
    //  E — ELEVATION OF PRIVILEGE
    // ================================================================

    /**
     * @notice E01: Single resolver cannot bypass quorum and call resolve
     * @dev resolve() requires RESOLVE_QUORUM (2) approvals before execution
     */
    function test_E01_singleResolverCantResolve() public {
        uint256 flaggedId = _mintToFlagged(user1, 400);

        // Single resolver approves
        vm.prank(manufacturer);
        tagitCore.approveResolve(flaggedId, user2);

        // Same resolver tries to resolve with only 1 approval — should fail
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.QuorumNotReached.selector,
                flaggedId,
                1,
                2
            )
        );
        tagitCore.resolve(flaggedId, user2);

        // Also verify the same resolver cannot approve twice
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.AlreadyApproved.selector,
                flaggedId,
                manufacturer
            )
        );
        tagitCore.approveResolve(flaggedId, user2);
    }

    /**
     * @notice E02: Revoking a capability immediately blocks the action
     * @dev Grant MINTER to user1, verify mint works, revoke, verify mint fails
     */
    function test_E02_capabilityRevocationEnforced() public {
        // Grant MINTER capability to user1
        capabilityBadge.grantCapability(user1, uint256(tagitCore.MINTER_CAPABILITY()));

        // user1 can mint
        vm.prank(user1);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);
        assertGt(tokenId, 0, "Mint should succeed with capability");

        // Revoke MINTER capability
        capabilityBadge.revokeCapability(user1, uint256(tagitCore.MINTER_CAPABILITY()));

        // user1 can no longer mint — immediately effective
        vm.prank(user1);
        vm.expectRevert(); // MissingCapability
        tagitCore.mint(user1, METADATA_2);
    }

    /**
     * @notice E03: Resolver with revoked capability cannot participate in quorum
     * @dev After revoking RESOLVER_CAPABILITY, the address can no longer call approveResolve
     */
    function test_E03_revokedResolverCantApprove() public {
        uint256 flaggedId = _mintToFlagged(user1, 500);

        // resolver2 has RESOLVER_CAPABILITY — verify it works
        vm.prank(resolver2);
        tagitCore.approveResolve(flaggedId, user2);

        // Now revoke resolver2's capability
        capabilityBadge.revokeCapability(resolver2, uint256(tagitCore.RESOLVER_CAPABILITY()));

        // Create a new flagged asset for a fresh quorum round
        uint256 flaggedId2 = _mintToFlagged(user1, 501);

        // resolver2 should no longer be able to approve
        vm.prank(resolver2);
        vm.expectRevert(); // MissingCapability
        tagitCore.approveResolve(flaggedId2, user2);

        // resolver2 should no longer be able to call resolve
        vm.prank(resolver2);
        vm.expectRevert(); // MissingCapability
        tagitCore.resolve(flaggedId2, user2);
    }

    /**
     * @notice E04: Non-owner cannot change the trusted oracle address
     * @dev setTrustedOracle is onlyOwner; attacker and manufacturer should both be blocked
     */
    function test_E04_nonOwnerCantSetOracle() public {
        address maliciousOracle = makeAddr("maliciousOracle");

        // Attacker tries to set oracle
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        tagitCore.setTrustedOracle(maliciousOracle);

        // Manufacturer (has all capabilities but is NOT owner) tries to set oracle
        vm.prank(manufacturer);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        tagitCore.setTrustedOracle(maliciousOracle);

        // Verify oracle remains unchanged
        assertEq(tagitCore.trustedOracle(), vm.addr(ORACLE_PK), "Oracle should not have changed");
    }

    /**
     * @notice E05: Non-owner cannot change the access controller
     * @dev setAccessController is onlyOwner; attacker should be blocked
     */
    function test_E05_nonOwnerCantSetAccessController() public {
        address maliciousController = makeAddr("maliciousController");

        // Attacker tries to remove access control
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        tagitCore.setAccessController(address(0));

        // Attacker tries to set a malicious controller
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        tagitCore.setAccessController(maliciousController);

        // Manufacturer (not owner) tries to set controller
        vm.prank(manufacturer);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        tagitCore.setAccessController(maliciousController);

        // Verify access controller remains unchanged
        assertEq(
            address(tagitCore.accessController()),
            address(tagitAccess),
            "Access controller should not have changed"
        );
    }
}
