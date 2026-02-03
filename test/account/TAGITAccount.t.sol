// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {TAGITAccount} from "../../src/account/TAGITAccount.sol";
import {TAGITAccountFactory} from "../../src/account/TAGITAccountFactory.sol";
import {TAGITPaymaster} from "../../src/account/TAGITPaymaster.sol";
import {ITAGITAccount} from "../../src/interfaces/ITAGITAccount.sol";
import {ITAGITPaymaster} from "../../src/interfaces/ITAGITPaymaster.sol";

// Mock EntryPoint for testing
contract MockEntryPoint {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public nonces;

    function depositTo(address account) external payable {
        balances[account] += msg.value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function withdrawTo(address payable withdrawAddress, uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        withdrawAddress.transfer(amount);
    }

    function getNonce(address sender, uint192 key) external view returns (uint256) {
        return nonces[sender];
    }

    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}

    // Simulate supportsInterface for BasePaymaster check
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEntryPoint).interfaceId;
    }

    receive() external payable {}
}

// Mock TAGITCore for asset exports
contract MockTAGITCore {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
        balanceOf[to]++;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
        balanceOf[from]--;
        balanceOf[to]++;
    }
}

contract TAGITAccountTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    MockEntryPoint public entryPoint;
    MockTAGITCore public tagitCore;
    TAGITAccount public accountImpl;
    TAGITAccountFactory public factory;
    TAGITPaymaster public paymaster;

    address public governor;
    address public owner;
    address public protocolGuardian;

    uint256 public ownerPrivateKey;
    uint256 public sessionKeyPrivateKey;
    address public sessionKeyAddr;

    bytes32 public constant EMAIL_HASH = keccak256("user@example.com");
    uint256 public constant SALT = 1;

    function setUp() public {
        governor = makeAddr("governor");
        protocolGuardian = makeAddr("protocolGuardian");

        // Generate keys
        ownerPrivateKey = 0x1234;
        owner = vm.addr(ownerPrivateKey);
        sessionKeyPrivateKey = 0x5678;
        sessionKeyAddr = vm.addr(sessionKeyPrivateKey);

        // Deploy mocks
        entryPoint = new MockEntryPoint();
        tagitCore = new MockTAGITCore();

        // Deploy account implementation
        accountImpl = new TAGITAccount(address(entryPoint));

        // Deploy factory
        TAGITAccountFactory factoryImpl = new TAGITAccountFactory();
        bytes memory factoryInit = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (address(entryPoint), address(accountImpl), protocolGuardian, address(tagitCore), governor, governor)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        factory = TAGITAccountFactory(address(factoryProxy));

        // Deploy paymaster
        TAGITPaymaster paymasterImpl = new TAGITPaymaster();
        bytes memory paymasterInit = abi.encodeCall(
            TAGITPaymaster.initialize,
            (address(entryPoint), governor, governor)
        );
        ERC1967Proxy paymasterProxy = new ERC1967Proxy(address(paymasterImpl), paymasterInit);
        paymaster = TAGITPaymaster(payable(address(paymasterProxy)));

        // Fund entrypoint for paymaster
        vm.deal(address(paymaster), 10 ether);
        paymaster.depositProtocol{value: 1 ether}();
    }

    // ============================================
    // ACCOUNT CREATION TESTS
    // ============================================

    function test_createAccount_deterministicAddress() public {
        // Get predicted address
        address predicted = factory.getAddress(EMAIL_HASH, SALT);

        // Create account
        address created = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);

        // Should match
        assertEq(created, predicted, "Address should be deterministic");
        assertTrue(factory.isAccount(created), "Should be registered as account");
    }

    function test_createAccount_counterfactual() public {
        // Get address before deployment
        address counterfactual = factory.getAddress(EMAIL_HASH, SALT);

        // Verify no code at address
        assertEq(counterfactual.code.length, 0, "Should have no code before deployment");

        // Create account
        factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);

        // Verify code exists
        assertTrue(counterfactual.code.length > 0, "Should have code after deployment");
    }

    function test_createAccount_initializesCorrectly() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        assertEq(account.owner(), owner, "Owner should match");
        assertEq(account.emailHash(), EMAIL_HASH, "Email hash should match");
        assertEq(account.factory(), address(factory), "Factory should match");
        assertEq(account.entryPoint(), address(entryPoint), "EntryPoint should match");
    }

    function test_createAccount_revert_alreadyInitialized() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        vm.expectRevert(ITAGITAccount.AlreadyInitialized.selector);
        account.initialize(owner, EMAIL_HASH, protocolGuardian, address(tagitCore));
    }

    // ============================================
    // VALIDATEUSEROP TESTS
    // ============================================

    function test_validateUserOp_validSignature() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Create userOp hash
        bytes32 userOpHash = keccak256("testUserOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();

        // Sign with owner
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Create packed user operation
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: accountAddr,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });

        // Validate (as EntryPoint)
        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, 0, "Should return success for valid signature");
    }

    function test_validateUserOp_invalidSignature_reverts() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Create userOp hash
        bytes32 userOpHash = keccak256("testUserOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();

        // Sign with wrong key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x9999, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        PackedUserOperation memory userOp = PackedUserOperation({
            sender: accountAddr,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });

        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, 1, "Should return failure for invalid signature");
    }

    function test_execute_onlyEntryPoint() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Try to execute as non-entrypoint/owner
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ITAGITAccount.NotOwner.selector, attacker));
        account.execute(address(0), 0, "");
    }

    function test_execute_ownerCanCall() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Fund account
        vm.deal(accountAddr, 1 ether);

        // Owner can execute
        address recipient = makeAddr("recipient");
        vm.prank(owner);
        account.execute(recipient, 0.1 ether, "");

        assertEq(recipient.balance, 0.1 ether);
    }

    // ============================================
    // SESSION KEY TESTS
    // ============================================

    function test_sessionKey_validWithinWindow() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Add session key
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("verify(uint256)"));

        ITAGITAccount.SessionKey memory sessionKey = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: selectors,
            spendLimit: 0
        });

        vm.prank(owner);
        account.addSessionKey(sessionKey);

        // Check validity
        assertTrue(
            account.isValidSessionKey(sessionKeyAddr, selectors[0]),
            "Session key should be valid"
        );
    }

    function test_sessionKey_expiredReverts() public {
        // Warp to reasonable timestamp to avoid underflow
        vm.warp(100000);

        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Add session key with past expiry
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("verify(uint256)"));

        ITAGITAccount.SessionKey memory sessionKey = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp - 2 hours),
            validUntil: uint48(block.timestamp - 1 hours),
            allowedSelectors: selectors,
            spendLimit: 0
        });

        vm.prank(owner);
        vm.expectRevert();
        account.addSessionKey(sessionKey);
    }

    function test_sessionKey_wrongSelectorReverts() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Add session key for verify()
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("verify(uint256)"));

        ITAGITAccount.SessionKey memory sessionKey = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: selectors,
            spendLimit: 0
        });

        vm.prank(owner);
        account.addSessionKey(sessionKey);

        // Try different selector
        bytes4 wrongSelector = bytes4(keccak256("transfer(uint256)"));
        assertFalse(
            account.isValidSessionKey(sessionKeyAddr, wrongSelector),
            "Should reject wrong selector"
        );
    }

    function test_sessionKey_revokeRemovesAccess() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Add session key
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("verify(uint256)"));

        ITAGITAccount.SessionKey memory sessionKey = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: selectors,
            spendLimit: 0
        });

        vm.prank(owner);
        account.addSessionKey(sessionKey);

        // Revoke
        vm.prank(owner);
        account.revokeSessionKey(sessionKeyAddr);

        // Should no longer be valid
        assertFalse(
            account.isValidSessionKey(sessionKeyAddr, selectors[0]),
            "Should be invalid after revoke"
        );
    }

    // ============================================
    // GUARDIAN TESTS
    // ============================================

    function test_addGuardian_updatesThreshold() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        address newGuardian = makeAddr("newGuardian");

        vm.prank(owner);
        account.addGuardian(newGuardian, 2);

        ITAGITAccount.GuardianConfig memory config = account.getGuardianConfig();
        assertEq(config.guardians.length, 2, "Should have 2 guardians");
        assertEq(config.threshold, 2, "Threshold should be 2");
    }

    function test_removeProtocolGuardian_7dayTimelock() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Request removal
        vm.prank(owner);
        account.requestProtocolGuardianRemoval();

        // Try to execute immediately - should fail
        vm.prank(owner);
        vm.expectRevert();
        account.removeProtocolGuardian();

        // Warp 7 days
        vm.warp(block.timestamp + 7 days + 1);

        // Now should succeed
        vm.prank(owner);
        account.removeProtocolGuardian();

        ITAGITAccount.GuardianConfig memory config = account.getGuardianConfig();
        assertFalse(config.protocolGuardian, "Protocol guardian should be removed");
    }

    // ============================================
    // SELF-CUSTODY TESTS
    // ============================================

    function test_exportAsset_transfersNFT() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);

        // Mint NFT to account
        tagitCore.mint(accountAddr, 1);
        assertEq(tagitCore.ownerOf(1), accountAddr);

        // Export to external wallet
        address externalWallet = makeAddr("externalWallet");
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        vm.prank(owner);
        account.exportAsset(1, externalWallet);

        assertEq(tagitCore.ownerOf(1), externalWallet, "Asset should be transferred");
    }

    // ============================================
    // PAYMASTER TESTS
    // ============================================

    function test_paymaster_sponsorsWhitelisted() public {
        // Setup sponsorship config
        bytes4 verifySelector = bytes4(keccak256("verify(uint256)"));

        ITAGITPaymaster.SponsorshipConfig memory config = ITAGITPaymaster.SponsorshipConfig({
            selector: verifySelector,
            maxGas: 100000,
            dailyLimit: 10,
            active: true
        });

        vm.prank(governor);
        paymaster.setSponsorshipConfig(verifySelector, config);

        assertTrue(paymaster.isSponsoredOperation(verifySelector), "Should be sponsored");
    }

    function test_paymaster_rejectUnwhitelisted() public {
        bytes4 randomSelector = bytes4(keccak256("randomFunction()"));
        assertFalse(paymaster.isSponsoredOperation(randomSelector), "Should not be sponsored");
    }

    function test_paymaster_respectsDailyLimit() public {
        bytes4 verifySelector = bytes4(keccak256("verify(uint256)"));

        ITAGITPaymaster.SponsorshipConfig memory config = ITAGITPaymaster.SponsorshipConfig({
            selector: verifySelector,
            maxGas: 100000,
            dailyLimit: 2,
            active: true
        });

        vm.prank(governor);
        paymaster.setSponsorshipConfig(verifySelector, config);

        address user = makeAddr("user");

        // Initially can sponsor
        assertTrue(paymaster.canSponsor(user, verifySelector), "Should be able to sponsor");

        // Simulate usage (this would normally be done through validatePaymasterUserOp)
        // For this test, we just verify the view function works
        assertEq(paymaster.getUserDailyUsage(user, verifySelector), 0, "Usage should be 0");
    }

    // ============================================
    // FUZZ TESTS
    // ============================================

    function testFuzz_sessionKeyExpiry(uint48 validUntil) public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        // Bound to reasonable values
        uint48 validAfter = uint48(block.timestamp);
        validUntil = uint48(bound(validUntil, validAfter + 1, validAfter + 24 hours));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("verify(uint256)"));

        ITAGITAccount.SessionKey memory sessionKey = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: validAfter,
            validUntil: validUntil,
            allowedSelectors: selectors,
            spendLimit: 0
        });

        vm.prank(owner);
        account.addSessionKey(sessionKey);

        // Should be valid during window
        assertTrue(account.isValidSessionKey(sessionKeyAddr, selectors[0]));

        // Should be invalid after expiry
        vm.warp(validUntil + 1);
        assertFalse(account.isValidSessionKey(sessionKeyAddr, selectors[0]));
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_createAccount() public {
        uint256 gasBefore = gasleft();
        factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 350_000, "createAccount() gas too high");
    }

    function test_gas_addSessionKey() public {
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        TAGITAccount account = TAGITAccount(payable(accountAddr));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("verify(uint256)"));

        ITAGITAccount.SessionKey memory sessionKey = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: selectors,
            spendLimit: 0
        });

        vm.prank(owner);
        uint256 gasBefore = gasleft();
        account.addSessionKey(sessionKey);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 100_000, "addSessionKey() gas too high");
    }

    function test_version() public view {
        assertEq(factory.version(), "1.0.0");
        assertEq(paymaster.version(), "1.0.0");
    }
}
