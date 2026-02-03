// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TAGITRecovery} from "../src/recovery/TAGITRecovery.sol";
import {TAGITPaymaster} from "../src/account/TAGITPaymaster.sol";
import {TAGITTreasury} from "../src/treasury/TAGITTreasury.sol";
import {TAGITPrograms} from "../src/programs/TAGITPrograms.sol";
import {TAGITStaking} from "../src/token/TAGITStaking.sol";
import {TAGITAccount} from "../src/account/TAGITAccount.sol";
import {TAGITAccountFactory} from "../src/account/TAGITAccountFactory.sol";
import {CCIPAdapter} from "../src/bridge/CCIPAdapter.sol";

/**
 * @title DeployNISTUpgrades
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deployment script for NIST CSF 2.0 security-patched implementations
 * @dev Run with: forge script script/DeployNISTUpgrades.s.sol --rpc-url <RPC_URL> --broadcast --verify
 *
 * NIST CSF 2.0 Controls Deployed:
 * - TAGITRecovery: CircuitBreaker (IR-4) + RateLimiter (AC-7)
 * - TAGITPaymaster: CircuitBreaker (IR-4) + DrainDetector (SI-4)
 * - TAGITTreasury: DrainDetector (SI-4) + timelocked alerts
 * - TAGITPrograms: DrainDetector (SI-4) for reward pools
 * - TAGITStaking: RateLimiter (AC-7) for spam protection
 * - TAGITAccount: Monitoring events (AU-3)
 * - CCIPAdapter: ReplayProtection (SC-8) + RateLimiter (AC-7)
 *
 * Post-deployment:
 * - Upgrade UUPS proxies via owner.upgradeToAndCall()
 * - Initialize NIST libraries (circuit breakers, drain detectors)
 */
contract DeployNISTUpgrades is Script {
    // New implementation addresses
    TAGITRecovery public recoveryImpl;
    TAGITPaymaster public paymasterImpl;
    TAGITTreasury public treasuryImpl;
    TAGITPrograms public programsImpl;
    TAGITStaking public stakingImpl;
    TAGITAccount public accountImpl;
    TAGITAccountFactory public accountFactoryImpl;
    CCIPAdapter public ccipAdapterImpl;

    // EntryPoint v0.7 canonical address
    address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("===========================================");
        console2.log("TAG IT Network - NIST CSF 2.0 Upgrade");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("EntryPoint:", ENTRY_POINT);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================
        // Deploy New Implementations (NIST Patched)
        // ============================================

        console2.log("Deploying NIST-patched implementations...");
        console2.log("");

        // 1. TAGITRecovery (CircuitBreaker + RateLimiter)
        console2.log("1. TAGITRecovery [NIST: IR-4, AC-7]");
        recoveryImpl = new TAGITRecovery();
        console2.log("   Implementation:", address(recoveryImpl));

        // 2. TAGITPaymaster (CircuitBreaker + DrainDetector)
        console2.log("2. TAGITPaymaster [NIST: IR-4, SI-4]");
        paymasterImpl = new TAGITPaymaster();
        console2.log("   Implementation:", address(paymasterImpl));

        // 3. TAGITTreasury (DrainDetector)
        console2.log("3. TAGITTreasury [NIST: SI-4]");
        treasuryImpl = new TAGITTreasury();
        console2.log("   Implementation:", address(treasuryImpl));

        // 4. TAGITPrograms (DrainDetector)
        console2.log("4. TAGITPrograms [NIST: SI-4]");
        programsImpl = new TAGITPrograms();
        console2.log("   Implementation:", address(programsImpl));

        // 5. TAGITStaking (RateLimiter)
        console2.log("5. TAGITStaking [NIST: AC-7]");
        stakingImpl = new TAGITStaking();
        console2.log("   Implementation:", address(stakingImpl));

        // 6. TAGITAccount (Monitoring Events - AU-3)
        console2.log("6. TAGITAccount [NIST: AU-3]");
        accountImpl = new TAGITAccount(ENTRY_POINT);
        console2.log("   Implementation:", address(accountImpl));

        // 7. TAGITAccountFactory (for new account implementation)
        console2.log("7. TAGITAccountFactory [Updated]");
        accountFactoryImpl = new TAGITAccountFactory();
        console2.log("   Implementation:", address(accountFactoryImpl));

        // 8. CCIPAdapter (ReplayProtection + RateLimiter)
        console2.log("8. CCIPAdapter [NIST: SC-8, AC-7]");
        ccipAdapterImpl = new CCIPAdapter();
        console2.log("   Implementation:", address(ccipAdapterImpl));

        vm.stopBroadcast();

        // ============================================
        // Summary
        // ============================================
        console2.log("");
        console2.log("===========================================");
        console2.log("NIST Implementations Deployed!");
        console2.log("===========================================");
        console2.log("");
        console2.log("New Implementation Addresses:");
        console2.log("  TAGITRecovery:       ", address(recoveryImpl));
        console2.log("  TAGITPaymaster:      ", address(paymasterImpl));
        console2.log("  TAGITTreasury:       ", address(treasuryImpl));
        console2.log("  TAGITPrograms:       ", address(programsImpl));
        console2.log("  TAGITStaking:        ", address(stakingImpl));
        console2.log("  TAGITAccount:        ", address(accountImpl));
        console2.log("  TAGITAccountFactory: ", address(accountFactoryImpl));
        console2.log("  CCIPAdapter:         ", address(ccipAdapterImpl));
        console2.log("");
        console2.log("NIST Controls:");
        console2.log("  IR-4 (Incident Response):  CircuitBreaker in Recovery, Paymaster");
        console2.log("  AC-7 (Rate Limiting):      RateLimiter in Recovery, Staking, CCIP");
        console2.log("  SI-4 (System Monitoring):  DrainDetector in Paymaster, Treasury, Programs");
        console2.log("  SC-8 (Transmission):       ReplayProtection in CCIPAdapter");
        console2.log("  AU-3 (Audit Logging):      Session events in TAGITAccount");
        console2.log("");
        console2.log("Next Steps:");
        console2.log("1. Upgrade UUPS proxies: proxy.upgradeToAndCall(newImpl, '')");
        console2.log("2. Initialize NIST libraries if needed via reinitializer");
        console2.log("3. Verify all contracts on Etherscan");
        console2.log("4. Test Forta event emission");
        console2.log("");
    }
}
