// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title TAGITCoreProxyTest
 * @notice Tests for TAGITCore UUPS proxy initialization, storage, and delegation
 */
contract TAGITCoreProxyTest is Test {
    TAGITCore public implementation;
    TAGITCore public proxy;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    address public owner;
    address public manufacturer;
    address public resolver2;
    address public attacker;

    bytes32 public constant METADATA = keccak256("ipfs://QmTest");
    bytes32 public constant TAG_HASH = keccak256("NFC_TAG_001");

    event UpgradeScheduled(
        address indexed oldImplementation,
        address indexed newImplementation,
        address indexed scheduledBy
    );

    function setUp() public {
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        resolver2 = makeAddr("resolver2");
        attacker = makeAddr("attacker");

        // Deploy implementation
        implementation = new TAGITCore();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy erc1967Proxy = new ERC1967Proxy(address(implementation), initData);
        proxy = TAGITCore(address(erc1967Proxy));

        // Deploy access control
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Set access controller via owner
        vm.prank(owner);
        proxy.setAccessController(address(tagitAccess));

        // Grant manufacturer all capabilities
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.BINDER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.ACTIVATOR_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.CLAIMER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.RESOLVER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(proxy.RECYCLER_CAPABILITY()));

        // Grant RESOLVER_CAPABILITY to resolver2 (second resolver for quorum)
        capabilityBadge.grantCapability(resolver2, uint256(proxy.RESOLVER_CAPABILITY()));
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialize_setsOwner() public view {
        assertEq(proxy.owner(), owner);
    }

    function test_initialize_setsERC721Name() public view {
        assertEq(proxy.name(), "TAG IT Digital Twin");
    }

    function test_initialize_setsERC721Symbol() public view {
        assertEq(proxy.symbol(), "TAGIT");
    }

    function test_initialize_startsTokenIdAt1() public {
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);
        assertEq(tokenId, 1);
    }

    function test_initialize_totalSupplyStartsAtZero() public view {
        assertEq(proxy.totalSupply(), 0);
    }

    function test_initialize_revertsOnZeroAddress() public {
        TAGITCore newImpl = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (address(0)));
        vm.expectRevert(TAGITCore.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        proxy.initialize(attacker);
    }

    function test_initialize_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(attacker);
    }

    // ============================================
    // PROXY DELEGATION TESTS
    // ============================================

    function test_proxy_getImplementation() public view {
        assertEq(proxy.getImplementation(), address(implementation));
    }

    function test_proxy_mintWorksThroughProxy() public {
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);
        assertEq(tokenId, 1);
        assertEq(proxy.ownerOf(1), manufacturer);
    }

    function test_proxy_fullLifecycleThroughProxy() public {
        // Mint
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);

        // Bind
        vm.prank(manufacturer);
        proxy.bindTag(tokenId, TAG_HASH);

        // Activate
        vm.prank(manufacturer);
        proxy.activate(tokenId);

        // Claim
        address consumer = makeAddr("consumer");
        vm.prank(manufacturer);
        proxy.claim(tokenId, consumer);

        // Verify state
        (address assetOwner,, TAGITCore.State state,,) = proxy.getAsset(tokenId);
        assertEq(assetOwner, consumer);
        assertEq(uint8(state), uint8(TAGITCore.State.CLAIMED));

        // Flag
        vm.prank(manufacturer);
        proxy.flag(tokenId);

        // Approve resolve (2-of-3 quorum)
        vm.prank(manufacturer);
        proxy.approveResolve(tokenId, consumer);
        vm.prank(resolver2);
        proxy.approveResolve(tokenId, consumer);

        // Resolve
        vm.prank(manufacturer);
        proxy.resolve(tokenId, consumer);

        // Recycle
        vm.prank(manufacturer);
        proxy.recycle(tokenId);

        // Verify terminal state
        (,, TAGITCore.State finalState,,) = proxy.getAsset(tokenId);
        assertEq(uint8(finalState), uint8(TAGITCore.State.RECYCLED));
    }

    function test_proxy_tagBindingPersistsThroughProxy() public {
        vm.prank(manufacturer);
        uint256 tokenId = proxy.mint(manufacturer, METADATA);

        vm.prank(manufacturer);
        proxy.bindTag(tokenId, TAG_HASH);

        assertEq(proxy.getTokenByTag(TAG_HASH), tokenId);
        assertEq(proxy.getTagByToken(tokenId), TAG_HASH);
    }

    function test_proxy_multipleMintsThroughProxy() public {
        vm.startPrank(manufacturer);
        uint256 id1 = proxy.mint(manufacturer, keccak256("asset1"));
        uint256 id2 = proxy.mint(manufacturer, keccak256("asset2"));
        uint256 id3 = proxy.mint(manufacturer, keccak256("asset3"));
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(proxy.totalSupply(), 3);
    }

    // ============================================
    // STORAGE LAYOUT TESTS
    // ============================================

    function test_storage_accessControllerPreserved() public view {
        assertEq(address(proxy.accessController()), address(tagitAccess));
    }

    function test_storage_circuitBreakerInitialized() public view {
        (bool isTripped,) = proxy.getFlagCircuitBreakerStatus();
        assertEq(isTripped, false);
    }

    function test_storage_rateLimiterInitialized() public view {
        (bool canMint,,) = proxy.getMintRateLimitStatus(manufacturer);
        assertEq(canMint, true);
    }

    function test_storage_capacityCorrect() public view {
        uint256 capacity = proxy.getFlagCircuitBreakerCapacity();
        assertEq(capacity, 50);
    }

    // ============================================
    // ADMIN FUNCTION TESTS (owner-only)
    // ============================================

    function test_admin_setAccessController_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        proxy.setAccessController(address(0));
    }

    function test_admin_resetCircuitBreaker_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        proxy.resetFlagCircuitBreaker();
    }

    function test_admin_unlockMinter_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        proxy.unlockMinter(manufacturer);
    }

    function test_admin_setThreshold_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        proxy.setFlagCircuitBreakerThreshold(100);
    }

    function test_admin_setRateLimitEnabled_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        proxy.setMintRateLimitEnabled(false);
    }

    function test_admin_ownerCanSetAccessController() public {
        vm.prank(owner);
        proxy.setAccessController(address(0));
        assertEq(address(proxy.accessController()), address(0));
    }

    function test_admin_ownerCanResetCircuitBreaker() public {
        vm.prank(owner);
        proxy.resetFlagCircuitBreaker();
    }

    function test_admin_ownerCanSetThreshold() public {
        vm.prank(owner);
        proxy.setFlagCircuitBreakerThreshold(100);
    }

    function test_admin_ownerCanSetRateLimitEnabled() public {
        vm.prank(owner);
        proxy.setMintRateLimitEnabled(false);
    }
}
