// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITEmissions
 * @notice Interface for the TAGIT token emissions/inflation contract
 */
interface ITAGITEmissions {
    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Allocation recipient and weight
    struct Allocation {
        address recipient;
        uint256 weight; // Basis points (must sum to 10000)
    }

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when weekly epoch distribution occurs
    event EpochDistributed(uint256 indexed epoch, uint256 amount, uint256 timestamp);

    /// @notice Emitted when allocation weights are updated
    event AllocationsUpdated(address[] recipients, uint256[] weights);

    /// @notice Emitted when token contract is set
    event TokenSet(address indexed token);

    /// @notice Emitted when governor is updated
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when attempting to distribute an already-distributed epoch
    error EpochAlreadyDistributed(uint256 epoch);

    /// @notice Thrown when allocation weights don't sum to BASIS_POINTS
    error InvalidAllocationWeights(uint256 totalWeight);

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when arrays have mismatched lengths
    error ArrayLengthMismatch();

    /// @notice Thrown when allocations array is empty
    error EmptyAllocations();

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Distribute tokens for the current epoch
     * @dev Permissionless - anyone can trigger distribution
     * @return distributed The total amount of tokens distributed
     */
    function distributeEpoch() external returns (uint256 distributed);

    // ============================================
    // GOVERNOR FUNCTIONS
    // ============================================

    /**
     * @notice Update allocation weights (Governor only)
     * @param recipients Array of recipient addresses
     * @param weights Array of weights in basis points (must sum to 10000)
     */
    function setAllocationWeights(address[] calldata recipients, uint256[] calldata weights) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the current epoch number
     * @return The current epoch based on time since genesis
     */
    function currentEpoch() external view returns (uint256);

    /**
     * @notice Get the timestamp of the next distribution
     * @return The Unix timestamp when next epoch becomes distributable
     */
    function nextDistributionTime() external view returns (uint256);

    /**
     * @notice Get the last distributed epoch number
     * @return The epoch number that was last distributed
     */
    function lastDistributedEpoch() external view returns (uint256);

    /**
     * @notice Get all current allocations
     * @return Array of Allocation structs
     */
    function getAllocations() external view returns (Allocation[] memory);

    /**
     * @notice Get the amount distributed in a specific epoch
     * @param epoch The epoch number to query
     * @return The amount of tokens distributed in that epoch
     */
    function epochDistribution(uint256 epoch) external view returns (uint256);

    /**
     * @notice Get total tokens distributed across all epochs
     * @return The cumulative total of all distributions
     */
    function totalDistributed() external view returns (uint256);

    /**
     * @notice Get the genesis timestamp
     * @return The timestamp when emissions started
     */
    function genesisTimestamp() external view returns (uint256);
}
