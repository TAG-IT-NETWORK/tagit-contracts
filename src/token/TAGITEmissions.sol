// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ITAGITEmissions} from "../interfaces/ITAGITEmissions.sol";
import {TAGITToken} from "./TAGITToken.sol";
import {
    INFLATION_RATE,
    EPOCHS_PER_YEAR,
    EPOCH_DURATION,
    BASIS_POINTS,
    VERSION
} from "../libraries/Constants.sol";

/**
 * @title TAGITEmissions
 * @author TAG IT Network <dev@tagit.network>
 * @notice Manages the 3.33% annual inflation distribution for TAGIT tokens
 * @dev Distributes tokens weekly via permissionless epoch triggers
 *
 * Key Features:
 * - Weekly epochs (52 per year)
 * - 3.33% annual inflation rate
 * - Permissionless distribution trigger
 * - Configurable allocation weights (Governor-only)
 * - UUPS upgradeable
 *
 * Inflation Math:
 * Weekly emission = totalSupply * 3.33% / 52 = totalSupply * 333 / (10000 * 52)
 *
 * Default Allocations:
 * - Ecosystem: 50% (incentives, rewards)
 * - Staking: 30% (staking rewards pool)
 * - Treasury: 15% (protocol reserve)
 * - Dev Fund: 5% (development budget)
 *
 * @custom:security-contact security@tagit.network
 */
