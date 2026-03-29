// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITAgentIdentity} from "../../src/agent/TAGITAgentIdentity.sol";

/**
 * @title DeployAgentIdentity
 * @author TAG IT Network <dev@tagit.network>
 * @notice Standalone deployment script for TAGITAgentIdentity (ERC-8004 Agent Registry)
 * @dev Run with:
 *   forge script script/deploy/DeployAgentIdentity.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL --broadcast --verify
 *
 * Environment variables:
 *   PRIVATE_KEY      - Deployer private key
 *   TAGIT_ACCESS     - (optional) TAGITAccess controller address for post-deploy config
 *
 * Post-deployment:
 *   - Call setAccessController(accessAddr) to wire BIDGES access control
 *   - Transfer ownership to multisig if desired
 *
 * @custom:security Owner is deployer (msg.sender). Transfer ownership to multisig post-deploy.
 */
contract DeployAgentIdentity is Script {
    TAGITAgentIdentity public agentIdentity;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("===========================================");
        console2.log("DeployAgentIdentity (ERC-8004 Agent Registry)");
        console2.log("===========================================");
        console2.log("Deployer: ", deployer);
        console2.log("Chain ID: ", block.chainid);
        console2.log("");

        vm.startBroadcast(pk);

        agentIdentity = new TAGITAgentIdentity();

        // Optionally wire access controller if env var is set
        address accessController = vm.envOr("TAGIT_ACCESS", address(0));
        if (accessController != address(0)) {
            agentIdentity.setAccessController(accessController);
            console2.log("Access controller set:", accessController);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("===========================================");
        console2.log("Deployment Complete");
        console2.log("===========================================");
        console2.log("TAGITAgentIdentity:", address(agentIdentity));
        console2.log("Owner:            ", agentIdentity.owner());
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify on block explorer");
        console2.log("  2. Call setAccessController() if not already set");
        console2.log("  3. Deploy Reputation + Validation with AGENT_IDENTITY_ADDRESS env var");
    }
}
