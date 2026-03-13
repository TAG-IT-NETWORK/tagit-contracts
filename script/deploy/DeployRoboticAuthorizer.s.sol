// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RoboticAuthorizer} from "../../src/robot/RoboticAuthorizer.sol";

/**
 * @title DeployRoboticAuthorizer
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploy standalone RoboticAuthorizer proxy (multi-chain)
 * @dev Automatically selects addresses based on chain ID.
 *
 *   # Arbitrum Sepolia
 *   forge script script/deploy/DeployRoboticAuthorizer.s.sol \
 *     --rpc-url arbitrum_sepolia --broadcast --verify
 *
 *   # OP Sepolia
 *   forge script script/deploy/DeployRoboticAuthorizer.s.sol \
 *     --rpc-url op_sepolia --broadcast --verify
 *
 * @custom:security Owner is TimelockController — future upgrades go through timelock delay
 */
contract DeployRoboticAuthorizer is Script {
    // ── Arbitrum Sepolia (421614) ──
    address constant ARB_CORE = 0x2cb1E0ecE274217F214057c0a829582834Aeaf7f;
    address constant ARB_ACCESS = 0x676f593c451E4dF2345026af891Acc92c4344455;
    address constant ARB_TIMELOCK = 0x6D7F3242DAFB07b8E873Cf1e0a635536ba241fbA;

    // ── OP Sepolia (11155420) ──
    address constant OP_CORE = 0x8BdE22da889306d422802728cb98B6Da42ed8e1a;
    address constant OP_ACCESS = 0x0611FE60f6E37230bDaf04c5F2Ac2dc9012130a9;
    address constant OP_TIMELOCK = 0x1B2bdd6f0a3C9127397dE51C36Dc237b097410a8;

    error UnsupportedChain(uint256 chainId);

    function _getAddresses() internal view returns (address core, address access, address timelock) {
        if (block.chainid == 421614) {
            return (ARB_CORE, ARB_ACCESS, ARB_TIMELOCK);
        } else if (block.chainid == 11155420) {
            return (OP_CORE, OP_ACCESS, OP_TIMELOCK);
        } else {
            revert UnsupportedChain(block.chainid);
        }
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        (address core, address access, address timelock) = _getAddresses();

        console2.log("===========================================");
        console2.log("DeployRoboticAuthorizer");
        console2.log("===========================================");
        console2.log("Deployer: ", deployer);
        console2.log("Core:     ", core);
        console2.log("Access:   ", access);
        console2.log("Owner:    ", timelock);
        console2.log("Chain ID: ", block.chainid);

        vm.startBroadcast(pk);

        // Deploy implementation
        RoboticAuthorizer implementation = new RoboticAuthorizer();
        console2.log("Impl:     ", address(implementation));

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(RoboticAuthorizer.initialize, (timelock, core, access));
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
