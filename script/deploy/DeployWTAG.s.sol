// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {wTAG} from "../../src/token/wTAG.sol";

/**
 * @title DeployWTAG
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploy wTAG (wrapped TAGIT token) to any supported chain.
 * @dev Requires TAGITToken to be deployed for wrap/unwrap.
 *
 *   # Base Sepolia
 *   TAGIT_TOKEN=0x8D4486152f6C8ff24B4e5a1ACF71d05755983a5E \
 *   forge script script/deploy/DeployWTAG.s.sol \
 *     --rpc-url base_sepolia --broadcast --verify
 */
contract DeployWTAG is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address tagitToken = vm.envAddress("TAGIT_TOKEN");

        console2.log("=====================================================");
        console2.log("TAG IT - wTAG Deployment");
        console2.log("=====================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Chain ID:       ", block.chainid);
        console2.log("TAGITToken:     ", tagitToken);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy wTAG (admin = deployer, minter = deployer for testnet)
        wTAG wtag = new wTAG(tagitToken, deployer, deployer);

        vm.stopBroadcast();

        console2.log("=====================================================");
        console2.log("wTAG deployed!");
        console2.log("=====================================================");
        console2.log("  wTAG:          ", address(wtag));
        console2.log("  Cap:           ", wtag.cap());
        console2.log("  Admin:         ", deployer);
        console2.log("  Minter:        ", deployer);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Set TGE: wtag.setTGE(timestamp)");
        console2.log("  2. Deploy wTAGStaking (requires TAGITStaking.token() to be configured)");
        console2.log("  3. Update deployment-addresses.json + docs");
    }
}
