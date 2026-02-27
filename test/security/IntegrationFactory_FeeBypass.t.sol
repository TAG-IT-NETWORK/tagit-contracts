// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IntegrationFactory} from "../../src/agent/IntegrationFactory.sol";
import {IIntegrationFactory} from "../../src/interfaces/IIntegrationFactory.sol";
import {ITAGITBurner} from "../../src/interfaces/ITAGITBurner.sol";
import {BASIS_POINTS} from "../../src/libraries/Constants.sol";

// ============================================
// MOCKS
// ============================================

/// @notice Minimal ERC-20 mock with public mint
contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MTK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal TAGITBurner mock — pulls tokens from caller via transferFrom
contract MockBurner is ITAGITBurner {
    IERC20 public token;

    constructor(address _token) {
        token = IERC20(_token);
    }

    /// @dev IntegrationFactory calls forceApprove(burner, protocolFee) before this,
    ///      so we pull the tokens from msg.sender (the factory).
    function routeFee(uint256 amount) external override {
        token.transferFrom(msg.sender, address(this), amount);
    }

    // ---- Stubs (unused by this test suite) ----
    function setBurnRate(uint256) external override {}
    function setTreasury(address) external override {}

    function burnRate() external pure override returns (uint256) {
        return 3330;
    }

    function totalBurned() external pure override returns (uint256) {
        return 0;
    }

    function totalToTreasury() external pure override returns (uint256) {
        return 0;
    }

    function treasury() external pure override returns (address) {
        return address(0);
    }

    function governor() external pure override returns (address) {
        return address(0);
    }
}

// ============================================
// TEST CONTRACT
// ============================================

/**
 * @title IntegrationFactory_FeeBypassTest
 * @notice Security tests for the onlyAuthorizedIntegrator access control on processPayment.
 * @dev Validates that:
 *   - Unauthorized callers cannot bypass fee routing via processPayment
 *   - Owner can grant/revoke integrator roles
 *   - Access-control events fire correctly
 *   - Fee arithmetic holds under fuzz
 */
