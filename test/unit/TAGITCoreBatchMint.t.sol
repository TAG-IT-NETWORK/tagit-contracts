// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title TAGITCoreBatchMintTest
 * @notice Tests for PATCH-05: batchMint MAX_BATCH_SIZE DoS guard
 */
contract TAGITCoreBatchMintTest is Test {
    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public manufacturer;
    address public consumer;

    uint256 constant CAP_MINT = uint256(keccak256("MINTER"));

    function setUp() public {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        consumer = makeAddr("consumer");

        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();

        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        TAGITCore implementation = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tagitCore = TAGITCore(address(proxy));

        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        capabilityBadge.grantCapability(manufacturer, CAP_MINT);
    }

    // ============================================
    // CONSTANT
    // ============================================

    function test_maxBatchSizeConstant() public view {
        assertEq(tagitCore.MAX_BATCH_SIZE(), 100, "MAX_BATCH_SIZE should be 100");
    }

    // ============================================
    // SUCCESS CASES
    // ============================================

    function test_batchMint_singleItem() public {
        address[] memory recipients = new address[](1);
        bytes32[] memory metadata = new bytes32[](1);
        recipients[0] = consumer;
        metadata[0] = keccak256("item1");

        vm.prank(manufacturer);
        uint256[] memory tokenIds = tagitCore.batchMint(recipients, metadata);

        assertEq(tokenIds.length, 1, "Should return 1 token ID");
        assertEq(tagitCore.ownerOf(tokenIds[0]), consumer, "Owner should be consumer");
        assertEq(tagitCore.totalSupply(), 1, "Total supply should be 1");
    }

    function test_batchMint_multipleItems() public {
        uint256 batchSize = 5;
        address[] memory recipients = new address[](batchSize);
        bytes32[] memory metadata = new bytes32[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            recipients[i] = consumer;
            metadata[i] = keccak256(abi.encodePacked("item", i));
        }

        vm.prank(manufacturer);
        uint256[] memory tokenIds = tagitCore.batchMint(recipients, metadata);

        assertEq(tokenIds.length, batchSize, "Should return correct number of token IDs");
        assertEq(tagitCore.totalSupply(), batchSize, "Total supply should match batch size");

        for (uint256 i = 0; i < batchSize; i++) {
            assertEq(tagitCore.ownerOf(tokenIds[i]), consumer, "Each token should be owned by consumer");
            (,, TAGITCore.State state,,) = tagitCore.getAsset(tokenIds[i]);
            assertEq(uint8(state), uint8(TAGITCore.State.MINTED), "Each token should be in MINTED state");
        }
    }

    function test_batchMint_exactlyMaxSize() public {
        uint256 batchSize = 100;
        address[] memory recipients = new address[](batchSize);
        bytes32[] memory metadata = new bytes32[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            recipients[i] = consumer;
            metadata[i] = keccak256(abi.encodePacked("item", i));
        }

        vm.prank(manufacturer);
        uint256[] memory tokenIds = tagitCore.batchMint(recipients, metadata);

        assertEq(tokenIds.length, batchSize, "Should mint exactly 100");
        assertEq(tagitCore.totalSupply(), batchSize, "Total supply should be 100");
    }

    function test_batchMint_multipleRecipients() public {
        address consumer2 = makeAddr("consumer2");
        address consumer3 = makeAddr("consumer3");

        address[] memory recipients = new address[](3);
        bytes32[] memory metadata = new bytes32[](3);
        recipients[0] = consumer;
        recipients[1] = consumer2;
        recipients[2] = consumer3;
        metadata[0] = keccak256("a");
        metadata[1] = keccak256("b");
        metadata[2] = keccak256("c");

        vm.prank(manufacturer);
        uint256[] memory tokenIds = tagitCore.batchMint(recipients, metadata);

        assertEq(tagitCore.ownerOf(tokenIds[0]), consumer, "Token 0 owner");
        assertEq(tagitCore.ownerOf(tokenIds[1]), consumer2, "Token 1 owner");
        assertEq(tagitCore.ownerOf(tokenIds[2]), consumer3, "Token 2 owner");
    }

    function test_batchMint_emptyBatch() public {
        address[] memory recipients = new address[](0);
        bytes32[] memory metadata = new bytes32[](0);

        vm.prank(manufacturer);
        uint256[] memory tokenIds = tagitCore.batchMint(recipients, metadata);

        assertEq(tokenIds.length, 0, "Should return empty array");
        assertEq(tagitCore.totalSupply(), 0, "Total supply should be 0");
    }

    function test_batchMint_tokenIdsAreSequential() public {
        address[] memory recipients = new address[](3);
        bytes32[] memory metadata = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            recipients[i] = consumer;
            metadata[i] = keccak256(abi.encodePacked("seq", i));
        }

        vm.prank(manufacturer);
        uint256[] memory tokenIds = tagitCore.batchMint(recipients, metadata);

        assertEq(tokenIds[0], 1, "First token ID should be 1");
        assertEq(tokenIds[1], 2, "Second token ID should be 2");
        assertEq(tokenIds[2], 3, "Third token ID should be 3");
    }

    // ============================================
    // REVERT CASES
    // ============================================

    function test_batchMint_revert_batchTooLarge() public {
        uint256 oversized = 101;
        address[] memory recipients = new address[](oversized);
        bytes32[] memory metadata = new bytes32[](oversized);

        for (uint256 i = 0; i < oversized; i++) {
            recipients[i] = consumer;
            metadata[i] = keccak256(abi.encodePacked("big", i));
        }

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.BatchTooLarge.selector, 101, 100));
        tagitCore.batchMint(recipients, metadata);
    }

    function test_batchMint_revert_arrayLengthMismatch() public {
        address[] memory recipients = new address[](3);
        bytes32[] memory metadata = new bytes32[](2);

        recipients[0] = consumer;
        recipients[1] = consumer;
        recipients[2] = consumer;
        metadata[0] = keccak256("a");
        metadata[1] = keccak256("b");

        vm.prank(manufacturer);
        vm.expectRevert(abi.encodeWithSelector(TAGITCore.ArrayLengthMismatch.selector, 3, 2));
        tagitCore.batchMint(recipients, metadata);
    }

    function test_batchMint_revert_zeroAddressInBatch() public {
        address[] memory recipients = new address[](3);
        bytes32[] memory metadata = new bytes32[](3);

        recipients[0] = consumer;
        recipients[1] = address(0); // Zero address
        recipients[2] = consumer;
        metadata[0] = keccak256("a");
        metadata[1] = keccak256("b");
        metadata[2] = keccak256("c");

        vm.prank(manufacturer);
        vm.expectRevert(TAGITCore.ZeroAddress.selector);
        tagitCore.batchMint(recipients, metadata);
    }

    function test_batchMint_revert_unauthorized() public {
        address[] memory recipients = new address[](1);
        bytes32[] memory metadata = new bytes32[](1);
        recipients[0] = consumer;
        metadata[0] = keccak256("x");

        vm.prank(consumer); // Not a manufacturer
        vm.expectRevert();
        tagitCore.batchMint(recipients, metadata);
    }

    // ============================================
    // GAS BOUNDED
    // ============================================

    function test_batchMint_gasBounded() public {
        uint256 batchSize = 100;
        address[] memory recipients = new address[](batchSize);
        bytes32[] memory metadata = new bytes32[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            recipients[i] = consumer;
            metadata[i] = keccak256(abi.encodePacked("gas", i));
        }

        vm.prank(manufacturer);
        uint256 gasBefore = gasleft();
        tagitCore.batchMint(recipients, metadata);
        uint256 gasUsed = gasBefore - gasleft();

        // 100 mints should stay well under block gas limit (30M)
        // Each mint ~185k gas, so 100 should be ~18.5M
        assertLt(gasUsed, 30_000_000, "Batch of 100 should not exceed block gas limit");
    }
}
