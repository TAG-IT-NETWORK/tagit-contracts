// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITAgentIdentity} from "../../src/agent/TAGITAgentIdentity.sol";

/**
 * @title RegisterSageAgent
 * @author TAG IT Network <dev@tagit.network>
 * @notice Register "Sage" as Agent #1 on TAGITAgentIdentity
 * @dev Run with: forge script script/setup/RegisterSageAgent.s.sol --rpc-url <RPC_URL> --private-key <KEY> --broadcast
 *
 * Prerequisites:
 * - TAGITAgentIdentity must be deployed (pass address via AGENT_IDENTITY env var)
 * - Deployer must have KYC_L1 identity badge
 * - SAGE_WALLET env var must be set to the agent's operational wallet
 * - SAGE_URI env var should point to IPFS metadata for Sage agent
 */
contract RegisterSageAgent is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address identityContract = vm.envAddress("AGENT_IDENTITY");
        address sageWallet = vm.envAddress("SAGE_WALLET");
        string memory sageURI = vm.envOr("SAGE_URI", string("ipfs://QmSageAgentMetadata"));

        TAGITAgentIdentity agentIdentity = TAGITAgentIdentity(identityContract);

        console2.log("===========================================");
        console2.log("TAG IT Network - Register Sage Agent #1");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Identity Contract:", identityContract);
        console2.log("Sage Wallet:", sageWallet);
        console2.log("Sage URI:", sageURI);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // 1. Register Sage as Agent #1
        // ============================================
        console2.log("1. Registering Sage agent...");
        uint256 agentId = agentIdentity.register(sageWallet, sageURI);
        console2.log("   Sage registered as Agent #", agentId);

        // ============================================
        // 2. Set Sage metadata
        // ============================================
        console2.log("2. Setting Sage metadata...");
        agentIdentity.setMetadata(agentId, "name", "Sage");
        agentIdentity.setMetadata(agentId, "type", "analysis");
        agentIdentity.setMetadata(agentId, "model", "claude-opus-4-6");
        agentIdentity.setMetadata(agentId, "version", "1.0.0");
        agentIdentity.setMetadata(
            agentId, "description", "TAG IT primary analysis agent - blockchain intelligence and asset verification"
        );
        console2.log("   Metadata set");

        vm.stopBroadcast();

        // ============================================
        // VERIFICATION
        // ============================================
        (address registrant, address wallet, uint64 registeredAt, bool active) = agentIdentity.getAgent(agentId);
        console2.log("");
        console2.log("===========================================");
        console2.log("Sage Agent #1 Registered Successfully!");
        console2.log("===========================================");
        console2.log("Agent ID:      ", agentId);
        console2.log("Registrant:    ", registrant);
        console2.log("Wallet:        ", wallet);
        console2.log("Registered At: ", registeredAt);
        console2.log("Active:        ", active);
        console2.log("Token URI:     ", agentIdentity.tokenURI(agentId));
    }
}