contract TAGITEmissions is
    ITAGITEmissions,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The TAGIT token contract
    TAGITToken public token;

    /// @notice The epoch number that was last distributed
    uint256 private _lastDistributedEpoch;

    /// @notice Timestamp when emissions started (genesis)
    uint256 private _genesisTimestamp;

    /// @notice Total tokens distributed across all epochs
    uint256 private _totalDistributed;

    /// @notice Current allocation recipients and weights
    Allocation[] private _allocations;

    /// @notice Amount distributed per epoch (epoch => amount)
    mapping(uint256 => uint256) private _epochDistributions;

    /// @notice Governor address for access control
    address public governor;

    /// @notice Maximum epochs that can be caught up in a single call (PATCH-10)
    /// @dev 12 epochs = ~3 months; prevents unbounded gas consumption
    uint256 public constant MAX_CATCH_UP_EPOCHS = 12;

    /// @dev Storage gap for future upgrades (50 slots)
    uint256[43] private __gap;

    // ============================================
    // CONSTRUCTOR (disabled for upgradeable)
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================
    // INITIALIZER
    // ============================================

    /**
     * @notice Initialize the emissions contract
     * @param _token Address of the TAGITToken contract
     * @param _governor Address authorized to update allocations
     * @param initialOwner Owner of the contract (for upgrades)
     */
    function initialize(
        address _token,
        address _governor,
        address initialOwner
    ) public initializer {
        if (_token == address(0)) revert ZeroAddress();
        if (_governor == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        token = TAGITToken(_token);
        governor = _governor;
        _genesisTimestamp = block.timestamp;

        // Set default allocations
        _setDefaultAllocations();

        emit TokenSet(_token);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Restricts access to governor only
     */
    modifier onlyGovernor() {
        if (msg.sender != governor) revert Unauthorized();
        _;
    }

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Distribute tokens for pending epochs with catch-up loop (PATCH-10)
     * @dev Permissionless - anyone can trigger. Loops from _lastDistributedEpoch+1
     *      through currentEpoch(), capped at MAX_CATCH_UP_EPOCHS per call.
     *      Each iteration compounds on the updated totalSupply.
     * @return distributed The total amount of tokens distributed across all caught-up epochs
     * @custom:security Uses nonReentrant to prevent reentrancy during minting
     * @custom:security Capped at MAX_CATCH_UP_EPOCHS (12) to bound gas consumption
     * @custom:emits EpochDistributed (per epoch)
     */
    function distributeEpoch() external nonReentrant returns (uint256 distributed) {
        uint256 current = currentEpoch();

        // Cannot distribute already-distributed epoch
        if (current <= _lastDistributedEpoch) {
            revert EpochAlreadyDistributed(current);
        }

        // PATCH-10: Calculate how many epochs to catch up, capped at MAX_CATCH_UP_EPOCHS
        uint256 pendingEpochs = current - _lastDistributedEpoch;
        uint256 epochsToDistribute = pendingEpochs > MAX_CATCH_UP_EPOCHS
            ? MAX_CATCH_UP_EPOCHS
            : pendingEpochs;

        uint256 startEpoch = _lastDistributedEpoch + 1;

        for (uint256 i = 0; i < epochsToDistribute;) {
            uint256 epoch = startEpoch + i;

            // Compounds: each iteration uses updated totalSupply (after previous mints)
            uint256 totalSupply = token.totalSupply();
            uint256 weeklyAmount = (totalSupply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR);

            // Distribute to each allocation
            uint256 allocLength = _allocations.length;
            for (uint256 j = 0; j < allocLength;) {
                uint256 share = (weeklyAmount * _allocations[j].weight) / BASIS_POINTS;
                if (share > 0) {
                    token.mint(_allocations[j].recipient, share);
                }
                unchecked { ++j; }
            }

            _epochDistributions[epoch] = weeklyAmount;
            _totalDistributed += weeklyAmount;
            distributed += weeklyAmount;

            emit EpochDistributed(epoch, weeklyAmount, block.timestamp);

            unchecked { ++i; }
        }

        // Update last distributed epoch (may not reach currentEpoch if capped)
        _lastDistributedEpoch = startEpoch + epochsToDistribute - 1;

        return distributed;
    }

    // ============================================
    // GOVERNOR FUNCTIONS
    // ============================================

    /**
     * @notice Update allocation weights
     * @dev Only callable by governor. Weights must sum to exactly BASIS_POINTS (10000).
     * @param recipients Array of recipient addresses
     * @param weights Array of weights in basis points
     * @custom:security Validates no zero addresses and weights sum correctly
     * @custom:emits AllocationsUpdated
     */
    function setAllocationWeights(
        address[] calldata recipients,
        uint256[] calldata weights
    ) external onlyGovernor {
        if (recipients.length == 0) revert EmptyAllocations();
        if (recipients.length != weights.length) revert ArrayLengthMismatch();

        // Validate weights sum to BASIS_POINTS
        uint256 totalWeight = 0;
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len;) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            totalWeight += weights[i];
            unchecked { ++i; }
        }

        if (totalWeight != BASIS_POINTS) {
            revert InvalidAllocationWeights(totalWeight);
        }

        // Clear existing allocations
        delete _allocations;

        // Set new allocations
        for (uint256 i = 0; i < len;) {
            _allocations.push(Allocation({
                recipient: recipients[i],
                weight: weights[i]
            }));
            unchecked { ++i; }
        }

        emit AllocationsUpdated(recipients, weights);
    }

    /**
     * @notice Update the governor address
     * @dev Only callable by owner (for emergencies/transitions)
     * @param newGovernor The new governor address
     * @custom:emits GovernorUpdated
     */
    function setGovernor(address newGovernor) external onlyOwner {
        if (newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = governor;
        governor = newGovernor;
        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the current epoch number
     * @dev Epoch 0 is the week of genesis, epoch 1 is the next week, etc.
     * @return The current epoch based on time since genesis
     */
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - _genesisTimestamp) / EPOCH_DURATION;
    }

    /**
     * @notice Get the timestamp of the next distribution window
     * @return The Unix timestamp when the next epoch begins
     */
    function nextDistributionTime() external view returns (uint256) {
        uint256 nextEpoch = _lastDistributedEpoch + 1;
        return _genesisTimestamp + (nextEpoch * EPOCH_DURATION);
    }

    /**
     * @notice Get the last distributed epoch number
     * @return The epoch number that was last distributed
     */
    function lastDistributedEpoch() external view returns (uint256) {
        return _lastDistributedEpoch;
    }

    /**
     * @notice Get all current allocations
     * @return Array of Allocation structs
     */
    function getAllocations() external view returns (Allocation[] memory) {
        return _allocations;
    }

    /**
     * @notice Get allocation count
     * @return Number of allocations
     */
    function allocationCount() external view returns (uint256) {
        return _allocations.length;
    }

    /**
     * @notice Get the amount distributed in a specific epoch
     * @param epoch The epoch number to query
     * @return The amount of tokens distributed in that epoch
     */
    function epochDistribution(uint256 epoch) external view returns (uint256) {
        return _epochDistributions[epoch];
    }

    /**
     * @notice Get total tokens distributed across all epochs
     * @return The cumulative total of all distributions
     */
    function totalDistributed() external view returns (uint256) {
        return _totalDistributed;
    }

    /**
     * @notice Get the genesis timestamp
     * @return The timestamp when emissions started
     */
    function genesisTimestamp() external view returns (uint256) {
        return _genesisTimestamp;
    }

    /**
     * @notice Check if current epoch can be distributed
     * @return True if distribution is available
     */
    function canDistribute() external view returns (bool) {
        return currentEpoch() > _lastDistributedEpoch;
    }

    /**
     * @notice Calculate the pending distribution amount across all pending epochs (PATCH-10)
     * @dev Estimates compounding across pending epochs (capped at MAX_CATCH_UP_EPOCHS).
     *      Actual distribution may differ slightly due to compounding.
     * @return The estimated total amount that would be distributed
     */
    function pendingDistribution() external view returns (uint256) {
        uint256 current = currentEpoch();
        if (current <= _lastDistributedEpoch) {
            return 0;
        }
        uint256 pendingEpochs = current - _lastDistributedEpoch;
        uint256 epochsToEstimate = pendingEpochs > MAX_CATCH_UP_EPOCHS
            ? MAX_CATCH_UP_EPOCHS
            : pendingEpochs;
        uint256 weeklyRate = INFLATION_RATE;
        uint256 supply = token.totalSupply();
        uint256 total = 0;
        for (uint256 i = 0; i < epochsToEstimate;) {
            uint256 amount = (supply * weeklyRate) / (BASIS_POINTS * EPOCHS_PER_YEAR);
            total += amount;
            supply += amount; // simulate compounding
            unchecked { ++i; }
        }
        return total;
    }

    /**
     * @notice Get the contract version
     * @return Current version string
     */
    function version() external pure returns (string memory) {
        return VERSION;
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Set default allocations on initialization
     * @dev Called once during initialize. Sets standard allocation weights.
     */
    function _setDefaultAllocations() internal {
        // Default allocations:
        // - Ecosystem: 50% (rewards, incentives)
        // - Staking: 30% (staking rewards pool)
        // - Treasury: 15% (protocol reserve)
        // - Dev Fund: 5% (development budget)

        // Note: These use placeholder addresses - real deployment should
        // call setAllocationWeights with actual contract addresses

        // For now, all goes to owner (will be updated post-deployment)
        _allocations.push(Allocation({
            recipient: msg.sender,  // Placeholder - update via setAllocationWeights
            weight: BASIS_POINTS    // 100% until properly configured
        }));
    }

    // ============================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================

    /**
     * @notice Authorize contract upgrades
     * @dev Only owner can authorize upgrades
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
