// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "@forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {TAGITAccount} from "../../src/account/TAGITAccount.sol";
import {TAGITAccountFactory} from "../../src/account/TAGITAccountFactory.sol";
import {ITAGITAccountFactory} from "../../src/interfaces/ITAGITAccountFactory.sol";

// Minimal mock EntryPoint for factory tests
contract MockEntryPointP15 {
    mapping(address => uint256) public balances;

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
 * @title Patch15EmailHashTest
 * @notice Tests for PATCH-15: email verification gate on account deployment
 */
contract Patch15EmailHashTest is Test {
    MockEntryPointP15 public entryPoint;
    TAGITAccount public accountImpl;
    TAGITAccountFactory public factory;

    address public governor = makeAddr("governor");
    address public verifier = makeAddr("verifier");
    address public user = makeAddr("user");
    address public attacker = makeAddr("attacker");

    bytes32 public constant EMAIL_HASH = keccak256("user@company.com");
    uint256 public constant SALT = 15;

    function setUp() public {
        entryPoint = new MockEntryPointP15();
        accountImpl = new TAGITAccount(address(entryPoint));

        // Deploy factory via UUPS proxy
        TAGITAccountFactory factoryImpl = new TAGITAccountFactory();
        bytes memory factoryInit = abi.encodeCall(
            TAGITAccountFactory.initialize,
            (address(entryPoint), address(accountImpl), address(0), address(0), governor, governor)
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        factory = TAGITAccountFactory(address(factoryProxy));

        // Set up email verifier
        vm.prank(governor);
        factory.setEmailVerifier(verifier);
    }

    function test_deployAccount_reverts_without_verification() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITAccountFactory.EmailNotVerified.selector, EMAIL_HASH
        ));
        factory.createAccount(EMAIL_HASH, SALT);
    }

    function test_deployAccountWithOwner_reverts_without_verification() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITAccountFactory.EmailNotVerified.selector, EMAIL_HASH
        ));
        factory.createAccountWithOwner(EMAIL_HASH, SALT, user);
    }

    function test_deployAccount_succeeds_after_governor_verification() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH);

        address account = factory.createAccount(EMAIL_HASH, SALT);
        assertTrue(account != address(0), "Account should be deployed");
        assertTrue(factory.isAccount(account), "Should be registered");
    }

    function test_deployAccount_succeeds_after_verifier_verification() public {
        vm.prank(verifier);
        factory.verifyEmail(EMAIL_HASH);

        address account = factory.createAccountWithOwner(EMAIL_HASH, SALT, user);
        assertTrue(account != address(0), "Account should be deployed");
    }

    function test_verifyEmail_requires_authorization() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITAccountFactory.NotAuthorized.selector, attacker
        ));
        factory.verifyEmail(EMAIL_HASH);
    }

    function test_emailHash_consumed_after_deploy() public {
        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH);

        // First deploy succeeds
        factory.createAccount(EMAIL_HASH, SALT);

        // Second deploy with different salt — hash was consumed
        bytes32 emailHash2 = keccak256("another@company.com");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITAccountFactory.EmailNotVerified.selector, emailHash2
        ));
        factory.createAccount(emailHash2, SALT + 1);
    }

    function test_frontrun_blocked() public {
        // Attacker tries to deploy before verification — blocked
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITAccountFactory.EmailNotVerified.selector, EMAIL_HASH
        ));
        factory.createAccountWithOwner(EMAIL_HASH, SALT, attacker);

        // Verifier approves
        vm.prank(verifier);
        factory.verifyEmail(EMAIL_HASH);

        // Legitimate user deploys
        address account = factory.createAccountWithOwner(EMAIL_HASH, SALT, user);
        assertTrue(account != address(0), "Legitimate deploy should succeed");
    }

    function test_isEmailVerified_returns_correct_state() public {
        assertFalse(factory.isEmailVerified(EMAIL_HASH), "Should not be verified initially");

        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH);
        assertTrue(factory.isEmailVerified(EMAIL_HASH), "Should be verified after call");

        // Deploy consumes it
        factory.createAccount(EMAIL_HASH, SALT);
        assertFalse(factory.isEmailVerified(EMAIL_HASH), "Should be consumed after deploy");
    }

    function test_setEmailVerifier_onlyGovernor() public {
        address newVerifier = makeAddr("newVerifier");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            ITAGITAccountFactory.NotAuthorized.selector, attacker
        ));
        factory.setEmailVerifier(newVerifier);

        vm.prank(governor);
        factory.setEmailVerifier(newVerifier);
        assertEq(factory.emailVerifier(), newVerifier);
    }

    function test_emailVerified_event_emitted() public {
        vm.expectEmit(true, true, false, false);
        emit ITAGITAccountFactory.EmailVerified(EMAIL_HASH, governor);

        vm.prank(governor);
        factory.verifyEmail(EMAIL_HASH);
    }
}
