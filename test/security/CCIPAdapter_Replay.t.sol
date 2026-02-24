// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";

import {CCIPAdapter} from "../../src/bridge/CCIPAdapter.sol";
import {ICCIPAdapter} from "../../src/interfaces/ICCIPAdapter.sol";
import {ReplayProtection} from "../../src/libraries/ReplayProtection.sol";

// ============================================
// MOCK CONTRACTS
// ============================================

/**
 * @title MockRouter
 * @notice Mock CCIP Router that can deliver inbound messages to CCIPAdapter
 * @dev Acts as the trusted router so it satisfies the onlyRouter modifier
 */
contract MockRouter {
    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256) {
        return 0.01 ether;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage memory) external payable returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender));
    }

    /**
     * @notice Simulate CCIP delivering a message to the adapter
     * @param adapter Target CCIPAdapter (must have this contract as its router)
     * @param message The Any2EVMMessage to deliver
     */
    function deliverMessage(
        address adapter,
        Client.Any2EVMMessage calldata message
    ) external {
        CCIPAdapter(payable(adapter)).ccipReceive(message);
    }
}

/**
 * @title MockTAGITCore
 * @notice Minimal mock that responds to getAsset(uint256) staticcall
 */
contract MockTAGITCore {
    function getAsset(uint256 tokenId) external view returns (
        address owner,
        uint8 state,
        bytes32 tagHash,
        bytes32 metadataHash,
        uint64 createdAt,
        uint64 activatedAt,
        uint64 claimedAt
    ) {
        return (
            address(0xBEEF),
            3, // ACTIVATED
            bytes32(uint256(tokenId)),
            bytes32(0),
            uint64(block.timestamp - 200),
            uint64(block.timestamp - 100),
            0
        );
    }
}

// ============================================
// TEST CONTRACT
// ============================================

/**
 * @title CCIPAdapterReplayTest
 * @notice Security tests for chain-bound CCIP messageId replay protection
 * @dev Validates the defense-in-depth layer added via _processedCcipMessages mapping.
 *      Key: keccak256(abi.encodePacked(message.messageId, block.chainid, sourceChainSelector))
 *
 * Test matrix:
 *  1. Happy path: single message processes successfully
 *  2. Replay: same messageId + same source chain reverts with MessageAlreadyProcessed
 *  3. Cross-chain isolation: same messageId + different sourceChainSelector = different key
 *  4. isCcipMessageProcessed view returns correct state before/after
 *  5. isMessageProcessed (requestId-based) returns correct state before/after
 */
