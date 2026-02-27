// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Client} from "@chainlink/ccip/libraries/Client.sol";

import {CCIPAdapter} from "../../src/bridge/CCIPAdapter.sol";
import {ICCIPAdapter} from "../../src/interfaces/ICCIPAdapter.sol";
import {ReplayProtection} from "../../src/libraries/ReplayProtection.sol";

/**
 * @title MockCCIPRouter
 * @notice Mock CCIP Router for testing
 */
contract MockCCIPRouter {
    uint256 public lastFee;

    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256) {
        return 0.01 ether;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage memory) external payable returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender));
    }
}

/**
 * @title MockTAGITCore
 * @notice Mock TAGITCore for testing
 */
contract MockTAGITCore {
    function getAsset(uint256 tokenId)
        external
        view
        returns (
            address owner,
            uint8 state,
            bytes32 tagHash,
            bytes32 metadataHash,
            uint64 createdAt,
            uint64 activatedAt,
            uint64 claimedAt
        )
    {
        return (
            address(0x1234),
            3, // ACTIVATED
            bytes32(uint256(tokenId)),
            bytes32(0),
            uint64(block.timestamp - 100),
            uint64(block.timestamp - 50),
            0
        );
    }
}

/**
 * @title CCIPAdapterNistTest
 * @notice NIST CSF 2.0 security control tests for CCIPAdapter
 * @dev Tests SC-8 (Transmission Confidentiality) and SC-23 (Session Authenticity)
 *      replay protection for cross-chain messages
 */
