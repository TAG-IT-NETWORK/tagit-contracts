// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IEmergencyPauseCoordinator
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for the unified emergency pause coordinator
 * @dev Manages a registry of IEmergencyPauseable contracts and enables
 *      atomic batch pause/unpause across the entire TAG IT protocol.
 *
 * NIST CSF 2.0 Compliance:
 * - RS-RP: Response Planning - single point of emergency control
 * - RS-MI: Mitigation - atomic containment of all protocol contracts
 * - DE-AE: Anomalous Activity Detection - circuit breaker state tracking
 *
 * @custom:security-contact security@tagit.network
 */
interface IEmergencyPauseCoordinator {
    // ============================================
    // ENUMS
    // ============================================

    /// @notice Circuit breaker states for the coordinator
    /// @param ACTIVE Protocol is operating normally
    /// @param PAUSED Protocol is paused (recoverable via unpauseAll)
    /// @param EMERGENCY Protocol is in emergency lockdown (requires admin to clear)
    enum SystemState {
        ACTIVE,
        PAUSED,
        EMERGENCY
    }

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a contract is registered with the coordinator
    /// @param contractAddress The address of the registered contract
    /// @param registeredBy The address that registered the contract
    event ContractRegistered(address indexed contractAddress, address indexed registeredBy);

    /// @notice Emitted when a contract is deregistered from the coordinator
    /// @param contractAddress The address of the deregistered contract
    /// @param deregisteredBy The address that deregistered the contract
    event ContractDeregistered(address indexed contractAddress, address indexed deregisteredBy);

    /// @notice Emitted when all registered contracts are paused
    /// @param triggeredBy The address that triggered the pause
    /// @param contractCount Number of contracts paused
    /// @param timestamp When the pause occurred
    event PauseTriggered(address indexed triggeredBy, uint256 contractCount, uint256 timestamp);

    /// @notice Emitted when all registered contracts are unpaused
    /// @param triggeredBy The address that triggered the unpause
    /// @param contractCount Number of contracts unpaused
    /// @param timestamp When the unpause occurred
    event UnpauseTriggered(address indexed triggeredBy, uint256 contractCount, uint256 timestamp);

    /// @notice Emitted when the system state changes
    /// @param oldState Previous system state
    /// @param newState New system state
    /// @param changedBy Address that changed the state
    event SystemStateChanged(SystemState indexed oldState, SystemState indexed newState, address indexed changedBy);

    /// @notice Emitted when a single contract fails to pause/unpause during batch operation
    /// @param contractAddress The contract that failed
    /// @param reason The revert reason (if available)
    event ContractPauseFailed(address indexed contractAddress, bytes reason);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Returned when trying to register an address that is already registered
    error AlreadyRegistered(address contractAddress);

    /// @notice Returned when trying to deregister an address that is not registered
    error NotRegistered(address contractAddress);

    /// @notice Returned when the provided address is zero
    error ZeroAddress();

    /// @notice Returned when the provided address is not a contract
    error NotAContract(address addr);

    /// @notice Returned when trying to pause while already paused
    error AlreadyPaused();

    /// @notice Returned when trying to unpause while not paused
    error NotPaused();

    /// @notice Returned when trying to operate in an invalid system state
    error InvalidSystemState(SystemState current, SystemState required);

    /// @notice Returned when trying to unpause from EMERGENCY state without admin role
    error EmergencyRequiresAdmin();

    // ============================================
    // FUNCTIONS
    // ============================================

    /// @notice Register a contract for coordinated pause management
    /// @dev Contract must implement IEmergencyPauseable. Only callable by admin.
    /// @param contractAddress The address of the contract to register
    function registerContract(address contractAddress) external;

    /// @notice Remove a contract from coordinated pause management
    /// @dev Only callable by admin.
    /// @param contractAddress The address of the contract to deregister
    function deregisterContract(address contractAddress) external;

    /// @notice Pause all registered contracts atomically
    /// @dev Only callable by accounts with PAUSER_ROLE. Transitions state to PAUSED.
    function pauseAll() external;

    /// @notice Unpause all registered contracts atomically
    /// @dev Only callable by accounts with PAUSER_ROLE (PAUSED state) or
    ///      DEFAULT_ADMIN_ROLE (EMERGENCY state). Transitions state to ACTIVE.
    function unpauseAll() external;

    /// @notice Escalate to emergency state (requires admin to clear)
    /// @dev Only callable by accounts with PAUSER_ROLE. Once in EMERGENCY,
    ///      only admin can call unpauseAll().
    function escalateToEmergency() external;

    /// @notice Get the list of all registered contract addresses
    /// @return Array of registered contract addresses
    function getRegistry() external view returns (address[] memory);

    /// @notice Check if a contract is registered
    /// @param contractAddress The address to check
    /// @return True if the contract is registered
    function isRegistered(address contractAddress) external view returns (bool);

    /// @notice Get the current system state
    /// @return The current SystemState enum value
    function systemState() external view returns (SystemState);

    /// @notice Get the number of registered contracts
    /// @return The count of registered contracts
    function registeredCount() external view returns (uint256);
}
