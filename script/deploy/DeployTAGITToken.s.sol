// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TAGITToken} from "../../src/token/TAGITToken.sol";

/**
 * @title DeployTAGITToken
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploy TAGITToken (UUPS proxy + implementation) to OP Sepolia
 * @dev Run with:
 *   forge script script/deploy/DeployTAGITToken.s.sol \
 *     --rpc-url optimism_sepolia --broadcast --verify
 *
 * Environment variables:
 *   PRIVATE_KEY  — deployer private key (also receives genesis supply + owns proxy)
 *   TREASURY     — optional override; defaults to deployer
 *
 * Genesis supply (7,777,777,333 TAGIT) is minted to TREASURY at initialize().
 * Deployer owns the proxy and can later call setEmissionsAddress() exactly once.
 *
 * @custom:security Transfer ownership to multisig post-deploy on mainnet.
 */
contract DeployTAGITToken is Script {
    function run() external returns (address proxy, address implementation) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury;
        try vm.envAddress("TREASURY") returns (address t) {
            treasury = t;
        } catch {
            treasury = deployer;
        }

        console2.log("===========================================");
        console2.log("DeployTAGITToken (UUPS)");
        console2.log("===========================================");
        console2.log("Deployer:  ", deployer);
        console2.log("Treasury:  ", treasury);
        console2.log("Owner:     ", deployer);
        console2.log("Chain ID:  ", block.chainid);
        console2.log("");

        vm.startBroadcast(pk);

        // 1. Deploy implementation
        TAGITToken impl = new TAGITToken();

        // 2. Encode initializer call
        bytes memory initData = abi.encodeWithSelector(TAGITToken.initialize.selector, treasury, deployer);

        // 3. Deploy ERC1967 proxy pointing at implementation
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(impl), initData);

        vm.stopBroadcast();

        proxy = address(proxyContract);
        implementation = address(impl);

        TAGITToken token = TAGITToken(proxy);
        console2.log("Implementation: ", implementation);
        console2.log("Proxy (TAGIT):  ", proxy);
        console2.log("Name:           ", token.name());
        console2.log("Symbol:         ", token.symbol());
        console2.log("Decimals:       ", token.decimals());
        console2.log("Total supply:   ", token.totalSupply());
        console2.log("Treasury balance:", token.balanceOf(treasury));
        console2.log("Owner:          ", token.owner());
        console2.log("");
    }
}
