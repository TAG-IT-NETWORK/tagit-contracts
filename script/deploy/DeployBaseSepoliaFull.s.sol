// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "@forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";

// Core & Access
import {TAGITCore} from "../../src/core/TAGITCore.sol";
import {TAGITAccess} from "../../src/access/TAGITAccess.sol";
import {IdentityBadge} from "../../src/access/IdentityBadge.sol";
import {CapabilityBadge} from "../../src/access/CapabilityBadge.sol";

// Token & Governance
import {TAGITToken} from "../../src/token/TAGITToken.sol";
import {TAGITStaking} from "../../src/token/TAGITStaking.sol";
import {TAGITGovernor} from "../../src/governance/TAGITGovernor.sol";
import {ITAGITAccess} from "../../src/interfaces/ITAGITAccess.sol";
import {ITAGITStaking} from "../../src/interfaces/ITAGITStaking.sol";

// NIST Proxies
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {TAGITRecovery} from "../../src/recovery/TAGITRecovery.sol";
import {TAGITPrograms} from "../../src/programs/TAGITPrograms.sol";
import {TAGITPaymaster} from "../../src/account/TAGITPaymaster.sol";

// Account Abstraction
import {TAGITAccount} from "../../src/account/TAGITAccount.sol";
import {TAGITAccountFactory} from "../../src/account/TAGITAccountFactory.sol";

// Bridge
import {CCIPAdapter} from "../../src/bridge/CCIPAdapter.sol";

// Agent Infrastructure
import {TAGITAgentIdentity} from "../../src/agent/TAGITAgentIdentity.sol";
import {TAGITAgentReputation} from "../../src/agent/TAGITAgentReputation.sol";
import {TAGITAgentValidation} from "../../src/agent/TAGITAgentValidation.sol";

// Robotics
import {RoboticAuthorizer} from "../../src/robot/RoboticAuthorizer.sol";

// Token Economics (new — never deployed before)
import {TAGITEmissions} from "../../src/token/TAGITEmissions.sol";
import {TAGITBurner} from "../../src/token/TAGITBurner.sol";
import {TAGITVesting} from "../../src/token/TAGITVesting.sol";
import {IntegrationFactory} from "../../src/agent/IntegrationFactory.sol";

/**
 * @title DeployBaseSepoliaFull
 * @author TAG IT Network <dev@tagit.network>
 * @notice Full-stack deployment of all TAG IT contracts to Base Sepolia (chain 84532).
 * @dev Hackathon mode — deployer keeps control, 60s timelock delay.
 *
 *   Deploys 23 new contracts across 8 phases:
 *     Phase 1: Core & Access (IdentityBadge, CapabilityBadge, TAGITAccess, Timelock, TAGITCore)
 *     Phase 2: Token & Governance (TAGITStaking, TAGITToken, TAGITGovernor)
 *     Phase 3: NIST Proxies (Treasury, Recovery, Programs, Paymaster)
 *     Phase 4: Account Abstraction (TAGITAccount, TAGITAccountFactory)
 *     Phase 5: Bridge & Agent (CCIPAdapter, AgentIdentity, AgentReputation, AgentValidation)
 *     Phase 6: Robotics (RoboticAuthorizer)
 *     Phase 7: New Contracts (Emissions, Burner, Vesting, IntegrationFactory)
 *     Phase 8: Wiring & Capabilities (access controller, oracle, badges, timelock delay)
 *
 *   Note: VerificationEscrow already deployed at 0x4c9aACfcb64169E3BC187c227c4C0e0a5CFDA1cF
 *
 *   # Dry-run
 *   forge script script/deploy/DeployBaseSepoliaFull.s.sol --rpc-url base_sepolia -vvv
 *
 *   # Broadcast + verify
 *   forge script script/deploy/DeployBaseSepoliaFull.s.sol \
 *     --rpc-url base_sepolia --broadcast --verify
 */