contract CCIPAdapterNistTest is Test {
    // ============================================
    // CONTRACTS
    // ============================================

    CCIPAdapter public adapter;
    MockCCIPRouter public router;
    MockTAGITCore public mockCore;

    // ============================================
    // ADDRESSES
    // ============================================

    address public owner;
    address public governor;
    address public remoteAdapter;
    address public user;
    address public attacker;

    // ============================================
    // CONSTANTS
    // ============================================

    uint64 public constant REMOTE_CHAIN = 16015286601757825753; // Sepolia
    uint64 public constant DEFAULT_MESSAGE_EXPIRY = 24 hours;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        remoteAdapter = makeAddr("remoteAdapter");
        user = makeAddr("user");
        attacker = makeAddr("attacker");

        vm.startPrank(owner);

        // Deploy mock contracts
        router = new MockCCIPRouter();
        mockCore = new MockTAGITCore();

        // Deploy CCIPAdapter (upgradeable)
        CCIPAdapter adapterImpl = new CCIPAdapter();
        bytes memory adapterData =
            abi.encodeCall(CCIPAdapter.initialize, (address(router), governor, address(mockCore), owner));
        ERC1967Proxy adapterProxy = new ERC1967Proxy(address(adapterImpl), adapterData);
        adapter = CCIPAdapter(payable(address(adapterProxy)));

        // Fund adapter for CCIP fees
        vm.deal(address(adapter), 10 ether);

        vm.stopPrank();

        // Setup remote chain
        _setupRemoteChain();
    }

    function _setupRemoteChain() internal {
        vm.prank(governor);
        adapter.scheduleChainAddition(
            ICCIPAdapter.ChainConfig({
                chainSelector: REMOTE_CHAIN, adapter: remoteAdapter, gasLimit: 200_000, active: true
            })
        );

        // Wait for timelock
        vm.warp(block.timestamp + 72 hours + 1);

        vm.prank(governor);
        adapter.executeChainAddition(REMOTE_CHAIN);
    }

    // ============================================
    // REPLAY PROTECTION TESTS (SC-8, SC-23)
    // ============================================

    function test_replayProtection_initialStateEnabled() public view {
        assertTrue(adapter.isReplayProtectionEnabled());
    }

    function test_replayProtection_defaultMessageExpiry() public view {
        uint64 expiry = adapter.getMessageExpiry();
        assertEq(expiry, DEFAULT_MESSAGE_EXPIRY);
    }

    function test_replayProtection_governorCanSetExpiry() public {
        vm.prank(governor);
        adapter.setMessageExpiry(48 hours);

        assertEq(adapter.getMessageExpiry(), 48 hours);
    }

    function test_replayProtection_governorCanDisable() public {
        vm.prank(governor);
        adapter.setReplayProtectionEnabled(false);

        assertFalse(adapter.isReplayProtectionEnabled());
    }

    function test_replayProtection_governorCanReEnable() public {
        vm.prank(governor);
        adapter.setReplayProtectionEnabled(false);

        vm.prank(governor);
        adapter.setReplayProtectionEnabled(true);

        assertTrue(adapter.isReplayProtectionEnabled());
    }

    function test_replayProtection_messagesMarkedAsProcessed() public {
        // Fund user
        vm.deal(user, 1 ether);

        // Send a request
        vm.prank(user);
        bytes32 requestId = adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, 1);

        // Request should be marked as processed
        assertTrue(adapter.isMessageProcessed(requestId));
    }

    function test_replayProtection_chainStateTracked() public {
        // Initial state
        (uint64 lastNonce, uint64 messageCount) = adapter.getReplayProtectionState(REMOTE_CHAIN);
        assertEq(lastNonce, 0);
        assertEq(messageCount, 0);
    }

    function test_replayProtection_governorCanSetChainNonce() public {
        vm.prank(governor);
        adapter.setChainNonce(REMOTE_CHAIN, 100);

        (uint64 lastNonce,) = adapter.getReplayProtectionState(REMOTE_CHAIN);
        assertEq(lastNonce, 100);
    }

    // ============================================
    // SECURITY TESTS
    // ============================================

    function test_security_nonGovernorCannotSetExpiry() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.setMessageExpiry(1 hours);
    }

    function test_security_nonGovernorCannotDisableReplayProtection() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.setReplayProtectionEnabled(false);
    }

    function test_security_nonGovernorCannotSetChainNonce() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.setChainNonce(REMOTE_CHAIN, 9999);
    }

    // ============================================
    // RATE LIMITING TESTS
    // ============================================

    function test_rateLimit_initialCapacity() public view {
        uint256 remaining = adapter.getRemainingCapacity();
        assertEq(remaining, 100); // DEFAULT_RATE_LIMIT
    }

    function test_rateLimit_decreasesOnRequest() public {
        vm.deal(user, 10 ether);

        vm.prank(user);
        adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, 1);

        uint256 remaining = adapter.getRemainingCapacity();
        assertEq(remaining, 99);
    }

    function test_rateLimit_blocksExcessiveRequests() public {
        vm.deal(user, 200 ether);

        vm.startPrank(user);

        // Use up all capacity
        for (uint256 i = 0; i < 100; i++) {
            adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, i);
        }

        // 101st request should fail
        vm.expectRevert();
        adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, 101);

        vm.stopPrank();
    }

    function test_rateLimit_resetsAfterHour() public {
        vm.deal(user, 200 ether);

        vm.startPrank(user);

        // Use up all capacity
        for (uint256 i = 0; i < 100; i++) {
            adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, i);
        }

        vm.stopPrank();

        // Move forward an hour
        vm.warp(block.timestamp + 1 hours + 1);

        // Should work again
        vm.prank(user);
        adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, 200);

        assertEq(adapter.getRemainingCapacity(), 99);
    }

    function test_rateLimit_governorCanUpdateLimit() public {
        vm.prank(governor);
        adapter.setRateLimit(200);

        assertEq(adapter.rateLimit(), 200);
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function test_pause_governorCanPause() public {
        vm.prank(governor);
        adapter.pause();

        assertTrue(adapter.isPaused());
    }

    function test_pause_governorCanUnpause() public {
        vm.prank(governor);
        adapter.pause();

        vm.prank(governor);
        adapter.unpause();

        assertFalse(adapter.isPaused());
    }

    function test_pause_blocksRequests() public {
        vm.prank(governor);
        adapter.pause();

        vm.deal(user, 1 ether);

        vm.prank(user);
        vm.expectRevert();
        adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, 1);
    }

    // ============================================
    // CHAIN MANAGEMENT TESTS
    // ============================================

    function test_chain_isSupported() public view {
        assertTrue(adapter.isChainSupported(REMOTE_CHAIN));
    }

    function test_chain_configCorrect() public view {
        ICCIPAdapter.ChainConfig memory config = adapter.getChainConfig(REMOTE_CHAIN);

        assertEq(config.chainSelector, REMOTE_CHAIN);
        assertEq(config.adapter, remoteAdapter);
        assertEq(config.gasLimit, 200_000);
        assertTrue(config.active);
    }

    function test_chain_governorCanRemove() public {
        vm.prank(governor);
        adapter.removeChain(REMOTE_CHAIN);

        assertFalse(adapter.isChainSupported(REMOTE_CHAIN));
    }

    function test_chain_governorCanUpdateGasLimit() public {
        vm.prank(governor);
        adapter.updateChainGasLimit(REMOTE_CHAIN, 300_000);

        ICCIPAdapter.ChainConfig memory config = adapter.getChainConfig(REMOTE_CHAIN);
        assertEq(config.gasLimit, 300_000);
    }

    // ============================================
    // REQUEST TESTS
    // ============================================

    function test_request_verification() public {
        vm.deal(user, 1 ether);

        vm.prank(user);
        bytes32 requestId = adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, 1);

        ICCIPAdapter.CrossChainRequest memory req = adapter.getRequest(requestId);
        assertEq(req.tokenId, 1);
        assertEq(req.sender, user);
        assertEq(uint8(req.reqType), uint8(ICCIPAdapter.RequestType.VERIFY));
    }

    function test_request_status() public {
        vm.deal(user, 1 ether);

        vm.prank(user);
        bytes32 requestId = adapter.requestStatus{value: 0.1 ether}(REMOTE_CHAIN, 1);

        ICCIPAdapter.CrossChainRequest memory req = adapter.getRequest(requestId);
        assertEq(uint8(req.reqType), uint8(ICCIPAdapter.RequestType.STATUS));
    }

    function test_request_data() public {
        vm.deal(user, 1 ether);

        vm.prank(user);
        bytes32 requestId = adapter.requestData{value: 0.1 ether}(REMOTE_CHAIN, 1, ICCIPAdapter.RequestType.OWNERSHIP);

        ICCIPAdapter.CrossChainRequest memory req = adapter.getRequest(requestId);
        assertEq(uint8(req.reqType), uint8(ICCIPAdapter.RequestType.OWNERSHIP));
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_requestVerification() public {
        vm.deal(user, 1 ether);

        vm.prank(user);
        uint256 gasBefore = gasleft();
        adapter.requestVerification{value: 0.1 ether}(REMOTE_CHAIN, 1);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 250000, "requestVerification() too expensive");
    }

    function test_gas_isMessageProcessed() public view {
        bytes32 testId = keccak256("test");
        adapter.isMessageProcessed(testId);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function test_viewFunctions() public view {
        adapter.router();
        adapter.governor();
        adapter.tagitCore();
        adapter.isPaused();
        adapter.rateLimit();
        adapter.version();
    }

    function test_estimateFee() public view {
        uint256 fee = adapter.estimateFee(REMOTE_CHAIN, ICCIPAdapter.RequestType.VERIFY);
        assertGt(fee, 0);
    }

    // ============================================
    // INTERFACE SUPPORT
    // ============================================

    function test_supportsInterface() public view {
        // IAny2EVMMessageReceiver interface
        bytes4 receiverId = 0x85572ffb;
        assertTrue(adapter.supportsInterface(receiverId));

        // IERC165 interface
        bytes4 erc165Id = 0x01ffc9a7;
        assertTrue(adapter.supportsInterface(erc165Id));
    }
}
