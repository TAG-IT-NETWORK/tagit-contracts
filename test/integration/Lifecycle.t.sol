// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title LifecycleIntegrationTest
 * @notice Integration tests for full asset lifecycle scenarios
 * @dev Tests cross-contract interactions between TAGITCore, TAGITAccess, and badges
 */
contract LifecycleIntegrationTest is Test {
    uint256 constant ORACLE_PK = 0xA11CE;

    TAGITCore public tagitCore;
    TAGITAccess public tagitAccess;
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;

    // Test accounts with different roles
    address public owner;
    address public manufacturer;
    address public qaInspector;
    address public distributor;
    address public consumer;
    address public lawEnforcement;
    address public lawEnforcement2;
    address public recycler;
    address public unauthorizedUser;

    // Test data
    bytes32 public constant METADATA = keccak256("ipfs://QmTestProduct123");
    bytes32 public constant TAG_HASH = keccak256("NFC_UID_ABC123DEF456");

    // Events
    event AssetMinted(uint256 indexed tokenId, address indexed to, bytes32 metadata);
    event StateChanged(uint256 indexed tokenId, TAGITCore.State from, TAGITCore.State to, address actor);
    event TagBound(uint256 indexed tokenId, bytes32 indexed tagHash);

    function setUp() public {
        // Create role-based test accounts
        owner = makeAddr("owner");
        manufacturer = makeAddr("manufacturer");
        qaInspector = makeAddr("qaInspector");
        distributor = makeAddr("distributor");
        consumer = makeAddr("consumer");
        lawEnforcement = makeAddr("lawEnforcement");
        lawEnforcement2 = makeAddr("lawEnforcement2");
        recycler = makeAddr("recycler");
        unauthorizedUser = makeAddr("unauthorizedUser");

        // Deploy badge contracts
        identityBadge = new IdentityBadge();
        capabilityBadge = new CapabilityBadge();

        // Deploy TAGITAccess facade
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));

        // Deploy TAGITCore (upgradeable via UUPS proxy)
        TAGITCore implementation = new TAGITCore();
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tagitCore = TAGITCore(address(proxy));

        vm.prank(owner);
        tagitCore.setAccessController(address(tagitAccess));

        // Set trusted oracle for NFC verification
        vm.prank(owner);
        tagitCore.setTrustedOracle(vm.addr(ORACLE_PK));

        // Set up role-based capabilities
        _setupRoleCapabilities();
    }

    function _setupRoleCapabilities() internal {
        // Manufacturer: can mint and bind tags
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY()));
        capabilityBadge.grantCapability(manufacturer, uint256(tagitCore.BINDER_CAPABILITY()));

        // QA Inspector: can activate
        capabilityBadge.grantCapability(qaInspector, uint256(tagitCore.ACTIVATOR_CAPABILITY()));

        // Distributor: can claim (transfer to consumer)
        capabilityBadge.grantCapability(distributor, uint256(tagitCore.CLAIMER_CAPABILITY()));

        // Law Enforcement: can flag and resolve
        capabilityBadge.grantCapability(lawEnforcement, uint256(tagitCore.FLAGGER_CAPABILITY()));
        capabilityBadge.grantCapability(lawEnforcement, uint256(tagitCore.RESOLVER_CAPABILITY()));

        // Law Enforcement 2: second resolver for quorum
        capabilityBadge.grantCapability(lawEnforcement2, uint256(tagitCore.RESOLVER_CAPABILITY()));

        // Recycler: can recycle
        capabilityBadge.grantCapability(recycler, uint256(tagitCore.RECYCLER_CAPABILITY()));
    }

    // ============================================
    // SCENARIO 1: Happy Path - Full Lifecycle
    // ============================================

    /**
     * @notice Test complete happy path: mint → bind → activate → claim → recycle
     * @dev Simulates normal product lifecycle from manufacturing to end-of-life
     */
    function test_scenario_happyPath() public {
        // Step 1: Manufacturer mints Digital Twin
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA);
        assertEq(tokenId, 1, "First token should be ID 1");

        _verifyState(tokenId, TAGITCore.State.MINTED);
        assertEq(tagitCore.ownerOf(tokenId), manufacturer, "Manufacturer should own token");

        // Step 2: Manufacturer binds NFC tag
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, TAG_HASH, cr, sig);

        _verifyState(tokenId, TAGITCore.State.BOUND);
        assertEq(tagitCore.getTagByToken(tokenId), TAG_HASH, "Tag should be bound");
        assertEq(tagitCore.getTokenByTag(TAG_HASH), tokenId, "Token should map to tag");

        // Step 3: QA Inspector activates after quality check
        vm.prank(qaInspector);
        tagitCore.activate(tokenId);

        _verifyState(tokenId, TAGITCore.State.ACTIVATED);

        // Step 4: Distributor transfers to consumer
        vm.prank(distributor);
        tagitCore.claim(tokenId, consumer);

        _verifyState(tokenId, TAGITCore.State.CLAIMED);
        assertEq(tagitCore.ownerOf(tokenId), consumer, "Consumer should own token");

        // Step 5: Consumer recycles at end-of-life (via authorized recycler)
        vm.prank(recycler);
        tagitCore.recycle(tokenId);

        _verifyState(tokenId, TAGITCore.State.RECYCLED);
        // Owner remains unchanged after recycle
        assertEq(tagitCore.ownerOf(tokenId), consumer, "Consumer still owns recycled token");
    }

    // ============================================
    // SCENARIO 2: Dispute Path - Flag and Resolve
    // ============================================

    /**
     * @notice Test dispute path: mint → ... → claim → flag → resolve
     * @dev Simulates lost/stolen asset recovery via AIRP
     */
    function test_scenario_disputePath() public {
        // Setup: Complete lifecycle to CLAIMED
        uint256 tokenId = _setupToClaimedState(consumer);

        // Consumer reports asset stolen
        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);

        _verifyState(tokenId, TAGITCore.State.FLAGGED);

        // Law enforcement resolves to original owner after investigation
        address originalOwner = makeAddr("originalOwner");
        vm.prank(lawEnforcement);
        tagitCore.approveResolve(tokenId, originalOwner);
        vm.prank(lawEnforcement2);
        tagitCore.approveResolve(tokenId, originalOwner);
        vm.prank(lawEnforcement);
        tagitCore.resolve(tokenId, originalOwner);

        _verifyState(tokenId, TAGITCore.State.CLAIMED);
        assertEq(tagitCore.ownerOf(tokenId), originalOwner, "Original owner should have token");
    }

    // ============================================
    // SCENARIO 3: Flag then Recycle (Unrecoverable)
    // ============================================

    /**
     * @notice Test unrecoverable asset: claim → flag → recycle
     * @dev Simulates asset that cannot be recovered (destroyed, lost forever)
     */
    function test_scenario_flagThenRecycle() public {
        uint256 tokenId = _setupToClaimedState(consumer);

        // Flag as lost
        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);

        _verifyState(tokenId, TAGITCore.State.FLAGGED);

        // After investigation, asset is deemed unrecoverable
        vm.prank(recycler);
        tagitCore.recycle(tokenId);

        _verifyState(tokenId, TAGITCore.State.RECYCLED);
    }

    // ============================================
    // SCENARIO 4: Multiple Assets - Parallel Processing
    // ============================================

    /**
     * @notice Test parallel processing of multiple assets
     * @dev Simulates batch manufacturing workflow
     */
    function test_scenario_batchProcessing() public {
        uint256 batchSize = 10;
        uint256[] memory tokenIds = new uint256[](batchSize);

        // Batch mint
        vm.startPrank(manufacturer);
        for (uint256 i = 0; i < batchSize; i++) {
            bytes32 metadata = keccak256(abi.encodePacked("batch", i));
            tokenIds[i] = tagitCore.mint(manufacturer, metadata);
        }
        vm.stopPrank();

        assertEq(tagitCore.totalSupply(), batchSize, "Should have minted batch");

        // Batch bind
        for (uint256 i = 0; i < batchSize; i++) {
            bytes32 tagHash = keccak256(abi.encodePacked("tag", i));
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenIds[i], tagHash);
            vm.prank(manufacturer);
            tagitCore.bindTag(tokenIds[i], tagHash, cr, sig);
        }

        // Batch activate
        vm.startPrank(qaInspector);
        for (uint256 i = 0; i < batchSize; i++) {
            tagitCore.activate(tokenIds[i]);
        }
        vm.stopPrank();

        // Verify all activated
        for (uint256 i = 0; i < batchSize; i++) {
            _verifyState(tokenIds[i], TAGITCore.State.ACTIVATED);
        }
    }

    // ============================================
    // SCENARIO 5: Access Control - Role Separation
    // ============================================

    /**
     * @notice Test role-based access control enforcement
     * @dev Verifies each role can only perform authorized actions
     */
    function test_scenario_roleEnforcement() public {
        // Setup: Mint a token
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA);

        // QA Inspector cannot mint
        vm.prank(qaInspector);
        vm.expectRevert();
        tagitCore.mint(qaInspector, keccak256("unauthorized"));

        // Consumer cannot bind
        {
            bytes32 fakeTag = keccak256("fake_tag");
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, fakeTag);
            vm.prank(consumer);
            vm.expectRevert();
            tagitCore.bindTag(tokenId, fakeTag, cr, sig);
        }

        // Manufacturer binds correctly
        {
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH);
            vm.prank(manufacturer);
            tagitCore.bindTag(tokenId, TAG_HASH, cr, sig);
        }

        // Distributor cannot activate
        vm.prank(distributor);
        vm.expectRevert();
        tagitCore.activate(tokenId);

        // QA activates correctly
        vm.prank(qaInspector);
        tagitCore.activate(tokenId);

        // Unauthorized user cannot claim
        vm.prank(unauthorizedUser);
        vm.expectRevert();
        tagitCore.claim(tokenId, unauthorizedUser);

        // Distributor claims correctly
        vm.prank(distributor);
        tagitCore.claim(tokenId, consumer);

        _verifyState(tokenId, TAGITCore.State.CLAIMED);
    }

    // ============================================
    // SCENARIO 6: Capability Revocation Mid-Flow
    // ============================================

    /**
     * @notice Test capability revocation during workflow
     * @dev Verifies real-time access control updates
     */
    function test_scenario_capabilityRevocation() public {
        // Setup: Grant and verify minting works
        address tempMinter = makeAddr("tempMinter");
        capabilityBadge.grantCapability(tempMinter, uint256(tagitCore.MINTER_CAPABILITY()));

        vm.prank(tempMinter);
        uint256 tokenId1 = tagitCore.mint(tempMinter, METADATA);
        assertEq(tokenId1, 1, "First mint should work");

        // Revoke capability
        capabilityBadge.revokeCapability(tempMinter, uint256(tagitCore.MINTER_CAPABILITY()));

        // Second mint should fail
        vm.prank(tempMinter);
        vm.expectRevert();
        tagitCore.mint(tempMinter, keccak256("second"));
    }

    // ============================================
    // SCENARIO 7: Cross-Contract State Consistency
    // ============================================

    /**
     * @notice Test state consistency across TAGITCore, TAGITAccess, badges
     * @dev Verifies integrated system maintains consistent state
     */
    function test_scenario_crossContractConsistency() public {
        // Verify capability badge state
        assertTrue(
            capabilityBadge.hasCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY())),
            "Manufacturer should have MINTER capability in badge"
        );

        // Verify TAGITAccess reflects capability
        assertTrue(
            tagitAccess.hasCapability(manufacturer, uint256(tagitCore.MINTER_CAPABILITY())),
            "TAGITAccess should reflect MINTER capability"
        );

        // Verify TAGITCore respects access control
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA);

        // All systems should agree on state
        (address assetOwner,, TAGITCore.State state,,) = tagitCore.getAsset(tokenId);
        assertEq(assetOwner, manufacturer, "Asset owner correct");
        assertEq(uint8(state), uint8(TAGITCore.State.MINTED), "State correct");
        assertEq(tagitCore.ownerOf(tokenId), manufacturer, "ERC721 owner correct");
    }

    // ============================================
    // SCENARIO 8: Recovery After Multiple Flags
    // ============================================

    /**
     * @notice Test multiple flag/resolve cycles
     * @dev Simulates disputed ownership resolved multiple times
     */
    function test_scenario_multipleFlagResolveCycles() public {
        uint256 tokenId = _setupToClaimedState(consumer);

        address[] memory owners = new address[](3);
        owners[0] = makeAddr("claimant1");
        owners[1] = makeAddr("claimant2");
        owners[2] = makeAddr("finalOwner");

        // First flag/resolve
        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);
        vm.prank(lawEnforcement);
        tagitCore.approveResolve(tokenId, owners[0]);
        vm.prank(lawEnforcement2);
        tagitCore.approveResolve(tokenId, owners[0]);
        vm.prank(lawEnforcement);
        tagitCore.resolve(tokenId, owners[0]);
        assertEq(tagitCore.ownerOf(tokenId), owners[0], "First resolution");

        // Second flag/resolve
        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);
        vm.prank(lawEnforcement);
        tagitCore.approveResolve(tokenId, owners[1]);
        vm.prank(lawEnforcement2);
        tagitCore.approveResolve(tokenId, owners[1]);
        vm.prank(lawEnforcement);
        tagitCore.resolve(tokenId, owners[1]);
        assertEq(tagitCore.ownerOf(tokenId), owners[1], "Second resolution");

        // Third flag/resolve
        vm.prank(lawEnforcement);
        tagitCore.flag(tokenId);
        vm.prank(lawEnforcement);
        tagitCore.approveResolve(tokenId, owners[2]);
        vm.prank(lawEnforcement2);
        tagitCore.approveResolve(tokenId, owners[2]);
        vm.prank(lawEnforcement);
        tagitCore.resolve(tokenId, owners[2]);
        assertEq(tagitCore.ownerOf(tokenId), owners[2], "Final resolution");

        _verifyState(tokenId, TAGITCore.State.CLAIMED);
    }

    // ============================================
    // SCENARIO 9: Timestamp Progression
    // ============================================

    /**
     * @notice Test timestamp updates through lifecycle
     * @dev Verifies timestamps increase with each state change
     */
    function test_scenario_timestampProgression() public {
        vm.prank(manufacturer);
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA);
        (, uint64 ts1,,,) = tagitCore.getAsset(tokenId);

        vm.warp(block.timestamp + 1 hours);
        {
            (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, TAG_HASH);
            vm.prank(manufacturer);
            tagitCore.bindTag(tokenId, TAG_HASH, cr, sig);
        }
        (, uint64 ts2,,,) = tagitCore.getAsset(tokenId);
        assertGt(ts2, ts1, "Bind timestamp should be later");

        vm.warp(block.timestamp + 1 hours);
        vm.prank(qaInspector);
        tagitCore.activate(tokenId);
        (, uint64 ts3,,,) = tagitCore.getAsset(tokenId);
        assertGt(ts3, ts2, "Activate timestamp should be later");

        vm.warp(block.timestamp + 1 days);
        vm.prank(distributor);
        tagitCore.claim(tokenId, consumer);
        (, uint64 ts4,,,) = tagitCore.getAsset(tokenId);
        assertGt(ts4, ts3, "Claim timestamp should be later");
    }

    // ============================================
    // SCENARIO 10: Gas Efficiency Check
    // ============================================

    /**
     * @notice Verify gas usage is within expected bounds
     * @dev Documents gas costs for lifecycle operations
     */
    function test_scenario_gasEfficiency() public {
        // Mint
        vm.prank(manufacturer);
        uint256 gasBefore = gasleft();
        uint256 tokenId = tagitCore.mint(manufacturer, METADATA);
        uint256 mintGas = gasBefore - gasleft();
        assertLt(mintGas, 200000, "Mint gas should be under 200k (includes NIST AC-7 rate limit)");

        // Bind
        (bytes memory crGas, bytes memory sigGas) = _oracleSign(tokenId, TAG_HASH);
        vm.prank(manufacturer);
        gasBefore = gasleft();
        tagitCore.bindTag(tokenId, TAG_HASH, crGas, sigGas);
        uint256 bindGas = gasBefore - gasleft();
        assertLt(bindGas, 80000, "Bind gas should be under 80k");

        // Activate
        vm.prank(qaInspector);
        gasBefore = gasleft();
        tagitCore.activate(tokenId);
        uint256 activateGas = gasBefore - gasleft();
        assertLt(activateGas, 60000, "Activate gas should be under 60k");

        // Claim
        vm.prank(distributor);
        gasBefore = gasleft();
        tagitCore.claim(tokenId, consumer);
        uint256 claimGas = gasBefore - gasleft();
        assertLt(claimGas, 100000, "Claim gas should be under 100k");

        // Log gas for documentation
        console2.log("Gas - mint:", mintGas);
        console2.log("Gas - bind:", bindGas);
        console2.log("Gas - activate:", activateGas);
        console2.log("Gas - claim:", claimGas);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

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

    function _setupToClaimedState(address claimTo) internal returns (uint256 tokenId) {
        vm.prank(manufacturer);
        tokenId = tagitCore.mint(manufacturer, METADATA);

        bytes32 tagHash = keccak256(abi.encodePacked("tag", tokenId));
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        tagitCore.bindTag(tokenId, tagHash, cr, sig);

        vm.prank(qaInspector);
        tagitCore.activate(tokenId);

        vm.prank(distributor);
        tagitCore.claim(tokenId, claimTo);
    }

    function _verifyState(uint256 tokenId, TAGITCore.State expectedState) internal view {
        (,, TAGITCore.State actualState,,) = tagitCore.getAsset(tokenId);
        assertEq(uint8(actualState), uint8(expectedState), "State mismatch");
    }
}
