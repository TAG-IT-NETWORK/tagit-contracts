// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITCore} from "../src/core/TAGITCore.sol";
import {TAGITAccess} from "../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../src/access/CapabilityBadge.sol";

/**
 * @title Deploy
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deployment script for TAG IT contracts (BIDGES + Core)
 * @dev Run with: forge script script/Deploy.s.sol --rpc-url <RPC_URL> --private-key <KEY> --broadcast --verify
 *
 * Deployment Order:
 * 1. IdentityBadge (ERC-5192 soulbound badges)
 * 2. CapabilityBadge (ERC-1155 capability tokens)
 * 3. TAGITAccess (BIDGES facade controller)
 * 4. TAGITCore (Digital Twin NFT with lifecycle)
 *
 * Post-deployment configuration:
 * - TAGITAccess.setIdentityBadge(identityBadge)
 * - TAGITAccess.setCapabilityBadge(capabilityBadge)
 * - TAGITCore.setAccessController(tagitAccess)
 */
contract Deploy is Script {
    // Deployed contract addresses
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;
    TAGITAccess public tagitAccess;
    TAGITCore public tagitCore;

    function run() external {
        // Get deployer address from private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("===========================================");
        console2.log("TAG IT Network - Contract Deployment");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // 1. Deploy IdentityBadge (Soulbound ERC-5192)
        // ============================================
        console2.log("1. Deploying IdentityBadge...");
        identityBadge = new IdentityBadge();
        console2.log("   IdentityBadge deployed at:", address(identityBadge));

        // ============================================
        // 2. Deploy CapabilityBadge (ERC-1155)
        // ============================================
        console2.log("2. Deploying CapabilityBadge...");
        capabilityBadge = new CapabilityBadge();
        console2.log("   CapabilityBadge deployed at:", address(capabilityBadge));

        // ============================================
        // 3. Deploy TAGITAccess (BIDGES Facade)
        // ============================================
        console2.log("3. Deploying TAGITAccess...");
        tagitAccess = new TAGITAccess();
        console2.log("   TAGITAccess deployed at:", address(tagitAccess));

        // ============================================
        // 4. Deploy TAGITCore (Digital Twin NFT)
        // ============================================
        console2.log("4. Deploying TAGITCore...");
        tagitCore = new TAGITCore();
        console2.log("   TAGITCore deployed at:", address(tagitCore));

        // ============================================
        // 5. Configure TAGITAccess
        // ============================================
        console2.log("5. Configuring TAGITAccess...");
        tagitAccess.setIdentityBadge(address(identityBadge));
        console2.log("   - Set IdentityBadge");
        tagitAccess.setCapabilityBadge(address(capabilityBadge));
        console2.log("   - Set CapabilityBadge");

        // ============================================
        // 6. Configure TAGITCore
        // ============================================
        console2.log("6. Configuring TAGITCore...");
        tagitCore.setAccessController(address(tagitAccess));
        console2.log("   - Set AccessController");

        vm.stopBroadcast();

        // ============================================
        // Summary
        // ============================================
        console2.log("");
        console2.log("===========================================");
        console2.log("Deployment Complete!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Contract Addresses:");
        console2.log("  IdentityBadge:   ", address(identityBadge));
        console2.log("  CapabilityBadge: ", address(capabilityBadge));
        console2.log("  TAGITAccess:     ", address(tagitAccess));
        console2.log("  TAGITCore:       ", address(tagitCore));
        console2.log("");
        console2.log("Owner:             ", deployer);
        console2.log("");
        console2.log("Next Steps:");
        console2.log("1. Grant capabilities to operators via CapabilityBadge");
        console2.log("2. Grant identity badges to verified users via IdentityBadge");
        console2.log("3. Test mint() on TAGITCore (requires MINTER_CAPABILITY)");
        console2.log("");
    }
}
