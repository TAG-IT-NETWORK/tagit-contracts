// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TAGITAccount} from "../../src/account/TAGITAccount.sol";
import {TAGITAccountFactory} from "../../src/account/TAGITAccountFactory.sol";
import {ITAGITAccountFactory} from "../../src/interfaces/ITAGITAccountFactory.sol";

// Minimal mock EntryPoint for factory tests
contract MockEntryPointForFactory {
    mapping(address => uint256) public balances;

    function depositTo(address account) external payable {
        balances[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function getNonce(address, uint192) external pure returns (uint256) {
        return 0;
    }

    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function withdrawTo(address payable, uint256) external {}

    receive() external payable {}
}

// Minimal mock TAGITCore
contract MockTAGITCoreForFactory {
    function ownerOf(uint256) external pure returns (address) {
        return address(0);
    }
}

/**
 * @title TAGITAccountFactoryTest
 * @notice Comprehensive unit tests for TAGITAccountFactory contract
 * @dev Tests cover initialization, account creation, email verification,
 *      admin functions, access control, and deterministic addressing
 */
contract TAGITAccountFactoryTest is Test {
    TAGITAccountFactory public factory;
    TAGITAccount public accountImpl;
    MockEntryPointForFactory public entryPoint;
    MockTAGITCoreForFactory public tagitCore;

    address public factoryOwner;
    address public governor;
    address public protocolGuardian;
    address public emailVerifier;
    address public user1;
    address public user2;
    address public attacker;

    bytes32 public constant EMAIL_HASH_1 = keccak256("alice@example.com");
    bytes32 public constant EMAIL_HASH_2 = keccak256("bob@example.com");
    uint256 public constant SALT_1 = 1;
    uint256 public constant SALT_2 = 2;

    // Events (re-declared for expectEmit)
    event AccountCreated(address indexed account, bytes32 indexed emailHash, uint256 salt, address indexed owner);
    event ImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);
    event ProtocolGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);
    event EmailVerified(bytes32 indexed emailHash, address indexed verifier);
    event EmailVerifierUpdated(address indexed oldVerifier, address indexed newVerifier);

    function setUp() public {
        factoryOwner = makeAddr("factoryOwner");
        governor = makeAddr("governor");
        protocolGuardian = makeAddr("protocolGuardian");
        emailVerifier = makeAddr("emailVerifier");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        attacker = makeAddr("attacker");

        // Deploy mocks
        entryPoint = new MockEntryPointForFactory();
        tagitCore = new MockTAGITCoreForFactory();

        // Deploy account implementation
        accountImpl = new TAGITAccount(address(entryPoint));

        // Deploy factory behind UUPS proxy
        TAGITAccountFactory factoryImpl = new TAGITAccountFactory();
        bytes memory initData = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (address(entryPoint), address(accountImpl), protocolGuardian, address(tagitCore), governor, factoryOwner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = TAGITAccountFactory(address(proxy));
    }

    // ──────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────

    function test_initialize_setsStateCorrectly() public view {
        assertEq(factory.entryPoint(), address(entryPoint));
        assertEq(factory.accountImplementation(), address(accountImpl));
        assertEq(factory.protocolGuardian(), protocolGuardian);
        assertEq(factory.tagitCore(), address(tagitCore));
        assertEq(factory.governor(), governor);
        assertEq(factory.totalAccounts(), 0);
    }

    function test_initialize_setsOwner() public view {
        assertEq(factory.owner(), factoryOwner);
    }

    function test_initialize_revertsZeroEntryPoint() public {
        TAGITAccountFactory impl = new TAGITAccountFactory();
        bytes memory initData = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (address(0), address(accountImpl), protocolGuardian, address(tagitCore), governor, factoryOwner)
        );
        vm.expectRevert(ITAGITAccountFactory.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsZeroAccountImpl() public {
        TAGITAccountFactory impl = new TAGITAccountFactory();
        bytes memory initData = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (address(entryPoint), address(0), protocolGuardian, address(tagitCore), governor, factoryOwner)
        );
        vm.expectRevert(ITAGITAccountFactory.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsZeroGovernor() public {
        TAGITAccountFactory impl = new TAGITAccountFactory();
        bytes memory initData = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (address(entryPoint), address(accountImpl), protocolGuardian, address(tagitCore), address(0), factoryOwner)
        );
        vm.expectRevert(ITAGITAccountFactory.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_revertsZeroOwner() public {
        TAGITAccountFactory impl = new TAGITAccountFactory();
        bytes memory initData = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (address(entryPoint), address(accountImpl), protocolGuardian, address(tagitCore), governor, address(0))
        );
        vm.expectRevert(ITAGITAccountFactory.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        factory.initialize(
            address(entryPoint), address(accountImpl), protocolGuardian, address(tagitCore), governor, factoryOwner
        );
    }

    function test_version() public view {
        assertEq(factory.version(), "1.0.0");
    }

    // ──────────────────────────────────────────────
    // Email Verification (PATCH-15)
    // ──────────────────────────────────────────────

    function test_verifyEmail_byGovernor() public {
        vm.expectEmit(true, true, false, false);
        emit EmailVerified(EMAIL_HASH_1, governor);

        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        assertTrue(factory.isEmailVerified(EMAIL_HASH_1));
    }

    function test_verifyEmail_byEmailVerifier() public {
        // First set the email verifier
        vm.prank(governor);
        factory.setEmailVerifier(emailVerifier);

        vm.expectEmit(true, true, false, false);
        emit EmailVerified(EMAIL_HASH_1, emailVerifier);

        vm.prank(emailVerifier);
        factory.verifyEmail(EMAIL_HASH_1);

        assertTrue(factory.isEmailVerified(EMAIL_HASH_1));
    }

    function test_verifyEmail_revertsNotAuthorized() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.NotAuthorized.selector, attacker));
        factory.verifyEmail(EMAIL_HASH_1);
    }

    function test_verifyEmail_revertsZeroHash() public {
        vm.prank(governor);
        vm.expectRevert(ITAGITAccountFactory.InvalidEmailHash.selector);
        factory.verifyEmail(bytes32(0));
    }

    function test_isEmailVerified_defaultFalse() public view {
        assertFalse(factory.isEmailVerified(EMAIL_HASH_1));
    }

    // ──────────────────────────────────────────────
    // Account Creation — createAccount
    // ──────────────────────────────────────────────

    function test_createAccount_success() public {
        // Pre-verify email
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        // Get predicted address
        address predicted = factory.getAddress(EMAIL_HASH_1, SALT_1);

        // Create account (msg.sender becomes owner)
        vm.prank(user1);
        address created = factory.createAccount(EMAIL_HASH_1, SALT_1);

        assertEq(created, predicted);
        assertTrue(factory.isAccount(created));
        assertEq(factory.totalAccounts(), 1);
        assertEq(factory.getAccountByEmail(EMAIL_HASH_1), created);
    }

    function test_createAccount_emitsEvent() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        address predicted = factory.getAddress(EMAIL_HASH_1, SALT_1);

        vm.expectEmit(true, true, false, true);
        emit AccountCreated(predicted, EMAIL_HASH_1, SALT_1, user1);

        vm.prank(user1);
        factory.createAccount(EMAIL_HASH_1, SALT_1);
    }

    function test_createAccount_consumesEmailVerification() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        vm.prank(user1);
        factory.createAccount(EMAIL_HASH_1, SALT_1);

        // Email verification should be consumed (one-time use)
        assertFalse(factory.isEmailVerified(EMAIL_HASH_1));
    }

    function test_createAccount_returnsExistingIfDeployed() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        vm.prank(user1);
        address first = factory.createAccount(EMAIL_HASH_1, SALT_1);

        // Second call with same params should return same address
        vm.prank(user2);
        address second = factory.createAccount(EMAIL_HASH_1, SALT_1);

        assertEq(first, second);
        // totalAccounts should still be 1
        assertEq(factory.totalAccounts(), 1);
    }

    function test_createAccount_revertsZeroEmailHash() public {
        vm.prank(user1);
        vm.expectRevert(ITAGITAccountFactory.InvalidEmailHash.selector);
        factory.createAccount(bytes32(0), SALT_1);
    }

    function test_createAccount_revertsUnverifiedEmail() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.EmailNotVerified.selector, EMAIL_HASH_1));
        factory.createAccount(EMAIL_HASH_1, SALT_1);
    }

    // ──────────────────────────────────────────────
    // Account Creation — createAccountWithOwner
    // ──────────────────────────────────────────────

    function test_createAccountWithOwner_success() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        address predicted = factory.getAddress(EMAIL_HASH_1, SALT_1);

        vm.prank(user1);
        address created = factory.createAccountWithOwner(EMAIL_HASH_1, SALT_1, user2);

        assertEq(created, predicted);
        assertTrue(factory.isAccount(created));
        assertEq(factory.totalAccounts(), 1);
    }

    function test_createAccountWithOwner_emitsEvent() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        address predicted = factory.getAddress(EMAIL_HASH_1, SALT_1);

        vm.expectEmit(true, true, false, true);
        emit AccountCreated(predicted, EMAIL_HASH_1, SALT_1, user2);

        vm.prank(user1);
        factory.createAccountWithOwner(EMAIL_HASH_1, SALT_1, user2);
    }

    function test_createAccountWithOwner_revertsZeroOwner() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        vm.prank(user1);
        vm.expectRevert(ITAGITAccountFactory.ZeroAddress.selector);
        factory.createAccountWithOwner(EMAIL_HASH_1, SALT_1, address(0));
    }

    function test_createAccountWithOwner_revertsZeroEmailHash() public {
        vm.prank(user1);
        vm.expectRevert(ITAGITAccountFactory.InvalidEmailHash.selector);
        factory.createAccountWithOwner(bytes32(0), SALT_1, user2);
    }

    function test_createAccountWithOwner_revertsUnverifiedEmail() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.EmailNotVerified.selector, EMAIL_HASH_2));
        factory.createAccountWithOwner(EMAIL_HASH_2, SALT_1, user2);
    }

    function test_createAccountWithOwner_returnsExistingIfDeployed() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_2);

        vm.prank(user1);
        address first = factory.createAccountWithOwner(EMAIL_HASH_2, SALT_2, user2);

        vm.prank(user1);
        address second = factory.createAccountWithOwner(EMAIL_HASH_2, SALT_2, user2);

        assertEq(first, second);
        assertEq(factory.totalAccounts(), 1);
    }

    // ──────────────────────────────────────────────
    // Deterministic Addressing
    // ──────────────────────────────────────────────

    function test_getAddress_deterministicAcrossCalls() public view {
        address addr1 = factory.getAddress(EMAIL_HASH_1, SALT_1);
        address addr2 = factory.getAddress(EMAIL_HASH_1, SALT_1);
        assertEq(addr1, addr2);
    }

    function test_getAddress_differentEmailsYieldDifferentAddresses() public view {
        address addr1 = factory.getAddress(EMAIL_HASH_1, SALT_1);
        address addr2 = factory.getAddress(EMAIL_HASH_2, SALT_1);
        assertTrue(addr1 != addr2);
    }

    function test_getAddress_differentSaltsYieldDifferentAddresses() public view {
        address addr1 = factory.getAddress(EMAIL_HASH_1, SALT_1);
        address addr2 = factory.getAddress(EMAIL_HASH_1, SALT_2);
        assertTrue(addr1 != addr2);
    }

    function test_isAccount_defaultFalse() public view {
        assertFalse(factory.isAccount(address(0xdead)));
    }

    // ──────────────────────────────────────────────
    // Admin — setImplementation
    // ──────────────────────────────────────────────

    function test_setImplementation_success() public {
        address newImpl = makeAddr("newImpl");

        vm.expectEmit(true, true, false, false);
        emit ImplementationUpdated(address(accountImpl), newImpl);

        vm.prank(governor);
        factory.setImplementation(newImpl);

        assertEq(factory.accountImplementation(), newImpl);
    }

    function test_setImplementation_revertsNotGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.NotAuthorized.selector, attacker));
        factory.setImplementation(makeAddr("newImpl"));
    }

    function test_setImplementation_revertsZeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(ITAGITAccountFactory.ZeroAddress.selector);
        factory.setImplementation(address(0));
    }

    // ──────────────────────────────────────────────
    // Admin — setProtocolGuardian
    // ──────────────────────────────────────────────

    function test_setProtocolGuardian_success() public {
        address newGuardian = makeAddr("newGuardian");

        vm.expectEmit(true, true, false, false);
        emit ProtocolGuardianUpdated(protocolGuardian, newGuardian);

        vm.prank(governor);
        factory.setProtocolGuardian(newGuardian);

        assertEq(factory.protocolGuardian(), newGuardian);
    }

    function test_setProtocolGuardian_revertsNotGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.NotAuthorized.selector, attacker));
        factory.setProtocolGuardian(makeAddr("newGuardian"));
    }

    // ──────────────────────────────────────────────
    // Admin — setGovernor
    // ──────────────────────────────────────────────

    function test_setGovernor_success() public {
        address newGovernor = makeAddr("newGovernor");

        vm.expectEmit(true, true, false, false);
        emit GovernorUpdated(governor, newGovernor);

        vm.prank(governor);
        factory.setGovernor(newGovernor);

        assertEq(factory.governor(), newGovernor);
    }

    function test_setGovernor_revertsNotGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.NotAuthorized.selector, attacker));
        factory.setGovernor(makeAddr("newGovernor"));
    }

    function test_setGovernor_revertsZeroAddress() public {
        vm.prank(governor);
        vm.expectRevert(ITAGITAccountFactory.ZeroAddress.selector);
        factory.setGovernor(address(0));
    }

    function test_setGovernor_oldGovernorLosesAccess() public {
        address newGovernor = makeAddr("newGovernor");

        vm.prank(governor);
        factory.setGovernor(newGovernor);

        // Old governor should lose access
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.NotAuthorized.selector, governor));
        factory.setImplementation(makeAddr("newImpl"));

        // New governor should have access
        vm.prank(newGovernor);
        factory.setImplementation(makeAddr("newImpl"));
    }

    // ──────────────────────────────────────────────
    // Admin — setTagitCore
    // ──────────────────────────────────────────────

    function test_setTagitCore_success() public {
        address newCore = makeAddr("newCore");

        vm.prank(governor);
        factory.setTagitCore(newCore);

        assertEq(factory.tagitCore(), newCore);
    }

    function test_setTagitCore_revertsNotGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.NotAuthorized.selector, attacker));
        factory.setTagitCore(makeAddr("newCore"));
    }

    // ──────────────────────────────────────────────
    // Admin — setEmailVerifier
    // ──────────────────────────────────────────────

    function test_setEmailVerifier_success() public {
        vm.expectEmit(true, true, false, false);
        emit EmailVerifierUpdated(address(0), emailVerifier);

        vm.prank(governor);
        factory.setEmailVerifier(emailVerifier);

        assertEq(factory.emailVerifier(), emailVerifier);
    }

    function test_setEmailVerifier_canDisable() public {
        vm.prank(governor);
        factory.setEmailVerifier(emailVerifier);

        vm.expectEmit(true, true, false, false);
        emit EmailVerifierUpdated(emailVerifier, address(0));

        vm.prank(governor);
        factory.setEmailVerifier(address(0));

        assertEq(factory.emailVerifier(), address(0));
    }

    function test_setEmailVerifier_revertsNotGovernor() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccountFactory.NotAuthorized.selector, attacker));
        factory.setEmailVerifier(emailVerifier);
    }

    // ──────────────────────────────────────────────
    // View — getAccountByEmail
    // ──────────────────────────────────────────────

    function test_getAccountByEmail_returnsZeroIfNotDeployed() public view {
        assertEq(factory.getAccountByEmail(EMAIL_HASH_1), address(0));
    }

    function test_getAccountByEmail_returnsCorrectAccount() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);

        vm.prank(user1);
        address created = factory.createAccount(EMAIL_HASH_1, SALT_1);

        assertEq(factory.getAccountByEmail(EMAIL_HASH_1), created);
    }

    // ──────────────────────────────────────────────
    // Multiple Accounts
    // ──────────────────────────────────────────────

    function test_multipleAccounts_incrementsTotalAccounts() public {
        // Create first account
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_1);
        vm.prank(user1);
        factory.createAccount(EMAIL_HASH_1, SALT_1);
        assertEq(factory.totalAccounts(), 1);

        // Create second account
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH_2);
        vm.prank(user2);
        factory.createAccount(EMAIL_HASH_2, SALT_2);
        assertEq(factory.totalAccounts(), 2);
    }

    // ──────────────────────────────────────────────
    // Fuzz Tests
    // ──────────────────────────────────────────────

    function testFuzz_getAddress_deterministic(bytes32 emailHash, uint256 salt) public view {
        vm.assume(emailHash != bytes32(0));
        address addr1 = factory.getAddress(emailHash, salt);
        address addr2 = factory.getAddress(emailHash, salt);
        assertEq(addr1, addr2);
    }

    function testFuzz_differentInputsProduceDifferentAddresses(bytes32 hash1, bytes32 hash2, uint256 salt) public view {
        vm.assume(hash1 != hash2);
        vm.assume(hash1 != bytes32(0));
        vm.assume(hash2 != bytes32(0));
        address addr1 = factory.getAddress(hash1, salt);
        address addr2 = factory.getAddress(hash2, salt);
        assertTrue(addr1 != addr2);
    }
}
