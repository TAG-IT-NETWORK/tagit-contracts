// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title DeployTAGITCoreProxy
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploys TAGITCore as UUPS proxy with TimelockController on OP Sepolia
 * @dev Reuses existing IdentityBadge, CapabilityBadge, and TAGITAccess contracts.
 *
 * Environment variables:
 *   PRIVATE_KEY    — Deployer private key
 *   SAFE_ADDRESS   — Gnosis Safe multisig address
 *   TAGIT_ACCESS   — Existing TAGITAccess contract address
 *
 * Deployment:
 *   # Dry-run
 *   forge script script/deploy/DeployTAGITCoreProxy.s.sol --rpc-url $OP_SEPOLIA_RPC_URL
 *
 *   # Broadcast + verify
 *   forge script script/deploy/DeployTAGITCoreProxy.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeployTAGITCoreProxy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address tagitAccess = vm.envAddress("TAGIT_ACCESS");

        console2.log("===========================================");
        console2.log("TAG IT - Deploy TAGITCore Proxy Stack");
        console2.log("===========================================");
        console2.log("Deployer:      ", deployer);
        console2.log("Safe:          ", safeAddress);
        console2.log("TAGITAccess:   ", tagitAccess);
        console2.log("Chain ID:      ", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy TimelockController (minDelay=0 for initial config)
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;
        TimelockController timelock = new TimelockController(0, proposers, executors, address(0));
        console2.log("1. TimelockController:", address(timelock));

        // 2. Deploy TAGITCore implementation
        TAGITCore impl = new TAGITCore();
        console2.log("2. TAGITCore impl:   ", address(impl));

        // 3. Deploy ERC1967Proxy -> initialize(timelock)
        ERC1967Proxy proxy;
        {
            bytes memory initData = abi.encodeCall(TAGITCore.initialize, (address(timelock)));
            proxy = new ERC1967Proxy(address(impl), initData);
        }
        console2.log("3. TAGITCore proxy:  ", address(proxy));

        // 4. setAccessController via timelock (delay=0)
        {
            bytes memory data = abi.encodeCall(TAGITCore.setAccessController, (tagitAccess));
            bytes32 salt = keccak256("setAccessController");
            timelock.schedule(address(proxy), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(proxy), 0, data, bytes32(0), salt);
        }
        console2.log("4. setAccessController done");

        // 5. Grant PROPOSER_ROLE + EXECUTOR_ROLE to Safe (delay still 0)
        {
            bytes32 role = timelock.PROPOSER_ROLE();
            bytes memory data = abi.encodeCall(IAccessControl.grantRole, (role, safeAddress));
            bytes32 salt = keccak256("grantProposerToSafe");
            timelock.schedule(address(timelock), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(timelock), 0, data, bytes32(0), salt);
        }
        console2.log("5a. PROPOSER_ROLE granted to Safe");

        {
            bytes32 role = timelock.EXECUTOR_ROLE();
            bytes memory data = abi.encodeCall(IAccessControl.grantRole, (role, safeAddress));
            bytes32 salt = keccak256("grantExecutorToSafe");
            timelock.schedule(address(timelock), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(timelock), 0, data, bytes32(0), salt);
        }
        console2.log("5b. EXECUTOR_ROLE granted to Safe");

        // 6. Bump delay to 5 minutes -- MUST be last zero-delay operation
        {
            bytes memory data = abi.encodeCall(TimelockController.updateDelay, (5 minutes));
            bytes32 salt = keccak256("updateDelay");
            timelock.schedule(address(timelock), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(timelock), 0, data, bytes32(0), salt);
        }
        console2.log("6. updateDelay(300s) done");

        // ============================================
        // PRE-AUDIT: Revoke deployer PROPOSER_ROLE + EXECUTOR_ROLE before mainnet
        //
        // For testnet iteration, deployer keeps roles so we can reconfigure
        // without going through the 5-minute timelock delay.
        //
        // Before mainnet deployment:
        //   timelock.schedule(address(timelock), 0,
        //     abi.encodeCall(IAccessControl.revokeRole, (PROPOSER_ROLE, deployer)),
        //     bytes32(0), keccak256("revokeProposerFromDeployer"), <delay>);
        //   timelock.schedule(address(timelock), 0,
        //     abi.encodeCall(IAccessControl.revokeRole, (EXECUTOR_ROLE, deployer)),
        //     bytes32(0), keccak256("revokeExecutorFromDeployer"), <delay>);
        // ============================================

        vm.stopBroadcast();

        // Summary
        console2.log("");
        console2.log("===========================================");
        console2.log("Deployment Complete!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Contract Addresses:");
        console2.log("  TimelockController:", address(timelock));
        console2.log("  TAGITCore (impl):  ", address(impl));
        console2.log("  TAGITCore (proxy): ", address(proxy));
        console2.log("");
        console2.log("Reused: TAGITAccess at", tagitAccess);
        console2.log("Timelock delay: 5 minutes (testnet)");
        console2.log("Safe:    ", safeAddress);
        console2.log("Deployer:", deployer);
        console2.log("  Both have PROPOSER + EXECUTOR (revoke deployer before mainnet)");
        console2.log("");
        console2.log("Verification:");
        console2.log("  cast call <PROXY> 'getImplementation()(address)' --rpc-url $OP_SEPOLIA_RPC_URL");
        console2.log("  cast call <PROXY> 'owner()(address)' --rpc-url $OP_SEPOLIA_RPC_URL");
        console2.log("  cast call <PROXY> 'name()(string)' --rpc-url $OP_SEPOLIA_RPC_URL");
        console2.log("");
        console2.log("Old TAGITCore (deprecated): 0x8B02b62FD388b2d7e3dF5Ec666D68Ac7c7ca02Fe");
    }
}
