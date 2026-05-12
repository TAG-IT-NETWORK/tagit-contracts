// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {ReputationStaking} from "../../src/staking/ReputationStaking.sol";

/**
 * @title DeployReputationStaking
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploy standalone ReputationStaking to OP Sepolia
 * @dev Run with:
 *   forge script script/deploy/DeployReputationStaking.s.sol \
 *     --rpc-url optimism_sepolia --broadcast --verify
 *
 * Environment variables:
 *   PRIVATE_KEY    — deployer private key
 *   STAKING_TOKEN  — TAGITToken proxy address (from DeployTAGITToken run)
 *
 * @custom:security Owner is deployer (msg.sender). Transfer to multisig post-deploy.
 */
contract DeployReputationStaking is Script {
    function run() external returns (address stakingAddr) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address stakingToken = vm.envAddress("STAKING_TOKEN");

        console2.log("===========================================");
        console2.log("DeployReputationStaking");
        console2.log("===========================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Staking Token:  ", stakingToken);
        console2.log("Chain ID:       ", block.chainid);
        console2.log("");

        vm.startBroadcast(pk);

        ReputationStaking staking = new ReputationStaking(stakingToken, deployer);

        vm.stopBroadcast();
        stakingAddr = address(staking);

        console2.log("ReputationStaking deployed at:", stakingAddr);
        console2.log("  Token:    ", address(staking.stakingToken()));
        console2.log("  Owner:    ", staking.owner());
        console2.log("  MIN_STAKE:", staking.MIN_STAKE());
        console2.log("  MIN_LOCK: ", staking.MIN_LOCK());
        console2.log("");
    }
}
