// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title TAGITCoreUpgradeTest
 * @notice Tests for UUPS upgrade flow: authorized upgrades, unauthorized reverts,
 *         UpgradeScheduled event, state preservation, and storage layout compatibility
 */
contract TAGITCoreUpgradeTest is Test {
    uint256 constant ORACLE_PK = 0xA11CE;

    TAGITCore public proxy;
    TAGITCore public implementation;
    TimelockController public timelock;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public proposer;
    address public executor;
    address public manufacturer;
    address public attacker;

    uint256 public constant TIMELOCK_DELAY = 48 hours;
    bytes32 public constant METADATA = keccak256("ipfs://QmTest");
    bytes32 public constant TAG_HASH = keccak256("NFC_TAG_001");

    event UpgradeScheduled(
        address indexed oldImplementation, address indexed newImplementation, address indexed scheduledBy
    );

    function setUp() public {
        proposer = makeAddr("proposer");
        executor = makeAddr("executor");
        manufacturer = makeAddr("manufacturer");
        attacker = makeAddr("attacker");

        // Deploy TimelockController
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = proposer;
        executors[0] = executor;
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        // Deploy TAGITCore behind proxy
        implementation = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (address(timelock)));
        ERC1967Proxy erc1967Proxy = new ERC1967Proxy(address(implementation), initData);
        proxy = TAGITCore(address(erc1967Proxy));

        // Deploy and configure access control
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Set access controller via timelock
        _timelockExecute(
            abi.encodeCall(TAGITCore.setAccessController, (address(tagitAccess))), keccak256("setup_access")
        );

        // Set trusted oracle for NFC verification via timelock
        _timelockExecute(abi.encodeCall(TAGITCore.setTrustedOracle, (vm.addr(ORACLE_PK))), keccak256("setup_oracle"));

        // Grant manufacturer capabilities
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.CLAIMER_CAPABILITY()));
    }

    // ============================================
    // HELPERS
    // ============================================

    function _timelockExecute(bytes memory data, bytes32 salt) internal {
        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, data, bytes32(0), salt, TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.prank(executor);
        timelock.execute(address(proxy), 0, data, bytes32(0), salt);
    }

    function _oracleSign(uint256 tokenId, bytes32 tagHash)
        internal
        returns (bytes memory challengeResponse, bytes memory oracleSignature)
    {
        challengeResponse = abi.encodePacked("challenge", tokenId);
        bytes32 messageHash = keccak256(abi.encodePacked(tokenId, tagHash, challengeResponse));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, ethHash);
        oracleSignature = abi.encodePacked(r, s, v);
    }

    // ============================================
    // AUTHORIZED UPGRADE TESTS
    // ============================================

    function test_upgrade_authorizedViaTimelock() public {
        TAGITCore newImpl = new TAGITCore();

        bytes memory upgradeData = abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), ""));

        _timelockExecute(upgradeData, keccak256("upgrade_1"));

        // Verify implementation changed
        assertEq(proxy.getImplementation(), address(newImpl));
    }

    function test_upgrade_emitsUpgradeScheduledEvent() public {
        TAGITCore newImpl = new TAGITCore();
        address oldImpl = proxy.getImplementation();

        bytes memory upgradeData = abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), ""));

        // Schedule
        vm.prank(proposer);
        timelock.schedule(address(proxy), 0, upgradeData, bytes32(0), keccak256("upgrade_event_1"), TIMELOCK_DELAY);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Expect UpgradeScheduled event
        vm.expectEmit(true, true, true, false);
        emit UpgradeScheduled(oldImpl, address(newImpl), address(timelock));

        vm.prank(executor);
        timelock.execute(address(proxy), 0, upgradeData, bytes32(0), keccak256("upgrade_event_1"));
    }

    function test_upgrade_implementationAddressUpdated() public {
        address oldImpl = proxy.getImplementation();
        TAGITCore newImpl = new TAGITCore();

        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_addr_1"));

        assertNotEq(proxy.getImplementation(), oldImpl);
        assertEq(proxy.getImplementation(), address(newImpl));
    }

    // ============================================
    // UNAUTHORIZED UPGRADE TESTS
    // ============================================

    function test_upgrade_attackerCannotUpgrade() public {
        TAGITCore newImpl = new TAGITCore();

        vm.prank(attacker);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_proposerCannotUpgradeDirectly() public {
        TAGITCore newImpl = new TAGITCore();

        vm.prank(proposer);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_executorCannotUpgradeDirectly() public {
        TAGITCore newImpl = new TAGITCore();

        vm.prank(executor);
        vm.expectRevert();
        proxy.upgradeToAndCall(address(newImpl), "");
    }

    // ============================================
    // STATE PRESERVATION AFTER UPGRADE TESTS
    // ============================================

    function test_upgrade_preservesOwner() public {
        address ownerBefore = proxy.owner();

        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_owner_1"));

        assertEq(proxy.owner(), ownerBefore);
    }

    function test_upgrade_preservesERC721Metadata() public {
        string memory nameBefore = proxy.name();
        string memory symbolBefore = proxy.symbol();

        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_meta_1"));

        assertEq(proxy.name(), nameBefore);
        assertEq(proxy.symbol(), symbolBefore);
    }

    function test_upgrade_preservesMintedAssets() public {
        // Mint before upgrade
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);

        assertEq(proxy.totalSupply(), 1);
        assertEq(proxy.ownerOf(tokenId), manufacturer);

        // Upgrade
        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_mint_1"));

        // Verify state preserved
        assertEq(proxy.totalSupply(), 1);
        assertEq(proxy.ownerOf(tokenId), manufacturer);
        (address assetOwner,, TAGITCore.State state,,) = proxy.getAsset(tokenId);
        assertEq(assetOwner, manufacturer);
        assertEq(uint8(state), uint8(TAGITCore.State.MINTED));
    }

    function test_upgrade_preservesTagBindings() public {
        // Mint and bind before upgrade
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);
        {
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH);
            vm.prank(manufacturer);
            proxy.bindTag(tokenId, TAG_HASH, cr, sig);
        }

        // Upgrade
        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_tag_1"));

        // Verify bindings preserved
        assertEq(proxy.getTokenByTag(TAG_HASH), tokenId);
        assertEq(proxy.getTagByToken(tokenId), TAG_HASH);
    }

    function test_upgrade_preservesAccessController() public {
        address controllerBefore = address(proxy.accessController());

        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_ac_1"));

        assertEq(address(proxy.accessController()), controllerBefore);
    }

    function test_upgrade_preservesTokenIdCounter() public {
        // Mint 3 tokens before upgrade
        vm.startPrank(manufacturer);
        proxy.mint(manufacturer, keccak256("a1"));
        proxy.mint(manufacturer, keccak256("a2"));
        proxy.mint(manufacturer, keccak256("a3"));
        vm.stopPrank();

        // Upgrade
        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_counter_1"));

        // Next mint should continue from 4
        vm.prank(manufacturer);
        uint256 nextId = proxy.mint(manufacturer, keccak256("a4"));
        assertEq(nextId, 4);
        assertEq(proxy.totalSupply(), 4);
    }

    function test_upgrade_preservesCircuitBreakerConfig() public {
        uint256 capacityBefore = proxy.getFlagCircuitBreakerCapacity();

        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_cb_1"));

        assertEq(proxy.getFlagCircuitBreakerCapacity(), capacityBefore);
    }

    // ============================================
    // FULL LIFECYCLE AFTER UPGRADE TESTS
    // ============================================

    function test_upgrade_lifecycleWorksAfterUpgrade() public {
        // Upgrade first
        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(
            abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_lifecycle_1")
        );

        // Full lifecycle through upgraded proxy
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);

        {
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH);
            vm.prank(manufacturer);
            proxy.bindTag(tokenId, TAG_HASH, cr, sig);
        }

        vm.prank(manufacturer);
        proxy.activate(tokenId);

        address consumer = makeAddr("consumer");
        vm.prank(manufacturer);
        proxy.claim(tokenId, consumer);

        (address assetOwner,, TAGITCore.State state,,) = proxy.getAsset(tokenId);
        assertEq(assetOwner, consumer);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED));
    }

    function test_upgrade_assetsCreatedBeforeUpgradeCanContinueLifecycle() public {
        // Mint and bind BEFORE upgrade
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);
        {
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH);
            vm.prank(manufacturer);
            proxy.bindTag(tokenId, TAG_HASH, cr, sig);
        }

        // Upgrade
        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(
            abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_continue_1")
        );

        // Continue lifecycle AFTER upgrade
        vm.prank(manufacturer);
        proxy.activate(tokenId);

        address consumer = makeAddr("consumer");
        vm.prank(manufacturer);
        proxy.claim(tokenId, consumer);

        (address assetOwner,, TAGITCore.State state,,) = proxy.getAsset(tokenId);
        assertEq(assetOwner, consumer);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED));
    }

    // ============================================
    // STORAGE LAYOUT COMPATIBILITY TESTS
    // ============================================

    function test_upgrade_cannotReinitializeAfterUpgrade() public {
        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_reinit_1"));

        // Should not be able to re-initialize
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        proxy.initialize(attacker);
    }

    function test_upgrade_proxyAddressUnchanged() public {
        address proxyAddr = address(proxy);

        TAGITCore newImpl = new TAGITCore();
        _timelockExecute(
            abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), "")), keccak256("upgrade_addr_stable_1")
        );

        // Proxy address stays the same
        assertEq(address(proxy), proxyAddr);
    }

    function test_upgrade_multipleUpgradesPreserveState() public {
        // Mint before any upgrades
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);

        // First upgrade
        TAGITCore impl2 = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(impl2), "")), keccak256("multi_upgrade_1"));

        // Second upgrade
        TAGITCore impl3 = new TAGITCore();
        _timelockExecute(abi.encodeCall(proxy.upgradeToAndCall, (address(impl3), "")), keccak256("multi_upgrade_2"));

        // State preserved through both upgrades
        assertEq(proxy.getImplementation(), address(impl3));
        assertEq(proxy.totalSupply(), 1);
        assertEq(proxy.ownerOf(tokenId), manufacturer);
        assertEq(proxy.owner(), address(timelock));
    }
}
