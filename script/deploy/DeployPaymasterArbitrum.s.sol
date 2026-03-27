// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console2} from "@forge-std/Script.sol";
import {TAGITPaymaster} from "../../src/account/TAGITPaymaster.sol";
import {ITAGITPaymaster} from "../../src/interfaces/ITAGITPaymaster.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployPaymasterArbitrum
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deploys TAGITPaymaster (ERC-4337) as UUPS proxy to Arbitrum Sepolia for hackathon demo.
 * @dev Hackathon simplification: deployer = governor = owner. Conservative 0.05 ETH funding.
 *
 *   # Dry-run
 *   forge script script/deploy/DeployPaymasterArbitrum.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL -vvv
 *
 *   # Broadcast + verify
 *   forge script script/deploy/DeployPaymasterArbitrum.s.sol \
 *     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --verify
 */
contract DeployPaymasterArbitrum is Script {
    /// @notice Canonical ERC-4337 EntryPoint v0.7 (all EVM chains)
    address public constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @notice Protocol deposit for gas sponsorship (conservative testnet amount)
    uint256 public constant PROTOCOL_DEPOSIT = 0.05 ether;

    /// @notice Stake amount for Pimlico bundler
    uint256 public constant STAKE_AMOUNT = 0.01 ether;

    /// @notice Unstake delay (1 day — hackathon minimum)
    uint32 public constant UNSTAKE_DELAY = 86400;

    /// @notice Max gas per sponsored call
    uint256 public constant MAX_GAS = 500_000;

    /// @notice Daily limit per user per selector
    uint256 public constant DAILY_LIMIT = 50;

    // TAGITCore function selectors (from `forge inspect TAGITCore methods`)
    bytes4 public constant SEL_BIND_TAG = 0xf1313d45; // bindTag(uint256,bytes32,bytes,bytes)
    bytes4 public constant SEL_ACTIVATE = 0xb260c42a; // activate(uint256)
    bytes4 public constant SEL_CLAIM = 0xddd5e1b2; // claim(uint256,address)
    bytes4 public constant SEL_MINT = 0x2cfd3005; // mint(address,bytes32)

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("==============================================");
        console2.log("HACK-T03: TAGITPaymaster - Arbitrum Sepolia");
        console2.log("==============================================");
        console2.log("Deployer:   ", deployer);
        console2.log("Chain ID:   ", block.chainid);
        console2.log("EntryPoint: ", ENTRY_POINT);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy TAGITPaymaster implementation
        TAGITPaymaster impl = new TAGITPaymaster();
        console2.log("1. TAGITPaymaster impl:  ", address(impl));

        // Step 2: Deploy ERC1967Proxy → initialize(entryPoint, deployer, deployer)
        bytes memory initData = abi.encodeCall(TAGITPaymaster.initialize, (ENTRY_POINT, deployer, deployer));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        TAGITPaymaster paymaster = TAGITPaymaster(payable(address(proxy)));
        console2.log("2. TAGITPaymaster proxy: ", address(proxy));

        // Step 3: Whitelist TAGITCore function selectors
        _whitelistSelector(paymaster, SEL_BIND_TAG, "bindTag(uint256,bytes32,bytes,bytes)");
        _whitelistSelector(paymaster, SEL_ACTIVATE, "activate(uint256)");
        _whitelistSelector(paymaster, SEL_CLAIM, "claim(uint256,address)");
        _whitelistSelector(paymaster, SEL_MINT, "mint(address,bytes32)");
        console2.log("3. Whitelisted 4 selectors (maxGas=500k, dailyLimit=50)");

        // Step 4: Deposit protocol ETH to EntryPoint for gas sponsorship
        paymaster.depositProtocol{value: PROTOCOL_DEPOSIT}();
        console2.log("4. Protocol deposit:     ", PROTOCOL_DEPOSIT);

        // Step 5: Add stake to EntryPoint (required by Pimlico bundler)
        paymaster.addStake{value: STAKE_AMOUNT}(UNSTAKE_DELAY);
        console2.log("5. Stake added:          ", STAKE_AMOUNT, "(delay: 86400s)");

        vm.stopBroadcast();

        // Step 6: Summary
        console2.log("");
        console2.log("==============================================");
        console2.log("HACK-T03 Deployment Complete!");
        console2.log("==============================================");
        console2.log("");
        console2.log("Contract Addresses:");
        console2.log("  TAGITPaymaster (impl):  ", address(impl));
        console2.log("  TAGITPaymaster (proxy): ", address(proxy));
        console2.log("  EntryPoint:             ", ENTRY_POINT);
        console2.log("");
        console2.log("Configuration:");
        console2.log("  Governor:        ", deployer);
        console2.log("  Owner (UUPS):    ", deployer);
        console2.log("  Protocol deposit:", PROTOCOL_DEPOSIT);
        console2.log("  Stake:           ", STAKE_AMOUNT);
        console2.log("  Unstake delay:    86400s (1 day)");
        console2.log("");
        console2.log("Sponsored Selectors:");
        console2.log("  bindTag  (0xf1313d45) - maxGas=500k, dailyLimit=50");
        console2.log("  activate (0xb260c42a) - maxGas=500k, dailyLimit=50");
        console2.log("  claim    (0xddd5e1b2) - maxGas=500k, dailyLimit=50");
        console2.log("  mint     (0x2cfd3005) - maxGas=500k, dailyLimit=50");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Update exports/addresses.json with Arbitrum Sepolia addresses");
        console2.log("  2. Verify on Arbiscan:");
        console2.log("     forge verify-contract <PROXY> TAGITPaymaster --chain-id 421614");
        console2.log("  3. Fund deployer with testnet ETH if needed");
        console2.log("  4. Test gasless NFC verification flow via Pimlico bundler");
    }

    function _whitelistSelector(TAGITPaymaster paymaster, bytes4 selector, string memory name) internal {
        ITAGITPaymaster.SponsorshipConfig memory config = ITAGITPaymaster.SponsorshipConfig({
            selector: selector, maxGas: MAX_GAS, dailyLimit: DAILY_LIMIT, active: true
        });
        paymaster.setSponsorshipConfig(selector, config);
        console2.log("   Whitelisted:", name);
    }
}
