// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {ITAGITAccess} from "../../src/interfaces/ITAGITAccess.sol";
import {ITAGITStaking} from "../../src/interfaces/ITAGITStaking.sol";

import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITGovernor} from "../../src/governance/TAGITGovernor.sol";
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {TAGITRecovery} from "../../src/recovery/TAGITRecovery.sol";
import {TAGITPrograms} from "../../src/programs/TAGITPrograms.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title DeployTokenAndGovernor
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploys TAGITToken + TAGITGovernor, redeploys Treasury, upgrades Recovery + Programs
 * @dev SEC-AUD-001 remediation: deploys missing contracts and wires all cross-references
 *
 * Usage:
 *   forge script script/deploy/DeployTokenAndGovernor.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL --broadcast
 */
contract DeployTokenAndGovernor is Script {
    // Existing deployed addresses
    address constant TAGIT_CORE        = 0x8BdE22da889306d422802728cb98B6Da42ed8e1a;
    address constant TIMELOCK          = 0x1B2bdd6f0a3C9127397dE51C36Dc237b097410a8;
    address constant TAGIT_ACCESS      = 0x0611FE60f6E37230bDaf04c5F2Ac2dc9012130a9;
    address constant TAGIT_STAKING     = 0xe500CDfbA693CE1f39A6F05CfB4614971370Ee93;
    address constant RECOVERY_PROXY    = 0x17c0af6B37aBD06587303f1695a06A668F8A5A8c;
    address constant PROGRAMS_PROXY    = 0x4d1007eB4823a5a13905A0361478C339421ce4C9;
    address constant TREASURY_IMPL_OLD = 0xf6f5e2e03f6e28aE9Dc17bCc814a0cf758c887c9;

    // Newly deployed addresses (populated during run)
    address public tokenProxy;
    address public tokenImpl;
    address public govProxy;
    address public govImpl;
    address public treasuryProxy;
    address public recoveryImplNew;
    address public programsImplNew;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("=============================================");
        console2.log("TAG IT - Deploy Token & Governor (SEC-AUD-001)");
        console2.log("=============================================");
        console2.log("Deployer:", deployer);
        console2.log("");

        vm.startBroadcast(pk);

        _deployToken(deployer);
        _deployGovernor(deployer);
        _redeployTreasury(deployer);
        _upgradeRecovery();
        _upgradePrograms();

        vm.stopBroadcast();

        _printSummary();
    }

    function _deployToken(address deployer) internal {
        console2.log("--- Step 1: Deploy TAGITToken ---");
        tokenImpl = address(new TAGITToken());
        bytes memory init = abi.encodeCall(TAGITToken.initialize, (deployer, deployer));
        tokenProxy = address(new ERC1967Proxy(tokenImpl, init));
        console2.log("  impl: ", tokenImpl);
        console2.log("  proxy:", tokenProxy);
        console2.log("");
    }

    function _deployGovernor(address deployer) internal {
        console2.log("--- Step 2: Deploy TAGITGovernor ---");
        govImpl = address(new TAGITGovernor());
        bytes memory init = abi.encodeCall(
            TAGITGovernor.initialize,
            (
                IVotes(tokenProxy),
                TimelockControllerUpgradeable(payable(TIMELOCK)),
                ITAGITAccess(TAGIT_ACCESS),
                ITAGITStaking(TAGIT_STAKING),
                deployer,
                deployer
            )
        );
        govProxy = address(new ERC1967Proxy(govImpl, init));
        console2.log("  impl: ", govImpl);
        console2.log("  proxy:", govProxy);
        console2.log("");
    }

    function _redeployTreasury(address deployer) internal {
        console2.log("--- Step 3: Redeploy TAGITTreasury ---");
        address[] memory signers = new address[](1);
        signers[0] = deployer;
        bytes memory init = abi.encodeCall(
            TAGITTreasury.initialize,
            (deployer, tokenProxy, signers)
        );
        treasuryProxy = address(new ERC1967Proxy(TREASURY_IMPL_OLD, init));
        console2.log("  proxy (NEW):", treasuryProxy);
        console2.log("  impl (reused):", TREASURY_IMPL_OLD);
        console2.log("");
    }

    function _upgradeRecovery() internal {
        console2.log("--- Step 4: Upgrade TAGITRecovery ---");
        recoveryImplNew = address(new TAGITRecovery());
        UUPSUpgradeable(RECOVERY_PROXY).upgradeToAndCall(recoveryImplNew, "");
        console2.log("  new impl:", recoveryImplNew);

        TAGITRecovery recovery = TAGITRecovery(RECOVERY_PROXY);
        recovery.setCore(TAGIT_CORE);
        recovery.setToken(tokenProxy);
        recovery.setTreasury(treasuryProxy);
        console2.log("  core:    ", TAGIT_CORE);
        console2.log("  token:   ", tokenProxy);
        console2.log("  treasury:", treasuryProxy);
        console2.log("");
    }

    function _upgradePrograms() internal {
        console2.log("--- Step 5: Upgrade TAGITPrograms ---");
        programsImplNew = address(new TAGITPrograms());
        UUPSUpgradeable(PROGRAMS_PROXY).upgradeToAndCall(programsImplNew, "");
        console2.log("  new impl:", programsImplNew);

        TAGITPrograms(PROGRAMS_PROXY).setToken(tokenProxy);
        console2.log("  token:   ", tokenProxy);
        console2.log("");
    }

    function _printSummary() internal view {
        console2.log("=============================================");
        console2.log("DEPLOYMENT COMPLETE");
        console2.log("=============================================");
        console2.log("TAGITToken proxy:    ", tokenProxy);
        console2.log("TAGITToken impl:     ", tokenImpl);
        console2.log("TAGITGovernor proxy: ", govProxy);
        console2.log("TAGITGovernor impl:  ", govImpl);
        console2.log("TAGITTreasury proxy: ", treasuryProxy);
        console2.log("TAGITRecovery impl:  ", recoveryImplNew);
        console2.log("TAGITPrograms impl:  ", programsImplNew);
        console2.log("");
        console2.log("Update deployment-registry.json with these addresses!");
    }
}
