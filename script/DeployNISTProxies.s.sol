// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Interfaces for initialization
import {TAGITRecovery} from "../src/recovery/TAGITRecovery.sol";
import {TAGITPaymaster} from "../src/account/TAGITPaymaster.sol";
import {TAGITTreasury} from "../src/treasury/TAGITTreasury.sol";
import {TAGITPrograms} from "../src/programs/TAGITPrograms.sol";
import {TAGITStaking} from "../src/token/TAGITStaking.sol";
import {TAGITAccountFactory} from "../src/account/TAGITAccountFactory.sol";
import {CCIPAdapter} from "../src/bridge/CCIPAdapter.sol";

/**
 * @title DeployNISTProxies
 * @notice Deploys ERC1967 proxies for NIST-patched implementations
 * @dev Run: forge script script/DeployNISTProxies.s.sol --rpc-url $OP_SEPOLIA_RPC_URL --broadcast
 */
contract DeployNISTProxies is Script {
    // NIST Implementation addresses (deployed in Phase 3)
    address constant RECOVERY_IMPL = 0x6138a80c06A5e6a3CB6cc491A3a2c4DF4adD1600;
    address constant PAYMASTER_IMPL = 0x4339c46D63231063250834D9b3fa4E51FdB8026e;
    address constant TREASURY_IMPL = 0xf6f5e2e03f6e28aE9Dc17bCc814a0cf758c887c9;
    address constant PROGRAMS_IMPL = 0xe78DB7702FF5190DAc2F3E09213Ff84bF9efE32b;
    address constant STAKING_IMPL = 0x12EE464e32a683f813fDb478e6C8e68E3d63d781;
    address constant ACCOUNT_IMPL = 0xC159FDec7a8fDc0d98571C89c342e28bB405e682;
    address constant ACCOUNT_FACTORY_IMPL = 0x8D27B612a9D3e45d51D2234B2f4e03dCC5ca844b;
    address constant CCIP_ADAPTER_IMPL = 0x8dA6D7ffCD4cc0F2c9FfD6411CeD7C9c573C9E88;

    // Existing contracts
    address constant TAGIT_CORE = 0x8B02b62FD388b2d7e3dF5Ec666D68Ac7c7ca02Fe;
    address constant TAGIT_ACCESS = 0x0611FE60f6E37230bDaf04c5F2Ac2dc9012130a9;

    // ERC-4337 EntryPoint (v0.7)
    address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // OP Sepolia CCIP Router
    address constant CCIP_ROUTER = 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57;

    // Deployed proxies
    address public recoveryProxy;
    address public paymasterProxy;
    address public treasuryProxy;
    address public programsProxy;
    address public stakingProxy;
    address public accountFactoryProxy;
    address public ccipAdapterProxy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("===========================================");
        console2.log("TAG IT Network - NIST Proxy Deployment");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. TAGITRecovery Proxy
        // initialize(address _core, address _access, address _token, address _governor, address _treasury, address initialOwner)
        console2.log("1. Deploying TAGITRecovery Proxy...");
        bytes memory recoveryInit = abi.encodeCall(
            TAGITRecovery.initialize,
            (
                TAGIT_CORE,     // _core
                TAGIT_ACCESS,   // _access
                deployer,       // _token (placeholder - update after TAGITToken deployed)
                deployer,       // _governor
                deployer,       // _treasury (placeholder)
                deployer        // initialOwner
            )
        );
        recoveryProxy = address(new ERC1967Proxy(RECOVERY_IMPL, recoveryInit));
        console2.log("   Proxy:", recoveryProxy);

        // 2. TAGITPaymaster Proxy
        // initialize(address entryPointAddr, address governorAddr, address initialOwner)
        console2.log("2. Deploying TAGITPaymaster Proxy...");
        bytes memory paymasterInit = abi.encodeCall(
            TAGITPaymaster.initialize,
            (
                ENTRY_POINT,    // entryPointAddr
                deployer,       // governorAddr
                deployer        // initialOwner
            )
        );
        paymasterProxy = address(new ERC1967Proxy(PAYMASTER_IMPL, paymasterInit));
        console2.log("   Proxy:", paymasterProxy);

        // 3. TAGITTreasury Proxy
        // initialize(address governorAddress, address tokenAddress, address[] calldata initialSigners)
        console2.log("3. Deploying TAGITTreasury Proxy...");
        address[] memory signers = new address[](1);
        signers[0] = deployer;
        bytes memory treasuryInit = abi.encodeCall(
            TAGITTreasury.initialize,
            (
                deployer,       // governorAddress
                deployer,       // tokenAddress (use deployer as placeholder - will update later)
                signers         // initialSigners
            )
        );
        treasuryProxy = address(new ERC1967Proxy(TREASURY_IMPL, treasuryInit));
        console2.log("   Proxy:", treasuryProxy);

        // 4. TAGITPrograms Proxy
        // initialize(address governorAddress, address coreAddress, address tokenAddress, address accessAddress, address stakingAddress, address initialOwner)
        console2.log("4. Deploying TAGITPrograms Proxy...");
        bytes memory programsInit = abi.encodeCall(
            TAGITPrograms.initialize,
            (
                deployer,       // governorAddress
                TAGIT_CORE,     // coreAddress
                deployer,       // tokenAddress (placeholder)
                TAGIT_ACCESS,   // accessAddress
                deployer,       // stakingAddress (placeholder)
                deployer        // initialOwner
            )
        );
        programsProxy = address(new ERC1967Proxy(PROGRAMS_IMPL, programsInit));
        console2.log("   Proxy:", programsProxy);

        // 5. TAGITStaking Proxy
        // initialize(address _token, address _governor, address initialOwner)
        console2.log("5. Deploying TAGITStaking Proxy...");
        bytes memory stakingInit = abi.encodeCall(
            TAGITStaking.initialize,
            (
                deployer,       // _token (placeholder)
                deployer,       // _governor
                deployer        // initialOwner
            )
        );
        stakingProxy = address(new ERC1967Proxy(STAKING_IMPL, stakingInit));
        console2.log("   Proxy:", stakingProxy);

        // 6. TAGITAccountFactory Proxy
        // initialize(address entryPointAddr, address accountImpl, address protocolGuardianAddr, address tagitCoreAddr, address governorAddr, address initialOwner)
        console2.log("6. Deploying TAGITAccountFactory Proxy...");
        bytes memory factoryInit = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (
                ENTRY_POINT,    // entryPointAddr
                ACCOUNT_IMPL,   // accountImpl
                deployer,       // protocolGuardianAddr
                TAGIT_CORE,     // tagitCoreAddr
                deployer,       // governorAddr
                deployer        // initialOwner
            )
        );
        accountFactoryProxy = address(new ERC1967Proxy(ACCOUNT_FACTORY_IMPL, factoryInit));
        console2.log("   Proxy:", accountFactoryProxy);

        // 7. CCIPAdapter Proxy
        // initialize(address routerAddr, address governorAddr, address tagitCoreAddr, address initialOwner)
        console2.log("7. Deploying CCIPAdapter Proxy...");
        bytes memory ccipInit = abi.encodeCall(
            CCIPAdapter.initialize,
            (
                CCIP_ROUTER,    // routerAddr
                deployer,       // governorAddr
                TAGIT_CORE,     // tagitCoreAddr
                deployer        // initialOwner
            )
        );
        ccipAdapterProxy = address(new ERC1967Proxy(CCIP_ADAPTER_IMPL, ccipInit));
        console2.log("   Proxy:", ccipAdapterProxy);

        vm.stopBroadcast();

        console2.log("");
        console2.log("===========================================");
        console2.log("NIST Proxies Deployed!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Proxy Addresses:");
        console2.log("  TAGITRecovery:       ", recoveryProxy);
        console2.log("  TAGITPaymaster:      ", paymasterProxy);
        console2.log("  TAGITTreasury:       ", treasuryProxy);
        console2.log("  TAGITPrograms:       ", programsProxy);
        console2.log("  TAGITStaking:        ", stakingProxy);
        console2.log("  TAGITAccountFactory: ", accountFactoryProxy);
        console2.log("  CCIPAdapter:         ", ccipAdapterProxy);
        console2.log("");
        console2.log("Next Steps:");
        console2.log("1. Update addresses.json with proxy addresses");
        console2.log("2. Deploy TAGITToken and configure contracts");
        console2.log("3. Grant capabilities via TAGITAccess");
        console2.log("4. Fund Paymaster with ETH for gas sponsorship");
        console2.log("");
    }
}
