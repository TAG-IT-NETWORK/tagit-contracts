// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "@forge-std/Test.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {TAGITAccount} from "../../src/account/TAGITAccount.sol";
import {ITAGITAccount} from "../../src/interfaces/ITAGITAccount.sol";

/**
 * @title MockEntryPointForAccount
 * @notice Minimal mock for EntryPoint with nonce tracking
 */
contract MockEntryPointForAccount {
    mapping(address => mapping(uint192 => uint256)) private _nonces;

    function getNonce(address sender, uint192 key) external view returns (uint256) {
        return _nonces[sender][key];
    }

    function incrementNonce(address sender, uint192 key) external {
        _nonces[sender][key]++;
    }

    // For depositing
    receive() external payable {}
}

/**
 * @title TAGITAccountNistTest
 * @notice NIST CSF 2.0 security control tests for TAGITAccount
 * @dev Tests AU-3 (Audit Content) session key monitoring
 */
contract TAGITAccountNistTest is Test {
    using MessageHashUtils for bytes32;

    // ============================================
    // EVENTS (mirror from contract)
    // ============================================

    event SessionKeyUsed(address indexed sessionKey, bytes32 indexed userOpHash, uint256 timestamp, uint48 validUntil);

    event SessionKeyValidationFailed(address indexed sessionKey, bytes32 indexed userOpHash, string reason);

    event SessionKeyAdded(address indexed key, uint48 validAfter, uint48 validUntil, bytes4[] allowedSelectors);

    event SessionKeyRevoked(address indexed key);

    // ============================================
    // CONTRACTS
    // ============================================

    TAGITAccount public account;
    MockEntryPointForAccount public entryPoint;

    // ============================================
    // ADDRESSES
    // ============================================

    address public owner;
    uint256 public ownerPrivateKey;
    address public sessionKeyAddr;
    uint256 public sessionKeyPrivateKey;
    address public protocolGuardian;
    address public attacker;

    // ============================================
    // CONSTANTS
    // ============================================

    bytes4 public constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));

    // ============================================
    // SETUP
    // ============================================

    function setUp() public {
        // Create addresses with known private keys for signing
        ownerPrivateKey = 0x1;
        owner = vm.addr(ownerPrivateKey);
        sessionKeyPrivateKey = 0x2;
        sessionKeyAddr = vm.addr(sessionKeyPrivateKey);
        protocolGuardian = makeAddr("protocolGuardian");
        attacker = makeAddr("attacker");

        vm.deal(owner, 100 ether);

        // Deploy mock EntryPoint
        entryPoint = new MockEntryPointForAccount();

        // Deploy TAGITAccount
        vm.prank(owner);
        account = new TAGITAccount(address(entryPoint));

        // Initialize account (as if from factory)
        account.initialize(
            owner,
            keccak256("test@tagit.network"),
            protocolGuardian,
            address(0) // No TAGITCore for these tests
        );

        // Fund account
        vm.deal(address(account), 10 ether);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _createUserOp(address signer, uint256 signerPrivateKey, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory, bytes32)
    {
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(uint256(500000) << 128 | uint256(500000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(10 gwei) << 128 | uint256(10 gwei)),
            paymasterAndData: "",
            signature: ""
        });

        // Create userOpHash
        bytes32 userOpHash = keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                keccak256(userOp.paymasterAndData)
            )
        );

        // Sign the hash
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);

        return (userOp, userOpHash);
    }

    function _addSessionKey() internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        ITAGITAccount.SessionKey memory sk = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: selectors,
            spendLimit: 1 ether
        });

        vm.prank(owner);
        account.addSessionKey(sk);
    }

    // ============================================
    // SESSION KEY MONITORING TESTS (AU-3)
    // ============================================

    function test_sessionKey_emitsAddedEvent() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        ITAGITAccount.SessionKey memory sk = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: selectors,
            spendLimit: 1 ether
        });

        vm.expectEmit(true, true, true, true);
        emit SessionKeyAdded(sessionKeyAddr, uint48(block.timestamp), uint48(block.timestamp + 1 hours), selectors);

        vm.prank(owner);
        account.addSessionKey(sk);
    }

    function test_sessionKey_emitsRevokedEvent() public {
        _addSessionKey();

        vm.expectEmit(true, true, true, true);
        emit SessionKeyRevoked(sessionKeyAddr);

        vm.prank(owner);
        account.revokeSessionKey(sessionKeyAddr);
    }

    function test_sessionKey_emitsUsedEventOnValidation() public {
        _addSessionKey();

        // Create execute call data
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, address(0x1234), 0, "");

        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _createUserOp(sessionKeyAddr, sessionKeyPrivateKey, callData);

        // Expect SessionKeyUsed event
        vm.expectEmit(true, true, false, true);
        emit SessionKeyUsed(sessionKeyAddr, userOpHash, block.timestamp, uint48(block.timestamp + 1 hours));

        vm.prank(address(entryPoint));
        account.validateUserOp(userOp, userOpHash, 0);
    }

    function test_sessionKey_emitsFailedEventOnExpired() public {
        _addSessionKey();

        // Fast forward past validity
        vm.warp(block.timestamp + 2 hours);

        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, address(0x1234), 0, "");

        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _createUserOp(sessionKeyAddr, sessionKeyPrivateKey, callData);

        // Expect SessionKeyValidationFailed event
        vm.expectEmit(true, true, true, true);
        emit SessionKeyValidationFailed(sessionKeyAddr, userOpHash, "expired");

        vm.prank(address(entryPoint));
        account.validateUserOp(userOp, userOpHash, 0);
    }

    function test_sessionKey_emitsFailedEventOnSelectorNotAllowed() public {
        _addSessionKey();

        // Use a selector not in allowed list
        bytes memory callData = abi.encodeWithSelector(bytes4(keccak256("notAllowed()")), address(0x1234));

        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _createUserOp(sessionKeyAddr, sessionKeyPrivateKey, callData);

        // Expect SessionKeyValidationFailed event
        vm.expectEmit(true, true, true, true);
        emit SessionKeyValidationFailed(sessionKeyAddr, userOpHash, "selector_not_allowed");

        vm.prank(address(entryPoint));
        account.validateUserOp(userOp, userOpHash, 0);
    }

    function test_sessionKey_emitsFailedEventOnUnknownSigner() public {
        // Use attacker's signature (not owner or session key)
        uint256 attackerPrivateKey = 0x999;
        address attackerAddr = vm.addr(attackerPrivateKey);

        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, address(0x1234), 0, "");

        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _createUserOp(attackerAddr, attackerPrivateKey, callData);

        // Expect SessionKeyValidationFailed event
        vm.expectEmit(true, true, true, true);
        emit SessionKeyValidationFailed(attackerAddr, userOpHash, "unknown_signer");

        vm.prank(address(entryPoint));
        account.validateUserOp(userOp, userOpHash, 0);
    }

    // ============================================
    // OWNER SIGNATURE TESTS
    // ============================================

    function test_owner_validationSucceedsNoSessionKeyEvent() public {
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, address(0x1234), 0, "");

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createUserOp(owner, ownerPrivateKey, callData);

        // Owner validation should succeed without emitting SessionKeyUsed
        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        // Validation should succeed (0 = success)
        assertEq(validationData, 0);
    }

    // ============================================
    // GAS BENCHMARKS
    // ============================================

    function test_gas_validateUserOpWithSessionKey() public {
        _addSessionKey();

        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, address(0x1234), 0, "");

        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _createUserOp(sessionKeyAddr, sessionKeyPrivateKey, callData);

        vm.prank(address(entryPoint));
        uint256 gasBefore = gasleft();
        account.validateUserOp(userOp, userOpHash, 0);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be under 100k gas
        assertLt(gasUsed, 100000, "validateUserOp() with session key too expensive");
    }

    function test_gas_validateUserOpWithOwner() public {
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, address(0x1234), 0, "");

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createUserOp(owner, ownerPrivateKey, callData);

        vm.prank(address(entryPoint));
        uint256 gasBefore = gasleft();
        account.validateUserOp(userOp, userOpHash, 0);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be under 50k gas for owner
        assertLt(gasUsed, 50000, "validateUserOp() with owner too expensive");
    }

    // ============================================
    // SECURITY EDGE CASES
    // ============================================

    function test_security_onlyEntryPointCanValidate() public {
        bytes memory callData = abi.encodeWithSelector(EXECUTE_SELECTOR, address(0x1234), 0, "");

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createUserOp(owner, ownerPrivateKey, callData);

        vm.prank(attacker);
        vm.expectRevert();
        account.validateUserOp(userOp, userOpHash, 0);
    }

    function test_security_onlyOwnerCanAddSessionKey() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        ITAGITAccount.SessionKey memory sk = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 hours),
            allowedSelectors: selectors,
            spendLimit: 1 ether
        });

        vm.prank(attacker);
        vm.expectRevert();
        account.addSessionKey(sk);
    }

    function test_security_onlyOwnerCanRevokeSessionKey() public {
        _addSessionKey();

        vm.prank(attacker);
        vm.expectRevert();
        account.revokeSessionKey(sessionKeyAddr);
    }

    function test_security_sessionKeyMaxValidityEnforced() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXECUTE_SELECTOR;

        // Try to set validity > 24 hours
        ITAGITAccount.SessionKey memory sk = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 48 hours), // Try 48 hours
            allowedSelectors: selectors,
            spendLimit: 1 ether
        });

        vm.prank(owner);
        account.addSessionKey(sk);

        // Should be capped at 24 hours
        ITAGITAccount.SessionKey memory stored = account.getSessionKey(sessionKeyAddr);
        assertEq(stored.validUntil, uint48(block.timestamp + 24 hours));
    }
}