contract DeployBaseSepoliaFull is Script {
    // ── External dependencies (canonical addresses on Base Sepolia) ──
    address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant CCIP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address constant VERIFICATION_ESCROW = 0x4c9aACfcb64169E3BC187c227c4C0e0a5CFDA1cF;

    // ── Badge / capability IDs ──
    uint256 constant ADMIN_BADGE = 1;
    uint256 constant CAP_MINTER = uint256(keccak256("MINTER"));
    uint256 constant CAP_BINDER = uint256(keccak256("BINDER"));
    uint256 constant CAP_ACTIVATOR = uint256(keccak256("ACTIVATOR"));
    uint256 constant CAP_CLAIMER = uint256(keccak256("CLAIMER"));
    uint256 constant CAP_FLAGGER = uint256(keccak256("FLAGGER"));
    uint256 constant CAP_RESOLVER = uint256(keccak256("RESOLVER"));
    uint256 constant CAP_RECYCLER = uint256(keccak256("RECYCLER"));

    // ── Deployed addresses (populated during run) ──
    // Phase 1
    IdentityBadge public identityBadge;
    CapabilityBadge public capabilityBadge;
    TAGITAccess public tagitAccess;
    TimelockController public timelock;
    address public coreImpl;
    address public coreProxy;

    // Phase 2
    address public stakingImpl;
    address public stakingProxy;
    address public tokenImpl;
    address public tokenProxy;
    address public govImpl;
    address public govProxy;

    // Phase 3
    address public treasuryImpl;
    address public treasuryProxy;
    address public recoveryImpl;
    address public recoveryProxy;
    address public programsImpl;
    address public programsProxy;
    address public paymasterImpl;
    address public paymasterProxy;

    // Phase 4
    address public accountImpl;
    address public accountFactoryImpl;
    address public accountFactoryProxy;

    // Phase 5
    address public ccipImpl;
    address public ccipProxy;
    address public agentIdentity;
    address public agentReputation;
    address public agentValidation;

    // Phase 6
    address public robotImpl;
    address public robotProxy;

    // Phase 7
    address public emissionsImpl;
    address public emissionsProxy;
    address public burnerImpl;
    address public burnerProxy;
    address public vestingAddr;
    address public integrationFactoryAddr;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=====================================================");
        console2.log("TAG IT - Base Sepolia Full Stack Deployment");
        console2.log("=====================================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        _phase1_CoreAndAccess(deployer);
        _phase2_TokenAndGovernance(deployer);
        _phase3_NISTProxies(deployer);
        _phase4_AccountAbstraction(deployer);
        _phase5_BridgeAndAgent(deployer);
        _phase6_RoboticAuthorizer(deployer);
        _phase7_NewContracts(deployer);
        _phase8_WiringAndCapabilities(deployer);

        vm.stopBroadcast();

        _printSummary(deployer);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 1: Core & Access Control (5 contracts)
    // ═══════════════════════════════════════════════════════════════════
    function _phase1_CoreAndAccess(address deployer) internal {
        console2.log("--- Phase 1: Core & Access Control ---");

        // 1. IdentityBadge
        identityBadge = new IdentityBadge();
        console2.log("1.  IdentityBadge:     ", address(identityBadge));

        // 2. CapabilityBadge
        capabilityBadge = new CapabilityBadge();
        console2.log("2.  CapabilityBadge:   ", address(capabilityBadge));

        // 3. TAGITAccess + wire badges
        tagitAccess = new TAGITAccess();
        tagitAccess.setIdentityBadge(address(identityBadge));
        tagitAccess.setCapabilityBadge(address(capabilityBadge));
        console2.log("3.  TAGITAccess:       ", address(tagitAccess));

        // 4. TimelockController (minDelay=0 for setup)
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = deployer;
        executors[0] = deployer;
        timelock = new TimelockController(0, proposers, executors, address(0));
        console2.log("4.  TimelockController:", address(timelock));

        // 5. TAGITCore (impl + proxy)
        TAGITCore impl = new TAGITCore();
        coreImpl = address(impl);
        bytes memory initData = abi.encodeCall(TAGITCore.initialize, (address(timelock)));
        ERC1967Proxy proxy = new ERC1967Proxy(coreImpl, initData);
        coreProxy = address(proxy);
        console2.log("5a. TAGITCore impl:    ", coreImpl);
        console2.log("5b. TAGITCore proxy:   ", coreProxy);
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 2: Token & Governance (3 contracts)
    // ═══════════════════════════════════════════════════════════════════
    function _phase2_TokenAndGovernance(address deployer) internal {
        console2.log("--- Phase 2: Token & Governance ---");

        // 6. TAGITStaking (deploy before Governor — Governor needs ITAGITStaking)
        {
            TAGITStaking impl = new TAGITStaking();
            stakingImpl = address(impl);
            bytes memory init = abi.encodeCall(TAGITStaking.initialize, (deployer, deployer, deployer));
            stakingProxy = address(new ERC1967Proxy(stakingImpl, init));
        }
        console2.log("6a. TAGITStaking impl: ", stakingImpl);
        console2.log("6b. TAGITStaking proxy:", stakingProxy);

        // 7. TAGITToken
        {
            TAGITToken impl = new TAGITToken();
            tokenImpl = address(impl);
            bytes memory init = abi.encodeCall(TAGITToken.initialize, (deployer, deployer));
            tokenProxy = address(new ERC1967Proxy(tokenImpl, init));
        }
        console2.log("7a. TAGITToken impl:   ", tokenImpl);
        console2.log("7b. TAGITToken proxy:  ", tokenProxy);

        // 8. TAGITGovernor
        {
            TAGITGovernor impl = new TAGITGovernor();
            govImpl = address(impl);
            bytes memory init = abi.encodeCall(
                TAGITGovernor.initialize,
                (
                    IVotes(tokenProxy),
                    TimelockControllerUpgradeable(payable(address(timelock))),
                    ITAGITAccess(address(tagitAccess)),
                    ITAGITStaking(stakingProxy),
                    deployer,
                    deployer
                )
            );
            govProxy = address(new ERC1967Proxy(govImpl, init));
        }
        console2.log("8a. TAGITGovernor impl:", govImpl);
        console2.log("8b. TAGITGovernor proxy:", govProxy);
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 3: NIST Proxies (4 contracts)
    // ═══════════════════════════════════════════════════════════════════
    function _phase3_NISTProxies(address deployer) internal {
        console2.log("--- Phase 3: NIST Proxies ---");

        // 9. TAGITTreasury
        {
            TAGITTreasury impl = new TAGITTreasury();
            treasuryImpl = address(impl);
            address[] memory signers = new address[](1);
            signers[0] = deployer;
            bytes memory init = abi.encodeCall(TAGITTreasury.initialize, (deployer, tokenProxy, signers));
            treasuryProxy = address(new ERC1967Proxy(treasuryImpl, init));
        }
        console2.log("9a. TAGITTreasury impl:", treasuryImpl);
        console2.log("9b. TAGITTreasury proxy:", treasuryProxy);

        // 10. TAGITRecovery
        {
            TAGITRecovery impl = new TAGITRecovery();
            recoveryImpl = address(impl);
            bytes memory init = abi.encodeCall(
                TAGITRecovery.initialize,
                (coreProxy, address(tagitAccess), tokenProxy, govProxy, treasuryProxy, deployer)
            );
            recoveryProxy = address(new ERC1967Proxy(recoveryImpl, init));
        }
        console2.log("10a. TAGITRecovery impl:", recoveryImpl);
        console2.log("10b. TAGITRecovery proxy:", recoveryProxy);

        // 11. TAGITPrograms
        {
            TAGITPrograms impl = new TAGITPrograms();
            programsImpl = address(impl);
            bytes memory init = abi.encodeCall(
                TAGITPrograms.initialize,
                (deployer, coreProxy, tokenProxy, address(tagitAccess), stakingProxy, deployer)
            );
            programsProxy = address(new ERC1967Proxy(programsImpl, init));
        }
        console2.log("11a. TAGITPrograms impl:", programsImpl);
        console2.log("11b. TAGITPrograms proxy:", programsProxy);

        // 12. TAGITPaymaster
        {
            TAGITPaymaster impl = new TAGITPaymaster();
            paymasterImpl = address(impl);
            bytes memory init = abi.encodeCall(TAGITPaymaster.initialize, (ENTRY_POINT, deployer, deployer));
            paymasterProxy = address(new ERC1967Proxy(paymasterImpl, init));
        }
        console2.log("12a. TAGITPaymaster impl:", paymasterImpl);
        console2.log("12b. TAGITPaymaster proxy:", paymasterProxy);
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 4: Account Abstraction (2 contracts)
    // ═══════════════════════════════════════════════════════════════════
    function _phase4_AccountAbstraction(address deployer) internal {
        console2.log("--- Phase 4: Account Abstraction ---");

        // 13. TAGITAccount (implementation singleton — factory creates per-user proxies)
        TAGITAccount acct = new TAGITAccount(ENTRY_POINT);
        accountImpl = address(acct);
        console2.log("13. TAGITAccount impl: ", accountImpl);

        // 14. TAGITAccountFactory
        {
            TAGITAccountFactory impl = new TAGITAccountFactory();
            accountFactoryImpl = address(impl);
            bytes memory init = abi.encodeCall(
                TAGITAccountFactory.initialize, (ENTRY_POINT, accountImpl, deployer, coreProxy, deployer, deployer)
            );
            accountFactoryProxy = address(new ERC1967Proxy(accountFactoryImpl, init));
        }
        console2.log("14a. AccountFactory impl:", accountFactoryImpl);
        console2.log("14b. AccountFactory proxy:", accountFactoryProxy);
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 5: Bridge & Agent Infrastructure (4 contracts)
    // ═══════════════════════════════════════════════════════════════════
    function _phase5_BridgeAndAgent(address deployer) internal {
        console2.log("--- Phase 5: Bridge & Agent Infrastructure ---");

        // 15. CCIPAdapter
        {
            CCIPAdapter impl = new CCIPAdapter();
            ccipImpl = address(impl);
            bytes memory init = abi.encodeCall(CCIPAdapter.initialize, (CCIP_ROUTER, deployer, coreProxy, deployer));
            ccipProxy = address(new ERC1967Proxy(ccipImpl, init));
        }
        console2.log("15a. CCIPAdapter impl: ", ccipImpl);
        console2.log("15b. CCIPAdapter proxy:", ccipProxy);

        // 16. TAGITAgentIdentity
        TAGITAgentIdentity identity = new TAGITAgentIdentity();
        agentIdentity = address(identity);
        identity.setAccessController(address(tagitAccess));
        console2.log("16. AgentIdentity:     ", agentIdentity);

        // 17. TAGITAgentReputation
        TAGITAgentReputation reputation = new TAGITAgentReputation();
        agentReputation = address(reputation);
        reputation.setAccessController(address(tagitAccess));
        reputation.setIdentityRegistry(agentIdentity);
        console2.log("17. AgentReputation:   ", agentReputation);

        // 18. TAGITAgentValidation
        TAGITAgentValidation validation = new TAGITAgentValidation();
        agentValidation = address(validation);
        validation.setAccessController(address(tagitAccess));
        validation.setIdentityRegistry(agentIdentity);
        console2.log("18. AgentValidation:   ", agentValidation);
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 6: Robotics (1 contract)
    // ═══════════════════════════════════════════════════════════════════
    function _phase6_RoboticAuthorizer(address deployer) internal {
        console2.log("--- Phase 6: Robotics ---");

        RoboticAuthorizer impl = new RoboticAuthorizer();
        robotImpl = address(impl);
        bytes memory initData =
            abi.encodeCall(RoboticAuthorizer.initialize, (deployer, coreProxy, address(tagitAccess)));
        ERC1967Proxy proxy = new ERC1967Proxy(robotImpl, initData);
        robotProxy = address(proxy);

        console2.log("19a. RoboticAuth impl: ", robotImpl);
        console2.log("19b. RoboticAuth proxy:", robotProxy);
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 7: New Contracts — never deployed before (4 contracts)
    // ═══════════════════════════════════════════════════════════════════
    function _phase7_NewContracts(address deployer) internal {
        console2.log("--- Phase 7: New Contracts (first-ever deployment) ---");

        // 20. TAGITEmissions (UUPS)
        {
            TAGITEmissions impl = new TAGITEmissions();
            emissionsImpl = address(impl);
            bytes memory init = abi.encodeCall(TAGITEmissions.initialize, (tokenProxy, deployer, deployer));
            emissionsProxy = address(new ERC1967Proxy(emissionsImpl, init));
        }
        console2.log("20a. TAGITEmissions impl:", emissionsImpl);
        console2.log("20b. TAGITEmissions proxy:", emissionsProxy);

        // 21. TAGITBurner (UUPS)
        {
            TAGITBurner impl = new TAGITBurner();
            burnerImpl = address(impl);
            bytes memory init = abi.encodeCall(TAGITBurner.initialize, (tokenProxy, treasuryProxy, deployer, deployer));
            burnerProxy = address(new ERC1967Proxy(burnerImpl, init));
        }
        console2.log("21a. TAGITBurner impl: ", burnerImpl);
        console2.log("21b. TAGITBurner proxy:", burnerProxy);

        // 22. TAGITVesting (NOT upgradeable — plain constructor)
        TAGITVesting vesting = new TAGITVesting(tokenProxy, deployer);
        vestingAddr = address(vesting);
        console2.log("22. TAGITVesting:      ", vestingAddr);

        // 23. IntegrationFactory (NOT upgradeable — plain constructor)
        //     Requires 3 unique signers — use deployer + two deterministic addresses for testnet
        {
            address[] memory signers = new address[](3);
            signers[0] = deployer;
            signers[1] = address(uint160(uint256(keccak256(abi.encodePacked(deployer, uint256(1))))));
            signers[2] = address(uint160(uint256(keccak256(abi.encodePacked(deployer, uint256(2))))));
            IntegrationFactory factory = new IntegrationFactory(burnerProxy, deployer, signers, 1);
            integrationFactoryAddr = address(factory);
        }
        console2.log("23. IntegrationFactory:", integrationFactoryAddr);
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Phase 8: Wiring & Capabilities
    // ═══════════════════════════════════════════════════════════════════
    function _phase8_WiringAndCapabilities(address deployer) internal {
        console2.log("--- Phase 8: Wiring & Capabilities ---");

        // 8a. setAccessController on TAGITCore via timelock (delay=0)
        {
            bytes memory data = abi.encodeCall(TAGITCore.setAccessController, (address(tagitAccess)));
            bytes32 salt = keccak256("setAccessController");
            timelock.schedule(coreProxy, 0, data, bytes32(0), salt, 0);
            timelock.execute(coreProxy, 0, data, bytes32(0), salt);
        }
        console2.log("8a. setAccessController done");

        // 8b. setTrustedOracle on TAGITCore via timelock (delay=0)
        {
            bytes memory data = abi.encodeCall(TAGITCore.setTrustedOracle, (deployer));
            bytes32 salt = keccak256("setTrustedOracle");
            timelock.schedule(coreProxy, 0, data, bytes32(0), salt, 0);
            timelock.execute(coreProxy, 0, data, bytes32(0), salt);
        }
        console2.log("8b. setTrustedOracle done (oracle = deployer)");

        // 8c. Grant deployer ADMIN identity badge
        identityBadge.grantIdentity(deployer, ADMIN_BADGE);
        console2.log("8c. ADMIN badge granted to deployer");

        // 8d. Grant deployer all 7 capabilities
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
        console2.log("8d. All 7 capabilities granted to deployer");

        // 8e. Bump timelock delay to 60s — MUST be last zero-delay operation
        {
            bytes memory data = abi.encodeCall(TimelockController.updateDelay, (60));
            bytes32 salt = keccak256("updateDelay");
            timelock.schedule(address(timelock), 0, data, bytes32(0), salt, 0);
            timelock.execute(address(timelock), 0, data, bytes32(0), salt);
        }
        console2.log("8e. updateDelay(60s) done");
        console2.log("");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Summary
    // ═══════════════════════════════════════════════════════════════════
    function _printSummary(address deployer) internal view {
        console2.log("=====================================================");
        console2.log("Base Sepolia Full Stack Deployment Complete!");
        console2.log("Chain ID: 84532");
        console2.log("=====================================================");
        console2.log("");

        console2.log("CORE & ACCESS CONTROL:");
        console2.log("  IdentityBadge:       ", address(identityBadge));
        console2.log("  CapabilityBadge:     ", address(capabilityBadge));
        console2.log("  TAGITAccess:         ", address(tagitAccess));
        console2.log("  TimelockController:  ", address(timelock));
        console2.log("  TAGITCore (impl):    ", coreImpl);
        console2.log("  TAGITCore (proxy):   ", coreProxy);
        console2.log("");

        console2.log("TOKEN & GOVERNANCE:");
        console2.log("  TAGITStaking (impl): ", stakingImpl);
        console2.log("  TAGITStaking (proxy):", stakingProxy);
        console2.log("  TAGITToken (impl):   ", tokenImpl);
        console2.log("  TAGITToken (proxy):  ", tokenProxy);
        console2.log("  TAGITGovernor (impl):", govImpl);
        console2.log("  TAGITGovernor (proxy):", govProxy);
        console2.log("");

        console2.log("NIST PROXIES:");
        console2.log("  TAGITTreasury (impl):", treasuryImpl);
        console2.log("  TAGITTreasury (proxy):", treasuryProxy);
        console2.log("  TAGITRecovery (impl):", recoveryImpl);
        console2.log("  TAGITRecovery (proxy):", recoveryProxy);
        console2.log("  TAGITPrograms (impl):", programsImpl);
        console2.log("  TAGITPrograms (proxy):", programsProxy);
        console2.log("  TAGITPaymaster (impl):", paymasterImpl);
        console2.log("  TAGITPaymaster (proxy):", paymasterProxy);
        console2.log("");

        console2.log("ACCOUNT ABSTRACTION:");
        console2.log("  TAGITAccount (impl): ", accountImpl);
        console2.log("  AccountFactory (impl):", accountFactoryImpl);
        console2.log("  AccountFactory (proxy):", accountFactoryProxy);
        console2.log("");

        console2.log("BRIDGE & AGENT:");
        console2.log("  CCIPAdapter (impl):  ", ccipImpl);
        console2.log("  CCIPAdapter (proxy): ", ccipProxy);
        console2.log("  AgentIdentity:       ", agentIdentity);
        console2.log("  AgentReputation:     ", agentReputation);
        console2.log("  AgentValidation:     ", agentValidation);
        console2.log("");

        console2.log("ROBOTICS:");
        console2.log("  RoboticAuth (impl):  ", robotImpl);
        console2.log("  RoboticAuth (proxy): ", robotProxy);
        console2.log("");

        console2.log("NEW CONTRACTS (first-ever deployment):");
        console2.log("  TAGITEmissions (impl):", emissionsImpl);
        console2.log("  TAGITEmissions (proxy):", emissionsProxy);
        console2.log("  TAGITBurner (impl):  ", burnerImpl);
        console2.log("  TAGITBurner (proxy): ", burnerProxy);
        console2.log("  TAGITVesting:        ", vestingAddr);
        console2.log("  IntegrationFactory:  ", integrationFactoryAddr);
        console2.log("");

        console2.log("PREVIOUSLY DEPLOYED:");
        console2.log("  VerificationEscrow:  ", VERIFICATION_ESCROW);
        console2.log("");

        console2.log("CONFIGURATION:");
        console2.log("  Oracle:              ", deployer);
        console2.log("  Timelock delay:       60 seconds (hackathon)");
        console2.log("  EntryPoint (v0.7):   ", ENTRY_POINT);
        console2.log("  CCIP Router:         ", CCIP_ROUTER);
        console2.log("");

        console2.log("TOTAL: 23 new contracts + 1 existing = 24 on Base Sepolia");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Update deployment-addresses.json with Base Sepolia addresses");
        console2.log("  2. Update Notion page Section 8.3");
        console2.log("  3. Update tagit-docs contract pages");
        console2.log("  4. Mint test assets for demo");
    }
}
