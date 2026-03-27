// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ReplayProtection} from "../../src/libraries/ReplayProtection.sol";

/**
 * @title ReplayProtectionTest
 * @notice Tests for NIST SC-8 compliant replay protection
 */
contract ReplayProtectionTest is Test {
    using ReplayProtection for ReplayProtection.Config;

    // ============================================
    // STATE
    // ============================================

    ReplayProtectionHarness public harness;

    // Test parameters
    uint64 constant MESSAGE_EXPIRY = 1 hours;
    uint64 constant CHAIN_SELECTOR_ETH = 5009297550715157269; // Ethereum mainnet
    uint64 constant CHAIN_SELECTOR_OP = 3734403246176062136; // OP Mainnet
    uint64 constant CHAIN_SELECTOR_ARB = 4949039107694359620; // Arbitrum

    // Test addresses
    address constant SENDER = address(0xBEEF);

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        harness = new ReplayProtectionHarness();
        harness.initialize(MESSAGE_EXPIRY, true); // Sequential nonces required
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsCorrectValues() public view {
        assertTrue(harness.isEnabled(), "Should be enabled");
        assertEq(harness.getExpiry(), MESSAGE_EXPIRY, "Expiry set");
        assertTrue(harness.isSequential(), "Sequential required");
    }

    function test_initialize_nonSequential() public {
        ReplayProtectionHarness h = new ReplayProtectionHarness();
        h.initialize(MESSAGE_EXPIRY, false);

        assertTrue(h.isEnabled(), "Should be enabled");
        assertFalse(h.isSequential(), "Sequential not required");
    }

    function test_initialize_noExpiry() public {
        ReplayProtectionHarness h = new ReplayProtectionHarness();
        h.initialize(0, false);

        assertEq(h.getExpiry(), 0, "No expiry");
    }

    function test_isInitialized_returnsTrueAfterInit() public view {
        assertTrue(harness.isInitialized(), "Should be initialized");
    }

    function test_isInitialized_returnsFalseBeforeInit() public {
        ReplayProtectionHarness h = new ReplayProtectionHarness();
        assertFalse(h.isInitialized(), "Should not be initialized");
    }

    // ============================================
    // BASIC VALIDATION TESTS
    // ============================================

    function test_validateAndMark_acceptsFirstMessage() public {
        bytes32 messageId = keccak256("message1");

        bool valid = harness.validateAndMark(
            messageId,
            CHAIN_SELECTOR_ETH,
            block.timestamp,
            1 // First nonce
        );

        assertTrue(valid, "Should accept first message");
        assertTrue(harness.isProcessed(messageId), "Should be marked processed");
    }

    function test_validateAndMark_acceptsSequentialMessages() public {
        for (uint64 i = 1; i <= 5; i++) {
            bytes32 messageId = keccak256(abi.encodePacked("message", i));

            bool valid = harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, i);

            assertTrue(valid, "Should accept sequential messages");
        }

        (uint64 lastNonce, uint64 messageCount) = harness.getChainState(CHAIN_SELECTOR_ETH);
        assertEq(lastNonce, 5, "Last nonce should be 5");
        assertEq(messageCount, 5, "Message count should be 5");
    }

    function test_validateAndMark_emitsMessageProcessed() public {
        bytes32 messageId = keccak256("message1");

        vm.expectEmit(true, true, false, true);
        emit ReplayProtection.MessageProcessed(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 1);
    }

    // ============================================
    // REPLAY DETECTION TESTS
    // ============================================

    function test_validateAndMark_detectsReplay() public {
        bytes32 messageId = keccak256("message1");

        // First submission OK
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        // Replay attempt should fail
        vm.expectRevert(
            abi.encodeWithSelector(ReplayProtection.MessageAlreadyProcessed.selector, messageId, CHAIN_SELECTOR_ETH)
        );
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 2);
    }

    function test_validateAndMark_emitsReplayAttempt() public {
        bytes32 messageId = keccak256("message1");

        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        vm.expectEmit(true, true, false, true);
        emit ReplayProtection.ReplayAttempt(messageId, CHAIN_SELECTOR_ETH, block.timestamp);

        vm.expectRevert();
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 2);
    }

    function test_validateAndMark_sameIdDifferentChains() public {
        bytes32 messageId = keccak256("message1");

        // Accept from ETH
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        // Same ID from different chain should still fail (ID is unique globally)
        // This is intentional - message IDs should be globally unique
        vm.expectRevert(
            abi.encodeWithSelector(ReplayProtection.MessageAlreadyProcessed.selector, messageId, CHAIN_SELECTOR_OP)
        );
        harness.validateAndMark(messageId, CHAIN_SELECTOR_OP, block.timestamp, 1);
    }

    // ============================================
    // EXPIRY TESTS
    // ============================================

    function test_validateAndMark_acceptsBeforeExpiry() public {
        bytes32 messageId = keccak256("message1");
        uint256 messageTime = block.timestamp;

        // Move time forward but stay within expiry
        vm.warp(block.timestamp + MESSAGE_EXPIRY - 1);

        bool valid = harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, messageTime, 1);
        assertTrue(valid, "Should accept before expiry");
    }

    function test_validateAndMark_rejectsAfterExpiry() public {
        bytes32 messageId = keccak256("message1");
        uint256 messageTime = block.timestamp;

        // Move time past expiry
        vm.warp(block.timestamp + MESSAGE_EXPIRY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ReplayProtection.MessageExpired.selector, messageId, messageTime, MESSAGE_EXPIRY)
        );
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, messageTime, 1);
    }

    function test_validateAndMark_emitsExpiredEvent() public {
        bytes32 messageId = keccak256("message1");
        uint256 messageTime = block.timestamp;

        vm.warp(block.timestamp + MESSAGE_EXPIRY + 1);

        vm.expectEmit(true, true, false, true);
        emit ReplayProtection.MessageExpiredEvent(messageId, CHAIN_SELECTOR_ETH, messageTime, MESSAGE_EXPIRY);

        vm.expectRevert();
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, messageTime, 1);
    }

    function test_validateAndMark_noExpiryAcceptsOldMessages() public {
        ReplayProtectionHarness h = new ReplayProtectionHarness();
        h.initialize(0, true); // No expiry

        bytes32 messageId = keccak256("message1");
        uint256 messageTime = block.timestamp;

        // Move time forward significantly
        vm.warp(block.timestamp + 365 days);

        // Should still accept (no expiry)
        bool valid = h.validateAndMark(messageId, CHAIN_SELECTOR_ETH, messageTime, 1);
        assertTrue(valid, "Should accept without expiry");
    }

    // ============================================
    // NONCE SEQUENCE TESTS
    // ============================================

    function test_validateAndMark_rejectsNonSequentialNonce() public {
        bytes32 messageId1 = keccak256("message1");
        bytes32 messageId2 = keccak256("message2");

        // First message with nonce 1 OK
        harness.validateAndMark(messageId1, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        // Try to skip to nonce 3
        vm.expectRevert(
            abi.encodeWithSelector(
                ReplayProtection.NonceNotSequential.selector,
                2, // expected
                3, // received
                CHAIN_SELECTOR_ETH
            )
        );
        harness.validateAndMark(messageId2, CHAIN_SELECTOR_ETH, block.timestamp, 3);
    }

    function test_validateAndMark_emitsNonceViolation() public {
        bytes32 messageId1 = keccak256("message1");
        bytes32 messageId2 = keccak256("message2");

        harness.validateAndMark(messageId1, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        vm.expectEmit(true, false, false, true);
        emit ReplayProtection.NonceViolation(CHAIN_SELECTOR_ETH, 2, 3);

        vm.expectRevert();
        harness.validateAndMark(messageId2, CHAIN_SELECTOR_ETH, block.timestamp, 3);
    }

    function test_validateAndMark_acceptsAnyNonceWhenNotSequential() public {
        ReplayProtectionHarness h = new ReplayProtectionHarness();
        h.initialize(MESSAGE_EXPIRY, false); // Not sequential

        bytes32 messageId1 = keccak256("message1");
        bytes32 messageId2 = keccak256("message2");
        bytes32 messageId3 = keccak256("message3");

        // Can use any nonces in any order
        h.validateAndMark(messageId1, CHAIN_SELECTOR_ETH, block.timestamp, 100);
        h.validateAndMark(messageId2, CHAIN_SELECTOR_ETH, block.timestamp, 5);
        h.validateAndMark(messageId3, CHAIN_SELECTOR_ETH, block.timestamp, 999);

        (, uint64 messageCount) = h.getChainState(CHAIN_SELECTOR_ETH);
        assertEq(messageCount, 3, "All messages processed");
    }

    function test_validateAndMark_independentNoncesPerChain() public {
        bytes32 msgEth = keccak256("eth1");
        bytes32 msgOp = keccak256("op1");
        bytes32 msgArb = keccak256("arb1");

        // Each chain has independent nonce sequence
        harness.validateAndMark(msgEth, CHAIN_SELECTOR_ETH, block.timestamp, 1);
        harness.validateAndMark(msgOp, CHAIN_SELECTOR_OP, block.timestamp, 1);
        harness.validateAndMark(msgArb, CHAIN_SELECTOR_ARB, block.timestamp, 1);

        (uint64 ethNonce,) = harness.getChainState(CHAIN_SELECTOR_ETH);
        (uint64 opNonce,) = harness.getChainState(CHAIN_SELECTOR_OP);
        (uint64 arbNonce,) = harness.getChainState(CHAIN_SELECTOR_ARB);

        assertEq(ethNonce, 1, "ETH nonce");
        assertEq(opNonce, 1, "OP nonce");
        assertEq(arbNonce, 1, "ARB nonce");
    }

    // ============================================
    // HIGH VOLUME WARNING TESTS
    // ============================================

    function test_validateAndMark_emitsHighVolumeWarning() public {
        ReplayProtectionHarness h = new ReplayProtectionHarness();
        h.initialize(0, true); // No expiry, sequential

        // Process 999 messages
        for (uint64 i = 1; i < 1000; i++) {
            bytes32 messageId = keccak256(abi.encodePacked("msg", i));
            h.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, i);
        }

        // The 1000th message should emit warning
        vm.expectEmit(true, false, false, true);
        emit ReplayProtection.HighVolumeWarning(CHAIN_SELECTOR_ETH, 1000, 1000);

        bytes32 msg1000 = keccak256(abi.encodePacked("msg", uint64(1000)));
        h.validateAndMark(msg1000, CHAIN_SELECTOR_ETH, block.timestamp, 1000);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_isProcessed_returnsFalseForNew() public view {
        bytes32 messageId = keccak256("newMessage");
        assertFalse(harness.isProcessed(messageId), "Should not be processed");
    }

    function test_isProcessed_returnsTrueAfterProcessing() public {
        bytes32 messageId = keccak256("message1");
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        assertTrue(harness.isProcessed(messageId), "Should be processed");
    }

    function test_wouldBeValid_returnsTrueForNew() public view {
        bytes32 messageId = keccak256("newMessage");

        (bool valid, uint8 reason) = harness.wouldBeValid(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        assertTrue(valid, "Should be valid");
        assertEq(reason, 0, "No rejection reason");
    }

    function test_wouldBeValid_detectsReplay() public {
        bytes32 messageId = keccak256("message1");
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        (bool valid, uint8 reason) = harness.wouldBeValid(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 2);

        assertFalse(valid, "Should not be valid");
        assertEq(reason, 2, "Replay reason");
    }

    function test_wouldBeValid_detectsExpiry() public {
        bytes32 messageId = keccak256("message1");
        uint256 messageTime = block.timestamp;

        vm.warp(block.timestamp + MESSAGE_EXPIRY + 1);

        (bool valid, uint8 reason) = harness.wouldBeValid(messageId, CHAIN_SELECTOR_ETH, messageTime, 1);

        assertFalse(valid, "Should not be valid");
        assertEq(reason, 1, "Expiry reason");
    }

    function test_wouldBeValid_detectsNonceMismatch() public {
        bytes32 messageId1 = keccak256("message1");
        bytes32 messageId2 = keccak256("message2");

        harness.validateAndMark(messageId1, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        (bool valid, uint8 reason) =
            harness.wouldBeValid(
                messageId2,
                CHAIN_SELECTOR_ETH,
                block.timestamp,
                5 // Wrong nonce
            );

        assertFalse(valid, "Should not be valid");
        assertEq(reason, 3, "Nonce reason");
    }

    function test_getChainState_returnsZeroForNew() public view {
        (uint64 lastNonce, uint64 messageCount) = harness.getChainState(CHAIN_SELECTOR_ETH);

        assertEq(lastNonce, 0, "No nonce yet");
        assertEq(messageCount, 0, "No messages yet");
    }

    // ============================================
    // CONFIGURATION TESTS
    // ============================================

    function test_setEnabled_disablesProtection() public {
        harness.setEnabled(false);

        bytes32 messageId = keccak256("message1");

        // Should accept without checking
        bool valid = harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 999);
        assertTrue(valid, "Should allow when disabled");

        // Message should NOT be marked as processed when disabled
        assertFalse(harness.isProcessed(messageId), "Should not mark when disabled");
    }

    function test_setExpiry_updatesValue() public {
        harness.setExpiry(2 hours);
        assertEq(harness.getExpiry(), 2 hours, "Expiry updated");
    }

    function test_setSequential_updatesValue() public {
        harness.setSequential(false);
        assertFalse(harness.isSequential(), "Sequential updated");
    }

    function test_setNonce_updatesChainNonce() public {
        harness.setNonce(CHAIN_SELECTOR_ETH, 100);

        (uint64 lastNonce,) = harness.getChainState(CHAIN_SELECTOR_ETH);
        assertEq(lastNonce, 100, "Nonce set");

        // Next message should expect nonce 101
        bytes32 messageId = keccak256("message101");
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 101);

        (lastNonce,) = harness.getChainState(CHAIN_SELECTOR_ETH);
        assertEq(lastNonce, 101, "Nonce incremented");
    }

    // ============================================
    // HELPER FUNCTION TESTS
    // ============================================

    function test_computeMessageId_consistent() public pure {
        bytes32 id1 = ReplayProtection.computeMessageId(CHAIN_SELECTOR_ETH, SENDER, 1, hex"1234");

        bytes32 id2 = ReplayProtection.computeMessageId(CHAIN_SELECTOR_ETH, SENDER, 1, hex"1234");

        assertEq(id1, id2, "Same inputs should produce same ID");
    }

    function test_computeMessageId_differentInputsDifferentIds() public pure {
        bytes32 id1 = ReplayProtection.computeMessageId(CHAIN_SELECTOR_ETH, SENDER, 1, hex"1234");

        bytes32 id2 = ReplayProtection.computeMessageId(
            CHAIN_SELECTOR_ETH,
            SENDER,
            2, // Different nonce
            hex"1234"
        );

        assertTrue(id1 != id2, "Different inputs should produce different IDs");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_replayDetection(bytes32 messageId, uint64 nonce) public {
        // Bound nonce to avoid overflow when incrementing
        nonce = uint64(bound(nonce, 1, type(uint64).max - 1));

        // Set nonce to allow this message
        harness.setNonce(CHAIN_SELECTOR_ETH, nonce - 1);

        // First submission OK
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, nonce);

        // Replay should fail (already processed)
        vm.expectRevert(
            abi.encodeWithSelector(ReplayProtection.MessageAlreadyProcessed.selector, messageId, CHAIN_SELECTOR_ETH)
        );
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, nonce + 1);
    }

    function testFuzz_expiryRespected(uint64 delay) public {
        delay = uint64(bound(delay, 0, MESSAGE_EXPIRY * 2));

        bytes32 messageId = keccak256(abi.encodePacked("msg", delay));
        uint256 messageTime = block.timestamp;

        vm.warp(block.timestamp + delay);

        if (delay > MESSAGE_EXPIRY) {
            vm.expectRevert();
            harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, messageTime, 1);
        } else {
            bool valid = harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, messageTime, 1);
            assertTrue(valid, "Should accept within expiry");
        }
    }

    function testFuzz_nonceSequence(uint64 startNonce, uint8 numMessages) public {
        startNonce = uint64(bound(startNonce, 0, type(uint64).max - 256));
        numMessages = uint8(bound(numMessages, 1, 100));

        harness.setNonce(CHAIN_SELECTOR_ETH, startNonce);

        for (uint8 i = 0; i < numMessages; i++) {
            bytes32 messageId = keccak256(abi.encodePacked("msg", i));
            uint64 expectedNonce = startNonce + uint64(i) + 1;

            harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, expectedNonce);
        }

        (uint64 lastNonce, uint64 messageCount) = harness.getChainState(CHAIN_SELECTOR_ETH);
        assertEq(lastNonce, startNonce + numMessages, "Final nonce correct");
        assertEq(messageCount, numMessages, "Message count correct");
    }

    // ============================================
    // GAS TESTS
    // ============================================

    function test_validateAndMark_gasEfficiency() public {
        // Warm up storage
        bytes32 warmupId = keccak256("warmup");
        harness.validateAndMark(warmupId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        // Measure warm gas
        bytes32 messageId = keccak256("gasTest");
        uint256 gasBefore = gasleft();
        harness.validateAndMark(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 2);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be < 32,000 gas (includes mapping write which is ~20k cold)
        assertLt(gasUsed, 32000, "Validate should be < 32000 gas");
    }

    function test_wouldBeValid_gasEfficiency() public {
        // Warm up storage
        bytes32 warmupId = keccak256("warmup");
        harness.validateAndMark(warmupId, CHAIN_SELECTOR_ETH, block.timestamp, 1);

        // Measure view function gas
        bytes32 messageId = keccak256("gasTest");
        uint256 gasBefore = gasleft();
        harness.wouldBeValid(messageId, CHAIN_SELECTOR_ETH, block.timestamp, 2);
        uint256 gasUsed = gasBefore - gasleft();

        // View should be cheaper (only reads)
        assertLt(gasUsed, 7000, "View should be < 7000 gas");
    }
}

