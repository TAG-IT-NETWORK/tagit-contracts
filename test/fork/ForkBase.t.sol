// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ForkBase
 * @notice Base contract for fork tests against Base Sepolia (84532)
 * @dev Provides common setup and helpers for testing against real chain state.
 *      Retargeted from OP Mainnet 2026-08-01: OP Sepolia and Arbitrum Sepolia are
 *      "status": "archived" in deployment-addresses.json and OP Mainnet was never
 *      deployed to, so the old fork asserted chainid 10 against a chain carrying
 *      none of our contracts. Every address and selector below was verified live
 *      against https://sepolia.base.org on 2026-08-01.
 */
abstract contract ForkBase is Test {
    // ============================================
    // BASE SEPOLIA ADDRESSES (chainId 84532)
    // ============================================

    /// @notice CCIP Router on Base Sepolia. Verified: has code, answers isChainSupported().
    address public constant CCIP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;

    /// @notice EntryPoint v0.7 (ERC-4337) — same address on all chains. Verified: has code.
    address public constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @notice WETH on Base Sepolia (OP-stack predeploy). Verified: symbol() == "WETH", 18 dp.
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice USDC on Base Sepolia. Verified: symbol() == "USDC", 6 dp.
    address public constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    // ============================================
    // CHAIN SELECTORS (CCIP)
    // ============================================

    // Testnet selectors. The previous constants were MAINNET selectors, every one of
    // which returns isChainSupported() == false on the Base Sepolia router — so any
    // test using them was asserting against a route that does not exist here.
    // Verified live against the router on 2026-08-01.

    /// @notice Ethereum Sepolia chain selector. Router: supported.
    uint64 public constant ETH_SEPOLIA_SELECTOR = 16015286601757825753;

    /// @notice Arbitrum Sepolia chain selector. Router: supported.
    uint64 public constant ARBITRUM_SEPOLIA_SELECTOR = 3478487238524512106;

    /// @notice OP Sepolia chain selector. Router: supported.
    /// @dev Kept as a CCIP *destination* only. We have no contracts on OP Sepolia —
    ///      it is archived. This is a Chainlink route, not a TAG IT deployment.
    uint64 public constant OP_SEPOLIA_SELECTOR = 5224473277236331295;

    /// @notice Base Sepolia's own selector. Router returns false — a chain cannot
    ///         route to itself. Present so tests can assert that.
    uint64 public constant BASE_SEPOLIA_SELECTOR = 10344971235874465080;

    // ============================================
    // STATE
    // ============================================

    /// @notice Fork ID for Base Sepolia
    uint256 public baseSepoliaFork;

    /// @notice Block number pinned for reproducibility
    uint256 public constant FORK_BLOCK = 44917834;

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
        baseSepoliaFork = vm.createFork(rpcUrl, FORK_BLOCK);
        vm.selectFork(baseSepoliaFork);

        // Verify we are on Base Sepolia — the only live chain
        assertEq(block.chainid, 84532, "Should be Base Sepolia (chainId 84532)");
    }

    // ============================================
    // HELPERS
    // ============================================

    /// @notice Get RPC URL from environment or fallback to public
    function _getRpcUrl() internal view returns (string memory) {
        try vm.envString("BASE_SEPOLIA_RPC_URL") returns (string memory url) {
            if (bytes(url).length > 0) {
                return url;
            }
        } catch {}

        // Fallback to public RPC (rate limited)
        return "https://sepolia.base.org";
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
    function _deployProxy(address implementation, bytes memory initData) internal returns (address) {
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
        return address(proxy);
    }

    /// @notice Skip test if RPC is not available
    modifier skipIfNoRpc() {
        try vm.envString("BASE_SEPOLIA_RPC_URL") returns (string memory url) {
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
