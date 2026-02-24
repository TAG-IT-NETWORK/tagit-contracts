// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {ITAGITAccountFactory} from "../interfaces/ITAGITAccountFactory.sol";
import {TAGITAccount} from "./TAGITAccount.sol";

/**
 * @title TAGITAccountFactory
 * @author TAG IT Network <dev@tagit.network>
 * @notice Factory for creating ERC-4337 smart wallets
 * @dev Uses CREATE2 with Clones for deterministic minimal proxy deployment
 */
contract TAGITAccountFactory is
    ITAGITAccountFactory,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable
{
    using Clones for address;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Account implementation address
    address private _accountImplementation;

    /// @notice EntryPoint address
    IEntryPoint private _entryPoint;

    /// @notice Protocol guardian address (for new accounts)
    address private _protocolGuardian;

    /// @notice TAGITCore address
    address private _tagitCore;

    /// @notice Governor address
    address private _governor;

    /// @notice Total accounts created
    uint256 private _totalAccounts;

    /// @notice Deployed accounts mapping
    mapping(address => bool) private _deployedAccounts;

    /// @notice Email hash to account mapping
    mapping(bytes32 => address) private _emailToAccount;

    // PATCH-15: email verification gate
    /// @notice Pre-verified email hashes (must be true before account deployment)
    mapping(bytes32 => bool) private _verifiedEmails;

    /// @notice Trusted email verifier address (off-chain service)
    address private _emailVerifier;

    // ============================================
    // CONSTRUCTOR & INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the factory
     * @param entryPointAddr EntryPoint contract address
     * @param accountImpl Account implementation address
     * @param protocolGuardianAddr Protocol guardian address
     * @param tagitCoreAddr TAGITCore contract address
     * @param governorAddr Governor address
     * @param initialOwner Initial owner for upgrades
     */
    function initialize(
        address entryPointAddr,
        address accountImpl,
        address protocolGuardianAddr,
        address tagitCoreAddr,
        address governorAddr,
        address initialOwner
    ) external initializer {
        if (entryPointAddr == address(0)) revert ZeroAddress();
        if (accountImpl == address(0)) revert ZeroAddress();
        if (governorAddr == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        _entryPoint = IEntryPoint(entryPointAddr);
        _accountImplementation = accountImpl;
        _protocolGuardian = protocolGuardianAddr;
        _tagitCore = tagitCoreAddr;
        _governor = governorAddr;
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyGovernor() {
        if (msg.sender != _governor) revert NotAuthorized(msg.sender);
        _;
    }

    // ============================================
    // ACCOUNT CREATION
    // ============================================

    /// @inheritdoc ITAGITAccountFactory
    function createAccount(
        bytes32 emailHash,
        uint256 salt
    ) external override returns (address account) {
        if (emailHash == bytes32(0)) revert InvalidEmailHash();

        // Compute deterministic address
        bytes32 combinedSalt = keccak256(abi.encodePacked(emailHash, salt));
        account = _accountImplementation.predictDeterministicAddress(combinedSalt);

        // Return existing if already deployed
        if (_deployedAccounts[account]) {
            return account;
        }

        // PATCH-15: require pre-verified email hash
        if (!_verifiedEmails[emailHash]) revert EmailNotVerified(emailHash);
        _verifiedEmails[emailHash] = false; // consume — one-time use

        // Deploy clone
        account = _accountImplementation.cloneDeterministic(combinedSalt);

        // EFFECTS: Update state BEFORE external call (CEI pattern)
        _deployedAccounts[account] = true;
        _emailToAccount[emailHash] = account;
        _totalAccounts++;

        // INTERACTIONS: Initialize account (external call last)
        TAGITAccount(payable(account)).initialize(
            msg.sender, // Initial owner is caller
            emailHash,
            _protocolGuardian,
            _tagitCore
        );

        emit AccountCreated(account, emailHash, salt, msg.sender);
    }

    /// @inheritdoc ITAGITAccountFactory
    function createAccountWithOwner(
        bytes32 emailHash,
        uint256 salt,
        address initialOwner
    ) external override returns (address account) {
        if (emailHash == bytes32(0)) revert InvalidEmailHash();
        if (initialOwner == address(0)) revert ZeroAddress();

        // Compute deterministic address
        bytes32 combinedSalt = keccak256(abi.encodePacked(emailHash, salt));
        account = _accountImplementation.predictDeterministicAddress(combinedSalt);

        // Return existing if already deployed
        if (_deployedAccounts[account]) {
            return account;
        }

        // PATCH-15: require pre-verified email hash
        if (!_verifiedEmails[emailHash]) revert EmailNotVerified(emailHash);
        _verifiedEmails[emailHash] = false; // consume — one-time use

        // Deploy clone
        account = _accountImplementation.cloneDeterministic(combinedSalt);

        // EFFECTS: Update state BEFORE external call (CEI pattern)
        _deployedAccounts[account] = true;
        _emailToAccount[emailHash] = account;
        _totalAccounts++;

        // INTERACTIONS: Initialize account (external call last)
        TAGITAccount(payable(account)).initialize(
            initialOwner,
            emailHash,
            _protocolGuardian,
            _tagitCore
        );

        emit AccountCreated(account, emailHash, salt, initialOwner);
    }

    /// @inheritdoc ITAGITAccountFactory
    function getAddress(
        bytes32 emailHash,
        uint256 salt
    ) external view override returns (address) {
        bytes32 combinedSalt = keccak256(abi.encodePacked(emailHash, salt));
        return _accountImplementation.predictDeterministicAddress(combinedSalt);
    }

    /// @inheritdoc ITAGITAccountFactory
    function isAccount(address account) external view override returns (bool) {
        return _deployedAccounts[account];
    }

    // ============================================
    // PATCH-15: EMAIL VERIFICATION
    // ============================================

    /**
     * @notice Pre-verify an email hash before account deployment
     * @dev Only governor or trusted email verifier can call.
     *      Off-chain service verifies email ownership then calls this.
     * @param emailHash Keccak256 hash of verified email
     */
    function verifyEmail(bytes32 emailHash) external {
        if (msg.sender != _governor && msg.sender != _emailVerifier) {
            revert NotAuthorized(msg.sender);
        }
        if (emailHash == bytes32(0)) revert InvalidEmailHash();
        _verifiedEmails[emailHash] = true;
        emit EmailVerified(emailHash, msg.sender);
    }

    /**
     * @notice Check if an email hash is pre-verified
     * @param emailHash Email hash to check
     * @return verified True if verified and available for deployment
     */
    function isEmailVerified(bytes32 emailHash) external view returns (bool) {
        return _verifiedEmails[emailHash];
    }

    /**
     * @notice Set the trusted email verifier address
     * @param newVerifier New email verifier address (address(0) to disable)
     */
    function setEmailVerifier(address newVerifier) external onlyGovernor {
        address oldVerifier = _emailVerifier;
        _emailVerifier = newVerifier;
        emit EmailVerifierUpdated(oldVerifier, newVerifier);
    }

    /**
     * @notice Get the email verifier address
     */
    function emailVerifier() external view returns (address) {
        return _emailVerifier;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @inheritdoc ITAGITAccountFactory
    function setImplementation(address newImplementation) external override onlyGovernor {
        if (newImplementation == address(0)) revert ZeroAddress();

        address oldImplementation = _accountImplementation;
        _accountImplementation = newImplementation;

        emit ImplementationUpdated(oldImplementation, newImplementation);
    }

    /// @inheritdoc ITAGITAccountFactory
    function setProtocolGuardian(address newGuardian) external override onlyGovernor {
        address oldGuardian = _protocolGuardian;
        _protocolGuardian = newGuardian;

        emit ProtocolGuardianUpdated(oldGuardian, newGuardian);
    }

    /**
     * @notice Update TAGITCore address
     * @param newCore New TAGITCore address
     */
    function setTagitCore(address newCore) external onlyGovernor {
        _tagitCore = newCore;
    }

    /**
     * @notice Update governor address
     * @param newGovernor New governor address
     */
    function setGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = _governor;
        _governor = newGovernor;
        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @inheritdoc ITAGITAccountFactory
    function accountImplementation() external view override returns (address) {
        return _accountImplementation;
    }

    /// @inheritdoc ITAGITAccountFactory
    function protocolGuardian() external view override returns (address) {
        return _protocolGuardian;
    }

    /// @inheritdoc ITAGITAccountFactory
    function entryPoint() external view override returns (address) {
        return address(_entryPoint);
    }

    /// @inheritdoc ITAGITAccountFactory
    function tagitCore() external view override returns (address) {
        return _tagitCore;
    }

    /// @inheritdoc ITAGITAccountFactory
    function totalAccounts() external view override returns (uint256) {
        return _totalAccounts;
    }

    /**
     * @notice Get governor address
     */
    function governor() external view returns (address) {
        return _governor;
    }

    /**
     * @notice Get account by email hash
     * @param emailHash Email hash
     * @return account Account address (address(0) if not deployed)
     */
    function getAccountByEmail(bytes32 emailHash) external view returns (address) {
        return _emailToAccount[emailHash];
    }

    /// @inheritdoc ITAGITAccountFactory
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    // ============================================
    // UUPS UPGRADE
    // ============================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
