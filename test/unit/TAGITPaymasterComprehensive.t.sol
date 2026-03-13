// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {IPaymaster} from "@account-abstraction/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";

import {TAGITPaymaster} from "../../src/account/TAGITPaymaster.sol";
import {ITAGITPaymaster} from "../../src/interfaces/ITAGITPaymaster.sol";

/**
 * @title MockEntryPointFull
 * @notice Extended mock for ERC-4337 EntryPoint with stake management
 */
contract MockEntryPointFull {
    mapping(address => uint256) public deposits;

    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return deposits[account];
    }

    function withdrawTo(address payable to, uint256 amount) external {
        require(deposits[msg.sender] >= amount, "Insufficient");
        deposits[msg.sender] -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "Transfer failed");
    }

    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}

    receive() external payable {}
}

/**
 * @title TAGITPaymasterComprehensiveTest
 * @notice Comprehensive tests covering rate limiting, drain protection,
 *         validatePaymasterUserOp flow, postOp brand deduction, and admin functions
 */
contract TAGITPaymasterComprehensiveTest is Test {
    // Events
    event OperationSponsored(address indexed user, bytes4 indexed selector, uint256 gasCost, bytes32 brandId);
    event PaymasterPausedEvent(uint256 indexed timestamp, string reason);
    event PaymasterUnpausedEvent(uint256 indexed timestamp);
    event SponsorshipConfigSet(bytes4 indexed selector, uint256 maxGas, uint256 dailyLimit, bool active);

    TAGITPaymaster public paymaster;
    TAGITPaymaster public paymasterImpl;
    MockEntryPointFull public entryPoint;

    address public owner;
    address public governor;
    address public user;
    address public attacker;

    bytes4 public constant MINT_SELECTOR = bytes4(keccak256("mint(address,bytes32)"));
    bytes4 public constant BIND_SELECTOR = bytes4(keccak256("bindTag(uint256,bytes32,bytes)"));
    bytes4 public constant TEST_SELECTOR = bytes4(keccak256("testFunction()"));
    bytes32 public constant BRAND_ID = keccak256("TestBrand");

    function setUp() public {
        owner = makeAddr("owner");
        governor = makeAddr("governor");
        user = makeAddr("user");
        attacker = makeAddr("attacker");

        vm.deal(owner, 100 ether);
        vm.deal(governor, 100 ether);
        vm.deal(user, 100 ether);

        vm.startPrank(owner);

        entryPoint = new MockEntryPointFull();
        vm.deal(address(entryPoint), 1000 ether);

        paymasterImpl = new TAGITPaymaster();
        bytes memory initData = abi.encodeCall(TAGITPaymaster.initialize, (address(entryPoint), governor, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(paymasterImpl), initData);
        paymaster = TAGITPaymaster(payable(address(proxy)));

        vm.stopPrank();

        // Setup: register brand, configure sponsorship, fund paymaster
        vm.startPrank(governor);
        paymaster.registerBrand(BRAND_ID, user);

        paymaster.setSponsorshipConfig(
            MINT_SELECTOR,
            ITAGITPaymaster.SponsorshipConfig({selector: MINT_SELECTOR, maxGas: 500_000, dailyLimit: 5, active: true})
        );

        paymaster.setSponsorshipConfig(
            TEST_SELECTOR,
            ITAGITPaymaster.SponsorshipConfig({
                selector: TEST_SELECTOR,
                maxGas: 500_000,
                dailyLimit: 0, // unlimited
                active: true
            })
        );

        paymaster.depositProtocol{value: 10 ether}();
        vm.stopPrank();

        // Fund the paymaster on the entry point
        entryPoint.depositTo{value: 10 ether}(address(paymaster));

        // Set tx.gasprice so maxCost checks work (Foundry defaults to 0)
        vm.txGasPrice(1 gwei);
    }

    // ========================================================================
    // HELPERS
    // ========================================================================

    /// @dev Build a minimal PackedUserOperation for testing
    function _buildUserOp(address sender, bytes4 selector) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: abi.encodePacked(selector),
            accountGasLimits: bytes32(uint256(500_000) << 128 | uint256(500_000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }

    /// @dev Build a UserOp with paymasterAndData containing brand ID
    function _buildUserOpWithBrand(address sender, bytes4 selector, bytes32 brandId)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _buildUserOp(sender, selector);
        // paymasterAndData = [paymaster address (20)] + [paymaster validation gas (16)] + [paymaster post-op gas (16)] + [brand ID (32)]
        op.paymasterAndData = abi.encodePacked(
            address(paymaster), // 20 bytes
            uint128(100_000), // paymasterVerificationGasLimit - 16 bytes
            uint128(50_000), // paymasterPostOpGasLimit - 16 bytes
            brandId // 32 bytes
        );
    }

    /// @dev Call validatePaymasterUserOp as the EntryPoint
    function _validate(PackedUserOperation memory op, uint256 maxCost)
        internal
        returns (bytes memory context, uint256 validationData)
    {
        vm.prank(address(entryPoint));
        return paymaster.validatePaymasterUserOp(op, keccak256("hash"), maxCost);
    }

    /// @dev Call postOp as the EntryPoint
    function _postOp(bytes memory context, uint256 gasCost) internal {
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, gasCost, tx.gasprice);
    }

    // ========================================================================
    // validatePaymasterUserOp — HAPPY PATH
    // ========================================================================

    function test_validate_happyPath() public {
        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        (bytes memory context, uint256 validationData) = _validate(op, 0.0001 ether);

        assertEq(validationData, 0, "validationData should be 0 (valid)");
        assertTrue(context.length > 0, "Context should be non-empty");

        // Decode context
        (address ctxUser, bytes4 ctxSelector,,) = abi.decode(context, (address, bytes4, bytes32, uint256));
        assertEq(ctxUser, user, "Context user should match");
        assertEq(ctxSelector, MINT_SELECTOR, "Context selector should match");
    }

    // ========================================================================
    // validatePaymasterUserOp — REVERT PATHS
    // ========================================================================

    function test_validate_revert_notEntryPoint() public {
        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotEntryPoint.selector, attacker));
        paymaster.validatePaymasterUserOp(op, keccak256("hash"), 0.0001 ether);
    }

    function test_validate_revert_paused() public {
        vm.prank(governor);
        paymaster.pause();

        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        vm.prank(address(entryPoint));
        vm.expectRevert(ITAGITPaymaster.PaymasterPaused.selector);
        paymaster.validatePaymasterUserOp(op, keccak256("hash"), 0.0001 ether);
    }

    function test_validate_revert_invalidPaymasterData() public {
        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);
        op.callData = ""; // Empty callData, less than 4 bytes

        vm.prank(address(entryPoint));
        vm.expectRevert(ITAGITPaymaster.InvalidPaymasterData.selector);
        paymaster.validatePaymasterUserOp(op, keccak256("hash"), 0.0001 ether);
    }

    function test_validate_revert_operationNotSponsored() public {
        bytes4 unsponsoredSelector = bytes4(keccak256("notSponsored()"));
        PackedUserOperation memory op = _buildUserOp(user, unsponsoredSelector);

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.OperationNotSponsored.selector, unsponsoredSelector));
        paymaster.validatePaymasterUserOp(op, keccak256("hash"), 0.0001 ether);
    }

    function test_validate_revert_depositTooLow() public {
        // Drain the entry point deposit for paymaster
        // The mock doesn't let us easily reduce, so use a fresh paymaster
        vm.startPrank(owner);
        TAGITPaymaster pm2Impl = new TAGITPaymaster();
        bytes memory initData = abi.encodeCall(TAGITPaymaster.initialize, (address(entryPoint), governor, owner));
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(pm2Impl), initData);
        TAGITPaymaster pm2 = TAGITPaymaster(payable(address(proxy2)));
        vm.stopPrank();

        vm.prank(governor);
        pm2.setSponsorshipConfig(
            MINT_SELECTOR,
            ITAGITPaymaster.SponsorshipConfig({selector: MINT_SELECTOR, maxGas: 500_000, dailyLimit: 0, active: true})
        );

        // Don't deposit anything — entryPoint balance for pm2 is 0
        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        vm.prank(address(entryPoint));
        vm.expectRevert(); // DepositTooLow
        pm2.validatePaymasterUserOp(op, keccak256("hash"), 0.0001 ether);
    }

    // ========================================================================
    // DAILY LIMIT — increment and enforcement
    // ========================================================================

    function test_dailyLimit_incrementsOnValidation() public {
        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        // Validate 3 times
        for (uint256 i = 0; i < 3; i++) {
            _validate(op, 0.0001 ether);
        }

        uint256 usage = paymaster.getUserDailyUsage(user, MINT_SELECTOR);
        assertEq(usage, 3, "Daily usage should be 3 after 3 validations");
    }

    function test_dailyLimit_revert_exceeded() public {
        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        // Use all 5 daily limit slots
        for (uint256 i = 0; i < 5; i++) {
            _validate(op, 0.0001 ether);
        }

        // 6th call should revert
        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.DailyLimitExceeded.selector, user, MINT_SELECTOR, 5));
        paymaster.validatePaymasterUserOp(op, keccak256("hash"), 0.0001 ether);
    }

    function test_dailyLimit_resets_nextDay() public {
        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        // Use all 5 slots
        for (uint256 i = 0; i < 5; i++) {
            _validate(op, 0.0001 ether);
        }

        assertEq(paymaster.getUserDailyUsage(user, MINT_SELECTOR), 5);

        // Advance to next day
        vm.warp(block.timestamp + 1 days);

        // Should work again
        (bytes memory ctx, uint256 vd) = _validate(op, 0.0001 ether);
        assertEq(vd, 0, "Should be valid on new day");
        assertTrue(ctx.length > 0);
    }

    function test_dailyLimit_unlimitedWhenZero() public {
        // TEST_SELECTOR has dailyLimit = 0 (unlimited)
        PackedUserOperation memory op = _buildUserOp(user, TEST_SELECTOR);

        // Should succeed many times
        for (uint256 i = 0; i < 20; i++) {
            _validate(op, 0.0001 ether);
        }

        // No revert — unlimited works
    }

    function test_dailyLimit_independentPerUser() public {
        PackedUserOperation memory opUser = _buildUserOp(user, MINT_SELECTOR);
        PackedUserOperation memory opAttacker = _buildUserOp(attacker, MINT_SELECTOR);

        // User exhausts limit
        for (uint256 i = 0; i < 5; i++) {
            _validate(opUser, 0.0001 ether);
        }

        // Attacker should still have their own allowance
        (bytes memory ctx,) = _validate(opAttacker, 0.0001 ether);
        assertTrue(ctx.length > 0, "Other user should not be affected");
    }

    // ========================================================================
    // postOp — brand deposit deduction
    // ========================================================================

    function test_postOp_brandDeduction() public {
        // Fund brand
        vm.prank(user);
        paymaster.depositForBrand{value: 1 ether}(BRAND_ID);

        uint256 balBefore = paymaster.getBrandDeposit(BRAND_ID).balance;
        assertEq(balBefore, 1 ether);

        // Simulate postOp with brand context
        bytes memory context = abi.encode(user, MINT_SELECTOR, BRAND_ID, uint256(0.0001 ether));
        uint256 gasCost = 0.0005 ether;

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, gasCost, tx.gasprice);

        ITAGITPaymaster.BrandDeposit memory dep = paymaster.getBrandDeposit(BRAND_ID);
        assertEq(dep.balance, 1 ether - gasCost, "Brand balance should decrease");
        assertEq(dep.totalSpent, gasCost, "Total spent should increase");
    }

    function test_postOp_noBrandDeduction_whenInsufficient() public {
        // Brand has no deposit
        bytes memory context = abi.encode(user, MINT_SELECTOR, BRAND_ID, uint256(0.0001 ether));

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.0005 ether, tx.gasprice);

        assertEq(paymaster.getBrandDeposit(BRAND_ID).balance, 0, "Brand balance should remain 0");
    }

    function test_postOp_emitsOperationSponsored() public {
        bytes memory context = abi.encode(user, MINT_SELECTOR, bytes32(0), uint256(0.0001 ether));

        vm.prank(address(entryPoint));
        vm.expectEmit(true, true, false, true);
        emit OperationSponsored(user, MINT_SELECTOR, 0.0005 ether, bytes32(0));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.0005 ether, tx.gasprice);
    }

    function test_postOp_revert_notEntryPoint() public {
        bytes memory context = abi.encode(user, MINT_SELECTOR, bytes32(0), uint256(0.0001 ether));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotEntryPoint.selector, attacker));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.0005 ether, tx.gasprice);
    }

    // ========================================================================
    // setGovernor
    // ========================================================================

    function test_setGovernor_success() public {
        address newGov = makeAddr("newGov");

        vm.prank(governor);
        paymaster.setGovernor(newGov);

        // Old governor can no longer call governor functions
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotGovernor.selector, governor));
        paymaster.pause();

        // New governor can
        vm.prank(newGov);
        paymaster.pause();
        assertTrue(paymaster.paused());
    }

    function test_setGovernor_revert_notGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotGovernor.selector, attacker));
        paymaster.setGovernor(attacker);
    }

    function test_setGovernor_revert_zeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(ITAGITPaymaster.ZeroAddress.selector);
        paymaster.setGovernor(address(0));
    }

    // ========================================================================
    // batchSetSponsorshipConfig
    // ========================================================================

    function test_batchSetSponsorshipConfig_success() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MINT_SELECTOR;
        selectors[1] = BIND_SELECTOR;

        ITAGITPaymaster.SponsorshipConfig[] memory configs = new ITAGITPaymaster.SponsorshipConfig[](2);
        configs[0] = ITAGITPaymaster.SponsorshipConfig({
            selector: MINT_SELECTOR, maxGas: 1_000_000, dailyLimit: 10, active: true
        });
        configs[1] =
            ITAGITPaymaster.SponsorshipConfig({selector: BIND_SELECTOR, maxGas: 800_000, dailyLimit: 20, active: true});

        vm.prank(governor);
        paymaster.batchSetSponsorshipConfig(selectors, configs);

        assertTrue(paymaster.isSponsoredOperation(BIND_SELECTOR), "BIND should be sponsored");
        ITAGITPaymaster.SponsorshipConfig memory cfg = paymaster.getSponsorshipConfig(BIND_SELECTOR);
        assertEq(cfg.maxGas, 800_000);
        assertEq(cfg.dailyLimit, 20);
    }

    function test_batchSetSponsorshipConfig_revert_mismatchedLengths() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MINT_SELECTOR;
        selectors[1] = BIND_SELECTOR;

        ITAGITPaymaster.SponsorshipConfig[] memory configs = new ITAGITPaymaster.SponsorshipConfig[](1);
        configs[0] =
            ITAGITPaymaster.SponsorshipConfig({selector: MINT_SELECTOR, maxGas: 500_000, dailyLimit: 5, active: true});

        vm.prank(governor);
        vm.expectRevert(ITAGITPaymaster.InvalidPaymasterData.selector);
        paymaster.batchSetSponsorshipConfig(selectors, configs);
    }

    function test_batchSetSponsorshipConfig_revert_notGovernor() public {
        bytes4[] memory selectors = new bytes4[](0);
        ITAGITPaymaster.SponsorshipConfig[] memory configs = new ITAGITPaymaster.SponsorshipConfig[](0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotGovernor.selector, attacker));
        paymaster.batchSetSponsorshipConfig(selectors, configs);
    }

    // ========================================================================
    // withdrawProtocol
    // ========================================================================

    function test_withdrawProtocol_success() public {
        uint256 balBefore = governor.balance;

        vm.prank(governor);
        paymaster.withdrawProtocol(1 ether, governor);

        assertEq(governor.balance, balBefore + 1 ether, "Governor should receive funds");
    }

    function test_withdrawProtocol_revert_notGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotGovernor.selector, attacker));
        paymaster.withdrawProtocol(1 ether, attacker);
    }

    function test_withdrawProtocol_revert_exceedsBalance() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.WithdrawalExceedsBalance.selector, 100 ether, 10 ether));
        paymaster.withdrawProtocol(100 ether, governor);
    }

    // ========================================================================
    // setBrandActive
    // ========================================================================

    function test_setBrandActive_deactivate() public {
        vm.prank(governor);
        paymaster.setBrandActive(BRAND_ID, false);

        assertFalse(paymaster.getBrandDeposit(BRAND_ID).active, "Brand should be inactive");
    }

    function test_setBrandActive_reactivate() public {
        vm.prank(governor);
        paymaster.setBrandActive(BRAND_ID, false);

        vm.prank(governor);
        paymaster.setBrandActive(BRAND_ID, true);

        assertTrue(paymaster.getBrandDeposit(BRAND_ID).active, "Brand should be active again");
    }

    function test_setBrandActive_revert_notGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotGovernor.selector, attacker));
        paymaster.setBrandActive(BRAND_ID, false);
    }

    // ========================================================================
    // depositForBrand — edge cases
    // ========================================================================

    function test_depositForBrand_revert_zeroValue() public {
        vm.prank(user);
        vm.expectRevert(ITAGITPaymaster.ZeroAmount.selector);
        paymaster.depositForBrand{value: 0}(BRAND_ID);
    }

    function test_depositForBrand_revert_unregistered() public {
        bytes32 unknownBrand = keccak256("Unknown");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.BrandNotRegistered.selector, unknownBrand));
        paymaster.depositForBrand{value: 1 ether}(unknownBrand);
    }

    // ========================================================================
    // depositProtocol — edge cases
    // ========================================================================

    function test_depositProtocol_revert_zeroValue() public {
        vm.prank(governor);
        vm.expectRevert(ITAGITPaymaster.ZeroAmount.selector);
        paymaster.depositProtocol{value: 0}();
    }

    // ========================================================================
    // initialize — zero address reverts
    // ========================================================================

    function test_initialize_revert_zeroEntryPoint() public {
        TAGITPaymaster impl = new TAGITPaymaster();
        vm.expectRevert(ITAGITPaymaster.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(TAGITPaymaster.initialize, (address(0), governor, owner)));
    }

    function test_initialize_revert_zeroGovernor() public {
        TAGITPaymaster impl = new TAGITPaymaster();
        vm.expectRevert(ITAGITPaymaster.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(TAGITPaymaster.initialize, (address(entryPoint), address(0), owner))
        );
    }

    function test_initialize_revert_zeroOwner() public {
        TAGITPaymaster impl = new TAGITPaymaster();
        vm.expectRevert(ITAGITPaymaster.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(TAGITPaymaster.initialize, (address(entryPoint), governor, address(0)))
        );
    }

    function test_initialize_revert_doubleInit() public {
        vm.expectRevert();
        paymaster.initialize(address(entryPoint), governor, owner);
    }

    // ========================================================================
    // initialize on implementation directly — disabled
    // ========================================================================

    function test_initialize_onImplementation_reverts() public {
        vm.expectRevert();
        paymasterImpl.initialize(address(entryPoint), governor, owner);
    }

    // ========================================================================
    // pause / unpause with validation
    // ========================================================================

    function test_pause_blocksValidation() public {
        vm.prank(governor);
        paymaster.pause();

        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        vm.prank(address(entryPoint));
        vm.expectRevert(ITAGITPaymaster.PaymasterPaused.selector);
        paymaster.validatePaymasterUserOp(op, keccak256("hash"), 0.0001 ether);
    }

    function test_unpause_resumesValidation() public {
        vm.prank(governor);
        paymaster.pause();

        vm.prank(governor);
        paymaster.unpause();

        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);
        (bytes memory ctx, uint256 vd) = _validate(op, 0.0001 ether);
        assertEq(vd, 0);
        assertTrue(ctx.length > 0);
    }

    // ========================================================================
    // canSponsor view function
    // ========================================================================

    function test_canSponsor_trueBeforeLimit() public view {
        assertTrue(paymaster.canSponsor(user, MINT_SELECTOR), "Should be sponsorable");
    }

    function test_canSponsor_falseAfterLimit() public {
        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        for (uint256 i = 0; i < 5; i++) {
            _validate(op, 0.0001 ether);
        }

        assertFalse(paymaster.canSponsor(user, MINT_SELECTOR), "Should not be sponsorable after limit");
    }

    function test_canSponsor_falseForUnsponsored() public view {
        assertFalse(
            paymaster.canSponsor(user, bytes4(keccak256("notSponsored()"))), "Unsponsored selector should return false"
        );
    }

    // ========================================================================
    // FUZZ: daily limit boundary
    // ========================================================================

    function testFuzz_dailyLimit_exactBoundary(uint256 limit) public {
        limit = bound(limit, 1, 20);

        // Reconfigure with fuzzed limit
        vm.prank(governor);
        paymaster.setSponsorshipConfig(
            MINT_SELECTOR,
            ITAGITPaymaster.SponsorshipConfig({
                selector: MINT_SELECTOR, maxGas: 500_000, dailyLimit: limit, active: true
            })
        );

        PackedUserOperation memory op = _buildUserOp(user, MINT_SELECTOR);

        // Exactly `limit` validations should succeed
        for (uint256 i = 0; i < limit; i++) {
            _validate(op, 0.0001 ether);
        }

        // Next one should revert
        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.DailyLimitExceeded.selector, user, MINT_SELECTOR, limit));
        paymaster.validatePaymasterUserOp(op, keccak256("hash"), 0.0001 ether);
    }

    // ========================================================================
    // FUZZ: random caller cannot withdraw brand deposit
    // ========================================================================

    function testFuzz_withdrawBrand_randomCaller(address caller) public {
        vm.assume(caller != user); // user is brand owner
        vm.assume(caller != address(0));

        vm.prank(user);
        paymaster.depositForBrand{value: 1 ether}(BRAND_ID);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITAGITPaymaster.NotBrandOwner.selector, BRAND_ID, caller));
        paymaster.withdrawBrandDeposit(BRAND_ID, 0.5 ether);
    }

    // ========================================================================
    // version
    // ========================================================================

    function test_version_returns() public view {
        string memory ver = paymaster.version();
        assertTrue(bytes(ver).length > 0, "Version should be non-empty");
    }

    // ========================================================================
    // receive() ETH
    // ========================================================================

    function test_receive_acceptsEth() public {
        uint256 balBefore = address(paymaster).balance;
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(paymaster).call{value: 0.5 ether}("");
        assertTrue(ok, "Should accept ETH");
        assertEq(address(paymaster).balance, balBefore + 0.5 ether);
    }
}
