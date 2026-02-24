// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IIntegrationFactory} from "../interfaces/IIntegrationFactory.sol";
import {ITAGITBurner} from "../interfaces/ITAGITBurner.sol";
import {BASIS_POINTS} from "../libraries/Constants.sol";

/**
 * @title IntegrationFactory
 * @author TAG IT Network <dev@tagit.network>
 * @notice Partner onboarding contract for the AdAgent pipeline
 * @dev Creates lightweight per-partner configurations, handles x402 payment
 *      routing through TAGITBurner, and provides 2-of-3 multi-sig governance.
 *
 * Key Features:
 * - Per-partner integration configs (no proxy clones needed — config-only)
 * - Payment routing: protocol fee → TAGITBurner (burn + treasury), remainder → partner
 * - $1K TAGIT max payment cap per transaction [SECURITY - REQ T1]
 * - 2-of-3 multi-sig admin for config changes
 * - Emergency pause function
 * - 30-day grace period on partner deactivation
 * - ReentrancyGuard on all payment functions
 *
 * @custom:security-contact security@tagit.network
 */
contract IntegrationFactory is
    IIntegrationFactory,
    Ownable,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Grace period before deactivation is finalized
    uint256 public constant DEACTIVATION_GRACE_PERIOD = 30 days;

    /// @notice Default max payment per transaction (1000 TAGIT)
    uint256 public constant DEFAULT_MAX_PAYMENT = 1000 * 1e18;

    /// @notice Minimum required signers for multi-sig
    uint256 public constant MIN_SIGNERS = 3;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice TAGITBurner contract for fee routing
    ITAGITBurner public burner;

    /// @notice Integration counter (starts at 1)
    uint256 private _nextIntegrationId;

    /// @notice Maximum payment per transaction
    uint256 private _maxPaymentPerTx;

    /// @notice Total active integrations
    uint256 private _activeIntegrations;

    /// @notice Required signatures for multi-sig operations
    uint256 private _requiredSignatures;

    /// @notice Nonce for multi-sig replay protection
    uint256 private _nonce;

    /// @notice Integration ID → Integration config
    mapping(uint256 => Integration) private _integrations;

    /// @notice Agent ID → Integration ID
    mapping(uint256 => uint256) private _agentToIntegration;

    /// @notice Multi-sig signers
    mapping(address => bool) private _signers;

    /// @notice Ordered list of signers
    address[] private _signerList;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the IntegrationFactory
     * @param burnerAddr TAGITBurner contract address
     * @param initialOwner Contract owner
     * @param signers Initial multi-sig signers (minimum 3)
     * @param requiredSigs Required signatures (e.g., 2 of 3)
     */
    constructor(
        address burnerAddr,
        address initialOwner,
        address[] memory signers,
        uint256 requiredSigs
    ) Ownable(initialOwner) {
        if (burnerAddr == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (signers.length < MIN_SIGNERS) revert MinimumSignersRequired();
        if (requiredSigs == 0 || requiredSigs > signers.length) {
            revert InsufficientSignatures(requiredSigs, signers.length);
        }

        burner = ITAGITBurner(burnerAddr);
        _maxPaymentPerTx = DEFAULT_MAX_PAYMENT;
        _nextIntegrationId = 1;
        _requiredSignatures = requiredSigs;

        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == address(0)) revert ZeroAddress();
            if (_signers[signers[i]]) revert DuplicateSigner(signers[i]);
            _signers[signers[i]] = true;
            _signerList.push(signers[i]);
        }
    }

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /// @inheritdoc IIntegrationFactory
    function deployIntegration(
        uint256 agentId,
        address partnerWallet,
        uint96 feeRate,
        address paymentToken
    ) external onlyOwner nonReentrant whenNotPaused returns (uint256 integrationId) {
        // CHECKS
        if (agentId == 0) revert InvalidAgentId(agentId);
        if (partnerWallet == address(0)) revert ZeroAddress();
        if (paymentToken == address(0)) revert ZeroAddress();
        if (feeRate > uint96(BASIS_POINTS)) revert InvalidFeeRate(feeRate);
        if (_agentToIntegration[agentId] != 0) revert AgentAlreadyIntegrated(agentId);

        // EFFECTS
        integrationId = _nextIntegrationId++;

        _integrations[integrationId] = Integration({
            agentId: agentId,
            partnerWallet: partnerWallet,
            paymentToken: paymentToken,
            feeRate: feeRate,
            deployedAt: uint64(block.timestamp),
            deactivateRequestedAt: 0,
            active: true
        });

        _agentToIntegration[agentId] = integrationId;
        _activeIntegrations++;

        emit IntegrationDeployed(integrationId, agentId, partnerWallet, paymentToken, feeRate);
    }

    /// @inheritdoc IIntegrationFactory
    function processPayment(
        uint256 integrationId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        // CHECKS
        if (amount == 0) revert ZeroAmount();
        if (amount > _maxPaymentPerTx) revert PaymentExceedsCap(amount, _maxPaymentPerTx);

        Integration storage integration = _integrations[integrationId];
        if (!integration.active) revert IntegrationNotActive(integrationId);

        address token = integration.paymentToken;
        uint256 protocolFee = (amount * uint256(integration.feeRate)) / BASIS_POINTS;
        uint256 partnerShare = amount - protocolFee;

        // EFFECTS — nothing to update in storage

        // INTERACTIONS
        // 1. Transfer full amount from payer to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // 2. Route protocol fee through burner
        if (protocolFee > 0) {
            IERC20(token).forceApprove(address(burner), protocolFee);
            burner.routeFee(protocolFee);
        }

        // 3. Transfer partner share to partner wallet
        if (partnerShare > 0) {
            IERC20(token).safeTransfer(integration.partnerWallet, partnerShare);
        }

        emit PaymentProcessed(integrationId, msg.sender, amount, protocolFee, partnerShare);
    }

    /// @inheritdoc IIntegrationFactory
    function deactivateIntegration(
        uint256 integrationId
    ) external onlyOwner nonReentrant {
        Integration storage integration = _integrations[integrationId];
        if (!integration.active) revert IntegrationNotActive(integrationId);
        if (integration.deactivateRequestedAt != 0) {
            revert IntegrationInGracePeriod(integrationId);
        }

        // EFFECTS
        integration.deactivateRequestedAt = uint64(block.timestamp);

        uint256 gracePeriodEnds = block.timestamp + DEACTIVATION_GRACE_PERIOD;
        emit IntegrationDeactivationRequested(integrationId, gracePeriodEnds);
    }

    /// @inheritdoc IIntegrationFactory
    function executeDeactivation(
        uint256 integrationId
    ) external nonReentrant {
        Integration storage integration = _integrations[integrationId];
        if (!integration.active) revert IntegrationNotActive(integrationId);
        if (integration.deactivateRequestedAt == 0) {
            revert IntegrationNotFound(integrationId);
        }

        uint256 expiresAt = uint256(integration.deactivateRequestedAt) + DEACTIVATION_GRACE_PERIOD;
        if (block.timestamp < expiresAt) {
            revert GracePeriodNotExpired(integrationId, expiresAt);
        }

        // EFFECTS
        integration.active = false;
        _activeIntegrations--;

        emit IntegrationDeactivated(integrationId, integration.agentId);
    }

    /// @inheritdoc IIntegrationFactory
    function reactivateIntegration(
        uint256 integrationId,
        bytes[] calldata signatures
    ) external nonReentrant {
        _verifyMultiSig(
            keccak256(abi.encodePacked("REACTIVATE", integrationId, _nonce)),
            signatures
        );
        _nonce++;

        Integration storage integration = _integrations[integrationId];
        if (!integration.active) revert IntegrationNotActive(integrationId);
        if (integration.deactivateRequestedAt == 0) {
            revert IntegrationNotFound(integrationId);
        }

        // EFFECTS
        integration.deactivateRequestedAt = 0;

        emit IntegrationReactivated(integrationId);
    }

    // ============================================
    // ADMIN FUNCTIONS (MULTI-SIG)
    // ============================================

    /// @inheritdoc IIntegrationFactory
    function setMaxPayment(
        uint256 newMax,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (newMax == 0) revert ZeroAmount();

        _verifyMultiSig(
            keccak256(abi.encodePacked("SET_MAX_PAYMENT", newMax, _nonce)),
            signatures
        );
        _nonce++;

        uint256 oldMax = _maxPaymentPerTx;
        _maxPaymentPerTx = newMax;

        emit MaxPaymentUpdated(oldMax, newMax);
    }

    /// @inheritdoc IIntegrationFactory
    function addSigner(
        address signer,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (signer == address(0)) revert ZeroAddress();
        if (_signers[signer]) revert SignerAlreadyExists(signer);

        _verifyMultiSig(
            keccak256(abi.encodePacked("ADD_SIGNER", signer, _nonce)),
            signatures
        );
        _nonce++;

        _signers[signer] = true;
        _signerList.push(signer);

        emit SignerAdded(signer);
    }

    /// @inheritdoc IIntegrationFactory
    function removeSigner(
        address signer,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (!_signers[signer]) revert SignerNotFound(signer);
        if (_signerList.length <= MIN_SIGNERS) revert MinimumSignersRequired();

        _verifyMultiSig(
            keccak256(abi.encodePacked("REMOVE_SIGNER", signer, _nonce)),
            signatures
        );
        _nonce++;

        _signers[signer] = false;

        // Remove from array by swapping with last
        for (uint256 i = 0; i < _signerList.length; i++) {
            if (_signerList[i] == signer) {
                _signerList[i] = _signerList[_signerList.length - 1];
                _signerList.pop();
                break;
            }
        }

        emit SignerRemoved(signer);
    }

    /**
     * @notice Emergency pause all operations (requires multisig)
     * @param signatures Multi-sig signatures
     */
    function emergencyPause(bytes[] calldata signatures) external nonReentrant {
        _verifyMultiSig(
            keccak256(abi.encodePacked("EMERGENCY_PAUSE", _nonce)),
            signatures
        );
        _nonce++;

        _pause();
    }

    /**
     * @notice Resume operations after emergency (requires multisig)
     * @param signatures Multi-sig signatures
     */
    function emergencyUnpause(bytes[] calldata signatures) external nonReentrant {
        _verifyMultiSig(
            keccak256(abi.encodePacked("EMERGENCY_UNPAUSE", _nonce)),
            signatures
        );
        _nonce++;

        _unpause();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @inheritdoc IIntegrationFactory
    function getIntegration(uint256 integrationId)
        external view returns (Integration memory)
    {
        return _integrations[integrationId];
    }

    /// @inheritdoc IIntegrationFactory
    function getIntegrationByAgent(uint256 agentId)
        external view returns (uint256)
    {
        return _agentToIntegration[agentId];
    }

    /// @inheritdoc IIntegrationFactory
    function getIntegrationStatus(uint256 integrationId)
        external view returns (IntegrationStatus)
    {
        Integration storage integration = _integrations[integrationId];

        if (!integration.active) {
            return IntegrationStatus.DEACTIVATED;
        }
        if (integration.deactivateRequestedAt != 0) {
            return IntegrationStatus.GRACE_PERIOD;
        }
        return IntegrationStatus.ACTIVE;
    }

    /// @inheritdoc IIntegrationFactory
    function isIntegrationActive(uint256 integrationId)
        external view returns (bool)
    {
        return _integrations[integrationId].active;
    }

    /// @inheritdoc IIntegrationFactory
    function totalIntegrations() external view returns (uint256) {
        return _nextIntegrationId - 1;
    }

    /// @inheritdoc IIntegrationFactory
    function activeIntegrations() external view returns (uint256) {
        return _activeIntegrations;
    }

    /// @inheritdoc IIntegrationFactory
    function maxPaymentPerTx() external view returns (uint256) {
        return _maxPaymentPerTx;
    }

    /// @inheritdoc IIntegrationFactory
    function getSigners() external view returns (address[] memory) {
        return _signerList;
    }

    /// @inheritdoc IIntegrationFactory
    function requiredSignatures() external view returns (uint256) {
        return _requiredSignatures;
    }

    /// @notice Get the current nonce for multi-sig operations
    function nonce() external view returns (uint256) {
        return _nonce;
    }

    /// @inheritdoc IIntegrationFactory
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Verify multi-sig signatures against the signer set
     * @dev Uses EIP-191 personal signatures. Requires _requiredSignatures unique valid signers.
     * @param messageHash The hash of the operation being authorized
     * @param signatures Array of signatures from signers
     */
    function _verifyMultiSig(
        bytes32 messageHash,
        bytes[] calldata signatures
    ) internal view {
        if (signatures.length < _requiredSignatures) {
            revert InsufficientSignatures(signatures.length, _requiredSignatures);
        }

        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        uint256 validCount = 0;

        // Track seen signers to prevent duplicates
        address[] memory seen = new address[](signatures.length);

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ethSignedHash.recover(signatures[i]);

            if (!_signers[signer]) revert InvalidSignature(signer);

            // Check for duplicates
            for (uint256 j = 0; j < validCount; j++) {
                if (seen[j] == signer) revert DuplicateSigner(signer);
            }

            seen[validCount] = signer;
            validCount++;
        }

        if (validCount < _requiredSignatures) {
            revert InsufficientSignatures(validCount, _requiredSignatures);
        }
    }
}
