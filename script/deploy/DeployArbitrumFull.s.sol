// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title DeployArbitrumFull
 * @author TAG IT Network <dev@tagit.network>
 * @notice Full deployment of TAGITCore + Access Control stack to Arbitrum Sepolia.
 * @dev Hackathon mode — deployer keeps control, no Safe multisig.
 *
 *   Deploys: IdentityBadge, CapabilityBadge, TAGITAccess, TimelockController,
 *            TAGITCore (UUPS proxy). Wires access control and grants deployer
 *            ADMIN badge + all 7 capabilities for demo.
 *
 *   # Dry-run
 *   forge script script/deploy/DeployArbitrumFull.s.sol --rpc-url arbitrum_sepolia
 *
 *   # Broadcast + verify
 *   forge script script/deploy/DeployArbitrumFull.s.sol \
 *     --rpc-url arbitrum_sepolia --broadcast --verify
 */
contract DeployArbitrumFull is Script {
    // Badge / capability IDs
    uint256 constant ADMIN_BADGE = 1;

    // TAGITCore checks capabilities via keccak256 hashes cast to uint256
    uint256 constant CAP_MINTER = uint256(keccak256("MINTER"));
    uint256 constant CAP_BINDER = uint256(keccak256("BINDER"));
    uint256 constant CAP_ACTIVATOR = uint256(keccak256("ACTIVATOR"));
    uint256 constant CAP_CLAIMER = uint256(keccak256("CLAIMER"));
    uint256 constant CAP_FLAGGER = uint256(keccak256("FLAGGER"));
    uint256 constant CAP_RESOLVER = uint256(keccak256("RESOLVER"));
    uint256 constant CAP_RECYCLER = uint256(keccak256("RECYCLER"));

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("===========================================");
        console2.log("TAG IT - Arbitrum Sepolia Full Deploy");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ── 1. Deploy IdentityBadge (deployer = owner) ──────────────
        IdentityBadge identityBadge = new IdentityBadge();
        console2.log("1. IdentityBadge:    ", address(identityBadge));

        // ── 2. Deploy CapabilityBadge (deployer = owner) ────────────
        CapabilityBadge capabilityBadge = new CapabilityBadge();
        console2.log("2. CapabilityBadge:  ", address(capabilityBadge));

        // ── 3. Deploy TAGITAccess + wire badges ─────────────────────
        TAGITAccess tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));
        console2.log("3. TAGITAccess:      ", address(tagitAccess));

        // ── 4. Deploy TimelockController (minDelay=0 for setup) ─────
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;
        TimelockController timelock = new TimelockController(0, proposers, executors, address(0));
        console2.log("4. TimelockController:", address(timelock));

        // ── 5. Deploy TAGITCore implementation ──────────────────────
        TAGITCore impl = new TAGITCore();
        console2.log("5. TAGITCore impl:   ", address(impl));

        // ── 6. Deploy ERC1967Proxy → initialize(timelock) ──────────
        ERC1967Proxy proxy;
        {
            bytes memory initData = abi.encodeCall(TAGITCore.initialize, (address(timelock)));
            proxy = new ERC1967Proxy(address(impl), initData);
        }
        console2.log("6. TAGITCore proxy:  ", address(proxy));

        // ── 7a. setAccessController via timelock (delay=0) ──────────
        {
            bytes memory data = abi.encodeCall(TAGITCore.setAccessController, (address(tagitAccess)));
            bytes32 salt = keccak256("setAccessController");
            timelock.schedule(address(proxy), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(proxy), 0, data, bytes32(0), salt);
        }
        console2.log("7a. setAccessController done");

        // ── 7b. setTrustedOracle via timelock (delay=0) ─────────────
        {
            bytes memory data = abi.encodeCall(TAGITCore.setTrustedOracle, (deployer));
            bytes32 salt = keccak256("setTrustedOracle");
            timelock.schedule(address(proxy), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(proxy), 0, data, bytes32(0), salt);
        }
        console2.log("7b. setTrustedOracle done (oracle = deployer)");

        // ── 8. Grant deployer ADMIN identity badge ──────────────────
        identityBadge.grantIdentity(deployer, ADMIN_BADGE);
        console2.log("8.  ADMIN badge granted to deployer");

        // ── 9. Grant deployer all 7 capabilities ────────────────────
        {
            uint256[] memory caps = new uint256[](7);
            caps[0] = CAP_MINTER;
            caps[1] = CAP_BINDER;
            caps[2] = CAP_ACTIVATOR;
            caps[3] = CAP_CLAIMER;
            caps[4] = CAP_FLAGGER;
            caps[5] = CAP_RESOLVER;
            caps[6] = CAP_RECYCLER;
            capabilityBadge.batchGrantCapabilities(deployer, caps);
        }
        console2.log("9.  All 7 capabilities granted to deployer");

        // ── 10. Bump timelock delay to 60s — MUST be last 0-delay op
        {
            bytes memory data = abi.encodeCall(TimelockController.updateDelay, (60));
            bytes32 salt = keccak256("updateDelay");
            timelock.schedule(address(timelock), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(timelock), 0, data, bytes32(0), salt);
        }
        console2.log("10. updateDelay(60s) done");

        vm.stopBroadcast();

        // ── Summary ─────────────────────────────────────────────────
        console2.log("");
        console2.log("===========================================");
        console2.log("Arbitrum Sepolia Full Deployment Complete!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Contract Addresses:");
        console2.log("  IdentityBadge:     ", address(identityBadge));
        console2.log("  CapabilityBadge:   ", address(capabilityBadge));
        console2.log("  TAGITAccess:       ", address(tagitAccess));
        console2.log("  TimelockController:", address(timelock));
        console2.log("  TAGITCore (impl):  ", address(impl));
        console2.log("  TAGITCore (proxy): ", address(proxy));
        console2.log("");
        console2.log("Oracle:  ", deployer);
        console2.log("Timelock delay: 60 seconds (hackathon)");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Update exports/addresses.json with Arbitrum Sepolia addresses");
        console2.log("  2. Update tagit-dashboard/packages/contracts/src/addresses.ts");
        console2.log("  3. Mint test assets for demo");
    }
}
