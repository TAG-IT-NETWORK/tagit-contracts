// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITAgentIdentity} from "../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAgentReputation} from "../../src/agent/TAGITAgentReputation.sol";
import {TAGITAgentValidation} from "../../src/agent/TAGITAgentValidation.sol";

/**
 * @title DeployAgentSuite
 * @author TAG IT Network <dev@tagit.network>
 * @notice Orchestrated deployment script for ERC-8004 Agent Infrastructure
 * @dev Deploys all three agent contracts in dependency order within a single broadcast,
 *      capturing and passing addresses inline. No pre-deployed addresses needed.
 *
 * Run with:
 *   forge script script/deploy/DeployAgentSuite.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL --broadcast --verify
 *
 * Dry-run (no broadcast):
 *   forge script script/deploy/DeployAgentSuite.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL
 *
 * Environment variables:
 *   PRIVATE_KEY      - Deployer private key
 *   TAGIT_ACCESS     - TAGITAccess controller address (must be pre-deployed)
 *
 * Deployment Order (dependency graph):
 *   1. TAGITAgentIdentity  - ERC-721 soulbound agent registry (no deps)
 *   2. TAGITAgentReputation - Feedback & scoring (depends on Identity)
 *   3. TAGITAgentValidation - Proof verification (depends on Identity)
 *
 * Post-deployment configuration (all done inline):
 *   - Identity.setAccessController(access)
 *   - Reputation.setAccessController(access) + setIdentityRegistry(identity)
 *   - Validation.setAccessController(access) + setIdentityRegistry(identity)
 *
 * @custom:security Owner is deployer (msg.sender). Transfer ownership to multisig post-deploy.
 */
contract DeployAgentSuite is Script {
    TAGITAgentIdentity public agentIdentity;
    TAGITAgentReputation public agentReputation;
    TAGITAgentValidation public agentValidation;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address accessController = vm.envAddress("TAGIT_ACCESS");

        console2.log("===========================================");
        console2.log("TAG IT Network - Agent Suite Deployment");
        console2.log("ERC-8004 Trustless Agent Infrastructure");
        console2.log("===========================================");
        console2.log("Deployer:          ", deployer);
        console2.log("Chain ID:          ", block.chainid);
        console2.log("Access Controller: ", accessController);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // 1. Deploy TAGITAgentIdentity (no dependencies)
        // ============================================
        console2.log("1. Deploying TAGITAgentIdentity...");
        agentIdentity = new TAGITAgentIdentity();
        console2.log("   TAGITAgentIdentity deployed at:", address(agentIdentity));

        // ============================================
        // 2. Deploy TAGITAgentReputation (depends on Identity)
        // ============================================
        console2.log("2. Deploying TAGITAgentReputation...");
        agentReputation = new TAGITAgentReputation();
        console2.log("   TAGITAgentReputation deployed at:", address(agentReputation));

        // ============================================
        // 3. Deploy TAGITAgentValidation (depends on Identity)
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
        console2.log("   Access controllers set on all three contracts");

        // ============================================
        // 5. Wire Identity Registry (inline address passing)
        // ============================================
        console2.log("5. Wiring identity registry...");
        agentReputation.setIdentityRegistry(address(agentIdentity));
        agentValidation.setIdentityRegistry(address(agentIdentity));
        console2.log("   Reputation + Validation wired to Identity at:", address(agentIdentity));

        vm.stopBroadcast();

        // ============================================
        // DEPLOYMENT SUMMARY
        // ============================================
        console2.log("");
        console2.log("===========================================");
        console2.log("Deployment Complete!");
        console2.log("===========================================");
        console2.log("TAGITAgentIdentity:   ", address(agentIdentity));
        console2.log("TAGITAgentReputation: ", address(agentReputation));
        console2.log("TAGITAgentValidation: ", address(agentValidation));
        console2.log("");
        console2.log("Environment variables for downstream scripts:");
        console2.log("  AGENT_IDENTITY_ADDRESS=", address(agentIdentity));
        console2.log("  AGENT_REPUTATION_ADDRESS=", address(agentReputation));
        console2.log("  AGENT_VALIDATION_ADDRESS=", address(agentValidation));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify contracts on block explorer");
        console2.log("  2. Run RegisterSageAgent.s.sol to register Agent #1");
        console2.log("  3. Grant AGENT_VALIDATOR capability to validators via BIDGES");
        console2.log("  4. Transfer ownership to multisig");
    }
}
