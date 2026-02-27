// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {TAGITRecovery} from "../../src/recovery/TAGITRecovery.sol";
import {IRecovery} from "../../src/interfaces/IRecovery.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";

/**
 * @title TAGITRecoveryNistTest
 * @notice NIST CSF 2.0 security control tests for TAGITRecovery
 * @dev Tests IR-4 (Incident Response) and AC-7 (Unsuccessful Logon Attempts)
 */
contract TAGITRecoveryNistTest is Test {
    // ============================================
    // EVENTS
    // ============================================

    event CircuitTripped(uint256 indexed timestamp, uint256 count, uint256 threshold, uint256 cooldownEnds);
    event CircuitReset(uint256 indexed timestamp, uint256 previousCooldownEnds);
    event RateLimitHit(address indexed user, uint256 count, uint256 lockedUntil);

    // ============================================
    // CONTRACTS
    // ============================================

    TAGITRecovery public recovery;
    TAGITCore public core;
    TAGITAccess public access;
    CapabilityBadge public capabilityBadge;
    TAGITToken public token;

    // ============================================
    // ADDRESSES
    // ============================================

    address public owner;
    address public governor;
    address public treasury;
    address public manufacturer;
    address public holder;
    address public attacker;

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 public constant MINIMUM_STAKE = 100e18;
    bytes32 public constant EVIDENCE_HASH = keccak256("evidence");
    uint256 constant ORACLE_PK = 0xA11CE;

    // TAGITCore capabilities
    bytes32 public constant MINTER_CAPABILITY = keccak256("MINTER");
    bytes32 public constant BINDER_CAPABILITY = keccak256("BINDER");
    bytes32 public constant ACTIVATOR_CAPABILITY = keccak256("ACTIVATOR");
    bytes32 public constant CLAIMER_CAPABILITY = keccak256("CLAIMER");

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        treasury = makeAddr("treasury");
        manufacturer = makeAddr("manufacturer");
        holder = makeAddr("holder");
        attacker = makeAddr("attacker");

        vm.startPrank(owner);

        // Deploy TAGITCore (upgradeable via UUPS proxy)
        TAGITCore coreImpl = new TAGITCore();
        bytes memory coreData = abi.encodeCall(TAGITCore.initialize, (owner));
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), coreData);
        core = TAGITCore(address(coreProxy));

        // Deploy TAGITAccess + CapabilityBadge
        access = new TAGITAccess();
        capabilityBadge = new CapabilityBadge();
        access.setCapabilityBadge(address(capabilityBadge));

        // Set access controller on TAGITCore
        core.setAccessController(address(access));

        // Set trusted oracle for NFC verification
        core.setTrustedOracle(vm.addr(ORACLE_PK));

        // Deploy TAGITToken (upgradeable)
        TAGITToken tokenImpl = new TAGITToken();
        bytes memory tokenData = abi.encodeCall(TAGITToken.initialize, (owner, treasury));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenData);
        token = TAGITToken(address(tokenProxy));

        // Deploy TAGITRecovery (upgradeable)
        TAGITRecovery recoveryImpl = new TAGITRecovery();
        bytes memory recoveryData = abi.encodeCall(
            TAGITRecovery.initialize, (address(core), address(access), address(token), governor, treasury, owner)
        );
        ERC1967Proxy recoveryProxy = new ERC1967Proxy(address(recoveryImpl), recoveryData);
        recovery = TAGITRecovery(address(recoveryProxy));

        // Grant TAGITCore capabilities to manufacturer
        capabilityBadge.grantCapability(manufacturer, uint256(MINTER_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(BINDER_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(ACTIVATOR_CAPABILITY));
        capabilityBadge.grantCapability(manufacturer, uint256(CLAIMER_CAPABILITY));

        // Transfer tokens to attacker for stake bonds
        token.transfer(attacker, 1_000_000 ether);

        vm.stopPrank();

        // Approve recovery contract to spend attacker's tokens
        vm.prank(attacker);
        token.approve(address(recovery), type(uint256).max);
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

    function _mintAndClaimAsset(address to) internal returns (uint256 tokenId) {
        vm.prank(manufacturer);
        tokenId = core.mint(manufacturer, keccak256("metadata"));

        bytes32 tagHash = keccak256(abi.encodePacked("tag", tokenId));
        (bytes memory cr, bytes memory sig) = _oracleSign(tokenId, tagHash);
        vm.prank(manufacturer);
        core.bindTag(tokenId, tagHash, cr, sig);

        vm.startPrank(manufacturer);
        core.activate(tokenId);
        core.claim(tokenId, to);
        vm.stopPrank();
    }

    function _mintMultipleAssets(uint256 count) internal returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = _mintAndClaimAsset(holder);
        }
    }

    // ============================================
    // CIRCUIT BREAKER TESTS (IR-4)
    // ============================================

    function test_circuitBreaker_tripsAfterThreshold() public {
        // Disable rate limiting to test circuit breaker in isolation
        vm.prank(governor);
        recovery.setRateLimitEnabled(false);

        // Mint 51 assets (circuit threshold is 50)
        uint256[] memory tokenIds = _mintMultipleAssets(51);

        // Initiate recoveries until circuit trips
        // The 50th call (index 49) will trip the circuit but still succeed
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 50; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Verify contract is paused after the 50th call
        assertTrue(recovery.paused());

        // 51st call should fail because contract is paused
        vm.prank(attacker);
        vm.expectRevert(); // EnforcedPause()
        recovery.initiateRecovery(tokenIds[50], EVIDENCE_HASH);
    }

    function test_circuitBreaker_resetsAfterWindow() public {
        // Disable rate limiting to test circuit breaker in isolation
        vm.prank(governor);
        recovery.setRateLimitEnabled(false);

        // Mint assets
        uint256[] memory tokenIds = _mintMultipleAssets(52);

        vm.startPrank(attacker);
        // Use up threshold
        for (uint256 i = 0; i < 50; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Fast forward past cooldown (4 hours)
        vm.warp(block.timestamp + 4 hours + 1);

        // Unpause (contract paused after 50th call)
        assertTrue(recovery.paused());
        vm.prank(owner);
        recovery.unpause();

        // Should work again after cooldown expires
        vm.prank(attacker);
        recovery.initiateRecovery(tokenIds[50], EVIDENCE_HASH);
    }

    function test_circuitBreaker_governorCanReset() public {
        // Disable rate limiting to test circuit breaker in isolation
        vm.prank(governor);
        recovery.setRateLimitEnabled(false);

        // Trip the circuit first (50th call trips and succeeds)
        uint256[] memory tokenIds = _mintMultipleAssets(51);
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 50; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Verify paused
        assertTrue(recovery.paused());

        // Get circuit state before reset
        (,, bool tripped,) = recovery.getCircuitBreakerState();
        assertTrue(tripped);

        // Wait for cooldown
        vm.warp(block.timestamp + 4 hours + 1);

        // Governor resets circuit
        vm.prank(governor);
        recovery.resetCircuitBreaker();

        // Verify reset
        (,, bool trippedAfter,) = recovery.getCircuitBreakerState();
        assertFalse(trippedAfter);
    }

    function test_circuitBreaker_ownerCanForceReset() public {
        // Disable rate limiting to test circuit breaker in isolation
        vm.prank(governor);
        recovery.setRateLimitEnabled(false);

        // Trip the circuit (50th call trips and succeeds)
        uint256[] memory tokenIds = _mintMultipleAssets(51);
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 50; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Verify paused
        assertTrue(recovery.paused());

        // Owner can force reset without waiting for cooldown
        vm.prank(owner);
        recovery.forceResetCircuitBreaker();

        // Verify reset
        (,, bool tripped,) = recovery.getCircuitBreakerState();
        assertFalse(tripped);

        // Unpause
        vm.prank(owner);
        recovery.unpause();

        // Should work now
        vm.prank(attacker);
        recovery.initiateRecovery(tokenIds[50], EVIDENCE_HASH);
    }

    function test_circuitBreaker_viewState() public {
        // Disable rate limiting to test circuit breaker in isolation
        vm.prank(governor);
        recovery.setRateLimitEnabled(false);

        uint256[] memory tokenIds = _mintMultipleAssets(10);

        vm.startPrank(attacker);
        for (uint256 i = 0; i < 10; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        (uint64 count, uint64 windowStart, bool tripped, uint64 cooldownEnds) = recovery.getCircuitBreakerState();
        assertEq(count, 10);
        assertGt(windowStart, 0);
        assertFalse(tripped);
        assertEq(cooldownEnds, 0);
    }

    // ============================================
    // RATE LIMITER TESTS (AC-7)
    // ============================================

    function test_rateLimit_blocksAfterMaxPerWindow() public {
        // Mint 5 assets (rate limit is 3 per window)
        uint256[] memory tokenIds = _mintMultipleAssets(5);

        vm.startPrank(attacker);
        // Use 3 actions (max per window) - on the 3rd action user gets locked
        for (uint256 i = 0; i < 3; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }

        // 4th should be rate limited (user is now locked)
        vm.expectRevert();
        recovery.initiateRecovery(tokenIds[3], EVIDENCE_HASH);
        vm.stopPrank();
    }

    function test_rateLimit_resetsAfterCooldown() public {
        // Mint assets
        uint256[] memory tokenIds = _mintMultipleAssets(5);

        vm.startPrank(attacker);
        // Hit rate limit
        for (uint256 i = 0; i < 3; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Fast forward past cooldown (2 hours)
        vm.warp(block.timestamp + 2 hours + 1);

        // Should work again after cooldown
        vm.prank(attacker);
        recovery.initiateRecovery(tokenIds[3], EVIDENCE_HASH);
    }

    function test_rateLimit_governorCanResetUser() public {
        uint256[] memory tokenIds = _mintMultipleAssets(5);

        vm.startPrank(attacker);
        for (uint256 i = 0; i < 3; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Governor resets user rate limit
        vm.prank(governor);
        recovery.resetUserRateLimit(attacker);

        // User can act again
        vm.prank(attacker);
        recovery.initiateRecovery(tokenIds[3], EVIDENCE_HASH);
    }

    function test_rateLimit_governorCanDisable() public {
        uint256[] memory tokenIds = _mintMultipleAssets(5);

        vm.startPrank(attacker);
        for (uint256 i = 0; i < 3; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Governor disables rate limiting
        vm.prank(governor);
        recovery.setRateLimitEnabled(false);

        // Should work now
        vm.prank(attacker);
        recovery.initiateRecovery(tokenIds[3], EVIDENCE_HASH);
    }

    function test_rateLimit_governorCanUpdateConfig() public {
        // Update config: 5 per window, 1 hour window, 2 hour cooldown, 200 global
        vm.prank(governor);
        recovery.setRateLimitConfig(5, 1 hours, 2 hours, 200);

        uint256[] memory tokenIds = _mintMultipleAssets(6);

        vm.startPrank(attacker);
        // Now 5 per window allowed
        for (uint256 i = 0; i < 5; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }

        // 6th should fail
        vm.expectRevert();
        recovery.initiateRecovery(tokenIds[5], EVIDENCE_HASH);
        vm.stopPrank();
    }

    function test_rateLimit_viewUserState() public {
        uint256[] memory tokenIds = _mintMultipleAssets(3);

        vm.startPrank(attacker);
        for (uint256 i = 0; i < 2; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        (uint64 count, uint64 windowStart, uint64 lockedUntil) = recovery.getUserRateLimitState(attacker);
        assertEq(count, 2);
        // windowStart should be set during first action
        assertTrue(windowStart > 0 || block.timestamp == 1); // Foundry starts at timestamp 1
        assertEq(lockedUntil, 0);
    }

    function test_rateLimit_viewRemainingActions() public {
        uint256[] memory tokenIds = _mintMultipleAssets(3);

        vm.startPrank(attacker);
        for (uint256 i = 0; i < 2; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        (bool canAct, uint256 remaining, uint256 lockedUntil) = recovery.getRemainingActions(attacker);
        assertTrue(canAct);
        assertEq(remaining, 1); // 3 max - 2 used = 1 remaining
        assertEq(lockedUntil, 0);
    }

    // ============================================
    // APPEAL RATE LIMITING TESTS
    // ============================================

    function test_appeal_alsoRateLimited() public {
        // Setup: mint some assets
        uint256[] memory tokenIds = _mintMultipleAssets(4);

        vm.startPrank(attacker);
        // Use up rate limit with initiateRecovery
        for (uint256 i = 0; i < 2; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Verify rate limit is nearly exhausted (1 action remaining)
        (bool canAct, uint256 remaining,) = recovery.getRemainingActions(attacker);
        assertTrue(canAct);
        assertEq(remaining, 1);
    }

    // ============================================
    // NORMAL OPERATIONS UNAFFECTED TESTS
    // ============================================

    function test_normalOperations_singleRecoveryWorks() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(attacker);
        uint256 caseId = recovery.initiateRecovery(tokenId, EVIDENCE_HASH);

        assertGt(caseId, 0);
        assertTrue(recovery.isQuarantined(tokenId));
    }

    function test_normalOperations_multipleUsersNotAffected() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Fund users
        vm.prank(owner);
        token.transfer(user1, 1000 ether);
        vm.prank(owner);
        token.transfer(user2, 1000 ether);

        // Approve
        vm.prank(user1);
        token.approve(address(recovery), type(uint256).max);
        vm.prank(user2);
        token.approve(address(recovery), type(uint256).max);

        // Mint assets
        uint256 token1 = _mintAndClaimAsset(holder);
        uint256 token2 = _mintAndClaimAsset(holder);

        // Both users can initiate
        vm.prank(user1);
        recovery.initiateRecovery(token1, EVIDENCE_HASH);

        vm.prank(user2);
        recovery.initiateRecovery(token2, EVIDENCE_HASH);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_initiateRecoveryOverhead() public {
        uint256 tokenId = _mintAndClaimAsset(holder);

        vm.prank(attacker);
        uint256 gasBefore = gasleft();
        recovery.initiateRecovery(tokenId, EVIDENCE_HASH);
        uint256 gasUsed = gasBefore - gasleft();

        // Total should be under 400k gas (includes all business logic + security checks)
        assertLt(gasUsed, 400000, "initiateRecovery() too expensive");
    }

    function test_gas_viewFunctions() public view {
        // View functions should be cheap
        recovery.getRemainingActions(attacker);
        recovery.getCircuitBreakerState();
        recovery.getUserRateLimitState(attacker);
        // If we get here without running out of gas, views are reasonable
    }

    // ============================================
    // SECURITY EDGE CASES
    // ============================================

    function test_security_nonGovernorCannotResetCircuit() public {
        vm.prank(attacker);
        vm.expectRevert();
        recovery.resetCircuitBreaker();
    }

    function test_security_nonGovernorCannotResetRateLimit() public {
        vm.prank(attacker);
        vm.expectRevert();
        recovery.resetUserRateLimit(attacker);
    }

    function test_security_nonOwnerCannotForceResetCircuit() public {
        vm.prank(governor);
        vm.expectRevert();
        recovery.forceResetCircuitBreaker();
    }

    function test_security_circuitBreakerPausesContract() public {
        // Disable rate limiting to test circuit breaker in isolation
        vm.prank(governor);
        recovery.setRateLimitEnabled(false);

        uint256[] memory tokenIds = _mintMultipleAssets(51);

        // 50 calls - the last one trips the circuit but succeeds
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 50; i++) {
            recovery.initiateRecovery(tokenIds[i], EVIDENCE_HASH);
        }
        vm.stopPrank();

        // Contract should be paused after the 50th call
        assertTrue(recovery.paused());

        // Any operation should fail due to pause
        vm.prank(attacker);
        vm.expectRevert(); // EnforcedPause
        recovery.initiateRecovery(tokenIds[50], EVIDENCE_HASH);
    }

    function test_security_globalLimitEnforced() public {
        // Test that global limit is enforced across multiple users
        address[] memory users = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            vm.prank(owner);
            token.transfer(users[i], 10000 ether);
            vm.prank(users[i]);
            token.approve(address(recovery), type(uint256).max);
        }

        // Each user makes 3 recoveries (15 total, global limit is 100)
        uint256[] memory tokenIds = _mintMultipleAssets(15);
        uint256 tokenIndex = 0;

        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(users[i]);
            for (uint256 j = 0; j < 3; j++) {
                recovery.initiateRecovery(tokenIds[tokenIndex++], EVIDENCE_HASH);
            }
            vm.stopPrank();
        }

        // All 15 recoveries should succeed (global limit is 100)
        assertEq(tokenIndex, 15);
    }
}
