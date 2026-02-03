// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITAGITBurner} from "../interfaces/ITAGITBurner.sol";
import {TAGITToken} from "./TAGITToken.sol";
import {
    BURN_FLOOR,
    DEFAULT_BURN_RATE,
    BASIS_POINTS,
    VERSION
} from "../libraries/Constants.sol";

/**
 * @title TAGITBurner
 * @author TAG IT Network <dev@tagit.network>
 * @notice Routes protocol fees with configurable burn/treasury split
 * @dev Burns a percentage of fees and sends remainder to treasury
 *
 * Key Features:
 * - Configurable burn rate (default 33.3%)
 * - Immutable burn floor (3.33% minimum - can NEVER go below)
 * - Permissionless fee routing
 * - Governor-controlled rate updates
 * - UUPS upgradeable
 *
 * Fee Math:
 * burnAmount = amount * burnRate / 10000
 * treasuryAmount = amount - burnAmount
 *
 * Security:
 * - BURN_FLOOR is immutable and enforced on every setBurnRate call
 * - ReentrancyGuard prevents reentrancy attacks
 * - Zero address validation on all address parameters
 *
 * @custom:security-contact security@tagit.network
 */
contract TAGITBurner is
    ITAGITBurner,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The TAGIT token contract
    TAGITToken public token;

    /// @notice Treasury address for fee distribution
    address private _treasury;

    /// @notice Governor address for access control
    address public governor;

    /// @notice Current burn rate in basis points
    uint256 private _burnRate;

    /// @notice Cumulative tokens burned
    uint256 private _totalBurned;

    /// @notice Cumulative tokens sent to treasury
    uint256 private _totalToTreasury;

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
     * @notice Initialize the burner contract
     * @param _token Address of the TAGITToken contract
     * @param treasury_ Address of the treasury
     * @param _governor Address authorized to update burn rate
     * @param initialOwner Owner of the contract (for upgrades)
     */
    function initialize(
        address _token,
        address treasury_,
        address _governor,
        address initialOwner
    ) public initializer {
        if (_token == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (_governor == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        token = TAGITToken(_token);
        _treasury = treasury_;
        governor = _governor;
        _burnRate = DEFAULT_BURN_RATE; // 33.3% default

        emit TreasuryUpdated(address(0), treasury_);
        emit BurnRateUpdated(0, DEFAULT_BURN_RATE);
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
     * @notice Route protocol fees through burn/treasury split
     * @dev Transfers tokens from caller, burns portion, sends rest to treasury
     * @param amount The total fee amount to route
     * @custom:security Uses nonReentrant to prevent reentrancy
     * @custom:emits FeeRouted
     */
    function routeFee(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Transfer tokens from caller to this contract
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate split
        uint256 burnAmount = (amount * _burnRate) / BASIS_POINTS;
        uint256 treasuryAmount = amount - burnAmount;

        // Burn tokens
        if (burnAmount > 0) {
            token.burn(burnAmount);
            _totalBurned += burnAmount;
        }

        // Send to treasury
        if (treasuryAmount > 0) {
            IERC20(address(token)).safeTransfer(_treasury, treasuryAmount);
            _totalToTreasury += treasuryAmount;
        }

        emit FeeRouted(amount, burnAmount, treasuryAmount);
    }

    // ============================================
    // GOVERNOR FUNCTIONS
    // ============================================

    /**
     * @notice Update the burn rate
     * @dev Must be >= BURN_FLOOR (3.33%) and <= BASIS_POINTS (100%)
     * @param newRate New burn rate in basis points
     * @custom:security BURN_FLOOR is immutable - can never set rate below 3.33%
     * @custom:emits BurnRateUpdated
     */
    function setBurnRate(uint256 newRate) external onlyGovernor {
        if (newRate < BURN_FLOOR) revert BurnRateBelowFloor(newRate, BURN_FLOOR);
        if (newRate > BASIS_POINTS) revert BurnRateExceedsMax(newRate);

        uint256 oldRate = _burnRate;
        _burnRate = newRate;

        emit BurnRateUpdated(oldRate, newRate);
    }

    /**
     * @notice Update the treasury address
     * @dev Only callable by governor
     * @param newTreasury New treasury address
     * @custom:emits TreasuryUpdated
     */
    function setTreasury(address newTreasury) external onlyGovernor {
        if (newTreasury == address(0)) revert ZeroAddress();

        address oldTreasury = _treasury;
        _treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
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
     * @notice Get the current burn rate
     * @return Current burn rate in basis points
     */
    function burnRate() external view returns (uint256) {
        return _burnRate;
    }

    /**
     * @notice Get total tokens burned
     * @return Cumulative burned tokens
     */
    function totalBurned() external view returns (uint256) {
        return _totalBurned;
    }

    /**
     * @notice Get total tokens sent to treasury
     * @return Cumulative tokens sent to treasury
     */
    function totalToTreasury() external view returns (uint256) {
        return _totalToTreasury;
    }

    /**
     * @notice Get the treasury address
     * @return Current treasury address
     */
    function treasury() external view returns (address) {
        return _treasury;
    }

    /**
     * @notice Get the immutable burn floor
     * @return Minimum burn rate in basis points (333 = 3.33%)
     */
    function burnFloor() external pure returns (uint256) {
        return BURN_FLOOR;
    }

    /**
     * @notice Get the contract version
     * @return Current version string
     */
    function version() external pure returns (string memory) {
        return VERSION;
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
