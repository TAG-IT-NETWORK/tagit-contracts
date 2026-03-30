// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IEmergencyPauseable} from "../../src/interfaces/IEmergencyPauseable.sol";

/**
 * @title MockPauseableContract
 * @notice Mock contract implementing IEmergencyPauseable for testing
 */
contract MockPauseableContract is Pausable, IEmergencyPauseable {
    address private _coordinator;
    bool private _shouldFailPause;
    bool private _shouldFailUnpause;

    error ForcedPauseFailure();
    error ForcedUnpauseFailure();

    constructor(address coordinator_) {
        if (coordinator_ == address(0)) revert CoordinatorZeroAddress();
        _coordinator = coordinator_;
    }

    modifier onlyCoordinator() {
        if (msg.sender != _coordinator) revert OnlyCoordinator(msg.sender, _coordinator);
        _;
    }

    function coordinatorPause() external override onlyCoordinator {
        if (_shouldFailPause) revert ForcedPauseFailure();
        _pause();
    }

    function coordinatorUnpause() external override onlyCoordinator {
        if (_shouldFailUnpause) revert ForcedUnpauseFailure();
        _unpause();
    }

    function isPaused() external view override returns (bool) {
        return paused();
    }

    function emergencyCoordinator() external view override returns (address) {
        return _coordinator;
    }

    // Test helpers
    function setShouldFailPause(bool shouldFail) external {
        _shouldFailPause = shouldFail;
    }

    function setShouldFailUnpause(bool shouldFail) external {
        _shouldFailUnpause = shouldFail;
    }
}
