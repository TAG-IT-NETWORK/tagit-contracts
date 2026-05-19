// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {VerificationEscrow} from "../../src/escrow/VerificationEscrow.sol";

/**
 * @title DeployVerificationEscrow
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploy standalone VerificationEscrow to OP Sepolia / Base Sepolia (chain-aware)
 * @dev Run with:
 *   forge script script/deploy/DeployVerificationEscrow.s.sol \
 *     --rpc-url optimism_sepolia --broadcast --verify
 *
 * Environment variables:
 *   PRIVATE_KEY         — deployer private key
 *   TRUSTED_ORACLE      — oracle address for ECDSA proof verification
 *                          (optional; defaults to deployer)
 *   USDC_ADDRESS        — optional override for the USDC token address
 *
 * Defaults by chain:
 *   OP Sepolia   (11155420) — 0x5fd84259d66Cd46123540766Be93DFE6D43130D7 (Circle official)
 *   Base Sepolia (84532)    — 0x036CbD53842c5426634e7929541eC2318f3dCF7e (Circle official)
 *
 * @custom:security Owner is deployer (msg.sender). Transfer ownership to multisig post-deploy.
 */
contract DeployVerificationEscrow is Script {
    /// @notice Circle's official USDC on OP Sepolia
    address constant OP_SEPOLIA_USDC = 0x5fd84259d66Cd46123540766Be93DFE6D43130D7;

    /// @notice Circle's official USDC on Base Sepolia
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external returns (address escrowAddr) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address trustedOracle;
        try vm.envAddress("TRUSTED_ORACLE") returns (address o) {
            trustedOracle = o;
        } catch {
            trustedOracle = deployer;
        }

        address usdc;
        try vm.envAddress("USDC_ADDRESS") returns (address u) {
            usdc = u;
        } catch {
            if (block.chainid == 11155420) {
                usdc = OP_SEPOLIA_USDC;
            } else if (block.chainid == 84532) {
                usdc = BASE_SEPOLIA_USDC;
            } else {
                revert("Unknown chain: set USDC_ADDRESS env var");
            }
        }

        console2.log("===========================================");
        console2.log("DeployVerificationEscrow");
        console2.log("===========================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Trusted Oracle: ", trustedOracle);
        console2.log("USDC:           ", usdc);
        console2.log("Chain ID:       ", block.chainid);
        console2.log("");

        vm.startBroadcast(pk);

        VerificationEscrow escrow = new VerificationEscrow(usdc, trustedOracle);

        vm.stopBroadcast();
        escrowAddr = address(escrow);

        console2.log("VerificationEscrow deployed at:", address(escrow));
        console2.log("");
        console2.log("Verification:");
        console2.log("  USDC:    ", address(escrow.usdc()));
        console2.log("  Oracle:  ", escrow.trustedOracle());
        console2.log("  Owner:   ", escrow.owner());
        console2.log("");
    }
}
