// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title UpgradeCoreQuorum
 * @notice Upgrade TAGITCore proxy to new impl with RESOLVE_QUORUM = 1
 * @dev Testnet upgrade via TimelockController (5-minute delay).
 *
 *   Step 1 - Deploy new impl + schedule upgrade:
 *     forge script script/deploy/UpgradeCoreQuorum.s.sol --sig "schedule()" \
 *       --rpc-url $OP_SEPOLIA_RPC_URL --broadcast
 *
 *   Step 2 - Wait 5 minutes, then execute:
 *     NEW_IMPL=<address from step 1> forge script script/deploy/UpgradeCoreQuorum.s.sol \
 *       --sig "execute()" --rpc-url $OP_SEPOLIA_RPC_URL --broadcast
 */
contract UpgradeCoreQuorum is Script {
    address constant PROXY = 0x8BdE22da889306d422802728cb98B6Da42ed8e1a;
    address constant TIMELOCK = 0x1B2bdd6f0a3C9127397dE51C36Dc237b097410a8;
    bytes32 constant SALT = keccak256("upgrade-quorum-1");

    function schedule() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        TAGITCore proxy = TAGITCore(PROXY);

        console2.log("========================================");
        console2.log("UpgradeCoreQuorum - Schedule");
        console2.log("========================================");
        console2.log("Deployer:", deployer);
        console2.log("Proxy:  ", PROXY);

        address oldImpl = proxy.getImplementation();
        console2.log("Old impl:", oldImpl);

        vm.startBroadcast(pk);

        // 1. Deploy new implementation (RESOLVE_QUORUM = 1)
        TAGITCore newImpl = new TAGITCore();
        console2.log("New impl:", address(newImpl));

        // 2. Schedule upgradeToAndCall on timelock
        bytes memory upgradeCall = abi.encodeCall(proxy.upgradeToAndCall, (address(newImpl), ""));

        uint256 delay = timelock.getMinDelay();
        console2.log("Delay:  ", delay, "seconds");

        timelock.schedule(PROXY, 0, upgradeCall, bytes32(0), SALT, delay);

        vm.stopBroadcast();

        console2.log("");
        console2.log("Scheduled! Wait", delay, "seconds, then run:");
        console2.log("");
        console2.log("  NEW_IMPL=", vm.toString(address(newImpl)));
        console2.log("");
        console2.log("  NEW_IMPL=<above> forge script script/deploy/UpgradeCoreQuorum.s.sol \\");
        console2.log("    --sig 'execute()' --rpc-url $OP_SEPOLIA_RPC_URL --broadcast");
        console2.log("");
    }

    function execute() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address newImplAddr = vm.envAddress("NEW_IMPL");

        TimelockController timelock = TimelockController(payable(TIMELOCK));
        TAGITCore proxy = TAGITCore(PROXY);

        console2.log("========================================");
        console2.log("UpgradeCoreQuorum - Execute");
        console2.log("========================================");

        address oldImpl = proxy.getImplementation();
        console2.log("Old impl:", oldImpl);
        console2.log("New impl:", newImplAddr);

        bytes memory upgradeCall = abi.encodeCall(proxy.upgradeToAndCall, (newImplAddr, ""));

        bytes32 opId = timelock.hashOperation(PROXY, 0, upgradeCall, bytes32(0), SALT);
        bool ready = timelock.isOperationReady(opId);
        console2.log("Ready:  ", ready);
        require(ready, "Timelock delay not elapsed - wait 5 minutes");

        vm.startBroadcast(pk);
        timelock.execute(PROXY, 0, upgradeCall, bytes32(0), SALT);
        vm.stopBroadcast();

        address actual = proxy.getImplementation();
        console2.log("");
        console2.log("Upgrade complete!");
        console2.log("Impl now:", actual);

        // Verify quorum
        uint256 quorum = proxy.RESOLVE_QUORUM();
        console2.log("RESOLVE_QUORUM:", quorum);
        console2.log("");
    }
}
