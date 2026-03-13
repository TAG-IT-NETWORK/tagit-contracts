// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RoboticAuthorizer} from "../../src/robot/RoboticAuthorizer.sol";

/**
 * @title DeployRoboticAuthorizer
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploy standalone RoboticAuthorizer proxy on Arbitrum Sepolia
 * @dev Single-step deployment (no timelock needed for initial deploy):
 *
 *   forge script script/deploy/DeployRoboticAuthorizer.s.sol \
 *     --rpc-url arbitrum_sepolia --broadcast --verify
 *
 * @custom:security Owner is TimelockController — future upgrades go through timelock delay
 */
contract DeployRoboticAuthorizer is Script {
    /// @dev TAGITCore proxy (Arbitrum Sepolia)
    address constant CORE_PROXY = 0x2cb1E0ecE274217F214057c0a829582834Aeaf7f;

    /// @dev TAGITAccess (Arbitrum Sepolia)
    address constant ACCESS = 0x676f593c451E4dF2345026af891Acc92c4344455;

    /// @dev TimelockController — will be the owner
    address constant TIMELOCK = 0x6D7F3242DAFB07b8E873Cf1e0a635536ba241fbA;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("===========================================");
        console2.log("DeployRoboticAuthorizer");
        console2.log("===========================================");
        console2.log("Deployer: ", deployer);
        console2.log("Core:     ", CORE_PROXY);
        console2.log("Access:   ", ACCESS);
        console2.log("Owner:    ", TIMELOCK);
        console2.log("Chain ID: ", block.chainid);

        vm.startBroadcast(pk);

        // Deploy implementation
        RoboticAuthorizer implementation = new RoboticAuthorizer();
        console2.log("Impl:     ", address(implementation));

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(RoboticAuthorizer.initialize, (TIMELOCK, CORE_PROXY, ACCESS));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console2.log("Proxy:    ", address(proxy));

        vm.stopBroadcast();

        // Smoke test
        RoboticAuthorizer authorizer = RoboticAuthorizer(address(proxy));
        console2.log("");
        console2.log("Verification:");
        console2.log("  Core:   ", authorizer.coreContract());
        console2.log("  Access: ", authorizer.accessController());

        (bool isTripped,) = authorizer.getRobotCircuitBreakerStatus();
        console2.log("  CB tripped:", isTripped);

        uint256 capacity = authorizer.getRobotCircuitBreakerCapacity();
        console2.log("  CB capacity:", capacity);
        console2.log("");
    }
}
