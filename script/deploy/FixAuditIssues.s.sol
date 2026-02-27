// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {TAGITPrograms} from "../../src/programs/TAGITPrograms.sol";
import {TAGITRecovery} from "../../src/recovery/TAGITRecovery.sol";

/**
 * @title FixAuditIssues
 * @author TAG IT Network <dev@tagit.network>
 * @notice Fixes audit issues found in SEC-AUD-001:
 *   1. Grant deployer CAP_BIND (101) and CAP_ACTIVATE (102) on CapabilityBadge
 *   2. Update TAGITPrograms.setCore() to new TAGITCore proxy
 *   3. Update TAGITRecovery.setTreasury() to actual Treasury proxy
 *
 * @dev All calls are direct from deployer who is owner/governor on these contracts.
 *      No timelock needed.
 *
 * Usage:
 *   forge script script/deploy/FixAuditIssues.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL --broadcast
 */
contract FixAuditIssues is Script {
    // Deployed addresses from registry
    address constant CAPABILITY_BADGE = 0x5e190F6Ebde4BD1e11a5566a1e81a933cdDf3505;
    address constant TAGIT_CORE_PROXY = 0x8BdE22da889306d422802728cb98B6Da42ed8e1a;
    address constant TAGIT_PROGRAMS = 0x4d1007eB4823a5a13905A0361478C339421ce4C9;
    address constant TAGIT_RECOVERY = 0x17c0af6B37aBD06587303f1695a06A668F8A5A8c;
    address constant TAGIT_TREASURY = 0x841B07Ad929CCC589446e29Aa0C4Dd1639B48674;

    // Capability IDs
    uint256 constant CAP_BIND = 101;
    uint256 constant CAP_ACTIVATE = 102;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("===========================================");
        console2.log("TAG IT - Fix Audit Issues (SEC-AUD-001)");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("");

        CapabilityBadge badge = CapabilityBadge(CAPABILITY_BADGE);
        TAGITPrograms programs = TAGITPrograms(TAGIT_PROGRAMS);
        TAGITRecovery recovery = TAGITRecovery(TAGIT_RECOVERY);

        // === Pre-flight checks ===
        console2.log("--- Pre-flight State ---");

        uint256 bindBal = badge.balanceOf(deployer, CAP_BIND);
        uint256 activateBal = badge.balanceOf(deployer, CAP_ACTIVATE);
        console2.log("CAP_BIND balance:    ", bindBal);
        console2.log("CAP_ACTIVATE balance:", activateBal);

        address currentCore = programs.coreContract();
        console2.log("Programs.core:       ", currentCore);
        console2.log("Expected core:       ", TAGIT_CORE_PROXY);

        address currentTreasury = recovery.treasury();
        console2.log("Recovery.treasury:   ", currentTreasury);
        console2.log("Expected treasury:   ", TAGIT_TREASURY);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // === Fix 1: Grant CAP_BIND ===
        if (bindBal == 0) {
            badge.grantCapability(deployer, CAP_BIND);
            console2.log("1. Granted CAP_BIND (101) to deployer");
        } else {
            console2.log("1. CAP_BIND already granted, skipping");
        }

        // === Fix 2: Grant CAP_ACTIVATE ===
        if (activateBal == 0) {
            badge.grantCapability(deployer, CAP_ACTIVATE);
            console2.log("2. Granted CAP_ACTIVATE (102) to deployer");
        } else {
            console2.log("2. CAP_ACTIVATE already granted, skipping");
        }

        // === Fix 3: Update Programs core to new TAGITCore proxy ===
        if (currentCore != TAGIT_CORE_PROXY) {
            programs.setCore(TAGIT_CORE_PROXY);
            console2.log("3. Updated Programs.core to new TAGITCore proxy");
        } else {
            console2.log("3. Programs.core already correct, skipping");
        }

        // === Fix 4: Update Recovery treasury to actual Treasury proxy ===
        if (currentTreasury != TAGIT_TREASURY) {
            recovery.setTreasury(TAGIT_TREASURY);
            console2.log("4. Updated Recovery.treasury to TAGITTreasury proxy");
        } else {
            console2.log("4. Recovery.treasury already correct, skipping");
        }

        vm.stopBroadcast();

        // === Verification ===
        console2.log("");
        console2.log("--- Post-execution Verification ---");
        console2.log("CAP_BIND balance:    ", badge.balanceOf(deployer, CAP_BIND));
        console2.log("CAP_ACTIVATE balance:", badge.balanceOf(deployer, CAP_ACTIVATE));
        console2.log("Programs.core:       ", programs.coreContract());
        console2.log("Recovery.treasury:   ", recovery.treasury());
        console2.log("");
        console2.log("=== DONE ===");
        console2.log("");
        console2.log("REMAINING (blocked - needs TAGITToken deployment):");
        console2.log("  - Treasury.tagitToken is deployer placeholder");
        console2.log("  - Recovery.token is deployer placeholder");
        console2.log("  - Recovery.core is old TAGITCore (no setter - needs impl upgrade)");
    }
}
