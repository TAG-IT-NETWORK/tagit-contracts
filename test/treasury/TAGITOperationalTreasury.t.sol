// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {TAGITOperationalTreasury} from "../../src/treasury/TAGITOperationalTreasury.sol";
import {ITAGITOperationalTreasury} from "../../src/interfaces/ITAGITOperationalTreasury.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal mock ERC-20 for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 100_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TAGITOperationalTreasuryTest is Test {
    TAGITOperationalTreasury public treasury;
    MockERC20 public mockToken;

    // Actors
    address public admin;
    address public treasurer;
    address public operator;
    address public alice;
    address public bob;
    address public unauthorized;

    // Budget categories
    bytes32 public constant CAT_OPERATIONS = keccak256("OPERATIONS");
    bytes32 public constant CAT_MARKETING = keccak256("MARKETING");
    bytes32 public constant CAT_INFRA = keccak256("INFRASTRUCTURE");

    // Roles
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Events (re-declared for vm.expectEmit)
    event ETHDeposited(address indexed from, uint256 amount);
    event ERC20Deposited(address indexed token, address indexed from, uint256 amount);
    event ETHWithdrawn(bytes32 indexed category, address indexed to, uint256 amount);
    event ERC20Withdrawn(bytes32 indexed category, address indexed token, address indexed to, uint256 amount);
    event BudgetCapUpdated(bytes32 indexed category, uint256 oldCap, uint256 newCap);
    event CategoryDeactivated(bytes32 indexed category);
    event CategoryReactivated(bytes32 indexed category);
    event PeriodReset(bytes32 indexed category, uint48 newPeriodStart);
    event PeriodDurationUpdated(uint48 oldDuration, uint48 newDuration);
    event EmergencySweep(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        admin = makeAddr("admin");
        treasurer = makeAddr("treasurer");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        unauthorized = makeAddr("unauthorized");

        vm.startPrank(admin);
        treasury = new TAGITOperationalTreasury(admin, treasurer, operator);
        mockToken = new MockERC20();
        vm.stopPrank();

        // Fund operator with tokens for deposit tests
        vm.prank(admin);
        mockToken.transfer(operator, 10_000_000e18);

        // Fund operator with ETH for deposit tests
        vm.deal(operator, 1000 ether);
    }

    // ============================================
    // INITIALIZATION TESTS
    // ============================================

    function test_initialization() public view {
        assertEq(treasury.version(), "1.0.0");
        assertEq(treasury.periodDuration(), 30 days);
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(treasury.hasRole(ADMIN_ROLE, admin));
        assertTrue(treasury.hasRole(TREASURER_ROLE, treasurer));
        assertTrue(treasury.hasRole(OPERATOR_ROLE, operator));
    }

    function test_constructor_revert_zeroAdmin() public {
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAddress.selector);
        new TAGITOperationalTreasury(address(0), treasurer, operator);
    }

    function test_constructor_revert_zeroTreasurer() public {
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAddress.selector);
        new TAGITOperationalTreasury(admin, address(0), operator);
    }

    function test_constructor_revert_zeroOperator() public {
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAddress.selector);
        new TAGITOperationalTreasury(admin, treasurer, address(0));
    }

    // ============================================
    // DEPOSIT TESTS
    // ============================================

    function test_depositETH() public {
        vm.prank(operator);

        vm.expectEmit(true, false, false, true);
        emit ETHDeposited(operator, 10 ether);

        treasury.depositETH{value: 10 ether}();

        assertEq(address(treasury).balance, 10 ether);
    }

    function test_depositETH_revert_zeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAmount.selector);
        treasury.depositETH{value: 0}();
    }

    function test_depositETH_revert_unauthorized() public {
        vm.deal(unauthorized, 10 ether);
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, OPERATOR_ROLE
            )
        );
        treasury.depositETH{value: 1 ether}();
    }

    function test_depositETH_receive() public {
        vm.deal(alice, 5 ether);
        vm.prank(alice);

        (bool success,) = address(treasury).call{value: 5 ether}("");
        assertTrue(success);
        assertEq(address(treasury).balance, 5 ether);
    }

    function test_depositERC20() public {
        uint256 amount = 1000e18;

        vm.startPrank(operator);
        mockToken.approve(address(treasury), amount);

        vm.expectEmit(true, true, false, true);
        emit ERC20Deposited(address(mockToken), operator, amount);

        treasury.depositERC20(address(mockToken), amount);
        vm.stopPrank();

        assertEq(mockToken.balanceOf(address(treasury)), amount);
    }

    function test_depositERC20_revert_zeroToken() public {
        vm.prank(operator);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAddress.selector);
        treasury.depositERC20(address(0), 1000e18);
    }

    function test_depositERC20_revert_zeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAmount.selector);
        treasury.depositERC20(address(mockToken), 0);
    }

    function test_depositERC20_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, OPERATOR_ROLE
            )
        );
        treasury.depositERC20(address(mockToken), 1000e18);
    }

    // ============================================
    // BUDGET CAP MANAGEMENT TESTS
    // ============================================

    function test_setBudgetCap_newCategory() public {
        uint256 cap = 100_000e18;

        vm.prank(treasurer);

        vm.expectEmit(true, false, false, true);
        emit BudgetCapUpdated(CAT_OPERATIONS, 0, cap);

        treasury.setBudgetCap(CAT_OPERATIONS, cap);

        ITAGITOperationalTreasury.BudgetCap memory bc = treasury.getBudgetCap(CAT_OPERATIONS);
        assertEq(bc.cap, cap);
        assertEq(bc.spent, 0);
        assertTrue(bc.active);
        assertGt(bc.periodStart, 0);
    }

    function test_setBudgetCap_updateExisting() public {
        vm.startPrank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 100_000e18);

        vm.expectEmit(true, false, false, true);
        emit BudgetCapUpdated(CAT_OPERATIONS, 100_000e18, 200_000e18);

        treasury.setBudgetCap(CAT_OPERATIONS, 200_000e18);
        vm.stopPrank();

        ITAGITOperationalTreasury.BudgetCap memory bc = treasury.getBudgetCap(CAT_OPERATIONS);
        assertEq(bc.cap, 200_000e18);
    }

    function test_setBudgetCap_revert_zeroCap() public {
        vm.prank(treasurer);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroCap.selector);
        treasury.setBudgetCap(CAT_OPERATIONS, 0);
    }

    function test_setBudgetCap_revert_zeroCategory() public {
        vm.prank(treasurer);
        vm.expectRevert(abi.encodeWithSelector(ITAGITOperationalTreasury.CategoryNotFound.selector, bytes32(0)));
        treasury.setBudgetCap(bytes32(0), 100_000e18);
    }

    function test_setBudgetCap_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, TREASURER_ROLE
            )
        );
        treasury.setBudgetCap(CAT_OPERATIONS, 100_000e18);
    }

    function test_deactivateCategory() public {
        vm.startPrank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 100_000e18);

        vm.expectEmit(true, false, false, false);
        emit CategoryDeactivated(CAT_OPERATIONS);

        treasury.deactivateCategory(CAT_OPERATIONS);
        vm.stopPrank();

        ITAGITOperationalTreasury.BudgetCap memory bc = treasury.getBudgetCap(CAT_OPERATIONS);
        assertFalse(bc.active);
    }

    function test_deactivateCategory_revert_notFound() public {
        vm.prank(treasurer);
        vm.expectRevert(abi.encodeWithSelector(ITAGITOperationalTreasury.CategoryNotFound.selector, CAT_OPERATIONS));
        treasury.deactivateCategory(CAT_OPERATIONS);
    }

    function test_deactivateCategory_revert_alreadyInactive() public {
        vm.startPrank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 100_000e18);
        treasury.deactivateCategory(CAT_OPERATIONS);

        vm.expectRevert(abi.encodeWithSelector(ITAGITOperationalTreasury.CategoryNotActive.selector, CAT_OPERATIONS));
        treasury.deactivateCategory(CAT_OPERATIONS);
        vm.stopPrank();
    }

    function test_reactivateCategory() public {
        vm.startPrank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 100_000e18);
        treasury.deactivateCategory(CAT_OPERATIONS);

        vm.expectEmit(true, false, false, false);
        emit CategoryReactivated(CAT_OPERATIONS);

        treasury.reactivateCategory(CAT_OPERATIONS);
        vm.stopPrank();

        ITAGITOperationalTreasury.BudgetCap memory bc = treasury.getBudgetCap(CAT_OPERATIONS);
        assertTrue(bc.active);
    }

    function test_reactivateCategory_revert_alreadyActive() public {
        vm.startPrank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 100_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(ITAGITOperationalTreasury.CategoryAlreadyExists.selector, CAT_OPERATIONS)
        );
        treasury.reactivateCategory(CAT_OPERATIONS);
        vm.stopPrank();
    }

    function test_resetPeriod() public {
        vm.startPrank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 100_000e18);
        vm.stopPrank();

        // Spend some budget
        _fundTreasuryETH(50 ether);
        _setupAndSpendETH(CAT_OPERATIONS, 10 ether);

        // Verify spent
        ITAGITOperationalTreasury.BudgetCap memory bc = treasury.getBudgetCap(CAT_OPERATIONS);
        assertEq(bc.spent, 10 ether);

        // Reset
        vm.prank(treasurer);
        treasury.resetPeriod(CAT_OPERATIONS);

        bc = treasury.getBudgetCap(CAT_OPERATIONS);
        assertEq(bc.spent, 0);
    }

    function test_resetPeriod_revert_notFound() public {
        vm.prank(treasurer);
        vm.expectRevert(abi.encodeWithSelector(ITAGITOperationalTreasury.CategoryNotFound.selector, CAT_OPERATIONS));
        treasury.resetPeriod(CAT_OPERATIONS);
    }

    // ============================================
    // WITHDRAWAL TESTS — HAPPY PATH
    // ============================================

    function test_withdrawETH() public {
        _fundTreasuryETH(100 ether);

        vm.prank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 50 ether);

        uint256 aliceBefore = alice.balance;

        vm.prank(operator);

        vm.expectEmit(true, true, false, true);
        emit ETHWithdrawn(CAT_OPERATIONS, alice, 10 ether);

        treasury.withdrawETH(CAT_OPERATIONS, alice, 10 ether);

        assertEq(alice.balance, aliceBefore + 10 ether);
        assertEq(address(treasury).balance, 90 ether);

        // Check spend tracked
        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 40 ether);
    }

    function test_withdrawERC20() public {
        _fundTreasuryERC20(10_000e18);

        vm.prank(treasurer);
        treasury.setBudgetCap(CAT_MARKETING, 5_000e18);

        uint256 aliceBefore = mockToken.balanceOf(alice);

        vm.prank(operator);

        vm.expectEmit(true, true, true, true);
        emit ERC20Withdrawn(CAT_MARKETING, address(mockToken), alice, 1_000e18);

        treasury.withdrawERC20(CAT_MARKETING, address(mockToken), alice, 1_000e18);

        assertEq(mockToken.balanceOf(alice), aliceBefore + 1_000e18);
        assertEq(treasury.remainingBudget(CAT_MARKETING), 4_000e18);
    }

    function test_withdrawETH_multipleWithdrawals() public {
        _fundTreasuryETH(100 ether);

        vm.prank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 50 ether);

        vm.startPrank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 10 ether);
        treasury.withdrawETH(CAT_OPERATIONS, bob, 15 ether);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 5 ether);
        vm.stopPrank();

        // 30 ether spent total
        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 20 ether);
        assertEq(alice.balance, 15 ether);
        assertEq(bob.balance, 15 ether);
    }

    function test_withdrawETH_revert_zeroAddress() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(operator);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAddress.selector);
        treasury.withdrawETH(CAT_OPERATIONS, address(0), 1 ether);
    }

    function test_withdrawETH_revert_zeroAmount() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(operator);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAmount.selector);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 0);
    }

    function test_withdrawERC20_revert_zeroToken() public {
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(operator);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAddress.selector);
        treasury.withdrawERC20(CAT_OPERATIONS, address(0), alice, 1 ether);
    }

    function test_withdrawERC20_revert_zeroRecipient() public {
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(operator);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAddress.selector);
        treasury.withdrawERC20(CAT_OPERATIONS, address(mockToken), address(0), 1 ether);
    }

    // ============================================
    // BUDGET CAP ENFORCEMENT TESTS
    // ============================================

    function test_withdrawETH_revert_exceedsCap() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 10 ether);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITAGITOperationalTreasury.WithdrawalExceedsCap.selector, CAT_OPERATIONS, 15 ether, 10 ether
            )
        );
        treasury.withdrawETH(CAT_OPERATIONS, alice, 15 ether);
    }

    function test_withdrawETH_revert_exceedsCap_cumulative() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 20 ether);

        vm.startPrank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 15 ether);

        // Second withdrawal exceeds remaining cap (20 - 15 = 5 remaining)
        vm.expectRevert(
            abi.encodeWithSelector(
                ITAGITOperationalTreasury.WithdrawalExceedsCap.selector, CAT_OPERATIONS, 10 ether, 5 ether
            )
        );
        treasury.withdrawETH(CAT_OPERATIONS, alice, 10 ether);
        vm.stopPrank();
    }

    function test_withdrawETH_revert_categoryNotActive() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(treasurer);
        treasury.deactivateCategory(CAT_OPERATIONS);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ITAGITOperationalTreasury.CategoryNotActive.selector, CAT_OPERATIONS));
        treasury.withdrawETH(CAT_OPERATIONS, alice, 1 ether);
    }

    function test_withdrawETH_revert_categoryNotFound() public {
        _fundTreasuryETH(100 ether);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ITAGITOperationalTreasury.CategoryNotFound.selector, CAT_OPERATIONS));
        treasury.withdrawETH(CAT_OPERATIONS, alice, 1 ether);
    }

    function test_capResetAfterPeriod() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 20 ether);

        // Spend full cap
        vm.prank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 20 ether);

        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 0);

        // Cannot spend more
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITOperationalTreasury.WithdrawalExceedsCap.selector, CAT_OPERATIONS, 1 ether, 0)
        );
        treasury.withdrawETH(CAT_OPERATIONS, alice, 1 ether);

        // Advance past period (30 days)
        vm.warp(block.timestamp + 30 days + 1);

        // Cap should be fully available again
        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 20 ether);

        // Can spend again
        vm.prank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 15 ether);

        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 5 ether);
    }

    function test_cumulativeSpendTracked() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.startPrank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 10 ether);
        treasury.withdrawETH(CAT_OPERATIONS, bob, 5 ether);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 20 ether);
        vm.stopPrank();

        ITAGITOperationalTreasury.BudgetCap memory bc = treasury.getBudgetCap(CAT_OPERATIONS);
        assertEq(bc.spent, 35 ether);
        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 15 ether);
    }

    function test_multipleCategoriesIndependent() public {
        _fundTreasuryETH(100 ether);

        vm.startPrank(treasurer);
        treasury.setBudgetCap(CAT_OPERATIONS, 30 ether);
        treasury.setBudgetCap(CAT_MARKETING, 20 ether);
        vm.stopPrank();

        vm.startPrank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 25 ether);
        treasury.withdrawETH(CAT_MARKETING, bob, 15 ether);
        vm.stopPrank();

        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 5 ether);
        assertEq(treasury.remainingBudget(CAT_MARKETING), 5 ether);
    }

    // ============================================
    // ACCESS CONTROL TESTS
    // ============================================

    function test_withdrawETH_revert_unauthorized() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, OPERATOR_ROLE
            )
        );
        treasury.withdrawETH(CAT_OPERATIONS, alice, 1 ether);
    }

    function test_withdrawERC20_revert_unauthorized() public {
        _fundTreasuryERC20(10_000e18);
        _setCapAndActivate(CAT_OPERATIONS, 5_000e18);

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, OPERATOR_ROLE
            )
        );
        treasury.withdrawERC20(CAT_OPERATIONS, address(mockToken), alice, 1_000e18);
    }

    function test_pause_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, ADMIN_ROLE)
        );
        treasury.pause();
    }

    function test_unpause_revert_unauthorized() public {
        vm.prank(admin);
        treasury.pause();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, ADMIN_ROLE)
        );
        treasury.unpause();
    }

    function test_emergencySweep_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, ADMIN_ROLE)
        );
        treasury.emergencySweep(address(0), alice);
    }

    function test_setPeriodDuration_revert_unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, ADMIN_ROLE)
        );
        treasury.setPeriodDuration(7 days);
    }

    function test_roleGrantRevoke() public {
        address newOperator = makeAddr("newOperator");

        // Admin grants OPERATOR_ROLE
        vm.prank(admin);
        treasury.grantRole(OPERATOR_ROLE, newOperator);
        assertTrue(treasury.hasRole(OPERATOR_ROLE, newOperator));

        // Admin revokes OPERATOR_ROLE
        vm.prank(admin);
        treasury.revokeRole(OPERATOR_ROLE, newOperator);
        assertFalse(treasury.hasRole(OPERATOR_ROLE, newOperator));
    }

    function test_treasurerCannotWithdraw() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(treasurer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, treasurer, OPERATOR_ROLE)
        );
        treasury.withdrawETH(CAT_OPERATIONS, alice, 1 ether);
    }

    function test_operatorCannotSetCap() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, TREASURER_ROLE)
        );
        treasury.setBudgetCap(CAT_OPERATIONS, 100 ether);
    }

    function test_operatorCannotPause() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, ADMIN_ROLE)
        );
        treasury.pause();
    }

    // ============================================
    // PAUSE TESTS
    // ============================================

    function test_withdrawBlocked_whenPaused() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(admin);
        treasury.pause();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("EnforcedPause()"))));
        treasury.withdrawETH(CAT_OPERATIONS, alice, 1 ether);
    }

    function test_withdrawResumes_afterUnpause() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(admin);
        treasury.pause();

        vm.prank(admin);
        treasury.unpause();

        vm.prank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 1 ether);
        assertEq(alice.balance, 1 ether);
    }

    // ============================================
    // ADMIN FUNCTION TESTS
    // ============================================

    function test_setPeriodDuration() public {
        vm.prank(admin);

        vm.expectEmit(false, false, false, true);
        emit PeriodDurationUpdated(30 days, 7 days);

        treasury.setPeriodDuration(7 days);
        assertEq(treasury.periodDuration(), 7 days);
    }

    function test_setPeriodDuration_revert_tooShort() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITOperationalTreasury.InvalidPeriodDuration.selector, uint48(1 hours))
        );
        treasury.setPeriodDuration(1 hours);
    }

    function test_setPeriodDuration_revert_tooLong() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ITAGITOperationalTreasury.InvalidPeriodDuration.selector, uint48(400 days))
        );
        treasury.setPeriodDuration(400 days);
    }

    function test_emergencySweep_ETH() public {
        _fundTreasuryETH(50 ether);

        vm.prank(admin);

        vm.expectEmit(true, true, false, true);
        emit EmergencySweep(address(0), alice, 50 ether);

        treasury.emergencySweep(address(0), alice);

        assertEq(alice.balance, 50 ether);
        assertEq(address(treasury).balance, 0);
    }

    function test_emergencySweep_ERC20() public {
        _fundTreasuryERC20(5_000e18);

        vm.prank(admin);

        vm.expectEmit(true, true, false, true);
        emit EmergencySweep(address(mockToken), alice, 5_000e18);

        treasury.emergencySweep(address(mockToken), alice);

        assertEq(mockToken.balanceOf(alice), 5_000e18);
        assertEq(mockToken.balanceOf(address(treasury)), 0);
    }

    function test_emergencySweep_revert_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ITAGITOperationalTreasury.ZeroAddress.selector);
        treasury.emergencySweep(address(0), address(0));
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_remainingBudget_inactiveCategoryReturnsZero() public view {
        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 0);
    }

    function test_getBudgetCap_afterPeriodElapsed() public {
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);
        _fundTreasuryETH(100 ether);

        // Spend some
        vm.prank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, 30 ether);

        // Advance past period
        vm.warp(block.timestamp + 30 days + 1);

        // View should show reset state
        ITAGITOperationalTreasury.BudgetCap memory bc = treasury.getBudgetCap(CAT_OPERATIONS);
        assertEq(bc.spent, 0);
        assertEq(treasury.remainingBudget(CAT_OPERATIONS), 50 ether);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_depositETH(uint256 amount) public {
        amount = bound(amount, 1, 1000 ether);

        vm.deal(operator, amount);
        vm.prank(operator);
        treasury.depositETH{value: amount}();

        assertEq(address(treasury).balance, amount);
    }

    function testFuzz_withdrawWithinCap(uint256 cap, uint256 withdrawal) public {
        cap = bound(cap, 1 ether, 500 ether);
        withdrawal = bound(withdrawal, 1, cap);

        _fundTreasuryETH(cap);
        _setCapAndActivate(CAT_OPERATIONS, cap);

        vm.prank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, withdrawal);

        assertEq(alice.balance, withdrawal);
        assertEq(treasury.remainingBudget(CAT_OPERATIONS), cap - withdrawal);
    }

    function testFuzz_withdrawExceedsCap(uint256 cap, uint256 excess) public {
        cap = bound(cap, 1 ether, 100 ether);
        excess = bound(excess, 1, 100 ether);
        uint256 withdrawal = cap + excess;

        _fundTreasuryETH(withdrawal);
        _setCapAndActivate(CAT_OPERATIONS, cap);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITAGITOperationalTreasury.WithdrawalExceedsCap.selector, CAT_OPERATIONS, withdrawal, cap
            )
        );
        treasury.withdrawETH(CAT_OPERATIONS, alice, withdrawal);
    }

    function testFuzz_periodResetRestoresCap(uint256 cap, uint256 spend1, uint256 spend2) public {
        cap = bound(cap, 2 ether, 100 ether);
        spend1 = bound(spend1, 1, cap);
        spend2 = bound(spend2, 1, cap);

        _fundTreasuryETH(cap * 2);
        _setCapAndActivate(CAT_OPERATIONS, cap);

        // Spend in period 1
        vm.prank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, alice, spend1);

        // Advance past period
        vm.warp(block.timestamp + 30 days + 1);

        // Spend in period 2 should work (cap reset)
        vm.prank(operator);
        treasury.withdrawETH(CAT_OPERATIONS, bob, spend2);

        assertEq(bob.balance, spend2);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_depositETH() public {
        vm.deal(operator, 10 ether);
        vm.prank(operator);

        uint256 gasBefore = gasleft();
        treasury.depositETH{value: 1 ether}();
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 80_000, "depositETH() gas too high");
    }

    function test_gas_withdrawETH() public {
        _fundTreasuryETH(100 ether);
        _setCapAndActivate(CAT_OPERATIONS, 50 ether);

        vm.prank(operator);

        uint256 gasBefore = gasleft();
        treasury.withdrawETH(CAT_OPERATIONS, alice, 1 ether);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 100_000, "withdrawETH() gas too high");
    }

    function test_gas_setBudgetCap() public {
        vm.prank(treasurer);

        uint256 gasBefore = gasleft();
        treasury.setBudgetCap(CAT_OPERATIONS, 100 ether);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 120_000, "setBudgetCap() gas too high");
    }

    // ============================================
    // HELPERS
    // ============================================

    function _fundTreasuryETH(uint256 amount) internal {
        vm.deal(address(treasury), amount);
    }

    function _fundTreasuryERC20(uint256 amount) internal {
        vm.startPrank(operator);
        mockToken.approve(address(treasury), amount);
        treasury.depositERC20(address(mockToken), amount);
        vm.stopPrank();
    }

    function _setCapAndActivate(bytes32 category, uint256 cap) internal {
        vm.prank(treasurer);
        treasury.setBudgetCap(category, cap);
    }

    function _setupAndSpendETH(bytes32 category, uint256 amount) internal {
        vm.prank(operator);
        treasury.withdrawETH(category, alice, amount);
    }
}
