// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TAGITCore} from "../../src/core/TAGITCore.sol";

/**
 * @title TAGITCoreV2Mock
 * @notice Minimal V2 implementation for upgrade compatibility testing
 * @dev Adds one new storage variable (consuming 1 gap slot) and a new function.
 *      Used to validate that UUPS upgrades preserve V1 state and that the gap
 *      mechanism works correctly.
 */
contract TAGITCoreV2Mock is TAGITCore {
    /// @notice New V2 storage variable (consumes 1 slot from __gap, reducing it to 33)
    uint256 public newFeatureFlag;

    /// @notice V2 storage gap (reduced from 34 to 33 after adding newFeatureFlag)
    uint256[33] private __gapV2;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice V2-specific initializer (reinitializer(2) — callable once after upgrade)
    function initializeV2(uint256 _featureFlag) external reinitializer(2) {
        newFeatureFlag = _featureFlag;
    }

    /// @notice Set the new feature flag (owner-only)
    function setNewFeature(uint256 val) external onlyOwner {
        newFeatureFlag = val;
    }

    /// @notice Returns the V2 version string
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}
