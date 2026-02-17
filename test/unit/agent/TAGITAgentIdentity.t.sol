// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITAgentIdentity} from "../../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAccess} from "../../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../../src/access/CapabilityBadge.sol";

/**
 * @title TAGITAgentIdentityTest
 * @notice Unit tests for TAGITAgentIdentity contract
 * @dev Tests cover registration, metadata, wallet updates, soulbound enforcement, and access control
 */
contract TAGITAgentIdentityTest is Test {
    TAGITAgentIdentity public agentIdentity;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    // Test accounts
    address public owner;
    address public registrant1;
    address public registrant2;
    address public agentWallet1;
    address public agentWallet2;
    address public agentWallet3;
    address public govMilUser;
    address public noKycUser;

    // EIP-712 domain separator components
    bytes32 constant AGENT_WALLET_TYPEHASH =
        keccak256("AgentWallet(uint256 agentId,address wallet,uint256 nonce)");

    // Events
    event AgentRegistered(uint256 indexed agentId, address indexed registrant, address indexed wallet, string uri);
    event AgentURIUpdated(uint256 indexed agentId, string newURI);
    event AgentWalletUpdated(uint256 indexed agentId, address indexed oldWallet, address indexed newWallet);
    event AgentMetadataSet(uint256 indexed agentId, string key, string value);
    event AgentStatusChanged(uint256 indexed agentId, TAGITAgentIdentity.AgentStatus oldStatus, TAGITAgentIdentity.AgentStatus newStatus);

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        registrant1 = makeAddr("registrant1");
        registrant2 = makeAddr("registrant2");
        agentWallet1 = makeAddr("agentWallet1");
        agentWallet2 = makeAddr("agentWallet2");
        agentWallet3 = makeAddr("agentWallet3");
        govMilUser = makeAddr("govMilUser");
        noKycUser = makeAddr("noKycUser");

        // Deploy BIDGES stack
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Deploy AgentIdentity
        vm.prank(owner);
        agentIdentity = new TAGITAgentIdentity();
        vm.prank(owner);
        agentIdentity.setAccessController(address(tagitAccess));

        // Grant KYC_L1 identity to registrants
        identityBadge.grantIdentity(registrant1, 1); // KYC_L1
        identityBadge.grantIdentity(registrant2, 1);
        identityBadge.grantIdentity(govMilUser, 1);

        // Grant GOV_MIL capability to govMilUser (should be blocked)
        capabilityBadge.grantCapability(govMilUser, uint256(keccak256("GOV_MIL")));
    }

    // ============================================
    // REGISTRATION TESTS
    // ============================================

    function test_register_success() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        assertEq(agentId, 1, "First agent ID should be 1");
        assertEq(agentIdentity.totalAgents(), 1, "Total agents should be 1");

        (address reg, address wallet, uint64 registeredAt, bool active) = agentIdentity.getAgent(agentId);
        assertEq(reg, registrant1, "Registrant should match");
        assertEq(wallet, agentWallet1, "Wallet should match");
        assertGt(registeredAt, 0, "Timestamp should be set");
        assertTrue(active, "Agent should be active");

        // Check ERC721 ownership
        assertEq(agentIdentity.ownerOf(agentId), registrant1, "Token owner should be registrant");

        // Check token URI
        assertEq(agentIdentity.tokenURI(agentId), "ipfs://QmAgent1", "URI should match");
    }

    function test_register_multipleAgents() public {
        vm.prank(registrant1);
        uint256 id1 = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant1);
        uint256 id2 = agentIdentity.register(agentWallet2, "ipfs://QmAgent2");

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(agentIdentity.totalAgents(), 2);

        uint256[] memory agents = agentIdentity.getAgentsByRegistrant(registrant1);
        assertEq(agents.length, 2);
        assertEq(agents[0], 1);
        assertEq(agents[1], 2);
    }

    function test_register_walletLookup() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        assertEq(agentIdentity.getAgentByWallet(agentWallet1), agentId);
    }

    function test_register_emitsEvents() public {
        vm.expectEmit(true, true, true, true);
        emit AgentRegistered(1, registrant1, agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant1);
        agentIdentity.register(agentWallet1, "ipfs://QmAgent1");
    }

    function test_register_revertZeroWallet() public {
        vm.prank(registrant1);
        vm.expectRevert(TAGITAgentIdentity.ZeroAddress.selector);
        agentIdentity.register(address(0), "ipfs://QmAgent1");
    }

    function test_register_revertEmptyURI() public {
        vm.prank(registrant1);
        vm.expectRevert(TAGITAgentIdentity.InvalidURI.selector);
        agentIdentity.register(agentWallet1, "");
    }

    function test_register_revertDuplicateWallet() public {
        vm.prank(registrant1);
        agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant2);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.WalletAlreadyRegistered.selector, agentWallet1));
        agentIdentity.register(agentWallet1, "ipfs://QmAgent2");
    }

    function test_register_revertNoKYC() public {
        vm.prank(noKycUser);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.MissingKYCIdentity.selector, noKycUser));
        agentIdentity.register(agentWallet1, "ipfs://QmAgent1");
    }

    function test_register_revertGovMil() public {
        vm.prank(govMilUser);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.DefenseGuardBlocked.selector, govMilUser));
        agentIdentity.register(agentWallet1, "ipfs://QmAgent1");
    }

    function test_register_revertWhenPaused() public {
        vm.prank(owner);
        agentIdentity.pause();

        vm.prank(registrant1);
        vm.expectRevert();
        agentIdentity.register(agentWallet1, "ipfs://QmAgent1");
    }

    function test_register_withFee() public {
        vm.prank(owner);
        agentIdentity.setRegistrationFee(0.01 ether);

        vm.deal(registrant1, 1 ether);
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register{value: 0.01 ether}(agentWallet1, "ipfs://QmAgent1");

        assertEq(agentId, 1);
        assertEq(address(agentIdentity).balance, 0.01 ether);
    }

    // ============================================
    // URI UPDATE TESTS
    // ============================================

    function test_setAgentURI_success() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.expectEmit(true, false, false, true);
        emit AgentURIUpdated(agentId, "ipfs://QmAgent1Updated");

        vm.prank(registrant1);
        agentIdentity.setAgentURI(agentId, "ipfs://QmAgent1Updated");

        assertEq(agentIdentity.tokenURI(agentId), "ipfs://QmAgent1Updated");
    }

    function test_setAgentURI_revertNotRegistrant() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant2);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.NotRegistrant.selector, registrant2, agentId));
        agentIdentity.setAgentURI(agentId, "ipfs://QmHacked");
    }

    function test_setAgentURI_revertEmptyURI() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant1);
        vm.expectRevert(TAGITAgentIdentity.InvalidURI.selector);
        agentIdentity.setAgentURI(agentId, "");
    }

    // ============================================
    // METADATA TESTS
    // ============================================

    function test_setMetadata_success() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.expectEmit(true, false, false, true);
        emit AgentMetadataSet(agentId, "model", "gpt-4");

        vm.prank(registrant1);
        agentIdentity.setMetadata(agentId, "model", "gpt-4");

        assertEq(agentIdentity.getMetadata(agentId, "model"), "gpt-4");
    }

    function test_setMetadata_multipleKeys() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.startPrank(registrant1);
        agentIdentity.setMetadata(agentId, "model", "gpt-4");
        agentIdentity.setMetadata(agentId, "version", "1.0");
        agentIdentity.setMetadata(agentId, "type", "trading");
        vm.stopPrank();

        assertEq(agentIdentity.getMetadata(agentId, "model"), "gpt-4");
        assertEq(agentIdentity.getMetadata(agentId, "version"), "1.0");
        assertEq(agentIdentity.getMetadata(agentId, "type"), "trading");
    }

    function test_setMetadata_revertEmptyKey() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant1);
        vm.expectRevert(TAGITAgentIdentity.InvalidMetadataKey.selector);
        agentIdentity.setMetadata(agentId, "", "value");
    }

    // ============================================
    // WALLET UPDATE TESTS (EIP-712)
    // ============================================

    function test_setAgentWallet_success() public {
        // Use a real private key for EIP-712 signing
        uint256 newWalletKey = 0xBEEF;
        address newWallet = vm.addr(newWalletKey);

        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        // Create EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(AGENT_WALLET_TYPEHASH, agentId, newWallet, 0));
        bytes32 digest = _getTypedDataHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newWalletKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectEmit(true, true, true, false);
        emit AgentWalletUpdated(agentId, agentWallet1, newWallet);

        vm.prank(registrant1);
        agentIdentity.setAgentWallet(agentId, newWallet, signature);

        (, address wallet,,) = agentIdentity.getAgent(agentId);
        assertEq(wallet, newWallet, "Wallet should be updated");
        assertEq(agentIdentity.getAgentByWallet(newWallet), agentId, "Wallet lookup should work");
        assertEq(agentIdentity.getAgentByWallet(agentWallet1), 0, "Old wallet should be cleared");
        assertEq(agentIdentity.walletNonce(agentId), 1, "Nonce should increment");
    }

    function test_setAgentWallet_revertInvalidSignature() public {
        uint256 wrongKey = 0xDEAD;

        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        // Sign with wrong key
        address newWallet = makeAddr("newWallet");
        bytes32 structHash = keccak256(abi.encode(AGENT_WALLET_TYPEHASH, agentId, newWallet, 0));
        bytes32 digest = _getTypedDataHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(registrant1);
        vm.expectRevert(TAGITAgentIdentity.InvalidSignature.selector);
        agentIdentity.setAgentWallet(agentId, newWallet, signature);
    }

    // ============================================
    // SOULBOUND TESTS
    // ============================================

    function test_soulbound_transferBlocked() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant1);
        vm.expectRevert(TAGITAgentIdentity.SoulboundTransferDisabled.selector);
        agentIdentity.transferFrom(registrant1, registrant2, agentId);
    }

    function test_soulbound_safeTransferBlocked() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant1);
        vm.expectRevert(TAGITAgentIdentity.SoulboundTransferDisabled.selector);
        agentIdentity.safeTransferFrom(registrant1, registrant2, agentId);
    }

    // ============================================
    // STATUS MANAGEMENT TESTS
    // ============================================

    function test_suspendAgent_success() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.expectEmit(true, false, false, true);
        emit AgentStatusChanged(agentId, TAGITAgentIdentity.AgentStatus.ACTIVE, TAGITAgentIdentity.AgentStatus.SUSPENDED);

        vm.prank(owner);
        agentIdentity.suspendAgent(agentId);

        assertEq(uint8(agentIdentity.getAgentStatus(agentId)), uint8(TAGITAgentIdentity.AgentStatus.SUSPENDED));
        assertFalse(agentIdentity.isActiveAgent(agentId));
    }

    function test_reactivateAgent_success() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(owner);
        agentIdentity.suspendAgent(agentId);

        vm.prank(owner);
        agentIdentity.reactivateAgent(agentId);

        assertEq(uint8(agentIdentity.getAgentStatus(agentId)), uint8(TAGITAgentIdentity.AgentStatus.ACTIVE));
        assertTrue(agentIdentity.isActiveAgent(agentId));
    }

    function test_decommissionAgent_success() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant1);
        agentIdentity.decommissionAgent(agentId);

        assertEq(uint8(agentIdentity.getAgentStatus(agentId)), uint8(TAGITAgentIdentity.AgentStatus.DECOMMISSIONED));
        assertFalse(agentIdentity.isActiveAgent(agentId));
        // Wallet should be freed
        assertEq(agentIdentity.getAgentByWallet(agentWallet1), 0);
    }

    function test_decommissionAgent_revertNotRegistrant() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(registrant2);
        vm.expectRevert(abi.encodeWithSelector(TAGITAgentIdentity.NotRegistrant.selector, registrant2, agentId));
        agentIdentity.decommissionAgent(agentId);
    }

    function test_suspendAgent_revertAlreadySuspended() public {
        vm.prank(registrant1);
        uint256 agentId = agentIdentity.register(agentWallet1, "ipfs://QmAgent1");

        vm.prank(owner);
        agentIdentity.suspendAgent(agentId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITAgentIdentity.AgentAlreadyInStatus.selector,
            agentId,
            TAGITAgentIdentity.AgentStatus.SUSPENDED
        ));
        agentIdentity.suspendAgent(agentId);
    }

    // ============================================
    // FEE WITHDRAWAL TESTS
    // ============================================

    function test_withdrawFees_success() public {
        vm.prank(owner);
        agentIdentity.setRegistrationFee(0.01 ether);

        vm.deal(registrant1, 1 ether);
        vm.prank(registrant1);
        agentIdentity.register{value: 0.01 ether}(agentWallet1, "ipfs://QmAgent1");

        address treasury = makeAddr("treasury");
        vm.prank(owner);
        agentIdentity.withdrawFees(treasury);

        assertEq(treasury.balance, 0.01 ether);
        assertEq(address(agentIdentity).balance, 0);
    }

    // ============================================
    // ACCESS CONTROLLER TESTS
    // ============================================

    function test_register_revertNoAccessController() public {
        vm.prank(owner);
        TAGITAgentIdentity freshIdentity = new TAGITAgentIdentity();

        vm.prank(registrant1);
        vm.expectRevert(TAGITAgentIdentity.AccessControllerNotSet.selector);
        freshIdentity.register(agentWallet1, "ipfs://QmAgent1");
    }

    // ============================================
    // HELPERS
    // ============================================

    function _getTypedDataHash(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("TAGITAgentIdentity"),
            keccak256("1"),
            block.chainid,
            address(agentIdentity)
        ));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
