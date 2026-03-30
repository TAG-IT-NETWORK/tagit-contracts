// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IEmergencyPauseable
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for contracts that can be paused by the EmergencyPauseCoordinator
 * @dev Implement this interface on any contract that should participate in
 *      coordinated emergency pauses across the TAG IT protocol.
 *
 * NIST CSF 2.0 Compliance:
 * - RS-RP: Response Planning - coordinated incident response
 * - RS-MI: Mitigation - automated containment via pause
 *
 * @custom:security-contact security@tagit.network
 */
interface IEmergencyPauseable {
    /// @notice Emitted when the emergency pause coordinator address is updated
    /// @param oldCoordinator The previous coordinator address
    /// @param newCoordinator The new coordinator address
    event CoordinatorUpdated(address indexed oldCoordinator, address indexed newCoordinator);

    /// @notice Returned when the caller is not the registered coordinator
    error OnlyCoordinator(address caller, address coordinator);

    /// @notice Returned when attempting to set coordinator to the zero address
    error CoordinatorZeroAddress();

    /// @notice Pause this contract via the emergency coordinator
    /// @dev MUST only be callable by the registered EmergencyPauseCoordinator.
    ///      Implementations should call `_pause()` from OpenZeppelin Pausable.
    function coordinatorPause() external;

    /// @notice Unpause this contract via the emergency coordinator
    /// @dev MUST only be callable by the registered EmergencyPauseCoordinator.
    ///      Implementations should call `_unpause()` from OpenZeppelin Pausable.
    function coordinatorUnpause() external;

    /// @notice Check whether this contract is currently paused
    /// @return True if the contract is paused
    function isPaused() external view returns (bool);

    /// @notice Get the address of the registered emergency coordinator
    /// @return The coordinator contract address
    function emergencyCoordinator() external view returns (address);
}
