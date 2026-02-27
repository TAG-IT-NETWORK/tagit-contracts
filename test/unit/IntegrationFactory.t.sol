// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IntegrationFactory} from "../../src/agent/IntegrationFactory.sol";
import {IIntegrationFactory} from "../../src/interfaces/IIntegrationFactory.sol";
import {ITAGITBurner} from "../../src/interfaces/ITAGITBurner.sol";
import {BASIS_POINTS} from "../../src/libraries/Constants.sol";

// ============================================
// MOCK CONTRACTS
// ============================================

/// @notice Minimal ERC-20 mock for testing
contract MockToken is ERC20 {
    constructor() ERC20("Mock TAGIT", "MTAGIT") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock TAGITBurner that accepts tokens via routeFee
contract MockBurner is ITAGITBurner {
    IERC20 public paymentToken;
    uint256 public lastRoutedAmount;
    uint256 public routeFeeCallCount;

    function setPaymentToken(address token_) external {
        paymentToken = IERC20(token_);
    }

    function routeFee(uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        paymentToken.transferFrom(msg.sender, address(this), amount);
        lastRoutedAmount = amount;
        routeFeeCallCount++;
    }

    // View stubs
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
    function setBurnRate(uint256) external pure override {}
    function setTreasury(address) external pure override {}
}

/**
 * @title IntegrationFactory Unit Tests
 * @notice Comprehensive tests for partner onboarding and payment routing
 */
contract IntegrationFactoryTest is Test {
    IntegrationFactory public factory;
    MockToken public token;
    MockBurner public burner;

    address public owner;
    address public partner;
    address public payer;
    address public signer1;
    address public signer2;
    address public signer3;
    uint256 public signer1Key;
    uint256 public signer2Key;
    uint256 public signer3Key;

    // Events (redeclared for vm.expectEmit)
    event IntegrationDeployed(
        uint256 indexed integrationId,
        uint256 indexed agentId,
        address partnerWallet,
        address paymentToken,
        uint256 feeRate
    );
    event PaymentProcessed(
        uint256 indexed integrationId, address indexed payer_, uint256 amount, uint256 protocolFee, uint256 toPartner
    );
    event IntegrationDeactivationRequested(uint256 indexed integrationId, uint256 gracePeriodEnds);
    event IntegrationDeactivated(uint256 indexed integrationId, uint256 indexed agentId);
    event IntegrationReactivated(uint256 indexed integrationId);
    event MaxPaymentUpdated(uint256 oldMax, uint256 newMax);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);

    function setUp() public {
        owner = makeAddr("owner");
        partner = makeAddr("partner");
        payer = makeAddr("payer");

        // Create signers with known private keys
        (signer1, signer1Key) = makeAddrAndKey("signer1");
        (signer2, signer2Key) = makeAddrAndKey("signer2");
        (signer3, signer3Key) = makeAddrAndKey("signer3");

        // Deploy mock token
        token = new MockToken();

        // Deploy mock burner
        burner = new MockBurner();
        burner.setPaymentToken(address(token));

        // Deploy factory
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        factory = new IntegrationFactory(
            address(burner),
            owner,
            signers,
            2 // 2-of-3 multi-sig
        );

        // Fund payer with tokens
        token.mint(payer, 100_000 ether);

        // Grant payer as authorized integrator (required by onlyAuthorizedIntegrator modifier)
        vm.prank(owner);
        factory.grantIntegrator(payer);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _deployDefaultIntegration() internal returns (uint256) {
        vm.prank(owner);
        return factory.deployIntegration(
            1, // agentId
            partner,
            500, // 5% fee
            address(token)
        );
    }

    function _signMessage(bytes32 messageHash, uint256 privateKey) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _getMultiSigSignatures(bytes32 messageHash) internal view returns (bytes[] memory) {
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signMessage(messageHash, signer1Key);
        sigs[1] = _signMessage(messageHash, signer2Key);
        return sigs;
    }

    // ============================================
    // CONSTRUCTOR TESTS
    // ============================================

    function test_constructor_setsOwner() public view {
        assertEq(factory.owner(), owner);
    }

    function test_constructor_setsBurner() public view {
        assertEq(address(factory.burner()), address(burner));
    }

    function test_constructor_setsSigners() public view {
        address[] memory signers = factory.getSigners();
        assertEq(signers.length, 3);
        assertEq(signers[0], signer1);
        assertEq(signers[1], signer2);
        assertEq(signers[2], signer3);
    }

    function test_constructor_setsRequiredSignatures() public view {
        assertEq(factory.requiredSignatures(), 2);
    }

    function test_constructor_setsDefaultMaxPayment() public view {
        assertEq(factory.maxPaymentPerTx(), 1000 * 1e18);
    }

    function test_constructor_startsWithZeroIntegrations() public view {
        assertEq(factory.totalIntegrations(), 0);
        assertEq(factory.activeIntegrations(), 0);
    }

    function test_constructor_revert_zeroBurner() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.expectRevert(IIntegrationFactory.ZeroAddress.selector);
        new IntegrationFactory(address(0), owner, signers, 2);
    }

    function test_constructor_revert_zeroOwner() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        // OZ Ownable reverts with OwnableInvalidOwner before our ZeroAddress check
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new IntegrationFactory(address(burner), address(0), signers, 2);
    }

    function test_constructor_revert_tooFewSigners() public {
        address[] memory signers = new address[](2);
        signers[0] = signer1;
        signers[1] = signer2;

        vm.expectRevert(IIntegrationFactory.MinimumSignersRequired.selector);
        new IntegrationFactory(address(burner), owner, signers, 2);
    }

    function test_constructor_revert_zeroRequiredSigs() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.InsufficientSignatures.selector, 0, 3));
        new IntegrationFactory(address(burner), owner, signers, 0);
    }

    function test_constructor_revert_requiredSigsExceedsSigners() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.InsufficientSignatures.selector, 4, 3));
        new IntegrationFactory(address(burner), owner, signers, 4);
    }

    function test_constructor_revert_duplicateSigner() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer1; // duplicate
        signers[2] = signer3;

        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.DuplicateSigner.selector, signer1));
        new IntegrationFactory(address(burner), owner, signers, 2);
    }

    function test_constructor_revert_zeroSigner() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = address(0);
        signers[2] = signer3;

        vm.expectRevert(IIntegrationFactory.ZeroAddress.selector);
        new IntegrationFactory(address(burner), owner, signers, 2);
    }

    // ============================================
    // DEPLOY INTEGRATION TESTS
    // ============================================

    function test_deployIntegration_success() public {
        uint256 integrationId = _deployDefaultIntegration();
        assertEq(integrationId, 1);
    }

    function test_deployIntegration_incrementsId() public {
        _deployDefaultIntegration();

        vm.prank(owner);
        uint256 id2 = factory.deployIntegration(2, partner, 500, address(token));
        assertEq(id2, 2);
    }

    function test_deployIntegration_setsConfig() public {
        uint256 integrationId = _deployDefaultIntegration();

        IIntegrationFactory.Integration memory integration = factory.getIntegration(integrationId);
        assertEq(integration.agentId, 1);
        assertEq(integration.partnerWallet, partner);
        assertEq(integration.paymentToken, address(token));
        assertEq(integration.feeRate, 500);
        assertEq(integration.deployedAt, uint64(block.timestamp));
        assertEq(integration.deactivateRequestedAt, 0);
        assertTrue(integration.active);
    }

    function test_deployIntegration_mapsAgentToIntegration() public {
        uint256 integrationId = _deployDefaultIntegration();
        assertEq(factory.getIntegrationByAgent(1), integrationId);
    }

    function test_deployIntegration_incrementsActiveCount() public {
        _deployDefaultIntegration();
        assertEq(factory.activeIntegrations(), 1);
        assertEq(factory.totalIntegrations(), 1);
    }

    function test_deployIntegration_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IntegrationDeployed(1, 1, partner, address(token), 500);
        factory.deployIntegration(1, partner, 500, address(token));
    }

    function test_deployIntegration_revert_notOwner() public {
        vm.prank(payer);
        vm.expectRevert();
        factory.deployIntegration(1, partner, 500, address(token));
    }

    function test_deployIntegration_revert_zeroAgentId() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.InvalidAgentId.selector, 0));
        factory.deployIntegration(0, partner, 500, address(token));
    }

    function test_deployIntegration_revert_zeroPartner() public {
        vm.prank(owner);
        vm.expectRevert(IIntegrationFactory.ZeroAddress.selector);
        factory.deployIntegration(1, address(0), 500, address(token));
    }

    function test_deployIntegration_revert_zeroPaymentToken() public {
        vm.prank(owner);
        vm.expectRevert(IIntegrationFactory.ZeroAddress.selector);
        factory.deployIntegration(1, partner, 500, address(0));
    }

    function test_deployIntegration_revert_feeRateExceedsBasisPoints() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.InvalidFeeRate.selector, uint96(BASIS_POINTS) + 1));
        factory.deployIntegration(1, partner, uint96(BASIS_POINTS) + 1, address(token));
    }

    function test_deployIntegration_feeRateAtMaxBasisPoints() public {
        vm.prank(owner);
        uint256 id = factory.deployIntegration(1, partner, uint96(BASIS_POINTS), address(token));
        IIntegrationFactory.Integration memory integration = factory.getIntegration(id);
        assertEq(integration.feeRate, uint96(BASIS_POINTS));
    }

    function test_deployIntegration_revert_duplicateAgent() public {
        _deployDefaultIntegration();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.AgentAlreadyIntegrated.selector, 1));
        factory.deployIntegration(1, partner, 500, address(token));
    }

    // ============================================
    // PROCESS PAYMENT TESTS
    // ============================================

    function test_processPayment_splitsCorrectly() public {
        uint256 integrationId = _deployDefaultIntegration();
        uint256 amount = 100 ether;
        uint256 expectedFee = (amount * 500) / BASIS_POINTS; // 5%
        uint256 expectedPartner = amount - expectedFee;

        // Approve factory
        vm.prank(payer);
        token.approve(address(factory), amount);

        uint256 partnerBefore = token.balanceOf(partner);

        vm.prank(payer);
        factory.processPayment(integrationId, amount);

        // Partner receives their share
        assertEq(token.balanceOf(partner), partnerBefore + expectedPartner);
        // Burner received protocol fee
        assertEq(burner.lastRoutedAmount(), expectedFee);
    }

    function test_processPayment_emitsEvent() public {
        uint256 integrationId = _deployDefaultIntegration();
        uint256 amount = 100 ether;
        uint256 expectedFee = (amount * 500) / BASIS_POINTS;
        uint256 expectedPartner = amount - expectedFee;

        vm.prank(payer);
        token.approve(address(factory), amount);

        vm.prank(payer);
        vm.expectEmit(true, true, false, true);
        emit PaymentProcessed(integrationId, payer, amount, expectedFee, expectedPartner);
        factory.processPayment(integrationId, amount);
    }

    function test_processPayment_zeroFeeRate() public {
        // Deploy integration with 0% fee
        vm.prank(owner);
        uint256 integrationId = factory.deployIntegration(1, partner, 0, address(token));

        uint256 amount = 100 ether;

        vm.prank(payer);
        token.approve(address(factory), amount);

        uint256 partnerBefore = token.balanceOf(partner);

        vm.prank(payer);
        factory.processPayment(integrationId, amount);

        // Partner gets everything, no burner call
        assertEq(token.balanceOf(partner), partnerBefore + amount);
        assertEq(burner.routeFeeCallCount(), 0);
    }

    function test_processPayment_fullFeeRate() public {
        // Deploy integration with 100% fee
        vm.prank(owner);
        uint256 integrationId = factory.deployIntegration(1, partner, uint96(BASIS_POINTS), address(token));

        uint256 amount = 100 ether;

        vm.prank(payer);
        token.approve(address(factory), amount);

        uint256 partnerBefore = token.balanceOf(partner);

        vm.prank(payer);
        factory.processPayment(integrationId, amount);

        // Partner gets nothing, all goes to burner
        assertEq(token.balanceOf(partner), partnerBefore);
        assertEq(burner.lastRoutedAmount(), amount);
    }

    function test_processPayment_revert_zeroAmount() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(payer);
        vm.expectRevert(IIntegrationFactory.ZeroAmount.selector);
        factory.processPayment(integrationId, 0);
    }

    function test_processPayment_revert_exceedsCap() public {
        uint256 integrationId = _deployDefaultIntegration();
        uint256 maxPayment = factory.maxPaymentPerTx();
        uint256 overCap = maxPayment + 1;

        vm.prank(payer);
        token.approve(address(factory), overCap);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.PaymentExceedsCap.selector, overCap, maxPayment));
        factory.processPayment(integrationId, overCap);
    }

    function test_processPayment_atMaxCap() public {
        uint256 integrationId = _deployDefaultIntegration();
        uint256 atCap = factory.maxPaymentPerTx();

        token.mint(payer, atCap);

        vm.prank(payer);
        token.approve(address(factory), atCap);

        vm.prank(payer);
        factory.processPayment(integrationId, atCap);
        // Should not revert
    }

    function test_processPayment_revert_inactiveIntegration() public {
        uint256 integrationId = _deployDefaultIntegration();

        // Deactivate
        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        // Warp past grace period
        vm.warp(block.timestamp + 30 days + 1);
        factory.executeDeactivation(integrationId);

        vm.prank(payer);
        token.approve(address(factory), 100 ether);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.IntegrationNotActive.selector, integrationId));
        factory.processPayment(integrationId, 100 ether);
    }

    function test_processPayment_worksInGracePeriod() public {
        uint256 integrationId = _deployDefaultIntegration();

        // Request deactivation (starts grace period)
        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        // Payment should still work during grace period
        uint256 amount = 100 ether;
        vm.prank(payer);
        token.approve(address(factory), amount);

        vm.prank(payer);
        factory.processPayment(integrationId, amount);
        // Should not revert — integration.active is still true during grace period
    }

    // ============================================
    // DEACTIVATION TESTS
    // ============================================

    function test_deactivateIntegration_setsTimestamp() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        IIntegrationFactory.Integration memory integration = factory.getIntegration(integrationId);
        assertEq(integration.deactivateRequestedAt, uint64(block.timestamp));
        assertTrue(integration.active); // Still active during grace period
    }

    function test_deactivateIntegration_emitsEvent() public {
        uint256 integrationId = _deployDefaultIntegration();

        uint256 expectedGracePeriodEnd = block.timestamp + 30 days;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IntegrationDeactivationRequested(integrationId, expectedGracePeriodEnd);
        factory.deactivateIntegration(integrationId);
    }

    function test_deactivateIntegration_statusIsGracePeriod() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        assertEq(
            uint8(factory.getIntegrationStatus(integrationId)),
            uint8(IIntegrationFactory.IntegrationStatus.GRACE_PERIOD)
        );
    }

    function test_deactivateIntegration_revert_notOwner() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(payer);
        vm.expectRevert();
        factory.deactivateIntegration(integrationId);
    }

    function test_deactivateIntegration_revert_alreadyRequested() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.IntegrationInGracePeriod.selector, integrationId));
        factory.deactivateIntegration(integrationId);
    }

    // ============================================
    // EXECUTE DEACTIVATION TESTS
    // ============================================

    function test_executeDeactivation_afterGracePeriod() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        // Warp past grace period
        vm.warp(block.timestamp + 30 days + 1);

        factory.executeDeactivation(integrationId);

        IIntegrationFactory.Integration memory integration = factory.getIntegration(integrationId);
        assertFalse(integration.active);
    }

    function test_executeDeactivation_decrementsActiveCount() public {
        uint256 integrationId = _deployDefaultIntegration();
        assertEq(factory.activeIntegrations(), 1);

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        vm.warp(block.timestamp + 30 days + 1);
        factory.executeDeactivation(integrationId);

        assertEq(factory.activeIntegrations(), 0);
    }

    function test_executeDeactivation_emitsEvent() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        vm.warp(block.timestamp + 30 days + 1);

        vm.expectEmit(true, true, false, false);
        emit IntegrationDeactivated(integrationId, 1);
        factory.executeDeactivation(integrationId);
    }

    function test_executeDeactivation_statusIsDeactivated() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        vm.warp(block.timestamp + 30 days + 1);
        factory.executeDeactivation(integrationId);

        assertEq(
            uint8(factory.getIntegrationStatus(integrationId)), uint8(IIntegrationFactory.IntegrationStatus.DEACTIVATED)
        );
    }

    function test_executeDeactivation_revert_gracePeriodNotExpired() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        // Warp to just before grace period ends
        uint256 expiresAt = block.timestamp + 30 days;
        vm.warp(expiresAt - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IIntegrationFactory.GracePeriodNotExpired.selector, integrationId, expiresAt)
        );
        factory.executeDeactivation(integrationId);
    }

    function test_executeDeactivation_revert_noDeactivationRequested() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.IntegrationNotFound.selector, integrationId));
        factory.executeDeactivation(integrationId);
    }

    function test_executeDeactivation_callable_byAnyone() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        vm.warp(block.timestamp + 30 days + 1);

        // Anyone can execute after grace period
        vm.prank(payer);
        factory.executeDeactivation(integrationId);

        assertFalse(factory.isIntegrationActive(integrationId));
    }

    // ============================================
    // REACTIVATION TESTS (MULTI-SIG)
    // ============================================

    function test_reactivateIntegration_success() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REACTIVATE", integrationId, currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        factory.reactivateIntegration(integrationId, sigs);

        IIntegrationFactory.Integration memory integration = factory.getIntegration(integrationId);
        assertEq(integration.deactivateRequestedAt, 0);
        assertTrue(integration.active);
    }

    function test_reactivateIntegration_emitsEvent() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REACTIVATE", integrationId, currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        vm.expectEmit(true, false, false, false);
        emit IntegrationReactivated(integrationId);
        factory.reactivateIntegration(integrationId, sigs);
    }

    function test_reactivateIntegration_incrementsNonce() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        uint256 nonceBefore = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REACTIVATE", integrationId, nonceBefore));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        factory.reactivateIntegration(integrationId, sigs);

        assertEq(factory.nonce(), nonceBefore + 1);
    }

    function test_reactivateIntegration_revert_insufficientSignatures() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REACTIVATE", integrationId, currentNonce));

        // Only 1 signature (need 2)
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signMessage(messageHash, signer1Key);

        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.InsufficientSignatures.selector, 1, 2));
        factory.reactivateIntegration(integrationId, sigs);
    }

    function test_reactivateIntegration_revert_invalidSigner() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REACTIVATE", integrationId, currentNonce));

        (, uint256 randomKey) = makeAddrAndKey("random");

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signMessage(messageHash, signer1Key);
        sigs[1] = _signMessage(messageHash, randomKey);

        vm.expectRevert(); // InvalidSignature
        factory.reactivateIntegration(integrationId, sigs);
    }

    function test_reactivateIntegration_revert_duplicateSignature() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REACTIVATE", integrationId, currentNonce));

        // Same signer twice
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signMessage(messageHash, signer1Key);
        sigs[1] = _signMessage(messageHash, signer1Key);

        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.DuplicateSigner.selector, signer1));
        factory.reactivateIntegration(integrationId, sigs);
    }

    function test_reactivateIntegration_revert_replayAttack() public {
        uint256 integrationId = _deployDefaultIntegration();

        // First deactivation + reactivation
        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        uint256 nonce0 = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REACTIVATE", integrationId, nonce0));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);
        factory.reactivateIntegration(integrationId, sigs);

        // Second deactivation — try to replay old signatures
        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        // Old sigs used nonce 0, but nonce is now 1
        vm.expectRevert(); // InvalidSignature — wrong nonce
        factory.reactivateIntegration(integrationId, sigs);
    }

    // ============================================
    // SET MAX PAYMENT TESTS (MULTI-SIG)
    // ============================================

    function test_setMaxPayment_success() public {
        uint256 newMax = 500 * 1e18;
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("SET_MAX_PAYMENT", newMax, currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        factory.setMaxPayment(newMax, sigs);

        assertEq(factory.maxPaymentPerTx(), newMax);
    }

    function test_setMaxPayment_emitsEvent() public {
        uint256 oldMax = factory.maxPaymentPerTx();
        uint256 newMax = 500 * 1e18;
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("SET_MAX_PAYMENT", newMax, currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        vm.expectEmit(false, false, false, true);
        emit MaxPaymentUpdated(oldMax, newMax);
        factory.setMaxPayment(newMax, sigs);
    }

    function test_setMaxPayment_revert_zeroMax() public {
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("SET_MAX_PAYMENT", uint256(0), currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        vm.expectRevert(IIntegrationFactory.ZeroAmount.selector);
        factory.setMaxPayment(0, sigs);
    }

    // ============================================
    // ADD / REMOVE SIGNER TESTS (MULTI-SIG)
    // ============================================

    function test_addSigner_success() public {
        address newSigner = makeAddr("newSigner");
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("ADD_SIGNER", newSigner, currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        vm.expectEmit(true, false, false, false);
        emit SignerAdded(newSigner);
        factory.addSigner(newSigner, sigs);

        address[] memory signers = factory.getSigners();
        assertEq(signers.length, 4);
        assertEq(signers[3], newSigner);
    }

    function test_addSigner_revert_zeroAddress() public {
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("ADD_SIGNER", address(0), currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        vm.expectRevert(IIntegrationFactory.ZeroAddress.selector);
        factory.addSigner(address(0), sigs);
    }

    function test_addSigner_revert_alreadyExists() public {
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("ADD_SIGNER", signer1, currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.SignerAlreadyExists.selector, signer1));
        factory.addSigner(signer1, sigs);
    }

    function test_removeSigner_success() public {
        // First add a 4th signer so we can remove one and stay above MIN_SIGNERS
        address newSigner = makeAddr("newSigner");
        uint256 nonce0 = factory.nonce();
        bytes32 addHash = keccak256(abi.encodePacked("ADD_SIGNER", newSigner, nonce0));
        factory.addSigner(newSigner, _getMultiSigSignatures(addHash));

        // Now remove signer3
        uint256 nonce1 = factory.nonce();
        bytes32 removeHash = keccak256(abi.encodePacked("REMOVE_SIGNER", signer3, nonce1));

        vm.expectEmit(true, false, false, false);
        emit SignerRemoved(signer3);
        factory.removeSigner(signer3, _getMultiSigSignatures(removeHash));

        address[] memory signers = factory.getSigners();
        assertEq(signers.length, 3);
    }

    function test_removeSigner_revert_belowMinimum() public {
        // Cannot remove signer when we have exactly MIN_SIGNERS (3)
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REMOVE_SIGNER", signer3, currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        vm.expectRevert(IIntegrationFactory.MinimumSignersRequired.selector);
        factory.removeSigner(signer3, sigs);
    }

    function test_removeSigner_revert_notFound() public {
        address unknownSigner = makeAddr("unknown");
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REMOVE_SIGNER", unknownSigner, currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        vm.expectRevert(abi.encodeWithSelector(IIntegrationFactory.SignerNotFound.selector, unknownSigner));
        factory.removeSigner(unknownSigner, sigs);
    }

    // ============================================
    // EMERGENCY PAUSE / UNPAUSE TESTS
    // ============================================

    function test_emergencyPause_pausesContract() public {
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("EMERGENCY_PAUSE", currentNonce));
        bytes[] memory sigs = _getMultiSigSignatures(messageHash);

        factory.emergencyPause(sigs);

        assertTrue(factory.paused());
    }

    function test_emergencyPause_blocksPayment() public {
        uint256 integrationId = _deployDefaultIntegration();

        // Pause
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("EMERGENCY_PAUSE", currentNonce));
        factory.emergencyPause(_getMultiSigSignatures(messageHash));

        // Try payment
        vm.prank(payer);
        token.approve(address(factory), 100 ether);

        vm.prank(payer);
        vm.expectRevert(); // EnforcedPause
        factory.processPayment(integrationId, 100 ether);
    }

    function test_emergencyPause_blocksDeployment() public {
        // Pause
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("EMERGENCY_PAUSE", currentNonce));
        factory.emergencyPause(_getMultiSigSignatures(messageHash));

        vm.prank(owner);
        vm.expectRevert(); // EnforcedPause
        factory.deployIntegration(1, partner, 500, address(token));
    }

    function test_emergencyUnpause_resumesOperations() public {
        // Pause
        uint256 nonce0 = factory.nonce();
        bytes32 pauseHash = keccak256(abi.encodePacked("EMERGENCY_PAUSE", nonce0));
        factory.emergencyPause(_getMultiSigSignatures(pauseHash));
        assertTrue(factory.paused());

        // Unpause
        uint256 nonce1 = factory.nonce();
        bytes32 unpauseHash = keccak256(abi.encodePacked("EMERGENCY_UNPAUSE", nonce1));
        factory.emergencyUnpause(_getMultiSigSignatures(unpauseHash));
        assertFalse(factory.paused());

        // Operations should work again
        vm.prank(owner);
        factory.deployIntegration(1, partner, 500, address(token));
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_getIntegrationStatus_active() public {
        uint256 integrationId = _deployDefaultIntegration();
        assertEq(
            uint8(factory.getIntegrationStatus(integrationId)), uint8(IIntegrationFactory.IntegrationStatus.ACTIVE)
        );
    }

    function test_isIntegrationActive_true() public {
        uint256 integrationId = _deployDefaultIntegration();
        assertTrue(factory.isIntegrationActive(integrationId));
    }

    function test_isIntegrationActive_false() public {
        uint256 integrationId = _deployDefaultIntegration();

        vm.prank(owner);
        factory.deactivateIntegration(integrationId);
        vm.warp(block.timestamp + 30 days + 1);
        factory.executeDeactivation(integrationId);

        assertFalse(factory.isIntegrationActive(integrationId));
    }

    function test_version_returns100() public view {
        assertEq(factory.version(), "1.0.0");
    }

    function test_nonce_startsAtZero() public view {
        assertEq(factory.nonce(), 0);
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_processPayment_feeCalculation(uint256 amount, uint96 feeRate) public {
        // Bound inputs
        amount = bound(amount, 1, factory.maxPaymentPerTx());
        feeRate = uint96(bound(uint256(feeRate), 0, BASIS_POINTS));

        // Deploy integration with fuzzed fee rate
        vm.prank(owner);
        uint256 integrationId = factory.deployIntegration(1, partner, feeRate, address(token));

        // Fund and approve
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(factory), amount);

        uint256 partnerBefore = token.balanceOf(partner);

        vm.prank(payer);
        factory.processPayment(integrationId, amount);

        // Verify: protocolFee + partnerShare = amount
        uint256 expectedFee = (amount * uint256(feeRate)) / BASIS_POINTS;
        uint256 expectedPartner = amount - expectedFee;
        assertEq(token.balanceOf(partner), partnerBefore + expectedPartner);
    }

    function testFuzz_deployIntegration_uniqueIds(uint8 count) public {
        count = uint8(bound(uint256(count), 1, 20));

        for (uint256 i = 1; i <= count; i++) {
            vm.prank(owner);
            uint256 id = factory.deployIntegration(i, partner, 500, address(token));
            assertEq(id, i);
        }

        assertEq(factory.totalIntegrations(), count);
        assertEq(factory.activeIntegrations(), count);
    }

    // ============================================
    // INTEGRATION LIFECYCLE TEST
    // ============================================

    function test_fullLifecycle_deployProcessDeactivate() public {
        // Step 1: Deploy
        uint256 integrationId = _deployDefaultIntegration();
        assertEq(
            uint8(factory.getIntegrationStatus(integrationId)), uint8(IIntegrationFactory.IntegrationStatus.ACTIVE)
        );

        // Step 2: Process a payment
        uint256 amount = 100 ether;
        vm.prank(payer);
        token.approve(address(factory), amount);
        vm.prank(payer);
        factory.processPayment(integrationId, amount);

        // Step 3: Request deactivation
        vm.prank(owner);
        factory.deactivateIntegration(integrationId);
        assertEq(
            uint8(factory.getIntegrationStatus(integrationId)),
            uint8(IIntegrationFactory.IntegrationStatus.GRACE_PERIOD)
        );

        // Step 4: Reactivate during grace period
        uint256 currentNonce = factory.nonce();
        bytes32 messageHash = keccak256(abi.encodePacked("REACTIVATE", integrationId, currentNonce));
        factory.reactivateIntegration(integrationId, _getMultiSigSignatures(messageHash));
        assertEq(
            uint8(factory.getIntegrationStatus(integrationId)), uint8(IIntegrationFactory.IntegrationStatus.ACTIVE)
        );

        // Step 5: Deactivate again and let it expire
        vm.prank(owner);
        factory.deactivateIntegration(integrationId);

        vm.warp(block.timestamp + 30 days + 1);
        factory.executeDeactivation(integrationId);

        assertEq(
            uint8(factory.getIntegrationStatus(integrationId)), uint8(IIntegrationFactory.IntegrationStatus.DEACTIVATED)
        );
        assertEq(factory.activeIntegrations(), 0);
    }
}
