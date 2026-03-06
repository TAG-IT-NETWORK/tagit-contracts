// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {TAGITCoreDemo} from "../../src/core/TAGITCoreDemo.sol";

contract DeployArbitrumSepoliaDemo is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy TAGITCoreDemo
        TAGITCoreDemo core = new TAGITCoreDemo();
        console2.log("TAGITCoreDemo deployed at:", address(core));

        // Pre-mint 3 demo assets
        core.mint(1, "Nasal Drops");
        core.mint(2, "Di0r Eye Cream");
        core.mint(3, "Sunbiz Certificate");
        console2.log("3 demo assets minted (tokenIds 1, 2, 3)");

        vm.stopBroadcast();
    }
}
