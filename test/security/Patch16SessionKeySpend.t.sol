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
import {ITAGITAccount} from "../../src/interfaces/ITAGITAccount.sol";

// Reuse mock from TAGITAccount.t.sol
contract MockEntryPointP16 {
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

    function getNonce(address, uint192) external pure returns (uint256) {
        return 0;
    }

    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IEntryPoint).interfaceId;
    }

    receive() external payable {}
}

/**
 * @title Patch16SessionKeySpendTest
 * @notice Tests for PATCH-16: session key spend limit enforcement
 */
contract Patch16SessionKeySpendTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    MockEntryPointP16 public entryPoint;
    TAGITAccount public accountImpl;
    TAGITAccountFactory public factory;
    TAGITAccount public account;

    address public protocolGuardian;
    address public governor;

    uint256 public ownerPrivateKey = 0x1234;
    address public owner;
    uint256 public sessionKeyPrivateKey = 0x5678;
    address public sessionKeyAddr;

    bytes32 public constant EMAIL_HASH = keccak256("patch16@test.com");
    uint256 public constant SALT = 16;
    uint256 public constant SPEND_LIMIT = 0.01 ether;

    // execute(address,uint256,bytes) selector
    bytes4 internal constant EXEC_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));

    function setUp() public {
        governor = makeAddr("governor");
        protocolGuardian = makeAddr("protocolGuardian");
        owner = vm.addr(ownerPrivateKey);
        sessionKeyAddr = vm.addr(sessionKeyPrivateKey);

        // Deploy infrastructure
        entryPoint = new MockEntryPointP16();

        // Deploy account implementation
        accountImpl = new TAGITAccount(address(entryPoint));

        // Deploy factory via proxy
        TAGITAccountFactory factoryImpl = new TAGITAccountFactory();
        bytes memory factoryInit = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (address(entryPoint), address(accountImpl), protocolGuardian, address(0), governor, governor)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        factory = TAGITAccountFactory(address(factoryProxy));

        // PATCH-15 requires email verification before account creation
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH);

        // Create account
        address accountAddr = factory.createAccountWithOwner(EMAIL_HASH, SALT, owner);
        account = TAGITAccount(payable(accountAddr));

        // Fund account
        vm.deal(address(account), 100 ether);

        // Add session key with spend limit and execute selector allowed
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXEC_SELECTOR;

        ITAGITAccount.SessionKey memory sk = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 days),
            allowedSelectors: selectors,
            spendLimit: SPEND_LIMIT
        });

        vm.prank(owner);
        account.addSessionKey(sk);
    }

    /// @dev Build a PackedUserOperation with execute calldata and sign with given key
    function _buildUserOp(uint256 privateKey, address dest, uint256 value, bytes memory func)
        internal
        view
        returns (PackedUserOperation memory userOp, bytes32 userOpHash)
    {
        // Encode execute(address,uint256,bytes)
        bytes memory callData = abi.encodeWithSelector(EXEC_SELECTOR, dest, value, func);

        userOpHash = keccak256(abi.encodePacked("userOp", dest, value, func, block.timestamp));
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);

        userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: abi.encodePacked(r, s, v)
        });
    }

    // ============================================
    // PATCH-16 TESTS
    // ============================================

    function test_sessionKey_spend_within_limit_succeeds() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), SPEND_LIMIT, "");

        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        // Should succeed (bit 0 is 0 for success, bits 160+ encode time range)
        assertEq(validationData & 1, 0, "Validation should succeed for spend within limit");
    }

    function test_sessionKey_spend_over_limit_fails() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), SPEND_LIMIT + 1, "");

        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        // Should fail (SIG_VALIDATION_FAILED = 1)
        assertEq(validationData, 1, "Validation should fail for spend over limit");
    }

    function test_sessionKey_cumulative_tracking() public {
        uint256 half = SPEND_LIMIT / 2;

        // First spend: half
        (PackedUserOperation memory userOp1, bytes32 hash1) = _buildUserOp(sessionKeyPrivateKey, address(0x1), half, "");
        vm.prank(address(entryPoint));
        uint256 result1 = account.validateUserOp(userOp1, hash1, 0);
        assertEq(result1 & 1, 0, "First half spend should succeed");

        // Second spend: half
        (PackedUserOperation memory userOp2, bytes32 hash2) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), half, abi.encode(uint256(2)));
        vm.prank(address(entryPoint));
        uint256 result2 = account.validateUserOp(userOp2, hash2, 0);
        assertEq(result2 & 1, 0, "Second half spend should succeed");

        // Third spend: even 1 wei should fail
        (PackedUserOperation memory userOp3, bytes32 hash3) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), 1, abi.encode(uint256(3)));
        vm.prank(address(entryPoint));
        uint256 result3 = account.validateUserOp(userOp3, hash3, 0);
        assertEq(result3, 1, "Spend over cumulative limit should fail");
    }

    function test_sessionKey_reset_on_re_add() public {
        // Spend up to limit
        (PackedUserOperation memory userOp1, bytes32 hash1) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), SPEND_LIMIT, "");
        vm.prank(address(entryPoint));
        account.validateUserOp(userOp1, hash1, 0);

        // Re-add session key (resets spend counter)
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = EXEC_SELECTOR;

        ITAGITAccount.SessionKey memory sk = ITAGITAccount.SessionKey({
            key: sessionKeyAddr,
            validAfter: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 1 days),
            allowedSelectors: selectors,
            spendLimit: SPEND_LIMIT
        });

        vm.prank(owner);
        account.addSessionKey(sk);

        // Should be able to spend again
        (PackedUserOperation memory userOp2, bytes32 hash2) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), SPEND_LIMIT, abi.encode(uint256(2)));
        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp2, hash2, 0);
        assertEq(result & 1, 0, "Spend should succeed after key re-add");
    }

    function test_sessionKey_zero_value_not_tracked() public {
        // Zero-value execute should pass without affecting spend counter
        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), 0, "");

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result & 1, 0, "Zero-value call should succeed");

        // Full limit should still be available
        (PackedUserOperation memory userOp2, bytes32 hash2) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), SPEND_LIMIT, abi.encode(uint256(2)));
        vm.prank(address(entryPoint));
        uint256 result2 = account.validateUserOp(userOp2, hash2, 0);
        assertEq(result2 & 1, 0, "Full limit should be available after zero-value call");
    }

    function test_owner_bypasses_spend_limit() public {
        // Owner can spend any amount — no limit enforced
        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _buildUserOp(ownerPrivateKey, address(0x1), 50 ether, "");

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0, "Owner should bypass spend limits entirely");
    }

    function testFuzz_sessionKey_spend(uint256 amount) public {
        amount = bound(amount, SPEND_LIMIT + 1, 100 ether);

        (PackedUserOperation memory userOp, bytes32 userOpHash) =
            _buildUserOp(sessionKeyPrivateKey, address(0x1), amount, "");

        vm.prank(address(entryPoint));
        uint256 result = account.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Any amount over limit should fail validation");
    }
}
