// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title SetTrustedOracle
 * @author TAG IT Network <dev@tagit.network>
 * @notice Sets the trustedOracle on TAGITCore via TimelockController
 * @dev Required after PATCH-06 added oracle ECDSA verification to bindTag.
 *      On testnet, deployer has PROPOSER+EXECUTOR so we schedule+execute in one tx.
 *
 * Usage:
 *   forge script script/deploy/SetTrustedOracle.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL --broadcast
 */
contract SetTrustedOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Deployed addresses from registry
        address proxy = 0x8BdE22da889306d422802728cb98B6Da42ed8e1a;
        address timelockAddr = 0x1B2bdd6f0a3C9127397dE51C36Dc237b097410a8;

        // Oracle = deployer for testnet
        address oracle = deployer;

        TimelockController timelock = TimelockController(payable(timelockAddr));

        console2.log("===========================================");
        console2.log("TAG IT - Set Trusted Oracle");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Proxy:   ", proxy);
        console2.log("Timelock:", timelockAddr);
        console2.log("Oracle:  ", oracle);

        // Check current state
        address currentOracle = TAGITCore(proxy).trustedOracle();
        console2.log("Current oracle:", currentOracle);

        if (currentOracle == oracle) {
            console2.log("Oracle already set. Nothing to do.");
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        // Schedule + execute via timelock
        bytes memory data = abi.encodeCall(TAGITCore.setTrustedOracle, (oracle));
        bytes32 salt = keccak256("setTrustedOracle-testnet");
        uint256 delay = timelock.getMinDelay();

        console2.log("Timelock min delay:", delay);

        if (delay == 0) {
            // Zero delay — schedule and execute immediately
            timelock.schedule(proxy, 0, data, bytes32(0), salt, 0);
            timelock.execute(proxy, 0, data, bytes32(0), salt);
            console2.log("Executed immediately (delay=0)");
        } else {
            // Non-zero delay — schedule now, must execute later
            timelock.schedule(proxy, 0, data, bytes32(0), salt, delay);
            console2.log("Scheduled with delay:", delay, "seconds");
            console2.log("Execute after delay with:");
            console2.log("  cast send", timelockAddr);
            console2.log("  'execute(address,uint256,bytes,bytes32,bytes32)'");
            console2.log("  ", proxy, "0 <data> 0x0 <salt>");
        }

        vm.stopBroadcast();

        // Verify
        address newOracle = TAGITCore(proxy).trustedOracle();
        console2.log("");
        console2.log("Oracle after tx:", newOracle);

        if (newOracle == oracle) {
            console2.log("SUCCESS: trustedOracle is set!");
        } else {
            console2.log("NOTE: Oracle not yet set (timelock delay pending)");
        }
    }
}
