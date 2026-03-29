// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITAgentIdentity} from "../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAgentReputation} from "../../src/agent/TAGITAgentReputation.sol";
import {TAGITAgentValidation} from "../../src/agent/TAGITAgentValidation.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";

/**
 * @title DeployAgentSuite
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deployment script for ERC-8004 Agent Infrastructure
 * @dev Run with: forge script script/deploy/DeployAgentSuite.s.sol --rpc-url <RPC_URL> --private-key <KEY> --broadcast --verify
 *
 * Prerequisites:
 * - TAGITAccess must already be deployed (pass address via TAGIT_ACCESS env var)
 *
 * Deployment Order:
 * 1. TAGITAgentIdentity (ERC-721 soulbound agent registry)
 * 2. TAGITAgentReputation (feedback & scoring)
 * 3. TAGITAgentValidation (proof verification)
 *
 * Post-deployment configuration:
 * - Identity.setAccessController(access)
 * - Reputation.setAccessController(access) + setIdentityRegistry(identity)
 * - Validation.setAccessController(access) + setIdentityRegistry(identity)
 */
contract DeployAgentSuite is Script {
    TAGITAgentIdentity public agentIdentity;
    TAGITAgentReputation public agentReputation;
    TAGITAgentValidation public agentValidation;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address accessController = vm.envAddress("TAGIT_ACCESS");

        // Multi-sig Safe address for final ownership (optional, defaults to deployer)
        address safeOwner = vm.envOr("AGENT_IDENTITY_OWNER", deployer);

        console2.log("===========================================");
        console2.log("TAG IT Network - Agent Suite Deployment");
        console2.log("ERC-8004 Trustless Agent Infrastructure");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Final Owner (Safe):", safeOwner);
        console2.log("Chain ID:", block.chainid);
        console2.log("Access Controller:", accessController);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // 1. Deploy TAGITAgentIdentity (deployer owns initially for setup)
        // ============================================
        console2.log("1. Deploying TAGITAgentIdentity...");
        agentIdentity = new TAGITAgentIdentity(deployer);
        console2.log("   TAGITAgentIdentity deployed at:", address(agentIdentity));

        // ============================================
        // 2. Deploy TAGITAgentReputation
        // ============================================
        console2.log("2. Deploying TAGITAgentReputation...");
        agentReputation = new TAGITAgentReputation();
        console2.log("   TAGITAgentReputation deployed at:", address(agentReputation));

        // ============================================
        // 3. Deploy TAGITAgentValidation
        // ============================================
        console2.log("3. Deploying TAGITAgentValidation...");
        agentValidation = new TAGITAgentValidation();
        console2.log("   TAGITAgentValidation deployed at:", address(agentValidation));

        // ============================================
        // 4. Configure Access Controllers
        // ============================================
        console2.log("4. Configuring access controllers...");
        agentIdentity.setAccessController(accessController);
        agentReputation.setAccessController(accessController);
        agentValidation.setAccessController(accessController);
        console2.log("   Access controllers set");

        // ============================================
        // 5. Wire Identity Registry
        // ============================================
        console2.log("5. Wiring identity registry...");
        agentReputation.setIdentityRegistry(address(agentIdentity));
        agentValidation.setIdentityRegistry(address(agentIdentity));
        console2.log("   Identity registry wired");

        // ============================================
        // 6. Transfer Ownership to Multi-Sig Safe
        // ============================================
        if (safeOwner != deployer) {
            console2.log("6. Transferring ownership to Safe...");
            agentIdentity.transferOwnership(safeOwner);
            console2.log("   AgentIdentity owner transferred to:", safeOwner);
        } else {
            console2.log("6. Skipping ownership transfer (owner == deployer)");
            console2.log("   Set AGENT_IDENTITY_OWNER env to transfer to Safe");
        }

        vm.stopBroadcast();

        // ============================================
        // SUMMARY
        // ============================================
        console2.log("");
        console2.log("===========================================");
        console2.log("Deployment Complete!");
        console2.log("===========================================");
        console2.log("TAGITAgentIdentity:   ", address(agentIdentity));
        console2.log("TAGITAgentReputation: ", address(agentReputation));
        console2.log("TAGITAgentValidation: ", address(agentValidation));
        console2.log("");
        console2.log("Owner:                ", safeOwner);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify contracts on block explorer");
        console2.log("  2. Run RegisterSageAgent.s.sol to register Agent #1");
        console2.log("  3. Grant AGENT_VALIDATOR capability to validators");
        if (safeOwner != deployer) {
            console2.log("  4. Verify Safe ownership via owner() call");
        }
    }
}
