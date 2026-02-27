// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {CCIPAdapter} from "../../src/bridge/CCIPAdapter.sol";
import {ICCIPAdapter} from "../../src/interfaces/ICCIPAdapter.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/ccip/interfaces/IRouterClient.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title CCIPAdapterTest
 * @notice Unit tests for CCIPAdapter cross-chain verification
 */
contract CCIPAdapterTest is Test {
    CCIPAdapter public adapter;
    CCIPAdapter public adapterImpl;

    address public owner;
    address public governor;
    address public router;
    address public tagitCore;
    address public user;

    // Chain selectors
    uint64 public constant OP_MAINNET_SELECTOR = 3734403246176062136;
    uint64 public constant ETH_MAINNET_SELECTOR = 5009297550715157269;
    uint64 public constant BASE_SELECTOR = 15971525489660198786;
    uint64 public constant UNKNOWN_CHAIN = 999999999;

    // Default gas limit
    uint256 public constant DEFAULT_GAS = 200_000;

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        router = makeAddr("router");
        tagitCore = makeAddr("tagitCore");
        user = makeAddr("user");

        // Deploy implementation
        adapterImpl = new CCIPAdapter();

        // Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(CCIPAdapter.initialize.selector, router, governor, tagitCore, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(adapterImpl), initData);
        adapter = CCIPAdapter(payable(address(proxy)));

        // Fund the adapter for CCIP fees
        vm.deal(address(adapter), 10 ether);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsCorrectState() public view {
        assertEq(adapter.router(), router);
        assertEq(adapter.governor(), governor);
        assertEq(adapter.tagitCore(), tagitCore);
        assertEq(adapter.owner(), owner);
        assertEq(adapter.rateLimit(), 100); // DEFAULT_RATE_LIMIT
        assertFalse(adapter.isPaused());
    }

    function test_initialize_revertsOnZeroAddresses() public {
        CCIPAdapter newImpl = new CCIPAdapter();

        vm.expectRevert(ICCIPAdapter.ZeroAddress.selector);
        new ERC1967Proxy(
            address(newImpl),
            abi.encodeWithSelector(CCIPAdapter.initialize.selector, address(0), governor, tagitCore, owner)
        );
    }

    function test_supportsInterface_ccipReceiver() public view {
        // IAny2EVMMessageReceiver interface ID
        bytes4 receiverInterfaceId = 0x85572ffb;
        assertTrue(adapter.supportsInterface(receiverInterfaceId));
    }

    function test_supportsInterface_erc165() public view {
        bytes4 erc165InterfaceId = 0x01ffc9a7;
        assertTrue(adapter.supportsInterface(erc165InterfaceId));
    }

    // ============================================
    // CHAIN MANAGEMENT TESTS
    // ============================================

    function test_scheduleChainAddition_createsTimelock() public {
        ICCIPAdapter.ChainConfig memory config = ICCIPAdapter.ChainConfig({
            chainSelector: OP_MAINNET_SELECTOR, adapter: makeAddr("remoteAdapter"), gasLimit: DEFAULT_GAS, active: true
        });

        vm.prank(governor);
        adapter.scheduleChainAddition(config);

        ICCIPAdapter.PendingChainAddition memory pending = adapter.getPendingChainAddition(OP_MAINNET_SELECTOR);
        assertEq(pending.config.chainSelector, OP_MAINNET_SELECTOR);
        assertEq(pending.scheduledAt, block.timestamp);
        assertFalse(pending.executed);
    }

    function test_scheduleChainAddition_revertsIfNotGovernor() public {
        ICCIPAdapter.ChainConfig memory config = ICCIPAdapter.ChainConfig({
            chainSelector: OP_MAINNET_SELECTOR, adapter: makeAddr("remoteAdapter"), gasLimit: DEFAULT_GAS, active: true
        });

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICCIPAdapter.NotGovernor.selector, user));
        adapter.scheduleChainAddition(config);
    }

    function test_executeChainAddition_worksAfter72Hours() public {
        // Schedule
        address remoteAdapter = makeAddr("remoteAdapter");
        ICCIPAdapter.ChainConfig memory config = ICCIPAdapter.ChainConfig({
            chainSelector: OP_MAINNET_SELECTOR, adapter: remoteAdapter, gasLimit: DEFAULT_GAS, active: true
        });

        vm.prank(governor);
        adapter.scheduleChainAddition(config);

        // Warp past 72 hours
        vm.warp(block.timestamp + 72 hours + 1);

        // Execute
        vm.prank(governor);
        adapter.executeChainAddition(OP_MAINNET_SELECTOR);

        // Verify
        assertTrue(adapter.isChainSupported(OP_MAINNET_SELECTOR));
        ICCIPAdapter.ChainConfig memory storedConfig = adapter.getChainConfig(OP_MAINNET_SELECTOR);
        assertEq(storedConfig.adapter, remoteAdapter);
    }

    function test_executeChainAddition_revertsBeforeTimelock() public {
        // Schedule
        ICCIPAdapter.ChainConfig memory config = ICCIPAdapter.ChainConfig({
            chainSelector: OP_MAINNET_SELECTOR, adapter: makeAddr("remoteAdapter"), gasLimit: DEFAULT_GAS, active: true
        });

        vm.prank(governor);
        adapter.scheduleChainAddition(config);

        // Try to execute immediately
        vm.prank(governor);
        vm.expectRevert(); // TimelockNotElapsed
        adapter.executeChainAddition(OP_MAINNET_SELECTOR);
    }

    function test_cancelChainAddition_works() public {
        // Schedule
        ICCIPAdapter.ChainConfig memory config = ICCIPAdapter.ChainConfig({
            chainSelector: OP_MAINNET_SELECTOR, adapter: makeAddr("remoteAdapter"), gasLimit: DEFAULT_GAS, active: true
        });

        vm.prank(governor);
        adapter.scheduleChainAddition(config);

        // Cancel
        vm.prank(governor);
        adapter.cancelChainAddition(OP_MAINNET_SELECTOR);

        // Verify cancelled
        ICCIPAdapter.PendingChainAddition memory pending = adapter.getPendingChainAddition(OP_MAINNET_SELECTOR);
        assertEq(pending.scheduledAt, 0);
    }

    function test_removeChain_works() public {
        // Add chain first
        _addChainWithTimelock(OP_MAINNET_SELECTOR, makeAddr("remoteAdapter"));

        // Remove
        vm.prank(governor);
        adapter.removeChain(OP_MAINNET_SELECTOR);

        assertFalse(adapter.isChainSupported(OP_MAINNET_SELECTOR));
    }

    function test_updateChainGasLimit_works() public {
        // Add chain first
        _addChainWithTimelock(OP_MAINNET_SELECTOR, makeAddr("remoteAdapter"));

        uint256 newGasLimit = 300_000;
        vm.prank(governor);
        adapter.updateChainGasLimit(OP_MAINNET_SELECTOR, newGasLimit);

        ICCIPAdapter.ChainConfig memory config = adapter.getChainConfig(OP_MAINNET_SELECTOR);
        assertEq(config.gasLimit, newGasLimit);
    }

    // ============================================
    // RATE LIMITING TESTS
    // ============================================

    function test_setRateLimit_works() public {
        uint256 newLimit = 50;

        vm.prank(governor);
        adapter.setRateLimit(newLimit);

        assertEq(adapter.rateLimit(), newLimit);
    }

    function test_getRemainingCapacity_returnsCorrectValue() public view {
        // Initially should be at full capacity
        assertEq(adapter.getRemainingCapacity(), 100);
    }

    // ============================================
    // PAUSE/UNPAUSE TESTS
    // ============================================

    function test_pause_works() public {
        vm.prank(governor);
        adapter.pause();

        assertTrue(adapter.isPaused());
    }

    function test_unpause_works() public {
        vm.prank(governor);
        adapter.pause();

        vm.prank(governor);
        adapter.unpause();

        assertFalse(adapter.isPaused());
    }

    function test_pause_revertsIfNotGovernor() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICCIPAdapter.NotGovernor.selector, user));
        adapter.pause();
    }

    // ============================================
    // CCIP RECEIVE TESTS
    // ============================================

    function test_ccipReceive_revertsIfNotRouter() public {
        Client.Any2EVMMessage memory message = _createDummyMessage(OP_MAINNET_SELECTOR);

        vm.prank(user); // Not the router
        vm.expectRevert(abi.encodeWithSelector(ICCIPAdapter.NotRouter.selector, user));
        adapter.ccipReceive(message);
    }

    function test_ccipReceive_revertsOnUnknownChain() public {
        // Add OP chain first
        _addChainWithTimelock(OP_MAINNET_SELECTOR, makeAddr("remoteAdapter"));

        // Message from unknown chain
        Client.Any2EVMMessage memory message = _createDummyMessage(UNKNOWN_CHAIN);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(ICCIPAdapter.UnsupportedChain.selector, UNKNOWN_CHAIN));
        adapter.ccipReceive(message);
    }

    function test_ccipReceive_revertsOnUnknownSender() public {
        address remoteAdapter = makeAddr("remoteAdapter");
        address wrongSender = makeAddr("wrongSender");

        _addChainWithTimelock(OP_MAINNET_SELECTOR, remoteAdapter);

        // Message from wrong sender
        bytes32 requestId = keccak256("test");
        bytes memory data = abi.encode(requestId, uint8(0), abi.encode(uint256(1), ICCIPAdapter.RequestType.VERIFY));

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("msgId"),
            sourceChainSelector: OP_MAINNET_SELECTOR,
            sender: abi.encode(wrongSender),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(ICCIPAdapter.UnknownSender.selector, OP_MAINNET_SELECTOR, wrongSender));
        adapter.ccipReceive(message);
    }

    function test_ccipReceive_revertsOnReplayAttack() public {
        address remoteAdapter = makeAddr("remoteAdapter");
        _addChainWithTimelock(OP_MAINNET_SELECTOR, remoteAdapter);

        bytes32 requestId = keccak256("testReplay");
        bytes memory data = abi.encode(requestId, uint8(0), abi.encode(uint256(1), ICCIPAdapter.RequestType.VERIFY));

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("msgId1"),
            sourceChainSelector: OP_MAINNET_SELECTOR,
            sender: abi.encode(remoteAdapter),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        // Mock the router's getFee function
        vm.mockCall(router, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(0.01 ether));

        // Mock ccipSend
        vm.mockCall(router, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(keccak256("msgId")));

        // First call should succeed
        vm.prank(router);
        adapter.ccipReceive(message);

        // Second call with same requestId should revert
        message.messageId = keccak256("msgId2"); // Different message ID
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(ICCIPAdapter.RequestIdAlreadyUsed.selector, requestId));
        adapter.ccipReceive(message);
    }

    function test_ccipReceive_revertsWhenPaused() public {
        address remoteAdapter = makeAddr("remoteAdapter");
        _addChainWithTimelock(OP_MAINNET_SELECTOR, remoteAdapter);

        // Pause
        vm.prank(governor);
        adapter.pause();

        Client.Any2EVMMessage memory message = _createValidMessage(OP_MAINNET_SELECTOR, remoteAdapter);

        vm.prank(router);
        vm.expectRevert(ICCIPAdapter.ContractPaused.selector);
        adapter.ccipReceive(message);
    }

    // ============================================
    // OUTBOUND REQUEST TESTS
    // ============================================

    function test_requestVerification_revertsOnUnsupportedChain() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICCIPAdapter.UnsupportedChain.selector, OP_MAINNET_SELECTOR));
        adapter.requestVerification(OP_MAINNET_SELECTOR, 1);
    }

    function test_requestVerification_revertsWhenPaused() public {
        address remoteAdapter = makeAddr("remoteAdapter");
        _addChainWithTimelock(OP_MAINNET_SELECTOR, remoteAdapter);

        vm.prank(governor);
        adapter.pause();

        // Fund user with ETH
        vm.deal(user, 2 ether);
        vm.prank(user);
        vm.expectRevert(ICCIPAdapter.ContractPaused.selector);
        adapter.requestVerification{value: 1 ether}(OP_MAINNET_SELECTOR, 1);
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_version_returns100() public view {
        assertEq(adapter.version(), "1.0.0");
    }

    function test_getRequest_returnsEmptyForUnknown() public view {
        ICCIPAdapter.CrossChainRequest memory req = adapter.getRequest(keccak256("unknown"));
        assertEq(req.tokenId, 0);
        assertEq(req.sourceChain, 0);
    }

    function test_getResponse_returnsEmptyForUnknown() public view {
        ICCIPAdapter.CrossChainResponse memory resp = adapter.getResponse(keccak256("unknown"));
        assertFalse(resp.valid);
        assertEq(resp.requestId, bytes32(0));
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function test_rateLimit_enforced_at100() public {
        // Mock router for sending
        vm.mockCall(router, abi.encodeWithSelector(IRouterClient.getFee.selector), abi.encode(0.01 ether));
        vm.mockCall(router, abi.encodeWithSelector(IRouterClient.ccipSend.selector), abi.encode(keccak256("msgId")));

        // Add chain
        _addChainWithTimelock(OP_MAINNET_SELECTOR, makeAddr("remoteAdapter"));

        // Try to make 101 requests - first 100 should succeed, 101st should fail
        vm.startPrank(user);
        vm.deal(user, 200 ether);

        // Make 100 successful requests
        for (uint256 i = 0; i < 100; i++) {
            adapter.requestVerification{value: 1 ether}(OP_MAINNET_SELECTOR, i + 1);
        }

        // 101st request should fail
        vm.expectRevert(); // RateLimitExceeded
        adapter.requestVerification{value: 1 ether}(OP_MAINNET_SELECTOR, 101);
        vm.stopPrank();

        // Verify remaining capacity is 0
        assertEq(adapter.getRemainingCapacity(), 0);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _addChainWithTimelock(uint64 chainSelector, address remoteAdapter) internal {
        ICCIPAdapter.ChainConfig memory config = ICCIPAdapter.ChainConfig({
            chainSelector: chainSelector, adapter: remoteAdapter, gasLimit: DEFAULT_GAS, active: true
        });

        vm.prank(governor);
        adapter.scheduleChainAddition(config);

        vm.warp(block.timestamp + 72 hours + 1);

        vm.prank(governor);
        adapter.executeChainAddition(chainSelector);
    }

    function _createDummyMessage(uint64 sourceChain) internal pure returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId: keccak256("msgId"),
            sourceChainSelector: sourceChain,
            sender: abi.encode(address(0)),
            data: bytes(""),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _createValidMessage(uint64 sourceChain, address sender)
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        bytes32 requestId = keccak256("validRequest");
        bytes memory data = abi.encode(requestId, uint8(0), abi.encode(uint256(1), ICCIPAdapter.RequestType.VERIFY));

        return Client.Any2EVMMessage({
            messageId: keccak256("msgId"),
            sourceChainSelector: sourceChain,
            sender: abi.encode(sender),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }
}
