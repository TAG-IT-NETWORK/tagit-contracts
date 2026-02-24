// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IAccount} from "@account-abstraction/interfaces/IAccount.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "@account-abstraction/core/UserOperationLib.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITAGITAccount} from "../interfaces/ITAGITAccount.sol";

/**
 * @title TAGITAccount
 * @author TAG IT Network <dev@tagit.network>
 * @notice ERC-4337 smart wallet with session keys and self-custody
 * @dev Minimal proxy (Clone) pattern - each user gets their own clone
 */
contract TAGITAccount is IAccount, ITAGITAccount, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using UserOperationLib for PackedUserOperation;

    // ============================================
    // NIST AU-3 MONITORING EVENTS
    // ============================================

    /// @notice Emitted when a session key is used to sign a transaction
    event SessionKeyUsed(
        address indexed sessionKey,
        bytes32 indexed userOpHash,
        uint256 timestamp,
        uint48 validUntil
    );

    /// @notice Emitted when a session key validation fails
    event SessionKeyValidationFailed(
        address indexed sessionKey,
        bytes32 indexed userOpHash,
        string reason
    );

    /// @notice Emitted when session key spend is recorded
    event SessionKeySpendRecorded(
        address indexed sessionKey,
        uint256 amount,
        uint256 totalSpent,
        uint256 spendLimit
    );

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Protocol guardian removal timelock (7 days)
    uint48 public constant PROTOCOL_GUARDIAN_REMOVAL_DELAY = 7 days;

    /// @notice Maximum session key validity (24 hours)
    uint48 public constant MAX_SESSION_KEY_VALIDITY = 24 hours;

    /// @notice ERC-4337 signature validation success
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;

    /// @notice ERC-4337 signature validation failure
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    // ============================================
    // IMMUTABLES
    // ============================================

    /// @notice EntryPoint contract (canonical v0.7)
    IEntryPoint private immutable _entryPoint;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Account owner (primary signer)
    address private _owner;

    /// @notice Email hash (identity anchor)
    bytes32 private _emailHash;

    /// @notice Factory that created this account
    address private _factory;

    /// @notice TAGITCore contract for asset exports
    address private _tagitCore;

    /// @notice Whether account is initialized
    bool private _initialized;

    /// @notice Session keys mapping
    mapping(address => SessionKey) private _sessionKeys;

    /// @notice Session key spent amounts
    mapping(address => uint256) private _sessionKeySpent;

    /// @notice Guardian addresses
    address[] private _guardians;

    /// @notice Guardian index lookup
    mapping(address => uint256) private _guardianIndex;

    /// @notice Is guardian flag
    mapping(address => bool) private _isGuardian;

    /// @notice Guardian threshold
    uint8 private _threshold;

    /// @notice Recovery delay
    uint48 private _recoveryDelay;

    /// @notice Protocol guardian flag
    bool private _protocolGuardian;

    /// @notice Pending protocol guardian removal
    ProtocolGuardianRemoval private _pendingRemoval;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Constructor sets the EntryPoint
     * @param entryPointAddr Canonical EntryPoint address
     */
    constructor(address entryPointAddr) {
        _entryPoint = IEntryPoint(entryPointAddr);
    }

    // ============================================
    // INITIALIZER
    // ============================================

    /**
     * @notice Initialize the account (called by factory)
     * @param ownerAddr Initial owner address
     * @param emailHashVal Email hash for identity
     * @param protocolGuardianAddr Protocol guardian address
     * @param tagitCoreAddr TAGITCore contract address
     */
    function initialize(
        address ownerAddr,
        bytes32 emailHashVal,
        address protocolGuardianAddr,
        address tagitCoreAddr
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (ownerAddr == address(0)) revert ZeroAddress();

        _initialized = true;
        _owner = ownerAddr;
        _emailHash = emailHashVal;
        _factory = msg.sender;
        _tagitCore = tagitCoreAddr;

        // Setup protocol guardian
        if (protocolGuardianAddr != address(0)) {
            _guardians.push(protocolGuardianAddr);
            _guardianIndex[protocolGuardianAddr] = 0;
            _isGuardian[protocolGuardianAddr] = true;
            _protocolGuardian = true;
            _threshold = 1;
            _recoveryDelay = 2 days;
        }

        emit AccountInitialized(ownerAddr, emailHashVal, msg.sender);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyEntryPoint() {
        if (msg.sender != address(_entryPoint)) {
            revert NotEntryPoint(msg.sender);
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != _owner && msg.sender != address(this)) {
            revert NotOwner(msg.sender);
        }
        _;
    }

    modifier onlyEntryPointOrOwner() {
        if (msg.sender != address(_entryPoint) && msg.sender != _owner && msg.sender != address(this)) {
            revert NotOwner(msg.sender);
        }
        _;
    }

    // ============================================
    // ERC-4337 IMPLEMENTATION
    // ============================================

    /// @inheritdoc IAccount
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override(IAccount, ITAGITAccount) onlyEntryPoint returns (uint256 validationData) {
        address sessionKeyUsed;
        (validationData, sessionKeyUsed) = _validateSignatureWithTracking(userOp, userOpHash);

        // NIST AU-3: Emit session key monitoring events
        if (sessionKeyUsed != address(0)) {
            SessionKey storage sk = _sessionKeys[sessionKeyUsed];
            emit SessionKeyUsed(sessionKeyUsed, userOpHash, block.timestamp, sk.validUntil);
        }

        _payPrefund(missingAccountFunds);
    }

    /**
     * @dev Validate signature with tracking - returns validation data and session key used
     * @return validationData ERC-4337 validation data
     * @return sessionKeyUsed The session key address used (address(0) if owner or failed)
     */
    function _validateSignatureWithTracking(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal returns (uint256 validationData, address sessionKeyUsed) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address signer = hash.recover(userOp.signature);

        // Check owner signature
        if (signer == _owner) {
            return (SIG_VALIDATION_SUCCESS, address(0));
        }

        // Check session key signature
        SessionKey storage sessionKey = _sessionKeys[signer];
        if (sessionKey.key != address(0)) {
            // Validate time window
            if (block.timestamp < sessionKey.validAfter) {
                emit SessionKeyValidationFailed(signer, userOpHash, "not_yet_valid");
                return (_packValidationData(true, sessionKey.validUntil, sessionKey.validAfter), address(0));
            }
            if (block.timestamp > sessionKey.validUntil) {
                emit SessionKeyValidationFailed(signer, userOpHash, "expired");
                return (SIG_VALIDATION_FAILED, address(0));
            }

            // Validate selector if calldata exists
            if (userOp.callData.length >= 4) {
                bytes4 selector = bytes4(userOp.callData[:4]);
                bool selectorAllowed = false;
                for (uint256 i = 0; i < sessionKey.allowedSelectors.length; i++) {
                    if (sessionKey.allowedSelectors[i] == selector) {
                        selectorAllowed = true;
                        break;
                    }
                }
                if (!selectorAllowed) {
                    emit SessionKeyValidationFailed(signer, userOpHash, "selector_not_allowed");
                    return (SIG_VALIDATION_FAILED, address(0));
                }
            }

            // PATCH-16: enforce session key spend limit
            if (sessionKey.spendLimit > 0) {
                uint256 ethValue = _extractValueFromCalldata(userOp.callData);
                if (ethValue > 0) {
                    uint256 newTotal = _sessionKeySpent[signer] + ethValue;
                    if (newTotal > sessionKey.spendLimit) {
                        emit SessionKeyValidationFailed(signer, userOpHash, "spend_limit_exceeded");
                        return (SIG_VALIDATION_FAILED, address(0));
                    }
                    _sessionKeySpent[signer] = newTotal;
                    emit SessionKeySpendRecorded(signer, ethValue, newTotal, sessionKey.spendLimit);
                }
            }

            return (_packValidationData(false, sessionKey.validUntil, sessionKey.validAfter), signer);
        }

        emit SessionKeyValidationFailed(signer, userOpHash, "unknown_signer");
        return (SIG_VALIDATION_FAILED, address(0));
    }

    /**
     * @dev Pack validation data according to ERC-4337
     */
    function _packValidationData(
        bool sigFailed,
        uint48 validUntil,
        uint48 validAfter
    ) internal pure returns (uint256) {
        return (sigFailed ? 1 : 0) | (uint256(validUntil) << 160) | (uint256(validAfter) << (160 + 48));
    }

    /**
     * @dev Pay prefund to EntryPoint
     */
    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds}("");
            (success); // Ignore result - EntryPoint handles validation
        }
    }

    // ============================================
    // EXECUTION
    // ============================================

    /// @inheritdoc ITAGITAccount
    function execute(
        address dest,
        uint256 value,
        bytes calldata func
    ) external override onlyEntryPointOrOwner nonReentrant {
        _call(dest, value, func);
        emit Executed(dest, value, func);
    }

    /// @inheritdoc ITAGITAccount
    function executeBatch(
        address[] calldata dest,
        uint256[] calldata values,
        bytes[] calldata func
    ) external override onlyEntryPointOrOwner nonReentrant {
        if (dest.length != values.length || dest.length != func.length) {
            revert BatchLengthMismatch();
        }

        for (uint256 i = 0; i < dest.length; i++) {
            _call(dest[i], values[i], func[i]);
            emit Executed(dest[i], values[i], func[i]);
        }
    }

    /**
     * @dev PATCH-16: Extract ETH value from execute/executeBatch calldata
     * @param callData The userOp.callData containing the account-level call
     * @return ethValue The total ETH value being sent
     */
    function _extractValueFromCalldata(bytes calldata callData) internal pure returns (uint256 ethValue) {
        if (callData.length < 4) return 0;

        bytes4 selector = bytes4(callData[:4]);

        // execute(address dest, uint256 value, bytes calldata func)
        // ABI: 4 + 32 (address) + 32 (value) = 68 bytes minimum
        bytes4 execSelector = bytes4(keccak256("execute(address,uint256,bytes)"));
        if (selector == execSelector && callData.length >= 68) {
            return uint256(bytes32(callData[36:68]));
        }

        // executeBatch(address[] dest, uint256[] values, bytes[] func)
        // Sum all values from the dynamic array
        bytes4 batchSelector = bytes4(keccak256("executeBatch(address[],uint256[],bytes[])"));
        if (selector == batchSelector && callData.length >= 100) {
            // Values array offset is at position 36-68
            uint256 valuesOffset = uint256(bytes32(callData[36:68]));
            // Values array length is at valuesOffset + 4
            uint256 dataStart = 4 + valuesOffset;
            if (callData.length >= dataStart + 32) {
                uint256 arrLen = uint256(bytes32(callData[dataStart:dataStart + 32]));
                uint256 total = 0;
                for (uint256 i = 0; i < arrLen; i++) {
                    uint256 elemStart = dataStart + 32 + (i * 32);
                    if (callData.length >= elemStart + 32) {
                        total += uint256(bytes32(callData[elemStart:elemStart + 32]));
                    }
                }
                return total;
            }
        }

        return 0;
    }

    function _call(address target, uint256 value, bytes calldata data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            // Bubble up revert reason
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert ExecutionFailed(target, value, data);
        }
    }

    // ============================================
    // SESSION KEY MANAGEMENT
    // ============================================

    /// @inheritdoc ITAGITAccount
    function addSessionKey(SessionKey calldata key) external override onlyOwner {
        if (key.key == address(0)) revert ZeroAddress();
        if (key.validUntil <= key.validAfter) revert SessionKeyExpired(key.key, key.validUntil);
        if (key.validUntil <= uint48(block.timestamp)) revert SessionKeyExpired(key.key, key.validUntil);

        // Enforce max validity
        uint48 maxValidity = uint48(block.timestamp) + MAX_SESSION_KEY_VALIDITY;
        uint48 validUntil = key.validUntil > maxValidity ? maxValidity : key.validUntil;

        _sessionKeys[key.key] = SessionKey({
            key: key.key,
            validAfter: key.validAfter,
            validUntil: validUntil,
            allowedSelectors: key.allowedSelectors,
            spendLimit: key.spendLimit
        });
        _sessionKeySpent[key.key] = 0;

        emit SessionKeyAdded(key.key, key.validAfter, validUntil, key.allowedSelectors);
    }

    /// @inheritdoc ITAGITAccount
    function revokeSessionKey(address key) external override onlyOwner {
        delete _sessionKeys[key];
        delete _sessionKeySpent[key];
        emit SessionKeyRevoked(key);
    }

    /// @inheritdoc ITAGITAccount
    function isValidSessionKey(address key, bytes4 selector) external view override returns (bool) {
        SessionKey storage sk = _sessionKeys[key];
        if (sk.key == address(0)) return false;
        if (block.timestamp < sk.validAfter) return false;
        if (block.timestamp > sk.validUntil) return false;

        for (uint256 i = 0; i < sk.allowedSelectors.length; i++) {
            if (sk.allowedSelectors[i] == selector) return true;
        }
        return false;
    }

    /// @inheritdoc ITAGITAccount
    function getSessionKey(address key) external view override returns (SessionKey memory) {
        return _sessionKeys[key];
    }

    // ============================================
    // GUARDIAN MANAGEMENT
    // ============================================

    /// @inheritdoc ITAGITAccount
    function addGuardian(address guardian, uint8 threshold) external override onlyOwner {
        if (guardian == address(0)) revert ZeroAddress();
        if (_isGuardian[guardian]) revert GuardianAlreadyExists(guardian);
        if (threshold == 0 || threshold > _guardians.length + 1) {
            revert InvalidThreshold(threshold, uint8(_guardians.length + 1));
        }

        _guardianIndex[guardian] = _guardians.length;
        _guardians.push(guardian);
        _isGuardian[guardian] = true;
        _threshold = threshold;

        emit GuardianAdded(guardian, threshold);
    }

    /// @inheritdoc ITAGITAccount
    function removeGuardian(address guardian, uint8 threshold) external override onlyOwner {
        if (!_isGuardian[guardian]) revert GuardianNotFound(guardian);
        if (_guardians.length == 1) revert CannotRemoveLastGuardian();
        if (threshold == 0 || threshold > _guardians.length - 1) {
            revert InvalidThreshold(threshold, uint8(_guardians.length - 1));
        }

        // Swap and pop
        uint256 index = _guardianIndex[guardian];
        uint256 lastIndex = _guardians.length - 1;
        if (index != lastIndex) {
            address lastGuardian = _guardians[lastIndex];
            _guardians[index] = lastGuardian;
            _guardianIndex[lastGuardian] = index;
        }
        _guardians.pop();
        delete _guardianIndex[guardian];
        delete _isGuardian[guardian];
        _threshold = threshold;

        emit GuardianRemoved(guardian, threshold);
    }

    /// @inheritdoc ITAGITAccount
    function requestProtocolGuardianRemoval() external override onlyOwner {
        if (!_protocolGuardian) revert NoPendingRemoval();

        _pendingRemoval = ProtocolGuardianRemoval({
            requestedAt: uint48(block.timestamp),
            executed: false
        });

        uint48 readyAt = uint48(block.timestamp) + PROTOCOL_GUARDIAN_REMOVAL_DELAY;
        emit ProtocolGuardianRemovalRequested(uint48(block.timestamp), readyAt);
    }

    /// @inheritdoc ITAGITAccount
    function removeProtocolGuardian() external override onlyOwner {
        if (!_protocolGuardian) revert NoPendingRemoval();
        if (_pendingRemoval.requestedAt == 0) revert NoPendingRemoval();
        if (_pendingRemoval.executed) revert NoPendingRemoval();

        uint48 readyAt = _pendingRemoval.requestedAt + PROTOCOL_GUARDIAN_REMOVAL_DELAY;
        if (block.timestamp < readyAt) {
            revert RemovalNotReady(_pendingRemoval.requestedAt, readyAt);
        }

        // Find and remove protocol guardian (always at index 0)
        if (_guardians.length > 1) {
            // Move last guardian to index 0
            address lastGuardian = _guardians[_guardians.length - 1];
            _guardians[0] = lastGuardian;
            _guardianIndex[lastGuardian] = 0;
            _guardians.pop();
        } else {
            _guardians.pop();
        }

        _protocolGuardian = false;
        _pendingRemoval.executed = true;

        // Adjust threshold if needed
        if (_threshold > _guardians.length && _guardians.length > 0) {
            _threshold = uint8(_guardians.length);
        }

        emit ProtocolGuardianRemoved();
    }

    /// @inheritdoc ITAGITAccount
    function cancelProtocolGuardianRemoval() external override onlyOwner {
        delete _pendingRemoval;
    }

    /// @inheritdoc ITAGITAccount
    function getGuardianConfig() external view override returns (GuardianConfig memory) {
        return GuardianConfig({
            guardians: _guardians,
            threshold: _threshold,
            recoveryDelay: _recoveryDelay,
            protocolGuardian: _protocolGuardian
        });
    }

    // ============================================
    // SELF-CUSTODY (PRD-002)
    // ============================================

    /// @inheritdoc ITAGITAccount
    function exportAsset(uint256 tokenId, address destination) external override onlyOwner nonReentrant {
        if (destination == address(0)) revert ZeroAddress();
        if (_tagitCore == address(0)) revert ZeroAddress();

        IERC721(_tagitCore).transferFrom(address(this), destination, tokenId);
        emit AssetExported(tokenId, destination);
    }

    /// @inheritdoc ITAGITAccount
    function exportAllAssets(address destination) external override onlyOwner nonReentrant {
        if (destination == address(0)) revert ZeroAddress();
        if (_tagitCore == address(0)) revert ZeroAddress();

        // Get balance and transfer all
        uint256 balance = IERC721(_tagitCore).balanceOf(address(this));
        // Note: This requires enumerable extension or tracking owned tokens
        // For now, emit event - actual implementation would iterate tokens
        emit AllAssetsExported(destination);
    }

    /// @inheritdoc ITAGITAccount
    function requestKeyExport() external override onlyOwner returns (bytes memory) {
        // This would integrate with backend key management
        // Returns empty for on-chain implementation
        return "";
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @inheritdoc ITAGITAccount
    function owner() external view override returns (address) {
        return _owner;
    }

    /// @inheritdoc ITAGITAccount
    function emailHash() external view override returns (bytes32) {
        return _emailHash;
    }

    /// @inheritdoc ITAGITAccount
    function entryPoint() public view override returns (address) {
        return address(_entryPoint);
    }

    /// @inheritdoc ITAGITAccount
    function factory() external view override returns (address) {
        return _factory;
    }

    /// @inheritdoc ITAGITAccount
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Get account nonce from EntryPoint
     */
    function getNonce() public view returns (uint256) {
        return _entryPoint.getNonce(address(this), 0);
    }

    // ============================================
    // RECEIVE
    // ============================================

    receive() external payable {}
}
