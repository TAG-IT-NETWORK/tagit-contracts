// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITStateAnchor} from "../../src/mirror/TAGITStateAnchor.sol";

/**
 * @title DeployStateAnchor
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploys TAGITStateAnchor to the mirror chain for cross-chain state verification.
 *
 * @dev SUNSET NOTICE (2026-08-01): this script mirrors between OP Sepolia and Arbitrum
 *      Sepolia. BOTH are "status": "archived". TAGITStateAnchor is also explicitly out of
 *      audit scope (AUDIT-SCOPE.md 1.5). Retained as deployment history; do not use it to
 *      deploy anything new. Base Sepolia (84532) is the only live chain.
 *
 * @dev Deploy to OP Sepolia (mirror) when Arbitrum Sepolia is primary:
 *   forge script script/deploy/DeployStateAnchor.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
 *
 * Or deploy to Arbitrum Sepolia (mirror) when OP Sepolia is primary:
 *   forge script script/deploy/DeployStateAnchor.s.sol \
 *     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --verify --etherscan-api-key $ARBISCAN_API_KEY
 */
contract DeployStateAnchor is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("===========================================");
        console2.log("TAG IT - Deploy TAGITStateAnchor");
        console2.log("===========================================");
        console2.log("Deployer (anchor):", deployer);
        console2.log("Chain ID:         ", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Anchor = deployer for testnet (relayer uses same key)
        TAGITStateAnchor stateAnchor = new TAGITStateAnchor(deployer);

        vm.stopBroadcast();

        console2.log("===========================================");
        console2.log("Deployment Complete!");
        console2.log("===========================================");
        console2.log("TAGITStateAnchor:", address(stateAnchor));
        console2.log("Anchor (relayer):", deployer);
        console2.log("Owner:           ", deployer);
        console2.log("");
        console2.log("Verify:");
        console2.log("  cast call", address(stateAnchor), "'anchor()(address)'");
        console2.log("  cast call", address(stateAnchor), "'systemSyncAge()(uint256)'");
    }
}
