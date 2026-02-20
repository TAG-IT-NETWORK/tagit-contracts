// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core contracts
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";

// Token contracts
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITEmissions} from "../../src/token/TAGITEmissions.sol";
import {TAGITBurner} from "../../src/token/TAGITBurner.sol";
import {TAGITStaking} from "../../src/token/TAGITStaking.sol";
import {TAGITVesting} from "../../src/token/TAGITVesting.sol";

// Other contracts
import {TAGITRecovery} from "../../src/recovery/TAGITRecovery.sol";
import {TAGITPrograms} from "../../src/programs/TAGITPrograms.sol";
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";

/**
 * @title IntegrationBase
 * @notice Base contract for integration tests with full system deployment
 * @dev Deploys all TAG IT contracts with proper wiring
 */
abstract contract IntegrationBase is Test {
    // ============================================
    // CONTRACTS
    // ============================================

    // Access control
    TAGITAccess public access;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    // Core
    TAGITCore public core;

    // Token suite
    TAGITToken public token;
    TAGITEmissions public emissions;
    TAGITBurner public burner;
    TAGITStaking public staking;
    TAGITVesting public vesting;

    // Other
    TAGITRecovery public recovery;
    TAGITPrograms public programs;
    TAGITTreasury public treasury;

    // ============================================
    // TEST ACTORS
    // ============================================

    address public owner;
    address public governor;
    address public manufacturer;
    address public qaInspector;
    address public verifier;
    address public consumer1;
    address public consumer2;
    address public lawEnforcement;
    address public lawEnforcement2;
    address public recycler;

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 public constant INITIAL_TOKEN_SUPPLY = 100_000_000 ether;
    uint256 public constant USER_INITIAL_BALANCE = 100_000 ether;

    // Capability IDs (must match TAGITCore capability hashes)
    uint256 public constant CAP_MINT = uint256(keccak256("MINTER"));
    uint256 public constant CAP_BIND = uint256(keccak256("BINDER"));
    uint256 public constant CAP_ACTIVATE = uint256(keccak256("ACTIVATOR"));
    uint256 public constant CAP_CLAIM = uint256(keccak256("CLAIMER"));
    uint256 public constant CAP_FLAG = uint256(keccak256("FLAGGER"));
    uint256 public constant CAP_RESOLVE = uint256(keccak256("RESOLVER"));
    uint256 public constant CAP_RECYCLE = uint256(keccak256("RECYCLER"));

    // Identity badge IDs
    uint256 public constant BADGE_MANUFACTURER = 10;
    uint256 public constant BADGE_VERIFIER = 11;
    uint256 public constant BADGE_LAW_ENFORCEMENT = 21;

    // Recovery voting badge IDs (must match TAGITRecovery constants)
    uint256 public constant VOTE_BADGE_VERIFIER = 1;
    uint256 public constant VOTE_BADGE_MANUFACTURER = 10;
    uint256 public constant VOTE_BADGE_GOVERNANCE = 20;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public virtual {
        // Create test accounts
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        manufacturer = makeAddr("manufacturer");
        qaInspector = makeAddr("qaInspector");
        verifier = makeAddr("verifier");
        consumer1 = makeAddr("consumer1");
        consumer2 = makeAddr("consumer2");
        lawEnforcement = makeAddr("lawEnforcement");
        lawEnforcement2 = makeAddr("lawEnforcement2");
        recycler = makeAddr("recycler");

        vm.startPrank(owner);

        // Deploy badge contracts (non-upgradeable)
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();

        // Deploy TAGITAccess (non-upgradeable)
        access = new TAGITAccess();
        access.setIdentityBadge(address(identityBadge));
        access.setCapabilityBadge(address(capabilityBadge));

        // Deploy TAGITToken (upgradeable)
        token = _deployToken();

        // Deploy TAGITCore (upgradeable)
        core = _deployCore();

        // Deploy token suite
        staking = _deployStaking();
        emissions = _deployEmissions();
        burner = _deployBurner();

        // Deploy vesting (non-upgradeable)
        vesting = new TAGITVesting(address(token), owner);

        // Deploy treasury
        treasury = _deployTreasury();

        // Deploy programs
        programs = _deployPrograms();

        // Deploy recovery
        recovery = _deployRecovery();

        // Wire up contracts
        _wireContracts();

        // Setup roles
        _setupRoles();

        // Fund test users
        _fundUsers();

        vm.stopPrank();
    }

    // ============================================
    // DEPLOYMENT HELPERS
    // ============================================

    function _deployToken() internal returns (TAGITToken) {
        TAGITToken impl = new TAGITToken();
        bytes memory initData = abi.encodeWithSelector(
            TAGITToken.initialize.selector,
            owner, // treasury (temporary, will be updated)
            owner  // initialOwner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return TAGITToken(address(proxy));
    }

    function _deployCore() internal returns (TAGITCore) {
        // TAGITCore (upgradeable via UUPS proxy)
        TAGITCore impl = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        TAGITCore _core = TAGITCore(address(proxy));
        _core.setAccessController(address(access));
        return _core;
    }

    function _deployStaking() internal returns (TAGITStaking) {
        TAGITStaking impl = new TAGITStaking();
        bytes memory initData = abi.encodeWithSelector(
            TAGITStaking.initialize.selector,
            address(token),
            governor,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return TAGITStaking(address(proxy));
    }

    function _deployEmissions() internal returns (TAGITEmissions) {
        TAGITEmissions impl = new TAGITEmissions();
        bytes memory initData = abi.encodeWithSelector(
            TAGITEmissions.initialize.selector,
            address(token),
            governor,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return TAGITEmissions(address(proxy));
    }

    function _deployBurner() internal returns (TAGITBurner) {
        TAGITBurner impl = new TAGITBurner();
        bytes memory initData = abi.encodeWithSelector(
            TAGITBurner.initialize.selector,
            address(token),
            owner, // treasury (temporary)
            governor,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return TAGITBurner(address(proxy));
    }

    function _deployTreasury() internal returns (TAGITTreasury) {
        TAGITTreasury impl = new TAGITTreasury();
        address[] memory initialSigners = new address[](1);
        initialSigners[0] = owner;
        bytes memory initData = abi.encodeWithSelector(
            TAGITTreasury.initialize.selector,
            governor,
            address(token),
            initialSigners
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return TAGITTreasury(payable(address(proxy)));
    }

    function _deployPrograms() internal returns (TAGITPrograms) {
        TAGITPrograms impl = new TAGITPrograms();
        bytes memory initData = abi.encodeWithSelector(
            TAGITPrograms.initialize.selector,
            address(token),
            address(core),
            address(access),
            address(staking),
            governor,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return TAGITPrograms(address(proxy));
    }

    function _deployRecovery() internal returns (TAGITRecovery) {
        TAGITRecovery impl = new TAGITRecovery();
        bytes memory initData = abi.encodeWithSelector(
            TAGITRecovery.initialize.selector,
            address(core),
            address(access),
            address(token),
            governor,
            address(treasury),
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return TAGITRecovery(address(proxy));
    }

    function _wireContracts() internal {
        // Set emissions address on token
        token.setEmissionsAddress(address(emissions));

        // Set emissions on staking
        staking.setEmissions(address(emissions));

        // Update burner treasury
        vm.stopPrank();
        vm.prank(governor);
        burner.setTreasury(address(treasury));
        vm.startPrank(owner);
    }

    function _setupRoles() internal {
        // Grant manufacturer capabilities
        capabilityBadge.grantCapability(manufacturer, CAP_MINT);
        capabilityBadge.grantCapability(manufacturer, CAP_BIND);

        // Grant QA inspector capability
        capabilityBadge.grantCapability(qaInspector, CAP_ACTIVATE);

        // Grant verifier capabilities
        capabilityBadge.grantCapability(verifier, CAP_CLAIM);

        // Grant law enforcement capabilities
        capabilityBadge.grantCapability(lawEnforcement, CAP_FLAG);
        capabilityBadge.grantCapability(lawEnforcement, CAP_RESOLVE);

        // Grant law enforcement 2 resolver capability (second resolver for quorum)
        capabilityBadge.grantCapability(lawEnforcement2, CAP_RESOLVE);

        // Grant recycler capability
        capabilityBadge.grantCapability(recycler, CAP_RECYCLE);

        // Grant identity badges
        identityBadge.grantIdentity(manufacturer, BADGE_MANUFACTURER);
        identityBadge.grantIdentity(verifier, BADGE_VERIFIER);
        identityBadge.grantIdentity(lawEnforcement, BADGE_LAW_ENFORCEMENT);

        // Grant recovery voting capability badges
        capabilityBadge.grantCapability(verifier, VOTE_BADGE_VERIFIER);
        capabilityBadge.grantCapability(manufacturer, VOTE_BADGE_MANUFACTURER);
    }

    function _fundUsers() internal {
        // Token was already minted to owner during initialization
        // Owner has the initial supply - just transfer to test users

        // Fund test users
        token.transfer(consumer1, USER_INITIAL_BALANCE);
        token.transfer(consumer2, USER_INITIAL_BALANCE);
        token.transfer(manufacturer, USER_INITIAL_BALANCE);
        token.transfer(verifier, USER_INITIAL_BALANCE);

        // Fund treasury
        token.transfer(address(treasury), 10_000_000 ether);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    uint256 private _assetCounter;

    /// @notice Mint and fully activate an asset
    function _mintActivatedAsset(address to) internal returns (uint256 tokenId) {
        _assetCounter++;
        bytes32 metadata = keccak256(abi.encodePacked("metadata", block.timestamp, _assetCounter));
        bytes32 tagHash = keccak256(abi.encodePacked("tag", block.timestamp, _assetCounter));

        vm.prank(manufacturer);
        tokenId = core.mint(to, metadata);

        vm.prank(manufacturer);
        core.bindTag(tokenId, tagHash);

        vm.prank(qaInspector);
        core.activate(tokenId);

        return tokenId;
    }

    /// @notice Mint, activate, and claim an asset
    function _mintClaimedAsset(address to) internal returns (uint256 tokenId) {
        tokenId = _mintActivatedAsset(to);

        vm.prank(verifier);
        core.claim(tokenId, to);

        return tokenId;
    }
}
