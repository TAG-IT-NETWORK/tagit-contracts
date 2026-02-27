// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITCore} from "../src/core/TAGITCore.sol";
import {TAGITAccess} from "../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title Deploy
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deployment script for TAG IT contracts (BIDGES + Core via UUPS proxy)
 * @dev Run with: forge script script/Deploy.s.sol --rpc-url <RPC_URL> --private-key <KEY> --broadcast --verify
 *
 * Deployment Order:
 * 1. IdentityBadge (ERC-5192 soulbound badges)
 * 2. CapabilityBadge (ERC-1155 capability tokens)
 * 3. TAGITAccess (BIDGES facade controller)
 * 4. TimelockController (48hr delay, Gnosis Safe as proposer/executor)
 * 5. TAGITCore implementation + ERC1967Proxy (UUPS, owned by TimelockController)
 *
 * Post-deployment configuration:
 * - TAGITAccess.setIdentityBadge(identityBadge)
 * - TAGITAccess.setCapabilityBadge(capabilityBadge)
 * - TAGITCore.setAccessController(tagitAccess) — via TimelockController
 */
contract Deploy is Script {
    // Deployed contract addresses
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;
    TAGITAccess public tagitAccess;
    TimelockController public timelock;
    TAGITCore public tagitCoreImpl;
    TAGITCore public tagitCore; // proxy

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
        // 4. Deploy TimelockController (minDelay=0 for initial config)
        // ============================================
        console2.log("4. Deploying TimelockController (minDelay=0 for setup)...");
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer; // TODO: Replace with Gnosis Safe 3-of-5 address
        executors[0] = deployer; // TODO: Replace with Gnosis Safe 3-of-5 address
        timelock = new TimelockController(
            0, // minDelay: 0 for initial configuration (bumped to 48hr after setup)
            proposers, // proposers: Gnosis Safe multisig
            executors, // executors: Gnosis Safe multisig
            address(0) // admin: no additional admin (renounced)
        );
        console2.log("   TimelockController deployed at:", address(timelock));

        // ============================================
        // 5. Deploy TAGITCore via UUPS proxy
        // ============================================
        console2.log("5. Deploying TAGITCore (UUPS proxy)...");
        tagitCoreImpl = new TAGITCore();
        console2.log("   TAGITCore implementation at:", address(tagitCoreImpl));

        // Owner = TimelockController (all admin ops require 48hr delay)
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (address(timelock)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(tagitCoreImpl), initData);
        tagitCore = TAGITCore(address(proxy));
        console2.log("   TAGITCore proxy at:", address(tagitCore));

        // ============================================
        // 6. Configure TAGITAccess
        // ============================================
        console2.log("6. Configuring TAGITAccess...");
        tagitAccess.setIdentityBadge(address(identityBadge));
        console2.log("   - Set IdentityBadge");
        tagitAccess.setCapabilityBadge(address(capabilityBadge));
        console2.log("   - Set CapabilityBadge");

        // ============================================
        // 7. Configure TAGITCore (via TimelockController)
        // ============================================
        console2.log("7. Configuring TAGITCore access controller...");
        // Schedule + execute setAccessController through timelock
        // For initial deployment, we use deployer as proposer/executor
        bytes memory setAccessData = abi.encodeCall(TAGITCore.setAccessController, (address(tagitAccess)));
        timelock.schedule(
            address(tagitCore), // target
            0, // value
            setAccessData, // data
            bytes32(0), // predecessor
            bytes32(0), // salt
            0 // delay (0 for initial setup — deployer is proposer)
        );
        timelock.execute(address(tagitCore), 0, setAccessData, bytes32(0), bytes32(0));
        console2.log("   - Set AccessController via TimelockController");

        // ============================================
        // 8. Bump TimelockController delay to 48 hours
        // ============================================
        console2.log("8. Bumping TimelockController delay to 48 hours...");
        bytes memory updateDelayData = abi.encodeCall(TimelockController.updateDelay, (48 hours));
        bytes32 delaySalt = keccak256("updateDelay");
        timelock.schedule(address(timelock), 0, updateDelayData, bytes32(0), delaySalt, 0);
        timelock.execute(address(timelock), 0, updateDelayData, bytes32(0), delaySalt);
        console2.log("   - updateDelay(48 hours) done");

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
        console2.log("  IdentityBadge:      ", address(identityBadge));
        console2.log("  CapabilityBadge:    ", address(capabilityBadge));
        console2.log("  TAGITAccess:        ", address(tagitAccess));
        console2.log("  TimelockController: ", address(timelock));
        console2.log("  TAGITCore (impl):   ", address(tagitCoreImpl));
        console2.log("  TAGITCore (proxy):  ", address(tagitCore));
        console2.log("");
        console2.log("Admin: TimelockController (48hr delay)");
        console2.log("Deployer:          ", deployer);
        console2.log("");
        console2.log("Next Steps:");
        console2.log("1. Transfer TimelockController proposer/executor to Gnosis Safe 3-of-5");
        console2.log("2. Grant capabilities to operators via CapabilityBadge");
        console2.log("3. Grant identity badges to verified users via IdentityBadge");
        console2.log("4. Test mint() on TAGITCore (requires MINTER_CAPABILITY)");
        console2.log("");
    }
}
