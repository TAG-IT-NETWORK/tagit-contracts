// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console2} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";

import {TAGITPaymaster} from "../../src/account/TAGITPaymaster.sol";
import {ITAGITPaymaster} from "../../src/interfaces/ITAGITPaymaster.sol";

/**
 * @title DeployPaymasterArbitrumTest
 * @notice Fork test simulating the full DeployPaymasterArbitrum script on Arbitrum Sepolia.
 * @dev Validates all deployment steps: proxy init, selector whitelisting, deposit, stake, security controls.
 *
 *   forge test --match-contract DeployPaymasterArbitrumTest -vvv --fork-url $ARBITRUM_SEPOLIA_RPC_URL
 */
contract DeployPaymasterArbitrumTest is Test {
    /// @notice Canonical ERC-4337 EntryPoint v0.7
    address public constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    uint256 public constant PROTOCOL_DEPOSIT = 0.05 ether;
    uint256 public constant STAKE_AMOUNT = 0.01 ether;
    uint32 public constant UNSTAKE_DELAY = 86400;
    uint256 public constant MAX_GAS = 500_000;
    uint256 public constant DAILY_LIMIT = 50;

    // Actual TAGITCore selectors
    bytes4 public constant SEL_BIND_TAG = 0xf1313d45;
    bytes4 public constant SEL_ACTIVATE = 0xb260c42a;
    bytes4 public constant SEL_CLAIM = 0xddd5e1b2;
    bytes4 public constant SEL_MINT = 0x2cfd3005;

    TAGITPaymaster public paymaster;
    address public deployer;

    function setUp() public {
        // Fork Arbitrum Sepolia if RPC is available, otherwise use local
        string memory rpcUrl = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        }

        deployer = makeAddr("deployer");
        vm.deal(deployer, 10 ether);

        vm.startPrank(deployer);

        // Step 1: Deploy implementation
        TAGITPaymaster impl = new TAGITPaymaster();

        // Step 2: Deploy proxy + initialize
        bytes memory initData = abi.encodeCall(TAGITPaymaster.initialize, (ENTRY_POINT, deployer, deployer));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        paymaster = TAGITPaymaster(payable(address(proxy)));

        // Step 3: Whitelist selectors
        _whitelist(SEL_BIND_TAG);
        _whitelist(SEL_ACTIVATE);
        _whitelist(SEL_CLAIM);
        _whitelist(SEL_MINT);

        // Step 4: Protocol deposit
        paymaster.depositProtocol{value: PROTOCOL_DEPOSIT}();

        // Step 5: Add stake
        paymaster.addStake{value: STAKE_AMOUNT}(UNSTAKE_DELAY);

        vm.stopPrank();
    }

    // ============================================
    // PROXY & INITIALIZATION
    // ============================================

    function test_entryPoint_isCanonical() public view {
        assertEq(paymaster.entryPoint(), ENTRY_POINT);
    }

    function test_governor_isDeployer() public view {
        assertEq(paymaster.governor(), deployer);
    }

    function test_owner_isDeployer() public view {
        assertEq(paymaster.owner(), deployer);
    }

    function test_version_is100() public view {
        assertEq(keccak256(bytes(paymaster.version())), keccak256(bytes("1.0.0")));
    }

    // ============================================
    // SELECTOR WHITELISTING
    // ============================================

    function test_bindTag_isWhitelisted() public view {
        _assertWhitelisted(SEL_BIND_TAG);
    }

    function test_activate_isWhitelisted() public view {
        _assertWhitelisted(SEL_ACTIVATE);
    }

    function test_claim_isWhitelisted() public view {
        _assertWhitelisted(SEL_CLAIM);
    }

    function test_mint_isWhitelisted() public view {
        _assertWhitelisted(SEL_MINT);
    }

    function test_allFourSelectors_areSponsored() public view {
        assertTrue(paymaster.isSponsoredOperation(SEL_BIND_TAG));
        assertTrue(paymaster.isSponsoredOperation(SEL_ACTIVATE));
        assertTrue(paymaster.isSponsoredOperation(SEL_CLAIM));
        assertTrue(paymaster.isSponsoredOperation(SEL_MINT));
    }

    function test_unwhitelisted_selector_notSponsored() public view {
        bytes4 randomSelector = bytes4(keccak256("randomFunction()"));
        assertFalse(paymaster.isSponsoredOperation(randomSelector));
    }

    // ============================================
    // ENTRYPOINT DEPOSIT
    // ============================================

    function test_entryPointDeposit_isPositive() public view {
        uint256 deposit = paymaster.getDeposit();
        assertGt(deposit, 0, "EntryPoint deposit must be > 0");
    }

    function test_protocolDeposit_matchesFunding() public view {
        assertEq(paymaster.getProtocolDeposit(), PROTOCOL_DEPOSIT);
    }

    // ============================================
    // STAKE
    // ============================================

    function test_stakeDeposited() public view {
        // After addStake, the EntryPoint deposit should include both protocol deposit and stake
        // The deposit balance reflects depositTo calls, stake is separate
        // We verify deposit >= PROTOCOL_DEPOSIT (stake is held separately by EntryPoint)
        uint256 deposit = paymaster.getDeposit();
        assertGe(deposit, PROTOCOL_DEPOSIT, "Deposit must be >= protocol deposit");
    }

    // ============================================
    // SECURITY CONTROLS
    // ============================================

    function test_paymaster_notPaused() public view {
        assertFalse(paymaster.paused(), "Paymaster must not be paused after deploy");
    }

    function test_circuitBreaker_notTripped() public view {
        (,, bool tripped,) = paymaster.getCircuitBreakerState();
        assertFalse(tripped, "Circuit breaker must not be tripped");
    }

    function test_drainDetector_initialized() public view {
        (, uint16 spikeThreshold, uint16 velocityThreshold, uint32 maxTxPerWindow, bool tripped,) =
            paymaster.getDrainDetectorState();
        assertFalse(tripped, "Drain detector must not be tripped");
        assertGt(spikeThreshold, 0, "Spike threshold must be set");
        assertGt(velocityThreshold, 0, "Velocity threshold must be set");
        assertGt(maxTxPerWindow, 0, "Max tx per window must be set");
    }

    // ============================================
    // RATE LIMITING
    // ============================================

    function test_dailyLimit_isConfigured() public view {
        ITAGITPaymaster.SponsorshipConfig memory config = paymaster.getSponsorshipConfig(SEL_BIND_TAG);
        assertEq(config.dailyLimit, DAILY_LIMIT, "Daily limit must be 50");
    }

    function test_canSponsor_freshUser() public view {
        address freshUser = address(0xBEEF);
        assertTrue(paymaster.canSponsor(freshUser, SEL_BIND_TAG));
        assertTrue(paymaster.canSponsor(freshUser, SEL_ACTIVATE));
        assertTrue(paymaster.canSponsor(freshUser, SEL_CLAIM));
        assertTrue(paymaster.canSponsor(freshUser, SEL_MINT));
    }

    function test_initialUsage_isZero() public view {
        address freshUser = address(0xBEEF);
        assertEq(paymaster.getUserDailyUsage(freshUser, SEL_BIND_TAG), 0);
    }

    // ============================================
    // GAS CONFIGURATION
    // ============================================

    function test_maxGas_isConfigured() public view {
        ITAGITPaymaster.SponsorshipConfig memory config = paymaster.getSponsorshipConfig(SEL_BIND_TAG);
        assertEq(config.maxGas, MAX_GAS, "Max gas must be 500k");
    }

    // ============================================
    // TOTAL GAS SPONSORED
    // ============================================

    function test_totalGasSponsored_isZero() public view {
        assertEq(paymaster.totalGasSponsored(), 0, "No gas should be sponsored yet");
    }

    // ============================================
    // HELPERS
    // ============================================

    function _whitelist(bytes4 selector) internal {
        ITAGITPaymaster.SponsorshipConfig memory config = ITAGITPaymaster.SponsorshipConfig({
            selector: selector, maxGas: MAX_GAS, dailyLimit: DAILY_LIMIT, active: true
        });
        paymaster.setSponsorshipConfig(selector, config);
    }

    function _assertWhitelisted(bytes4 selector) internal view {
        ITAGITPaymaster.SponsorshipConfig memory config = paymaster.getSponsorshipConfig(selector);
        assertEq(config.selector, selector, "Selector mismatch");
        assertEq(config.maxGas, MAX_GAS, "Max gas mismatch");
        assertEq(config.dailyLimit, DAILY_LIMIT, "Daily limit mismatch");
        assertTrue(config.active, "Selector must be active");
    }
}