// ============================================
// TEST HARNESS
// ============================================

/**
 * @notice Test harness to expose internal library functions
 */
contract ReplayProtectionHarness {
    using ReplayProtection for ReplayProtection.Config;

    ReplayProtection.Config private _config;
    mapping(bytes32 => bool) private _processedMessages;
    mapping(uint64 => ReplayProtection.ChainState) private _chainStates;

    function initialize(uint64 messageExpiry, bool requireSequential) external {
        _config.initialize(messageExpiry, requireSequential);
    }

    function validateAndMark(bytes32 messageId, uint64 chainSelector, uint256 messageTimestamp, uint64 nonce)
        external
        returns (bool)
    {
        return _config.validateAndMark(
            _processedMessages, _chainStates, messageId, chainSelector, messageTimestamp, nonce
        );
    }

    function isProcessed(bytes32 messageId) external view returns (bool) {
        return ReplayProtection.isProcessed(_processedMessages, messageId);
    }

    function wouldBeValid(bytes32 messageId, uint64 chainSelector, uint256 messageTimestamp, uint64 nonce)
        external
        view
        returns (bool, uint8)
    {
        return _config.wouldBeValid(_processedMessages, _chainStates, messageId, chainSelector, messageTimestamp, nonce);
    }

    function getChainState(uint64 chainSelector) external view returns (uint64, uint64) {
        return ReplayProtection.getChainState(_chainStates, chainSelector);
    }

    function setNonce(uint64 chainSelector, uint64 newNonce) external {
        ReplayProtection.setNonce(_chainStates, chainSelector, newNonce);
    }

    function setEnabled(bool enabled) external {
        _config.setEnabled(enabled);
    }

    function setExpiry(uint64 newExpiry) external {
        _config.setExpiry(newExpiry);
    }

    function setSequential(bool requireSequential) external {
        _config.setSequential(requireSequential);
    }

    function isEnabled() external view returns (bool) {
        return _config.isEnabled();
    }

    function getExpiry() external view returns (uint64) {
        return _config.getExpiry();
    }

    function isSequential() external view returns (bool) {
        return _config.isSequential();
    }

    function isInitialized() external view returns (bool) {
        return _config.isInitialized();
    }
}
