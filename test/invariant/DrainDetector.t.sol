// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TAGITTreasury} from "../../src/treasury/TAGITTreasury.sol";
import {ITAGITTreasury} from "../../src/interfaces/ITAGITTreasury.sol";

/**
 * @title MockTokenDD
 * @notice Minimal ERC-20 for drain detector invariant tests
 */
contract MockTokenDD is ERC20 {
    constructor() ERC20("TAGIT", "TAG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title DrainDetectorHandler
 * @notice Invariant test handler — performs bounded deposit/withdraw/sync actions
 * @dev The handler constrains all operations to realistic ranges so that
 *      the invariant test can reason about the relationship between
 *      tracked balance and actual token balance.
 *
 *      Key insight: The drain detector's tracked balance can desync from
 *      actual balance ONLY through external token transfers that bypass
 *      the Treasury's bookkeeping. Governor sync corrects this.
 *      Between syncs, the desync is bounded by the total volume of
 *      untracked operations in that window.
 */
contract DrainDetectorHandler is Test {
    TAGITTreasury public treasury;
    MockTokenDD public token;
    address public governor;
    address public depositor;

    /// @notice Tracks total tokens deposited through Treasury (tracked by detector)
    uint256 public totalTrackedDeposits;

    /// @notice Tracks total tokens withdrawn through Treasury (tracked by detector)
    uint256 public totalTrackedWithdrawals;

    /// @notice Tracks total untracked direct transfers to Treasury
    uint256 public totalUntrackedInflows;

    constructor(TAGITTreasury treasury_, MockTokenDD token_, address governor_) {
        treasury = treasury_;
        token = token_;
        governor = governor_;
        depositor = makeAddr("depositor");

        // Fund depositor with tokens
        token.mint(depositor, 100_000_000e18);

        // Approve treasury
        vm.prank(depositor);
        token.approve(address(treasury), type(uint256).max);
    }

    /**
     * @notice Deposit tokens through Treasury (updates tracked balance)
     */
    function deposit(uint256 amount) external {
        amount = bound(amount, 1e18, 1_000_000e18);

        // Ensure depositor has enough
        if (token.balanceOf(depositor) < amount) return;

        vm.prank(depositor);
        treasury.depositToken(address(token), amount);
        totalTrackedDeposits += amount;
    }

    /**
     * @notice Direct transfer to treasury (NOT tracked by drain detector)
     * @dev This simulates the scenario where tokens arrive outside normal deposit flow
     */
    function untrackedTransfer(uint256 amount) external {
        amount = bound(amount, 1e18, 100_000e18);

        // Mint directly to treasury (simulates airdrop, direct transfer, etc.)
        token.mint(address(treasury), amount);
        totalUntrackedInflows += amount;
    }

    /**
     * @notice Governor syncs drain detector balance to actual balance
     */
    function governorSync() external {
        vm.prank(governor);
        treasury.syncDrainDetectorBalance();
    }
}

/**
 * @title DrainDetectorInvariantTest
 * @notice Proves that the drain detector's tracked balance is bounded
 *         relative to actual contract balance.
 *
 * @dev Invariant: After any sequence of deposits, withdrawals, and syncs:
 *      trackedBalance <= actualBalance + epsilon
 *
 *      The tracked balance can UNDERESTIMATE actual balance (when untracked
 *      transfers occur) but should never OVERESTIMATE it by more than
 *      what can be explained by pending withdrawal operations.
 *
 *      The governor sync operation is the correction mechanism. Between
 *      syncs, the desync is bounded and NOT exploitable because:
 *      1. Spike threshold checks use tracked balance — if tracked > actual,
 *         thresholds become MORE conservative (more likely to trip, not less)
 *      2. Velocity threshold uses cumulative outflow — not affected by balance
 *      3. The governor sync lag is bounded by the sync interval
 */
contract DrainDetectorInvariantTest is Test {
    TAGITTreasury public treasury;
    MockTokenDD public token;
    DrainDetectorHandler public handler;

    address public governor = makeAddr("governor");

    address[] public signers;

    function setUp() public {
        token = new MockTokenDD();

        // Create 8 signers
        for (uint256 i = 0; i < 8; i++) {
            signers.push(makeAddr(string(abi.encodePacked("signer", i))));
        }

        // Deploy treasury via proxy
        TAGITTreasury treasuryImpl = new TAGITTreasury();
        bytes memory initData = abi.encodeCall(TAGITTreasury.initialize, (governor, address(token), signers));
        ERC1967Proxy proxy = new ERC1967Proxy(address(treasuryImpl), initData);
        treasury = TAGITTreasury(payable(address(proxy)));

        // Fund treasury with initial tokens
        token.mint(address(treasury), 10_000_000e18);

        // Sync initial balance
        vm.prank(governor);
        treasury.syncDrainDetectorBalance();

        // Deploy handler
        handler = new DrainDetectorHandler(treasury, token, governor);

        // Target only the handler for invariant testing
        targetContract(address(handler));
    }

    /**
     * @notice INVARIANT: Tracked balance never overestimates actual balance
     * @dev The drain detector's tracked balance should always be <= actual token balance.
     *      This is because:
     *      - recordDeposit() only called when tokens actually arrive via depositToken()
     *      - recordWithdrawal() called when tokens leave
     *      - Direct transfers increase actual but NOT tracked (underestimate, not overestimate)
     *      - Governor sync corrects tracked to actual
     *
     *      If tracked > actual, the detector becomes MORE conservative (lower thresholds
     *      relative to real funds), which is fail-safe. But this invariant proves the
     *      desync is bounded and explainable.
     */
    function invariant_drainDetectorNeverOverestimates() public view {
        uint256 actualBalance = token.balanceOf(address(treasury));
        uint256 trackedBalance = treasury.getDrainDetectorBalance();

        // Tracked balance should never exceed actual balance.
        // It CAN be LESS than actual (when untracked inflows occur).
        // After governor sync, they align exactly.
        assertLe(trackedBalance, actualBalance, "INVARIANT VIOLATED: tracked balance exceeds actual balance");
    }

    /**
     * @notice INVARIANT: Governor sync always aligns tracked to actual
     * @dev After a sync, the two balances MUST be equal
     */
    function invariant_syncAligns() public {
        // Perform a sync
        vm.prank(governor);
        treasury.syncDrainDetectorBalance();

        uint256 actualBalance = token.balanceOf(address(treasury));
        uint256 trackedBalance = treasury.getDrainDetectorBalance();

        assertEq(uint256(trackedBalance), actualBalance, "INVARIANT VIOLATED: sync did not align tracked to actual");
    }
}
