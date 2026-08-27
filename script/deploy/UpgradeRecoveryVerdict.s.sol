// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITRecovery} from "../../src/recovery/TAGITRecovery.sol";
import {ITAGITAccess} from "../../src/interfaces/ITAGITAccess.sol";

/**
 * @title UpgradeRecoveryVerdict
 * @author TAG IT Network <dev@tagit.network>
 * @notice TAGIT-VDP-2026-001 remediation: "AIRP is an adjudicator, not a custodian".
 *
 *   DEPLOY ORDER IS LOAD-BEARING. TAGITCore MUST be upgraded FIRST. TAGITRecovery v2
 *   calls TAGITCore.preFlagState(uint256) inside initiateRecovery(); if the Core
 *   implementation behind the proxy does not yet expose that selector, EVERY
 *   initiateRecovery() reverts. Core-first is fail-safe (Core v2 is a pure superset);
 *   Recovery-first bricks the entry point until Core catches up.
 *
 *   Both steps MUST be built with FOUNDRY_PROFILE=deploy (via-ir) — TAGITCore is at
 *   22,664 bytes runtime under that profile and 1,500 bytes OVER the EIP-170 limit
 *   without it.
 *
 *   # STEP 1 — deploy TAGITCore v2 implementation + schedule the Core upgrade
 *   FOUNDRY_PROFILE=deploy STEP=1 CORE_PROXY=0x... TIMELOCK=0x... \
 *   forge script script/deploy/UpgradeRecoveryVerdict.s.sol --rpc-url base_sepolia --broadcast --verify
 *
 *   # ... wait out the timelock delay ...
 *
 *   # STEP 2 — execute the Core upgrade
 *   FOUNDRY_PROFILE=deploy STEP=2 CORE_PROXY=0x... TIMELOCK=0x... NEW_CORE_IMPL=0x... \
 *   forge script script/deploy/UpgradeRecoveryVerdict.s.sol --rpc-url base_sepolia --broadcast
 *
 *   # STEP 3 — VERIFY the new selector answers before touching Recovery:
 *   cast call <CORE_PROXY> "preFlagState(uint256)(uint8)" 1 --rpc-url base_sepolia
 *
 *   # STEP 4 — deploy + apply the TAGITRecovery v2 implementation
 *   FOUNDRY_PROFILE=deploy STEP=4 CORE_PROXY=0x... RECOVERY_PROXY=0x... ACCESS=0x... \
 *   forge script script/deploy/UpgradeRecoveryVerdict.s.sol --rpc-url base_sepolia --broadcast --verify
 *
 * @dev SECURITY INVARIANT enforced by this script: TAGITRecovery must hold NO capability
 *      in TAGITCore. Step 4 asserts this and aborts the deployment if it is ever false.
 */
