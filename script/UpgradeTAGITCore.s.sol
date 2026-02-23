// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITCore} from "../src/core/TAGITCore.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @title UpgradeTAGITCore
 * @author TAG IT Network <dev@tagit.network>
 * @notice Upgrade script for TAGITCore via TimelockController (48hr delay)
 * @dev Two entry points:
 *   1. schedule() — Deploy new implementation + schedule upgradeToAndCall on timelock
 *   2. execute()  — Execute a previously-scheduled upgrade after delay has passed
 *
 * Environment variables:
 *   PRIVATE_KEY        — Proposer/executor private key (Gnosis Safe signer)
 *   TAGIT_CORE_PROXY   — Address of the TAGITCore proxy contract
 *   TIMELOCK_ADDRESS   — Address of the TimelockController
 *
 * Usage:
 *   # Step 1: Deploy new impl + schedule upgrade (starts 48hr timer)
 *   forge script script/UpgradeTAGITCore.s.sol --sig "schedule()" --rpc-url <RPC> --broadcast
 *
 *   # Step 2: Execute upgrade (after 48hr delay)
 *   forge script script/UpgradeTAGITCore.s.sol --sig "execute()" --rpc-url <RPC> --broadcast
 */
contract UpgradeTAGITCore is Script {
    function schedule() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address proxyAddr = vm.envAddress("TAGIT_CORE_PROXY");
        address timelockAddr = vm.envAddress("TIMELOCK_ADDRESS");

        TimelockController timelock = TimelockController(payable(timelockAddr));
        TAGITCore proxy = TAGITCore(proxyAddr);

        console2.log("===========================================");
        console2.log("TAGITCore Upgrade - Schedule");
        console2.log("===========================================");
        console2.log("Proposer:       ", deployer);
        console2.log("Proxy:          ", proxyAddr);
        console2.log("Timelock:       ", timelockAddr);

        address oldImpl = proxy.getImplementation();
        console2.log("Old impl:       ", oldImpl);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new implementation
        console2.log("1. Deploying new TAGITCore implementation...");
        TAGITCore newImpl = new TAGITCore();
        console2.log("   New impl:    ", address(newImpl));

        // 2. Build upgradeToAndCall calldata (no reinitializer data)
        bytes memory upgradeCall = abi.encodeCall(
            proxy.upgradeToAndCall,
            (address(newImpl), "")
        );

        // 3. Schedule on timelock
        bytes32 salt = keccak256(abi.encodePacked("upgrade-tagitcore-", block.timestamp));
        uint256 minDelay = timelock.getMinDelay();

        console2.log("2. Scheduling upgrade on TimelockController...");
        console2.log("   Min delay:   ", minDelay, "seconds");

        timelock.schedule(
            proxyAddr,      // target
            0,              // value
            upgradeCall,    // data
            bytes32(0),     // predecessor
            salt,           // salt
            minDelay        // delay
        );

        bytes32 operationId = timelock.hashOperation(
            proxyAddr,
            0,
            upgradeCall,
            bytes32(0),
            salt
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("===========================================");
        console2.log("Upgrade Scheduled!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Operation ID:     ", vm.toString(operationId));
        console2.log("Salt:             ", vm.toString(salt));
        console2.log("Old impl:         ", oldImpl);
        console2.log("New impl:         ", address(newImpl));
        console2.log("Earliest execute: ", block.timestamp + minDelay);
        console2.log("");
        console2.log("Next: Wait for delay, then run execute() with:");
        console2.log("  NEW_IMPL=<new impl address> SALT=<salt> forge script script/UpgradeTAGITCore.s.sol --sig 'execute()' ...");
        console2.log("");
    }

    function execute() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address proxyAddr = vm.envAddress("TAGIT_CORE_PROXY");
        address timelockAddr = vm.envAddress("TIMELOCK_ADDRESS");
        address newImplAddr = vm.envAddress("NEW_IMPL");
        bytes32 salt = vm.envBytes32("SALT");

        TimelockController timelock = TimelockController(payable(timelockAddr));
        TAGITCore proxy = TAGITCore(proxyAddr);

        console2.log("===========================================");
        console2.log("TAGITCore Upgrade - Execute");
        console2.log("===========================================");
        console2.log("Executor:       ", deployer);
        console2.log("Proxy:          ", proxyAddr);
        console2.log("Timelock:       ", timelockAddr);

        address oldImpl = proxy.getImplementation();
        console2.log("Current impl:   ", oldImpl);
        console2.log("New impl:       ", newImplAddr);
        console2.log("");

        // Rebuild the same calldata used in schedule()
        bytes memory upgradeCall = abi.encodeCall(
            proxy.upgradeToAndCall,
            (newImplAddr, "")
        );

        bytes32 operationId = timelock.hashOperation(
            proxyAddr,
            0,
            upgradeCall,
            bytes32(0),
            salt
        );

        console2.log("Operation ID:   ", vm.toString(operationId));
        console2.log("Is ready:       ", timelock.isOperationReady(operationId));
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        console2.log("Executing upgrade...");
        timelock.execute(
            proxyAddr,
            0,
            upgradeCall,
            bytes32(0),
            salt
        );

        vm.stopBroadcast();

        address actualImpl = proxy.getImplementation();

        console2.log("");
        console2.log("===========================================");
        console2.log("Upgrade Complete!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Old impl:       ", oldImpl);
        console2.log("New impl:       ", actualImpl);
        console2.log("");
    }
}
