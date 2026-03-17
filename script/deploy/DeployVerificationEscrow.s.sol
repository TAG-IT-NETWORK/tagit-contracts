// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {VerificationEscrow} from "../../src/escrow/VerificationEscrow.sol";

/**
 * @title DeployVerificationEscrow
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploy standalone VerificationEscrow to Base Sepolia
 * @dev Run with:
 *   forge script script/deploy/DeployVerificationEscrow.s.sol \
 *     --rpc-url base_sepolia --broadcast --verify
 *
 * Environment variables:
 *   PRIVATE_KEY         — deployer private key
 *   TRUSTED_ORACLE      — oracle address for ECDSA proof verification
 *
 * Base Sepolia USDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e (Circle official, 6 decimals)
 *
 * @custom:security Owner is deployer (msg.sender). Transfer ownership to multisig post-deploy.
 */
contract DeployVerificationEscrow is Script {
    /// @notice Circle's official USDC on Base Sepolia
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address trustedOracle = vm.envAddress("TRUSTED_ORACLE");

        console2.log("===========================================");
        console2.log("DeployVerificationEscrow");
        console2.log("===========================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Trusted Oracle: ", trustedOracle);
        console2.log("USDC:           ", BASE_SEPOLIA_USDC);
        console2.log("Chain ID:       ", block.chainid);
        console2.log("");

        vm.startBroadcast(pk);

        VerificationEscrow escrow = new VerificationEscrow(BASE_SEPOLIA_USDC, trustedOracle);

        vm.stopBroadcast();

        console2.log("VerificationEscrow deployed at:", address(escrow));
        console2.log("");
        console2.log("Verification:");
        console2.log("  USDC:    ", address(escrow.usdc()));
        console2.log("  Oracle:  ", escrow.trustedOracle());
        console2.log("  Owner:   ", escrow.owner());
        console2.log("");
    }
}
