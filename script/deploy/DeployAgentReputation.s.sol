// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITAgentReputation} from "../../src/agent/TAGITAgentReputation.sol";

/**
 * @title DeployAgentReputation
 * @author TAG IT Network <dev@tagit.network>
 * @notice Standalone deployment script for TAGITAgentReputation (Agent Feedback & Scoring)
 * @dev Run with:
 *   forge script script/deploy/DeployAgentReputation.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL --broadcast --verify
 *
 * Environment variables:
 *   PRIVATE_KEY             - Deployer private key
 *   AGENT_IDENTITY_ADDRESS  - TAGITAgentIdentity contract address (required for wiring)
 *   TAGIT_ACCESS            - (optional) TAGITAccess controller address
 *
 * Post-deployment:
 *   - Call setIdentityRegistry(identityAddr) to wire agent identity lookup
 *   - Call setAccessController(accessAddr) to wire BIDGES access control
 *   - Transfer ownership to multisig if desired
 *
 * @custom:security Owner is deployer (msg.sender). Transfer ownership to multisig post-deploy.
 */
contract DeployAgentReputation is Script {
    TAGITAgentReputation public agentReputation;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address identityAddr = vm.envAddress("AGENT_IDENTITY_ADDRESS");

        console2.log("===========================================");
        console2.log("DeployAgentReputation (Agent Feedback & Scoring)");
        console2.log("===========================================");
        console2.log("Deployer:        ", deployer);
        console2.log("Chain ID:        ", block.chainid);
        console2.log("Identity Registry:", identityAddr);
        console2.log("");

        vm.startBroadcast(pk);

        agentReputation = new TAGITAgentReputation();

        // Wire identity registry
        agentReputation.setIdentityRegistry(identityAddr);
        console2.log("Identity registry wired:", identityAddr);

        // Optionally wire access controller if env var is set
        address accessController = vm.envOr("TAGIT_ACCESS", address(0));
        if (accessController != address(0)) {
            agentReputation.setAccessController(accessController);
            console2.log("Access controller set:", accessController);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("===========================================");
        console2.log("Deployment Complete");
        console2.log("===========================================");
        console2.log("TAGITAgentReputation:", address(agentReputation));
        console2.log("Owner:              ", agentReputation.owner());
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify on block explorer");
        console2.log("  2. Call setAccessController() if not already set");
    }
}
