// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";

/**
 * @title TAGITCoreTest
 * @notice Unit tests for TAGITCore contract
 * @dev Tests follow Checks-Effects-Interactions pattern validation
 */
contract TAGITCoreTest is Test {
    TAGITCore public tagitCore;

    // Test accounts
    address public owner;
    address public manufacturer;
    address public user1;
    address public user2;

    // Test data
    bytes32 public constant METADATA_1 = keccak256("ipfs://QmTest1");
    bytes32 public constant METADATA_2 = keccak256("ipfs://QmTest2");
    bytes32 public constant TAG_HASH_1 = keccak256("NFC_TAG_UID_001");
    bytes32 public constant TAG_HASH_2 = keccak256("NFC_TAG_UID_002");

    // Events (redeclare for testing)
    event AssetMinted(uint256 indexed tokenId, address indexed to, bytes32 metadata);
    event StateChanged(uint256 indexed tokenId, TAGITCore.State from, TAGITCore.State to, address actor);
    event TagBound(uint256 indexed tokenId, bytes32 indexed tagHash);

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy TAGITCore contract
        vm.prank(owner);
        tagitCore = new TAGITCore();
    }

    // ============================================
    // MINT TESTS
    // ============================================

    /**
     * @notice Test successful minting of asset NFT
     * @dev Should create token with MINTED state, emit events
     */
    function test_mint_success() public {
        uint256 expectedTokenId = 1;

        // Mint asset to user1
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);

        // Verify token ID
        assertEq(tokenId, expectedTokenId, "Token ID should be 1");

        // Verify asset state
        (
            address assetOwner,
            uint64 timestamp,
            TAGITCore.State state,
            uint8 flags,
            uint16 reserved
        ) = tagitCore.getAsset(tokenId);

        assertEq(assetOwner, user1, "Owner should be user1");
        assertEq(uint8(state), uint8(TAGITCore.State.MINTED), "State should be MINTED");
        assertGt(timestamp, 0, "Timestamp should be set");
        assertEq(flags, 0, "Flags should be 0");
        assertEq(reserved, 0, "Reserved should be 0");

        // Verify total supply
        assertEq(tagitCore.totalSupply(), 1, "Total supply should be 1");
    }

    /**
     * @notice Test minting reverts when recipient is zero address
     * @dev Should revert with ZeroAddress error
     */
    function test_mint_revert_zeroAddress() public {
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.ZeroAddress.selector);
        tagitCore.mint(address(0), METADATA_1);
    }

    /**
     * @notice Test minting emits correct events
     * @dev Should emit AssetMinted and StateChanged events
     */
    function test_mint_emitsEvent() public {
        uint256 expectedTokenId = 1;

        // Expect AssetMinted event
        vm.expectEmit(true, true, false, true);
        emit AssetMinted(expectedTokenId, user1, METADATA_1);

        // Expect StateChanged event
        vm.expectEmit(true, false, false, true);
        emit StateChanged(
            expectedTokenId,
            TAGITCore.State.NONE,
            TAGITCore.State.MINTED,
            manufacturer
        );

        // Mint asset
        vm.prank(manufacturer);
        tagitCore.mint(user1, METADATA_1);
    }

    /**
     * @notice Test multiple mints increment token IDs correctly
     * @dev Token IDs should increment sequentially
     */
    function test_mint_multipleAssets() public {
        vm.startPrank(manufacturer);

        uint256 tokenId1 = tagitCore.mint(user1, METADATA_1);
        uint256 tokenId2 = tagitCore.mint(user2, METADATA_2);

        vm.stopPrank();

        assertEq(tokenId1, 1, "First token should be ID 1");
        assertEq(tokenId2, 2, "Second token should be ID 2");
        assertEq(tagitCore.totalSupply(), 2, "Total supply should be 2");
    }

    /**
     * @notice Fuzz test: mint with random valid addresses
     * @dev Should succeed for any non-zero address
     */
    function testFuzz_mint(address to, bytes32 metadata) public {
        // Assume valid address (not zero, not contract)
        vm.assume(to != address(0));
        vm.assume(to.code.length == 0);

        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(to, metadata);

        assertEq(tokenId, 1, "Token ID should be 1");
        assertEq(tagitCore.totalSupply(), 1, "Total supply should be 1");

        (, , TAGITCore.State state, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.MINTED), "State should be MINTED");
    }

    // ============================================
    // BINDTAG TESTS
    // ============================================

    /**
     * @notice Test successful binding of NFC tag to asset
     * @dev Should transition MINTED → BOUND, emit events
     */
    function test_bindTag_success() public {
        // Mint asset first
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);

        // Bind tag
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, TAG_HASH_1);

        // Verify asset state changed to BOUND
        (, uint64 timestamp, TAGITCore.State state, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.BOUND), "State should be BOUND");
        assertGt(timestamp, 0, "Timestamp should be updated");

        // Verify tag mapping
        assertEq(tagitCore.getTokenByTag(TAG_HASH_1), tokenId, "Tag should map to token");
        assertEq(tagitCore.getTagByToken(tokenId), TAG_HASH_1, "Token should map to tag");
    }

    /**
     * @notice Test binding reverts when token does not exist
     * @dev Should revert with TokenNotFound error
     */
    function test_bindTag_revert_tokenNotFound() public {
        uint256 nonExistentTokenId = 999;

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TokenNotFound.selector, nonExistentTokenId));
        tagitCore.bindTag(nonExistentTokenId, TAG_HASH_1);
    }

    /**
     * @notice Test binding reverts when asset is not in MINTED state
     * @dev Should revert with InvalidState error
     */
    function test_bindTag_revert_invalidState() public {
        // Mint and bind tag
        vm.startPrank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);
        tagitCore.bindTag(tokenId, TAG_HASH_1);
        vm.stopPrank();

        // Try to bind again (state is now BOUND, not MINTED)
        vm.prank(manufacturer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TAGITCore.InvalidState.selector,
                tokenId,
                TAGITCore.State.BOUND,
                TAGITCore.State.MINTED
            )
        );
        tagitCore.bindTag(tokenId, TAG_HASH_2);
    }

    /**
     * @notice Test binding reverts when tag is already bound to another asset
     * @dev Should revert with TagAlreadyBound error
     */
    function test_bindTag_revert_tagAlreadyBound() public {
        // Mint two assets
        vm.startPrank(manufacturer);
        uint256 tokenId1 = tagitCore.mint(user1, METADATA_1);
        uint256 tokenId2 = tagitCore.mint(user2, METADATA_2);

        // Bind tag to first asset
        tagitCore.bindTag(tokenId1, TAG_HASH_1);

        // Try to bind same tag to second asset
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.TagAlreadyBound.selector, TAG_HASH_1));
        tagitCore.bindTag(tokenId2, TAG_HASH_1);
        vm.stopPrank();
    }

    /**
     * @notice Test binding reverts when tag hash is zero
     * @dev Should revert with InvalidTagHash error
     */
    function test_bindTag_revert_invalidTagHash() public {
        // Mint asset
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);

        // Try to bind zero tag hash
        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.InvalidTagHash.selector);
        tagitCore.bindTag(tokenId, bytes32(0));
    }

    /**
     * @notice Test binding emits correct events
     * @dev Should emit TagBound and StateChanged events
     */
    function test_bindTag_emitsEvent() public {
        // Mint asset
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);

        // Expect TagBound event
        vm.expectEmit(true, true, false, false);
        emit TagBound(tokenId, TAG_HASH_1);

        // Expect StateChanged event
        vm.expectEmit(true, false, false, true);
        emit StateChanged(
            tokenId,
            TAGITCore.State.MINTED,
            TAGITCore.State.BOUND,
            manufacturer
        );

        // Bind tag
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, TAG_HASH_1);
    }

    /**
     * @notice Fuzz test: bindTag with random valid tag hashes
     * @dev Should succeed for any non-zero tag hash on minted asset
     */
    function testFuzz_bindTag(bytes32 tagHash) public {
        // Assume valid tag hash (not zero)
        vm.assume(tagHash != bytes32(0));

        // Mint asset
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(user1, METADATA_1);

        // Bind tag
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash);

        // Verify state
        (, , TAGITCore.State state, , ) = tagitCore.getAsset(tokenId);
        assertEq(uint8(state), uint8(TAGITCore.State.BOUND), "State should be BOUND");

        // Verify mappings
        assertEq(tagitCore.getTokenByTag(tagHash), tokenId, "Tag should map to token");
        assertEq(tagitCore.getTagByToken(tokenId), tagHash, "Token should map to tag");
    }
}
