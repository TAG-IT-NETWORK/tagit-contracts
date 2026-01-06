// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ForkBase} from "./ForkBase.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TAGITAccount} from "../../src/account/TAGITAccount.sol";
import {TAGITAccountFactory} from "../../src/account/TAGITAccountFactory.sol";
import {ITAGITAccount} from "../../src/interfaces/ITAGITAccount.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title EntryPointForkTest
 * @notice Fork tests for ERC-4337 integration on OP Mainnet
 * @dev Verifies TAGITAccount works correctly with canonical EntryPoint v0.7
 */
contract EntryPointForkTest is ForkBase {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============================================
    // STATE
    // ============================================

    TAGITAccount public accountImpl;
    TAGITAccountFactory public factory;
    IEntryPoint public entryPoint;

    address public mockCore;
    address public protocolGuardian;

    uint256 public userPrivateKey;
    address public userAddress;

    // ============================================
    // SETUP
    // ============================================

    function setUp() public override {
        super.setUp();

        // Cast EntryPoint
        entryPoint = IEntryPoint(ENTRYPOINT_V07);

        // Create mock addresses
        mockCore = makeAddr("mockCore");
        protocolGuardian = makeAddr("protocolGuardian");

        // Create user with known private key for signing
        userPrivateKey = 0xA11CE;
        userAddress = vm.addr(userPrivateKey);
        vm.deal(userAddress, 10 ether);

        // Deploy account implementation (with real EntryPoint)
        vm.startPrank(deployer);
        accountImpl = new TAGITAccount(ENTRYPOINT_V07);

        // Deploy factory
        TAGITAccountFactory factoryImpl = new TAGITAccountFactory();
        bytes memory initData = abi.encodeWithSelector(
            TAGITAccountFactory.initialize.selector,
            ENTRYPOINT_V07,
            address(accountImpl),
            protocolGuardian,
            mockCore,
            governor,
            deployer
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = TAGITAccountFactory(address(proxy));
        vm.stopPrank();
    }

    // ============================================
    // ENTRYPOINT VERIFICATION
    // ============================================

    /**
     * @notice Verify EntryPoint v0.7 is deployed on OP Mainnet
     */
    function test_entryPointIsLive() public view {
        assertTrue(_hasCode(ENTRYPOINT_V07), "EntryPoint should have code");
        assertEq(address(entryPoint), ENTRYPOINT_V07, "Should use correct EntryPoint");
    }

    /**
     * @notice Verify EntryPoint supports expected functionality
     */
    function test_entryPointFunctions() public view {
        // Should be able to get nonce for any address
        uint256 nonce = entryPoint.getNonce(user1, 0);
        assertEq(nonce, 0, "Nonce should be 0 for unused account");
    }

    /**
     * @notice Verify EntryPoint deposit info
     */
    function test_entryPointDepositInfo() public view {
        IEntryPoint.DepositInfo memory depositInfo = entryPoint.getDepositInfo(user1);
        assertEq(depositInfo.deposit, 0, "Deposit should be 0 for new account");
        assertEq(depositInfo.stake, 0, "Stake should be 0");
    }

    // ============================================
    // FACTORY TESTS
    // ============================================

    /**
     * @notice Factory initializes correctly with real EntryPoint
     */
    function test_factoryInitialization() public view {
        assertEq(factory.entryPoint(), ENTRYPOINT_V07, "EntryPoint set correctly");
        assertEq(factory.accountImplementation(), address(accountImpl), "Account impl set correctly");
        assertEq(factory.protocolGuardian(), protocolGuardian, "Protocol guardian set correctly");
        assertEq(factory.tagitCore(), mockCore, "Core set correctly");
        assertEq(factory.totalAccounts(), 0, "No accounts initially");
    }

    /**
     * @notice Cannot reinitialize factory
     */
    function test_factoryCannotReinitialize() public {
        vm.expectRevert();
        factory.initialize(
            ENTRYPOINT_V07,
            address(accountImpl),
            protocolGuardian,
            mockCore,
            governor,
            deployer
        );
    }

    // ============================================
    // ACCOUNT CREATION
    // ============================================

    /**
     * @notice Create account with real EntryPoint
     */
    function test_createAccount() public {
        bytes32 emailHash = keccak256("user@test.com");
        uint256 salt = 12345;

        address predictedAddress = factory.getAddress(emailHash, salt);

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        assertEq(account, predictedAddress, "Account deployed at predicted address");
        assertTrue(factory.isAccount(account), "Account registered in factory");
        assertEq(factory.totalAccounts(), 1, "Account count incremented");

        // Verify account configuration
        TAGITAccount createdAccount = TAGITAccount(payable(account));
        assertEq(createdAccount.owner(), userAddress, "Owner set correctly");
        assertEq(createdAccount.emailHash(), emailHash, "Email hash set correctly");
        assertEq(createdAccount.entryPoint(), ENTRYPOINT_V07, "Uses correct EntryPoint");
        assertEq(createdAccount.factory(), address(factory), "Factory set correctly");
    }

    /**
     * @notice Idempotent account creation
     */
    function test_idempotentAccountCreation() public {
        bytes32 emailHash = keccak256("idempotent@test.com");
        uint256 salt = 999;

        vm.prank(userAddress);
        address account1 = factory.createAccount(emailHash, salt);

        vm.prank(user1);
        address account2 = factory.createAccount(emailHash, salt);

        assertEq(account1, account2, "Should return same address");
        assertEq(factory.totalAccounts(), 1, "Should only count once");
    }

    /**
     * @notice Deterministic address calculation
     */
    function test_deterministicAddress() public {
        bytes32 emailHash = keccak256("deterministic@test.com");
        uint256 salt = 42;

        // Pre-calculate address
        address predicted = factory.getAddress(emailHash, salt);

        // Should have no code yet
        assertFalse(_hasCode(predicted), "Should not have code before deployment");

        // Create account
        vm.prank(userAddress);
        address actual = factory.createAccount(emailHash, salt);

        assertEq(actual, predicted, "Address matches prediction");
        assertTrue(_hasCode(predicted), "Should have code after deployment");
    }

    // ============================================
    // ACCOUNT FUNCTIONALITY
    // ============================================

    /**
     * @notice Account can receive ETH
     */
    function test_accountReceivesEth() public {
        bytes32 emailHash = keccak256("receiver@test.com");
        uint256 salt = 1;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        // Send ETH to account
        vm.deal(user1, 5 ether);
        vm.prank(user1);
        (bool success,) = account.call{value: 1 ether}("");
        assertTrue(success, "Should receive ETH");
        assertEq(account.balance, 1 ether, "Balance updated");
    }

    /**
     * @notice Account nonce from EntryPoint
     */
    function test_accountNonceFromEntryPoint() public {
        bytes32 emailHash = keccak256("nonce@test.com");
        uint256 salt = 2;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        TAGITAccount tagitAccount = TAGITAccount(payable(account));
        uint256 nonce = tagitAccount.getNonce();

        assertEq(nonce, 0, "Initial nonce should be 0");
        assertEq(nonce, entryPoint.getNonce(account, 0), "Should match EntryPoint nonce");
    }

    /**
     * @notice Direct execution by owner
     */
    function test_directExecutionByOwner() public {
        bytes32 emailHash = keccak256("executor@test.com");
        uint256 salt = 3;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        // Fund the account
        vm.deal(account, 1 ether);

        // Owner executes transfer
        TAGITAccount tagitAccount = TAGITAccount(payable(account));
        uint256 balanceBefore = user2.balance;

        vm.prank(userAddress);
        tagitAccount.execute(user2, 0.5 ether, "");

        assertEq(user2.balance, balanceBefore + 0.5 ether, "ETH transferred");
    }

    /**
     * @notice Non-owner cannot execute
     */
    function test_nonOwnerCannotExecute() public {
        bytes32 emailHash = keccak256("locked@test.com");
        uint256 salt = 4;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        vm.deal(account, 1 ether);

        TAGITAccount tagitAccount = TAGITAccount(payable(account));

        vm.prank(user1);
        vm.expectRevert();
        tagitAccount.execute(user2, 0.5 ether, "");
    }

    // ============================================
    // SESSION KEY TESTS
    // ============================================

    /**
     * @notice Owner can add session key
     */
    function test_addSessionKey() public {
        bytes32 emailHash = keccak256("session@test.com");
        uint256 salt = 5;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        TAGITAccount tagitAccount = TAGITAccount(payable(account));

        // Create session key
        address sessionKeyAddr = makeAddr("sessionKey");
        bytes4[] memory allowedSelectors = new bytes4[](1);
        allowedSelectors[0] = TAGITAccount.execute.selector;

        ITAGITAccount.SessionKey memory sessionKey = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: allowedSelectors,
            spendLimit: 1 ether
        });

        vm.prank(userAddress);
        tagitAccount.addSessionKey(sessionKey);

        assertTrue(
            tagitAccount.isValidSessionKey(sessionKeyAddr, TAGITAccount.execute.selector),
            "Session key should be valid"
        );
    }

    /**
     * @notice Session key validity check
     */
    function test_sessionKeyValidity() public {
        bytes32 emailHash = keccak256("validity@test.com");
        uint256 salt = 6;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        TAGITAccount tagitAccount = TAGITAccount(payable(account));

        address sessionKeyAddr = makeAddr("expiring");
        bytes4[] memory allowedSelectors = new bytes4[](1);
        allowedSelectors[0] = TAGITAccount.execute.selector;

        ITAGITAccount.SessionKey memory sessionKey = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: allowedSelectors,
            spendLimit: 1 ether
        });

        vm.prank(userAddress);
        tagitAccount.addSessionKey(sessionKey);

        // Valid now
        assertTrue(tagitAccount.isValidSessionKey(sessionKeyAddr, TAGITAccount.execute.selector), "Valid now");

        // Invalid selector
        assertFalse(tagitAccount.isValidSessionKey(sessionKeyAddr, bytes4(0xdeadbeef)), "Invalid selector");

        // Expired
        vm.warp(block.timestamp + 2 hours);
        assertFalse(tagitAccount.isValidSessionKey(sessionKeyAddr, TAGITAccount.execute.selector), "Expired");
    }

    // ============================================
    // GUARDIAN TESTS
    // ============================================

    /**
     * @notice Protocol guardian is set by default
     */
    function test_protocolGuardianDefault() public {
        bytes32 emailHash = keccak256("guardian@test.com");
        uint256 salt = 7;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        TAGITAccount tagitAccount = TAGITAccount(payable(account));
        ITAGITAccount.GuardianConfig memory config = tagitAccount.getGuardianConfig();

        assertTrue(config.protocolGuardian, "Protocol guardian should be enabled");
        assertEq(config.threshold, 1, "Threshold should be 1");
        assertEq(config.guardians.length, 1, "Should have one guardian");
        assertEq(config.guardians[0], protocolGuardian, "Guardian should be protocol guardian");
    }

    /**
     * @notice Owner can add additional guardians
     */
    function test_addGuardian() public {
        bytes32 emailHash = keccak256("addguardian@test.com");
        uint256 salt = 8;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        TAGITAccount tagitAccount = TAGITAccount(payable(account));
        address newGuardian = makeAddr("newGuardian");

        vm.prank(userAddress);
        tagitAccount.addGuardian(newGuardian, 2);

        ITAGITAccount.GuardianConfig memory config = tagitAccount.getGuardianConfig();
        assertEq(config.guardians.length, 2, "Should have two guardians");
        assertEq(config.threshold, 2, "Threshold updated");
    }

    // ============================================
    // DEPOSIT TESTS
    // ============================================

    /**
     * @notice Deposit to EntryPoint for account
     */
    function test_depositToEntryPoint() public {
        bytes32 emailHash = keccak256("deposit@test.com");
        uint256 salt = 9;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        // Deposit for account
        vm.deal(deployer, 5 ether);
        vm.prank(deployer);
        entryPoint.depositTo{value: 1 ether}(account);

        IEntryPoint.DepositInfo memory info = entryPoint.getDepositInfo(account);
        assertEq(info.deposit, 1 ether, "Deposit recorded");
    }

    // ============================================
    // VERSION TESTS
    // ============================================

    /**
     * @notice Check contract versions
     */
    function test_versions() public {
        bytes32 emailHash = keccak256("version@test.com");
        uint256 salt = 10;

        vm.prank(userAddress);
        address account = factory.createAccount(emailHash, salt);

        TAGITAccount tagitAccount = TAGITAccount(payable(account));

        assertEq(factory.version(), "1.0.0", "Factory version");
        assertEq(tagitAccount.version(), "1.0.0", "Account version");
    }
}
