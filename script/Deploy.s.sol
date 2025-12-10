// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "@forge-std/Script.sol";

/**
 * @title Deploy
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deployment script for TAG IT contracts
 * @dev Run with: forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
 */
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        // Deployment logic will be implemented here

        vm.stopBroadcast();
    }
}
