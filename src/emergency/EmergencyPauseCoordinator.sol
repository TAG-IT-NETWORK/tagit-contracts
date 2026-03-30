// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IEmergencyPauseCoordinator} from "../interfaces/IEmergencyPauseCoordinator.sol";
import {IEmergencyPauseable} from "../interfaces/IEmergencyPauseable.sol";

/**
 * @title EmergencyPauseCoordinator
 * @author TAG IT Network <dev@tagit.network>
 * @notice Unified emergency pause coordinator for all TAG IT protocol contracts
 * @dev Manages a registry of IEmergencyPauseable contracts and provides atomic
 *      batch pause/unpause with circuit-breaker state management.
 *
 * Architecture:
 * - Uses OpenZeppelin AccessControl for role-based permissions
 * - Uses EnumerableSet for O(1) add/remove/contains on contract registry
 * - Circuit-breaker pattern: ACTIVE -> PAUSED -> ACTIVE (normal)
 * - Escalation path: ACTIVE/PAUSED -> EMERGENCY (requires admin to clear)
 *
 * NIST CSF 2.0 Compliance:
 * - RS-RP: Response Planning - centralized emergency control
 * - RS-MI: Mitigation - automated protocol containment
 * - DE-AE: Anomalous Activity Detection - circuit breaker states
 * - PR-AC: Access Control - role-based pause authority
 *
 * STRIDE Analysis:
 * - Spoofing: AccessControl roles prevent unauthorized pause
 * - Tampering: Registry mutations restricted to admin role
 * - Repudiation: Events emitted for all state changes
 * - Info Disclosure: No sensitive data stored
 * - DoS: Individual contract failures don't block batch operations
 * - Elevation: PAUSER_ROLE cannot clear EMERGENCY state
 *
 * @custom:security-contact security@tagit.network
 */
contract EmergencyPauseCoordinator is AccessControl, IEmergencyPauseCoordinator {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Role identifier for accounts authorized to pause/unpause
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Set of registered pauseable contract addresses
    EnumerableSet.AddressSet private _registry;

    /// @notice Current circuit-breaker state
    SystemState private _systemState;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the EmergencyPauseCoordinator
     * @param admin The address that receives DEFAULT_ADMIN_ROLE
     * @param pauser The initial address that receives PAUSER_ROLE
     */
    constructor(address admin, address pauser) {
        if (admin == address(0)) revert ZeroAddress();
        if (pauser == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        _systemState = SystemState.ACTIVE;
    }

    // ============================================
    // REGISTRY MANAGEMENT
    // ============================================

    /// @inheritdoc IEmergencyPauseCoordinator
    function registerContract(address contractAddress) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (contractAddress == address(0)) revert ZeroAddress();
        if (contractAddress.code.length == 0) revert NotAContract(contractAddress);
        if (_registry.contains(contractAddress)) revert AlreadyRegistered(contractAddress);

        _registry.add(contractAddress);

        emit ContractRegistered(contractAddress, msg.sender);
    }

    /// @inheritdoc IEmergencyPauseCoordinator
    function deregisterContract(address contractAddress) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (contractAddress == address(0)) revert ZeroAddress();
        if (!_registry.contains(contractAddress)) revert NotRegistered(contractAddress);

        _registry.remove(contractAddress);

        emit ContractDeregistered(contractAddress, msg.sender);
    }

    // ============================================
    // PAUSE / UNPAUSE
    // ============================================

    /// @inheritdoc IEmergencyPauseCoordinator
    function pauseAll() external override onlyRole(PAUSER_ROLE) {
        if (_systemState != SystemState.ACTIVE) {
            revert AlreadyPaused();
        }

        SystemState oldState = _systemState;
        _systemState = SystemState.PAUSED;

        uint256 count = _registry.length();
        for (uint256 i; i < count; ++i) {
            address target = _registry.at(i);
            try IEmergencyPauseable(target).coordinatorPause() {}
            catch (bytes memory reason) {
                emit ContractPauseFailed(target, reason);
            }
        }

        emit SystemStateChanged(oldState, SystemState.PAUSED, msg.sender);
        emit PauseTriggered(msg.sender, count, block.timestamp);
    }

    /// @inheritdoc IEmergencyPauseCoordinator
    function unpauseAll() external override {
        if (_systemState == SystemState.ACTIVE) {
            revert NotPaused();
        }

        if (_systemState == SystemState.EMERGENCY) {
            if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert EmergencyRequiresAdmin();
            }
        } else {
            // PAUSED state - PAUSER_ROLE can unpause
            if (!hasRole(PAUSER_ROLE, msg.sender)) {
                revert AccessControlUnauthorizedAccount(msg.sender, PAUSER_ROLE);
            }
        }

        SystemState oldState = _systemState;
        _systemState = SystemState.ACTIVE;

        uint256 count = _registry.length();
        for (uint256 i; i < count; ++i) {
            address target = _registry.at(i);
            try IEmergencyPauseable(target).coordinatorUnpause() {}
            catch (bytes memory reason) {
                emit ContractPauseFailed(target, reason);
            }
        }

        emit SystemStateChanged(oldState, SystemState.ACTIVE, msg.sender);
        emit UnpauseTriggered(msg.sender, count, block.timestamp);
    }

    /// @inheritdoc IEmergencyPauseCoordinator
    function escalateToEmergency() external override onlyRole(PAUSER_ROLE) {
        if (_systemState == SystemState.EMERGENCY) {
            revert InvalidSystemState(_systemState, SystemState.PAUSED);
        }

        SystemState oldState = _systemState;

        // If currently ACTIVE, pause all contracts first
        if (_systemState == SystemState.ACTIVE) {
            uint256 count = _registry.length();
            for (uint256 i; i < count; ++i) {
                address target = _registry.at(i);
                try IEmergencyPauseable(target).coordinatorPause() {}
                catch (bytes memory reason) {
                    emit ContractPauseFailed(target, reason);
                }
            }
            emit PauseTriggered(msg.sender, count, block.timestamp);
        }

        _systemState = SystemState.EMERGENCY;

        emit SystemStateChanged(oldState, SystemState.EMERGENCY, msg.sender);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @inheritdoc IEmergencyPauseCoordinator
    function getRegistry() external view override returns (address[] memory) {
        return _registry.values();
    }

    /// @inheritdoc IEmergencyPauseCoordinator
    function isRegistered(address contractAddress) external view override returns (bool) {
        return _registry.contains(contractAddress);
    }

    /// @inheritdoc IEmergencyPauseCoordinator
    function systemState() external view override returns (SystemState) {
        return _systemState;
    }

    /// @inheritdoc IEmergencyPauseCoordinator
    function registeredCount() external view override returns (uint256) {
        return _registry.length();
    }
}
