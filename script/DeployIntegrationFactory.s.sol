// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "@forge-std/Script.sol";
import {IntegrationFactory} from "../src/agent/IntegrationFactory.sol";

/**
 * @title DeployIntegrationFactory
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deployment script for IntegrationFactory (partner onboarding)
 * @dev Run with: forge script script/DeployIntegrationFactory.s.sol \
 *        --rpc-url <RPC_URL> --private-key <KEY> --broadcast --verify
 *
 * Required environment variables:
 *   PRIVATE_KEY       — Deployer private key
 *   BURNER_ADDRESS    — TAGITBurner contract address
 *   SIGNER_1          — Multi-sig signer 1 address
 *   SIGNER_2          — Multi-sig signer 2 address
 *   SIGNER_3          — Multi-sig signer 3 address
 *   REQUIRED_SIGS     — Required signature count (default: 2)
 */
contract DeployIntegrationFactory is Script {
    IntegrationFactory public factory;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address burnerAddr = vm.envAddress("BURNER_ADDRESS");
        address signer1 = vm.envAddress("SIGNER_1");
        address signer2 = vm.envAddress("SIGNER_2");
        address signer3 = vm.envAddress("SIGNER_3");
        uint256 requiredSigs = vm.envOr("REQUIRED_SIGS", uint256(2));

        console2.log("===========================================");
        console2.log("IntegrationFactory Deployment");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Burner:", burnerAddr);
        console2.log("Signer 1:", signer1);
        console2.log("Signer 2:", signer2);
        console2.log("Signer 3:", signer3);
        console2.log("Required sigs:", requiredSigs);
        console2.log("");

        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.startBroadcast(deployerPrivateKey);

        factory = new IntegrationFactory(burnerAddr, deployer, signers, requiredSigs);

        vm.stopBroadcast();

        console2.log("IntegrationFactory deployed at:", address(factory));
        console2.log("Owner:", factory.owner());
        console2.log("Max payment:", factory.maxPaymentPerTx());
        console2.log("Version:", factory.version());
    }
}