contract IntegrationFactory_FeeBypassTest is Test {
    // ============================================
    // STATE
    // ============================================

    IntegrationFactory public factory;
    MockERC20 public token;
    MockBurner public burner;

    address public owner;
    address public attacker;
    address public integrator;
    address public partnerWallet;

    address public signer1;
    address public signer2;
    address public signer3;

    uint256 public integrationId;

    uint96 public constant FEE_RATE = 500; // 5%
    uint256 public constant PAYMENT_AMOUNT = 100e18;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        owner = makeAddr("owner");
        attacker = makeAddr("attacker");
        integrator = makeAddr("integrator");
        partnerWallet = makeAddr("partnerWallet");
        signer1 = makeAddr("signer1");
        signer2 = makeAddr("signer2");
        signer3 = makeAddr("signer3");

        // Deploy mock token
        token = new MockERC20();

        // Deploy mock burner
        burner = new MockBurner(address(token));

        // Deploy IntegrationFactory with 3 signers, requiredSigs = 2
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.prank(owner);
        factory = new IntegrationFactory(
            address(burner),
            owner,
            signers,
            2 // requiredSigs
        );

        // Owner deploys an integration for agentId=1
        vm.prank(owner);
        integrationId = factory.deployIntegration(
            1, // agentId
            partnerWallet,
            FEE_RATE,
            address(token)
        );

        // Mint tokens to integrator so they can pay
        token.mint(integrator, 1_000_000e18);

        // Integrator approves factory to pull tokens
        vm.prank(integrator);
        token.approve(address(factory), type(uint256).max);
    }

    // ============================================
    // HELPER
    // ============================================

    /// @dev Grants integrator role and processes a payment; returns (protocolFee, partnerShare)
    function _grantAndPay(uint256 amount) internal returns (uint256 protocolFee, uint256 partnerShare) {
        vm.prank(owner);
        factory.grantIntegrator(integrator);

        vm.prank(integrator);
        factory.processPayment(integrationId, amount);

        protocolFee = (amount * uint256(FEE_RATE)) / BASIS_POINTS;
        partnerShare = amount - protocolFee;
    }

    // ============================================
    // TESTS: ACCESS CONTROL ON processPayment
    // ============================================

    /// @notice An address without the integrator role must be rejected
    function test_unauthorized_cannot_processPayment() public {
        // Mint tokens to attacker and approve
        token.mint(attacker, PAYMENT_AMOUNT);
        vm.prank(attacker);
        token.approve(address(factory), PAYMENT_AMOUNT);

        // Attempt processPayment without being authorized
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.NotAuthorizedIntegrator.selector, attacker));
        factory.processPayment(integrationId, PAYMENT_AMOUNT);
    }

    /// @notice A granted integrator can successfully process a payment
    function test_authorized_can_processPayment() public {
        // Grant integrator role
        vm.prank(owner);
        factory.grantIntegrator(integrator);

        uint256 partnerBalBefore = token.balanceOf(partnerWallet);
        uint256 burnerBalBefore = token.balanceOf(address(burner));

        // Process payment
        vm.prank(integrator);
        factory.processPayment(integrationId, PAYMENT_AMOUNT);

        uint256 expectedProtocolFee = (PAYMENT_AMOUNT * uint256(FEE_RATE)) / BASIS_POINTS;
        uint256 expectedPartnerShare = PAYMENT_AMOUNT - expectedProtocolFee;

        // Partner receives their share
        assertEq(token.balanceOf(partnerWallet) - partnerBalBefore, expectedPartnerShare, "partner share mismatch");

        // Burner receives protocol fee
        assertEq(token.balanceOf(address(burner)) - burnerBalBefore, expectedProtocolFee, "protocol fee mismatch");
    }

    // ============================================
    // TESTS: grantIntegrator / revokeIntegrator
    // ============================================

    /// @notice Owner can grant integrator role
    function test_owner_can_grant_integrator() public {
        assertFalse(factory.isAuthorizedIntegrator(integrator));

        vm.prank(owner);
        factory.grantIntegrator(integrator);

        assertTrue(factory.isAuthorizedIntegrator(integrator));
    }

    /// @notice Owner can revoke integrator role
    function test_owner_can_revoke_integrator() public {
        // Grant first
        vm.prank(owner);
        factory.grantIntegrator(integrator);
        assertTrue(factory.isAuthorizedIntegrator(integrator));

        // Revoke
        vm.prank(owner);
        factory.revokeIntegrator(integrator);

        assertFalse(factory.isAuthorizedIntegrator(integrator));
    }

    /// @notice Non-owner cannot call grantIntegrator
    function test_nonOwner_cannot_grant() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        factory.grantIntegrator(integrator);
    }

    /// @notice Non-owner cannot call revokeIntegrator
    function test_nonOwner_cannot_revoke() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        factory.revokeIntegrator(integrator);
    }

    // ============================================
    // TESTS: EVENTS
    // ============================================

    /// @notice grantIntegrator emits IntegratorAuthorized
    function test_grant_emits_event() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(factory));
        emit IIntegrationFactory.IntegratorAuthorized(integrator);
        factory.grantIntegrator(integrator);
    }

    /// @notice revokeIntegrator emits IntegratorRevoked
    function test_revoke_emits_event() public {
        // Grant first so there is something to revoke
        vm.prank(owner);
        factory.grantIntegrator(integrator);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(factory));
        emit IIntegrationFactory.IntegratorRevoked(integrator);
        factory.revokeIntegrator(integrator);
    }

    // ============================================
    // TESTS: FUZZ — fee arithmetic
    // ============================================

    /// @notice Fuzz payment amounts and verify fee split is correct
    function testFuzz_fee_amounts(uint256 amount) public {
        // Bound to valid payment range: [1, DEFAULT_MAX_PAYMENT]
        uint256 maxPayment = factory.maxPaymentPerTx();
        amount = bound(amount, 1, maxPayment);

        // Mint enough tokens and approve
        token.mint(integrator, amount);
        vm.prank(integrator);
        token.approve(address(factory), amount);

        // Grant integrator
        vm.prank(owner);
        factory.grantIntegrator(integrator);

        uint256 partnerBalBefore = token.balanceOf(partnerWallet);
        uint256 burnerBalBefore = token.balanceOf(address(burner));

        // Process payment
        vm.prank(integrator);
        factory.processPayment(integrationId, amount);

        uint256 expectedProtocolFee = (amount * uint256(FEE_RATE)) / BASIS_POINTS;
        uint256 expectedPartnerShare = amount - expectedProtocolFee;

        assertEq(
            token.balanceOf(partnerWallet) - partnerBalBefore, expectedPartnerShare, "fuzz: partner share mismatch"
        );

        assertEq(token.balanceOf(address(burner)) - burnerBalBefore, expectedProtocolFee, "fuzz: protocol fee mismatch");
    }

    // ============================================
    // TESTS: EDGE CASES
    // ============================================

    /// @notice After revocation a previously-authorized integrator is blocked
    function test_revoked_integrator_cannot_processPayment() public {
        // Grant → use → revoke → attempt again
        vm.prank(owner);
        factory.grantIntegrator(integrator);

        vm.prank(integrator);
        factory.processPayment(integrationId, PAYMENT_AMOUNT);

        vm.prank(owner);
        factory.revokeIntegrator(integrator);

        vm.prank(integrator);
        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.NotAuthorizedIntegrator.selector, integrator));
        factory.processPayment(integrationId, PAYMENT_AMOUNT);
    }
}