contract CCIPAdapterReplayTest is Test {
    // ============================================
    // STATE
    // ============================================

    CCIPAdapter public adapter;
    MockRouter public router;
    MockTAGITCore public mockCore;

    address public owner;
    address public governor;
    address public remoteAdapterA;
    address public remoteAdapterB;

    // Two distinct source chains for cross-chain isolation tests
    uint64 public constant CHAIN_A = 16015286601757825753; // Sepolia selector
    uint64 public constant CHAIN_B = 3734403246176062136;  // OP Mainnet selector

    uint256 public constant GAS_LIMIT = 200_000;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        remoteAdapterA = makeAddr("remoteAdapterA");
        remoteAdapterB = makeAddr("remoteAdapterB");

        vm.startPrank(owner);

        // Deploy mocks
        router = new MockRouter();
        mockCore = new MockTAGITCore();

        // Deploy CCIPAdapter behind ERC1967Proxy
        CCIPAdapter adapterImpl = new CCIPAdapter();
        bytes memory initData = abi.encodeCall(
            CCIPAdapter.initialize,
            (address(router), governor, address(mockCore), owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(adapterImpl), initData);
        adapter = CCIPAdapter(payable(address(proxy)));

        // Fund adapter so _sendResponse can pay CCIP fees
        vm.deal(address(adapter), 50 ether);

        vm.stopPrank();

        // Register both source chains through the timelock flow
        _addChain(CHAIN_A, remoteAdapterA);
        _addChain(CHAIN_B, remoteAdapterB);
    }

    // ============================================
    // TEST 1: Happy path -- single message succeeds
    // ============================================

    function test_processMessage_succeeds() public {
        bytes32 messageId = keccak256("ccip-msg-1");
        bytes32 requestId = keccak256("req-1");

        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            CHAIN_A,
            remoteAdapterA,
            requestId,
            uint8(0), // messageType = request
            abi.encode(uint256(42), ICCIPAdapter.RequestType.VERIFY)
        );

        // Expect the CcipMessageProcessed event
        vm.expectEmit(true, true, false, true, address(adapter));
        emit ICCIPAdapter.CcipMessageProcessed(messageId, CHAIN_A, block.chainid);

        // Deliver via mock router (satisfies onlyRouter)
        router.deliverMessage(address(adapter), message);

        // Verify the request was stored
        ICCIPAdapter.CrossChainRequest memory req = adapter.getRequest(requestId);
        assertEq(req.tokenId, 42, "tokenId mismatch");
        assertEq(req.sourceChain, CHAIN_A, "sourceChain mismatch");
        assertEq(uint8(req.reqType), uint8(ICCIPAdapter.RequestType.VERIFY), "reqType mismatch");
    }

    // ============================================
    // TEST 2: Replay with same messageId reverts
    // ============================================

    function test_replay_same_messageId_reverts() public {
        bytes32 messageId = keccak256("ccip-msg-replay");
        bytes32 requestId1 = keccak256("req-first");
        bytes32 requestId2 = keccak256("req-second");

        // First message: succeeds
        Client.Any2EVMMessage memory msg1 = _buildMessage(
            messageId,
            CHAIN_A,
            remoteAdapterA,
            requestId1,
            uint8(0),
            abi.encode(uint256(1), ICCIPAdapter.RequestType.VERIFY)
        );
        router.deliverMessage(address(adapter), msg1);

        // Second message: same messageId, same source chain, different requestId
        // The requestId-based ReplayProtection would not catch this because requestId2
        // is fresh. But the chain-bound messageId check MUST catch it.
        Client.Any2EVMMessage memory msg2 = _buildMessage(
            messageId,     // SAME messageId
            CHAIN_A,       // SAME source chain
            remoteAdapterA,
            requestId2,    // different requestId (passes requestId dedup)
            uint8(0),
            abi.encode(uint256(2), ICCIPAdapter.RequestType.VERIFY)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ReplayProtection.MessageAlreadyProcessed.selector,
                messageId,
                CHAIN_A
            )
        );
        router.deliverMessage(address(adapter), msg2);
    }

    // ============================================
    // TEST 3: Same messageId from different source chain is allowed
    // ============================================

    function test_different_sourceChain_treated_as_different() public {
        bytes32 messageId = keccak256("shared-ccip-msg-id");
        bytes32 requestIdA = keccak256("req-chain-a");
        bytes32 requestIdB = keccak256("req-chain-b");

        // Message from CHAIN_A
        Client.Any2EVMMessage memory msgA = _buildMessage(
            messageId,       // same messageId
            CHAIN_A,         // source = CHAIN_A
            remoteAdapterA,
            requestIdA,
            uint8(0),
            abi.encode(uint256(10), ICCIPAdapter.RequestType.STATUS)
        );

        // Message from CHAIN_B with the SAME messageId
        Client.Any2EVMMessage memory msgB = _buildMessage(
            messageId,       // same messageId
            CHAIN_B,         // source = CHAIN_B (different!)
            remoteAdapterB,
            requestIdB,
            uint8(0),
            abi.encode(uint256(20), ICCIPAdapter.RequestType.STATUS)
        );

        // Both should succeed because the chain-bound key differs:
        //   key_A = keccak256(messageId, block.chainid, CHAIN_A)
        //   key_B = keccak256(messageId, block.chainid, CHAIN_B)
        router.deliverMessage(address(adapter), msgA);
        router.deliverMessage(address(adapter), msgB);

        // Verify both requests stored correctly
        ICCIPAdapter.CrossChainRequest memory reqA = adapter.getRequest(requestIdA);
        assertEq(reqA.tokenId, 10, "reqA tokenId");
        assertEq(reqA.sourceChain, CHAIN_A, "reqA sourceChain");

        ICCIPAdapter.CrossChainRequest memory reqB = adapter.getRequest(requestIdB);
        assertEq(reqB.tokenId, 20, "reqB tokenId");
        assertEq(reqB.sourceChain, CHAIN_B, "reqB sourceChain");
    }

    // ============================================
    // TEST 4: isCcipMessageProcessed view function
    // ============================================

    function test_isCcipMessageProcessed_returns_correct_state() public {
        bytes32 messageId = keccak256("ccip-view-test");
        bytes32 requestId = keccak256("req-view");

        // Before processing: should return false
        assertFalse(
            adapter.isCcipMessageProcessed(messageId, CHAIN_A),
            "should be false before processing"
        );

        // Process the message
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            CHAIN_A,
            remoteAdapterA,
            requestId,
            uint8(0),
            abi.encode(uint256(99), ICCIPAdapter.RequestType.VERIFY)
        );
        router.deliverMessage(address(adapter), message);

        // After processing: should return true for the same chain
        assertTrue(
            adapter.isCcipMessageProcessed(messageId, CHAIN_A),
            "should be true after processing on same chain"
        );

        // Same messageId but queried with a different source chain: should return false
        assertFalse(
            adapter.isCcipMessageProcessed(messageId, CHAIN_B),
            "should be false for different source chain"
        );
    }

    // ============================================
    // TEST 5: isMessageProcessed (requestId-based) view
    // ============================================

    function test_isMessageProcessed_returns_correct_state() public {
        bytes32 messageId = keccak256("ccip-reqid-view");
        bytes32 requestId = keccak256("req-reqid-view");

        // Before processing: requestId not yet marked
        assertFalse(
            adapter.isMessageProcessed(requestId),
            "requestId should be unprocessed initially"
        );

        // Process the message
        Client.Any2EVMMessage memory message = _buildMessage(
            messageId,
            CHAIN_A,
            remoteAdapterA,
            requestId,
            uint8(0),
            abi.encode(uint256(7), ICCIPAdapter.RequestType.OWNERSHIP)
        );
        router.deliverMessage(address(adapter), message);

        // After processing: requestId should be marked
        assertTrue(
            adapter.isMessageProcessed(requestId),
            "requestId should be processed after delivery"
        );
    }

    // ============================================
    // HELPERS
    // ============================================

    /**
     * @dev Add a chain through the governor timelock flow:
     *      scheduleChainAddition -> warp 72h+1 -> executeChainAddition
     */
    function _addChain(uint64 chainSelector, address remoteAdapter) internal {
        vm.prank(governor);
        adapter.scheduleChainAddition(
            ICCIPAdapter.ChainConfig({
                chainSelector: chainSelector,
                adapter: remoteAdapter,
                gasLimit: GAS_LIMIT,
                active: true
            })
        );

        vm.warp(block.timestamp + 72 hours + 1);

        vm.prank(governor);
        adapter.executeChainAddition(chainSelector);
    }

    /**
     * @dev Build a well-formed Client.Any2EVMMessage for ccipReceive
     * @param messageId   CCIP-level message identifier
     * @param sourceChain Source chain selector
     * @param sender      Remote adapter address (abi.encoded)
     * @param requestId   Application-level request identifier
     * @param messageType 0 = request, 1 = response
     * @param payload     ABI-encoded payload (depends on messageType)
     */
    function _buildMessage(
        bytes32 messageId,
        uint64 sourceChain,
        address sender,
        bytes32 requestId,
        uint8 messageType,
        bytes memory payload
    ) internal pure returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: sourceChain,
            sender: abi.encode(sender),
            data: abi.encode(requestId, messageType, payload),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }
}
