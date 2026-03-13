// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployArbitrumSepolia
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploys TAGITCore as UUPS proxy to Arbitrum Sepolia for hackathon demo.
 * @dev Simplified deployment — no Safe, no TAGITAccess dependency. Deployer gets full control.
 *
 *   # Dry-run
 *   forge script script/deploy/DeployArbitrumSepolia.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL
 *
 *   # Broadcast + verify
 *   forge script script/deploy/DeployArbitrumSepolia.s.sol \
 *     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --verify
 */
contract DeployArbitrumSepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("===========================================");
        console2.log("TAG IT - Arbitrum Sepolia Hackathon Deploy");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy TimelockController (minDelay=0 for hackathon speed)
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;
        TimelockController timelock = new TimelockController(0, proposers, executors, address(0));
        console2.log("1. TimelockController:", address(timelock));

        // 2. Deploy TAGITCore implementation
        TAGITCore impl = new TAGITCore();
        console2.log("2. TAGITCore impl:   ", address(impl));

        // 3. Deploy ERC1967Proxy → initialize(timelock)
        ERC1967Proxy proxy;
        {
            bytes memory initData = abi.encodeCall(TAGITCore.initialize, (address(timelock)));
            proxy = new ERC1967Proxy(address(impl), initData);
        }
        console2.log("3. TAGITCore proxy:  ", address(proxy));

        // 4. Set deployer as trusted oracle (for NFC verification demo)
        {
            bytes memory data = abi.encodeCall(TAGITCore.setTrustedOracle, (deployer));
            bytes32 salt = keccak256("setTrustedOracle");
            timelock.schedule(address(proxy), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(proxy), 0, data, bytes32(0), salt);
        }
        console2.log("4. setTrustedOracle done (oracle = deployer)");

        // 5. Bump delay to 1 minute (lighter for hackathon demo)
        {
            bytes memory data = abi.encodeCall(TimelockController.updateDelay, (1 minutes));
            bytes32 salt = keccak256("updateDelay");
            timelock.schedule(address(timelock), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(timelock), 0, data, bytes32(0), salt);
        }
        console2.log("5. updateDelay(60s) done");

        vm.stopBroadcast();

        // Summary
        console2.log("");
        console2.log("===========================================");
        console2.log("Arbitrum Sepolia Deployment Complete!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Contract Addresses:");
        console2.log("  TimelockController:", address(timelock));
        console2.log("  TAGITCore (impl):  ", address(impl));
        console2.log("  TAGITCore (proxy): ", address(proxy));
        console2.log("");
        console2.log("Oracle: ", deployer);
        console2.log("Timelock delay: 1 minute (hackathon)");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Update exports/addresses.json with Arbitrum Sepolia addresses");
        console2.log("  2. Verify on Arbiscan:");
        console2.log("     forge verify-contract <PROXY> TAGITCore --chain-id 421614");
        console2.log("  3. Mint test assets for demo");
    }
}