contract UpgradeRecoveryVerdict is Script {
    bytes32 private constant RESOLVER_CAPABILITY = keccak256("RESOLVER");
    bytes32 private constant FLAGGER_CAPABILITY = keccak256("FLAGGER");
    bytes32 private constant MINTER_CAPABILITY = keccak256("MINTER");
    bytes32 private constant BINDER_CAPABILITY = keccak256("BINDER");
    bytes32 private constant ACTIVATOR_CAPABILITY = keccak256("ACTIVATOR");
    bytes32 private constant CLAIMER_CAPABILITY = keccak256("CLAIMER");
    bytes32 private constant RECYCLER_CAPABILITY = keccak256("RECYCLER");
    bytes32 private constant VIEWER_CAPABILITY = keccak256("VIEWER");
    bytes32 private constant AUDITOR_CAPABILITY = keccak256("AUDITOR");

    error CoreMissingPreFlagState(address coreProxy);
    error TrustBoundaryViolated(address recoveryProxy, bytes32 capability);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 step = vm.envOr("STEP", uint256(1));

        console2.log("TAGIT-VDP-2026-001 remediation | Step", step, "| Chain", block.chainid);
        console2.log("Deployer:", vm.addr(deployerPrivateKey));
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        if (step == 1) {
            _step1DeployCoreAndSchedule();
        } else if (step == 2) {
            _step2ExecuteCoreUpgrade();
        } else if (step == 4) {
            _step4UpgradeRecovery();
        } else {
            console2.log("Unknown STEP. Use 1 (deploy+schedule Core), 2 (execute Core), 4 (Recovery).");
        }

        vm.stopBroadcast();
    }

    // ============================================
    // STEP 1 — TAGITCore FIRST
    // ============================================

    function _step1DeployCoreAndSchedule() internal {
        address coreProxy = vm.envAddress("CORE_PROXY");
        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));
        uint256 delay = timelock.getMinDelay();

        TAGITCore newImpl = new TAGITCore();
        console2.log("1. TAGITCore v2 implementation:", address(newImpl));
        console2.log("   (adds preFlagState(uint256): +63 bytes runtime, no storage change)");

        bytes memory upgradeData = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newImpl), ""));
        timelock.schedule(coreProxy, 0, upgradeData, bytes32(0), keccak256("upgrade-core-preflagstate"), delay);
        console2.log("2. Core upgrade scheduled. Execute after", delay, "seconds.");
        console2.log("");
        console2.log("NEXT: STEP=2 NEW_CORE_IMPL=%s", address(newImpl));
    }

    // ============================================
    // STEP 2 — execute the Core upgrade
    // ============================================

    function _step2ExecuteCoreUpgrade() internal {
        address coreProxy = vm.envAddress("CORE_PROXY");
        address newImpl = vm.envAddress("NEW_CORE_IMPL");
        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));

        bytes memory upgradeData = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));
        timelock.execute(coreProxy, 0, upgradeData, bytes32(0), keccak256("upgrade-core-preflagstate"));
        console2.log("1. TAGITCore upgraded to:", newImpl);

        _requirePreFlagState(coreProxy);
        console2.log("2. preFlagState(uint256) confirmed live on the proxy");
        console2.log("");
        console2.log("VERIFY MANUALLY TOO:");
        console2.log('   cast call %s "preFlagState(uint256)(uint8)" 1', coreProxy);
        console2.log("THEN: STEP=4 to upgrade TAGITRecovery");
    }

    // ============================================
    // STEP 4 — TAGITRecovery SECOND
    // ============================================

    function _step4UpgradeRecovery() internal {
        address coreProxy = vm.envAddress("CORE_PROXY");
        address recoveryProxy = vm.envAddress("RECOVERY_PROXY");
        ITAGITAccess access = ITAGITAccess(vm.envAddress("ACCESS"));

        // GATE 1: Core must already expose preFlagState, or every initiateRecovery reverts.
        _requirePreFlagState(coreProxy);
        console2.log("1. Core dependency satisfied: preFlagState(uint256) is live");

        // GATE 2: the trust boundary. TAGITRecovery must hold NO capability in TAGITCore.
        //         This is the design's central security claim; a violation is an incident.
        _requireNoCapability(access, recoveryProxy, RESOLVER_CAPABILITY, "RESOLVER");
        _requireNoCapability(access, recoveryProxy, FLAGGER_CAPABILITY, "FLAGGER");
        _requireNoCapability(access, recoveryProxy, MINTER_CAPABILITY, "MINTER");
        _requireNoCapability(access, recoveryProxy, BINDER_CAPABILITY, "BINDER");
        _requireNoCapability(access, recoveryProxy, ACTIVATOR_CAPABILITY, "ACTIVATOR");
        _requireNoCapability(access, recoveryProxy, CLAIMER_CAPABILITY, "CLAIMER");
        _requireNoCapability(access, recoveryProxy, RECYCLER_CAPABILITY, "RECYCLER");
        _requireNoCapability(access, recoveryProxy, VIEWER_CAPABILITY, "VIEWER");
        _requireNoCapability(access, recoveryProxy, AUDITOR_CAPABILITY, "AUDITOR");
        console2.log("2. Trust boundary verified: TAGITRecovery holds ZERO capabilities");

        TAGITRecovery newImpl = new TAGITRecovery();
        console2.log("3. TAGITRecovery v2 implementation:", address(newImpl));

        // NOTE: the Recovery proxy owner is still an EOA on Base Sepolia (see G1 in the PR).
        // Once ownership moves to the Timelock this call becomes a schedule/execute pair.
        UUPSUpgradeable(recoveryProxy).upgradeToAndCall(address(newImpl), "");
        console2.log("4. TAGITRecovery upgraded. version() should now read 2.0.0");
        console2.log("");
        console2.log("POST-DEPLOY (the code is INERT without these):");
        console2.log(" - Grant RESOLVER_CAPABILITY to THREE independent human addresses");
        console2.log(" - Grant FLAGGER_CAPABILITY to AT LEAST TWO independent operators");
        console2.log(" - Grant AIRP jury seats on IdentityBadge to the voter roster:");
        console2.log("     70 = JUROR (1x), 71 = SENIOR_JUROR (2x), 72 = ARBITER (3x), 73 = TRIBUNAL (4x)");
        console2.log("     NEVER ids 1/2/10/20 - those are KYC_L1/KYC_L2/MANUFACTURER/GOV_MIL and");
        console2.log("     granting them would make every KYC'd account an AIRP juror");
        console2.log("     At least MINIMUM_VOTES (3) DISTINCT holders are needed or every case EXPIRES");
        console2.log(" - Confirm TAGITAccess.setIdentityBadge points at the live IdentityBadge");
        console2.log(" - Move the TAGITRecovery proxy owner to the TimelockController");
    }

    // ============================================
    // GATES
    // ============================================

    function _requirePreFlagState(address coreProxy) internal view {
        (bool ok,) = coreProxy.staticcall(abi.encodeCall(TAGITCore.preFlagState, (1)));
        if (!ok) revert CoreMissingPreFlagState(coreProxy);
    }

    function _requireNoCapability(ITAGITAccess access, address recoveryProxy, bytes32 cap, string memory name)
        internal
        view
    {
        if (access.hasCapability(recoveryProxy, uint256(cap))) {
            console2.log("FATAL: TAGITRecovery holds capability", name);
            revert TrustBoundaryViolated(recoveryProxy, cap);
        }
    }
}
