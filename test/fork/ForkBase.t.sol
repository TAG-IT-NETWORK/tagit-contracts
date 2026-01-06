// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ForkBase
 * @notice Base contract for fork tests against OP Mainnet
 * @dev Provides common setup and helpers for testing against real mainnet state
 */
abstract contract ForkBase is Test {
    // ============================================
    // OP MAINNET ADDRESSES
    // ============================================

    /// @notice CCIP Router on OP Mainnet
    address public constant CCIP_ROUTER = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f;

    /// @notice EntryPoint v0.7 (ERC-4337) - Same address on all chains
    address public constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @notice WETH on OP Mainnet
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice USDC on OP Mainnet
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    /// @notice OP Token on OP Mainnet
    address public constant OP_TOKEN = 0x4200000000000000000000000000000000000042;

    // ============================================
    // CHAIN SELECTORS (CCIP)
    // ============================================

    /// @notice Ethereum Mainnet chain selector
    uint64 public constant ETH_MAINNET_SELECTOR = 5009297550715157269;

    /// @notice Arbitrum One chain selector
    uint64 public constant ARBITRUM_SELECTOR = 4949039107694359620;

    /// @notice Base chain selector
    uint64 public constant BASE_SELECTOR = 15971525489660198786;

    /// @notice Polygon chain selector
    uint64 public constant POLYGON_SELECTOR = 4051577828743386545;

    // ============================================
    // STATE
    // ============================================

    /// @notice Fork ID for OP Mainnet
    uint256 public optimismFork;

    /// @notice Block number pinned for reproducibility
    uint256 public constant FORK_BLOCK = 125000000;

    // ============================================
    // TEST ACTORS
    // ============================================

    address public deployer;
    address public governor;
    address public user1;
    address public user2;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public virtual {
        // Create test accounts
        deployer = makeAddr("deployer");
        governor = makeAddr("governor");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Fund test accounts
        vm.deal(deployer, 100 ether);
        vm.deal(governor, 10 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);

        // Create fork - try environment variable first, fallback to public RPC
        string memory rpcUrl = _getRpcUrl();
        optimismFork = vm.createFork(rpcUrl, FORK_BLOCK);
        vm.selectFork(optimismFork);

        // Verify we're on OP Mainnet
        assertEq(block.chainid, 10, "Should be OP Mainnet (chainId 10)");
    }

    // ============================================
    // HELPERS
    // ============================================

    /// @notice Get RPC URL from environment or fallback to public
    function _getRpcUrl() internal view returns (string memory) {
        try vm.envString("OP_MAINNET_RPC_URL") returns (string memory url) {
            if (bytes(url).length > 0) {
                return url;
            }
        } catch {}

        // Fallback to public RPC (rate limited)
        return "https://mainnet.optimism.io";
    }

    /// @notice Check if an address has deployed code
    function _hasCode(address addr) internal view returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(addr)
        }
        return codeSize > 0;
    }

    /// @notice Impersonate a whale address for testing
    function _impersonateWhale(address whale) internal {
        vm.startPrank(whale);
    }

    /// @notice Stop impersonation
    function _stopImpersonation() internal {
        vm.stopPrank();
    }

    /// @notice Deal ERC20 tokens to an address
    function _dealToken(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    /// @notice Deploy a contract behind a UUPS proxy
    function _deployProxy(
        address implementation,
        bytes memory initData
    ) internal returns (address) {
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
        return address(proxy);
    }

    /// @notice Skip test if RPC is not available
    modifier skipIfNoRpc() {
        try vm.envString("OP_MAINNET_RPC_URL") returns (string memory url) {
            if (bytes(url).length == 0) {
                vm.skip(true);
            }
        } catch {
            // Use public RPC, continue test
        }
        _;
    }

    /// @notice Log contract verification
    function _logContractVerification(string memory name, address addr, bool hasCode) internal pure {
        console2.log(string.concat(name, " at"), addr);
        console2.log(string.concat("  Has code: ", hasCode ? "true" : "false"));
    }
}
