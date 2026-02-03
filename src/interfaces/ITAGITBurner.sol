// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITBurner
 * @notice Interface for the TAGIT fee burning contract
 * @dev Routes protocol fees with configurable burn/treasury split
 */
interface ITAGITBurner {
    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when fees are routed through the burner
    event FeeRouted(uint256 amount, uint256 burned, uint256 toTreasury);

    /// @notice Emitted when burn rate is updated
    event BurnRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when treasury address is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when governor is updated
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when burn rate is below the immutable floor
    error BurnRateBelowFloor(uint256 requested, uint256 floor);

    /// @notice Thrown when burn rate exceeds 100%
    error BurnRateExceedsMax(uint256 requested);

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Route protocol fees through burn/treasury split
     * @dev Burns burnRate% of tokens, sends remainder to treasury
     * @param amount The total fee amount to route
     */
    function routeFee(uint256 amount) external;

    // ============================================
    // GOVERNOR FUNCTIONS
    // ============================================

    /**
     * @notice Update the burn rate
     * @dev Must be >= BURN_FLOOR (3.33%) and <= 100%
     * @param newRate New burn rate in basis points
     */
    function setBurnRate(uint256 newRate) external;

    /**
     * @notice Update the treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the current burn rate
     * @return Current burn rate in basis points
     */
    function burnRate() external view returns (uint256);

    /**
     * @notice Get total tokens burned
     * @return Cumulative burned tokens
     */
    function totalBurned() external view returns (uint256);

    /**
     * @notice Get total tokens sent to treasury
     * @return Cumulative tokens sent to treasury
     */
    function totalToTreasury() external view returns (uint256);

    /**
     * @notice Get the treasury address
     * @return Current treasury address
     */
    function treasury() external view returns (address);

    /**
     * @notice Get the governor address
     * @return Current governor address
     */
    function governor() external view returns (address);
}
