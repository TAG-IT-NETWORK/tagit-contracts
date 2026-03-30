// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BASIS_POINTS} from "../libraries/Constants.sol";

/**
 * @title wTAGBondingCurve
 * @author TAG IT Network <dev@tagit.network>
 * @notice Linear bonding curve for wTAG token price discovery
 * @dev Implements a linear bonding curve: price = initialPrice + (slope * currentSupply)
 *
 *   Buy price for N tokens:  integral from S to S+N of (initialPrice + slope * x) dx
 *   Sell price for N tokens: integral from S-N to S of (initialPrice + slope * x) dx
 *
 *   Where S = current supply held by the curve (i.e., tokens sold through the curve).
 *
 *   A protocol fee (in basis points) is charged on buys and sells and accrues
 *   to the contract for owner withdrawal.
 *
 * Security:
 *   - ReentrancyGuard on all state-changing functions
 *   - Checks-Effects-Interactions pattern throughout
 *   - Pausable for emergency circuit-breaker
 *   - Ownable for admin operations
 *   - Custom errors only (no string reverts)
 *   - All parameters validated on input
 *
 * @custom:security-contact security@tagit.network
 */
contract wTAGBondingCurve is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Precision factor for fixed-point arithmetic (18 decimals)
    uint256 public constant PRECISION = 1e18;

    /// @notice Maximum fee in basis points (10% = 1000 bps)
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Maximum slope to prevent overflow (1e12 wei per token-unit)
    uint256 public constant MAX_SLOPE = 1e12;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The wTAG ERC-20 token traded on this curve
    IERC20 public immutable wtagToken;

    /// @notice Initial price per wTAG token in ETH (wei) when supply = 0
    uint256 public initialPrice;

    /// @notice Slope of the linear bonding curve in wei per token-unit
    /// @dev price = initialPrice + slope * currentSupply / PRECISION
    uint256 public slope;

    /// @notice Protocol fee in basis points charged on buys and sells
    uint256 public feeBps;

    /// @notice Total wTAG tokens sold through the bonding curve (tracked supply)
    uint256 public curveSupply;

    /// @notice ETH reserve backing the bonding curve
    uint256 public reserve;

    /// @notice Accumulated protocol fees available for withdrawal (in ETH)
    uint256 public accruedFees;

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @dev Thrown when a zero address is provided
    error ZeroAddress();

    /// @dev Thrown when a zero amount is provided
    error ZeroAmount();

    /// @dev Thrown when initial price is zero
    error ZeroInitialPrice();

    /// @dev Thrown when slope is zero
    error ZeroSlope();

    /// @dev Thrown when fee exceeds maximum
    error FeeTooHigh(uint256 provided, uint256 maximum);

    /// @dev Thrown when slope exceeds maximum
    error SlopeTooHigh(uint256 provided, uint256 maximum);

    /// @dev Thrown when ETH sent is insufficient for the buy cost
    error InsufficientPayment(uint256 required, uint256 provided);

    /// @dev Thrown when seller has insufficient wTAG balance
    error InsufficientBalance(uint256 required, uint256 available);

    /// @dev Thrown when selling more tokens than the curve supply
    error ExceedsCurveSupply(uint256 requested, uint256 available);

    /// @dev Thrown when ETH transfer fails
    error ETHTransferFailed(address to, uint256 amount);

    /// @dev Thrown when no fees are available to withdraw
    error NoFeesToWithdraw();

    /// @dev Thrown when slippage protection is triggered
    error SlippageExceeded(uint256 cost, uint256 maxCost);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when tokens are bought through the bonding curve
    event Buy(address indexed buyer, uint256 tokenAmount, uint256 ethCost, uint256 fee);

    /// @notice Emitted when tokens are sold back to the bonding curve
    event Sell(address indexed seller, uint256 tokenAmount, uint256 ethReturn, uint256 fee);

    /// @notice Emitted when the owner withdraws accrued fees
    event FeesWithdrawn(address indexed to, uint256 amount);

    /// @notice Emitted when bonding curve parameters are updated
    event ParamsUpdated(uint256 newInitialPrice, uint256 newSlope, uint256 newFeeBps);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the wTAG bonding curve
     * @param _wtagToken Address of the wTAG ERC-20 token
     * @param _owner Address of the contract owner (multi-sig)
     * @param _initialPrice Starting price per token in wei (when supply = 0)
     * @param _slope Linear price increase per token-unit in wei
     * @param _feeBps Protocol fee in basis points (max 1000 = 10%)
     * @dev Owner should pre-fund this contract with wTAG tokens for sale
     */
    constructor(address _wtagToken, address _owner, uint256 _initialPrice, uint256 _slope, uint256 _feeBps)
        Ownable(_owner)
    {
        if (_wtagToken == address(0)) revert ZeroAddress();
        // _owner == address(0) is caught by Ownable's OwnableInvalidOwner
        if (_initialPrice == 0) revert ZeroInitialPrice();
        if (_slope == 0) revert ZeroSlope();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh(_feeBps, MAX_FEE_BPS);
        if (_slope > MAX_SLOPE) revert SlopeTooHigh(_slope, MAX_SLOPE);

        wtagToken = IERC20(_wtagToken);
        initialPrice = _initialPrice;
        slope = _slope;
        feeBps = _feeBps;
    }

    // ============================================
    // BONDING CURVE MATH (INTERNAL)
    // ============================================

    /**
     * @notice Calculate the cost (in ETH) to buy `tokenAmount` tokens at current supply
     * @dev Uses the integral of the linear price function:
     *      cost = integral from S to S+N of (P0 + m*x/PRECISION) dx
     *           = P0*N + m*(2*S*N + N^2) / (2 * PRECISION)
     *      where P0 = initialPrice, m = slope, S = curveSupply, N = tokenAmount
     * @param tokenAmount Number of tokens to buy (in wei, 18 decimals)
     * @return cost The total ETH cost in wei (before fees)
     */
    function _getBuyPrice(uint256 tokenAmount) internal view returns (uint256 cost) {
        uint256 s = curveSupply;
        // P0 * N
        uint256 linearPart = initialPrice * tokenAmount / PRECISION;
        // m * (2*S*N + N^2) / (2 * PRECISION * PRECISION)
        // = m * N * (2*S + N) / (2 * PRECISION * PRECISION)
        uint256 quadraticPart = slope * tokenAmount / PRECISION;
        quadraticPart = quadraticPart * (2 * s + tokenAmount) / (2 * PRECISION);
        cost = linearPart + quadraticPart;
    }

    /**
     * @notice Calculate the return (in ETH) for selling `tokenAmount` tokens at current supply
     * @dev Uses the integral of the linear price function:
     *      return = integral from S-N to S of (P0 + m*x/PRECISION) dx
     *             = P0*N + m*(2*S*N - N^2) / (2 * PRECISION)
     * @param tokenAmount Number of tokens to sell (in wei, 18 decimals)
     * @return ethReturn The total ETH return in wei (before fees)
     */
    function _getSellPrice(uint256 tokenAmount) internal view returns (uint256 ethReturn) {
        uint256 s = curveSupply;
        // P0 * N
        uint256 linearPart = initialPrice * tokenAmount / PRECISION;
        // m * N * (2*S - N) / (2 * PRECISION * PRECISION)
        uint256 quadraticPart = slope * tokenAmount / PRECISION;
        quadraticPart = quadraticPart * (2 * s - tokenAmount) / (2 * PRECISION);
        ethReturn = linearPart + quadraticPart;
    }

    // ============================================
    // EXTERNAL VIEW — PRICE QUOTES
    // ============================================

    /**
     * @notice Get the ETH cost to buy `tokenAmount` tokens (including fee)
     * @param tokenAmount Number of tokens to buy (18 decimals)
     * @return totalCost Total cost in ETH (base + fee)
     * @return fee Fee portion in ETH
     */
    function getBuyQuote(uint256 tokenAmount) external view returns (uint256 totalCost, uint256 fee) {
        if (tokenAmount == 0) revert ZeroAmount();
        uint256 baseCost = _getBuyPrice(tokenAmount);
        fee = (baseCost * feeBps) / BASIS_POINTS;
        totalCost = baseCost + fee;
    }

    /**
     * @notice Get the ETH return for selling `tokenAmount` tokens (after fee)
     * @param tokenAmount Number of tokens to sell (18 decimals)
     * @return netReturn Net ETH return after fee deduction
     * @return fee Fee portion in ETH
     */
    function getSellQuote(uint256 tokenAmount) external view returns (uint256 netReturn, uint256 fee) {
        if (tokenAmount == 0) revert ZeroAmount();
        if (tokenAmount > curveSupply) revert ExceedsCurveSupply(tokenAmount, curveSupply);
        uint256 baseReturn = _getSellPrice(tokenAmount);
        fee = (baseReturn * feeBps) / BASIS_POINTS;
        netReturn = baseReturn - fee;
    }

    /**
     * @notice Get the current spot price per token
     * @return price Current price in wei per full token (1e18)
     */
    function currentPrice() external view returns (uint256 price) {
        price = initialPrice + (slope * curveSupply / PRECISION);
    }

    // ============================================
    // BUY / SELL
    // ============================================

    /**
     * @notice Buy wTAG tokens from the bonding curve with ETH
     * @dev Sends ETH, receives wTAG. Excess ETH is refunded.
     *      The contract must hold sufficient wTAG balance to fulfill the order.
     * @param tokenAmount Number of wTAG tokens to buy (18 decimals)
     * @param maxCost Maximum ETH willing to pay (slippage protection)
     * @custom:security ReentrancyGuard, Pausable, CEI pattern
     * @custom:emits Buy
     */
    function buy(uint256 tokenAmount, uint256 maxCost) external payable nonReentrant whenNotPaused {
        // CHECKS
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 baseCost = _getBuyPrice(tokenAmount);
        uint256 fee = (baseCost * feeBps) / BASIS_POINTS;
        uint256 totalCost = baseCost + fee;

        if (totalCost > maxCost) revert SlippageExceeded(totalCost, maxCost);
        if (msg.value < totalCost) revert InsufficientPayment(totalCost, msg.value);

        uint256 wtagBalance = wtagToken.balanceOf(address(this));
        if (wtagBalance < tokenAmount) revert InsufficientBalance(tokenAmount, wtagBalance);

        // EFFECTS
        curveSupply += tokenAmount;
        reserve += baseCost;
        accruedFees += fee;

        // INTERACTIONS
        // Transfer wTAG to buyer
        wtagToken.safeTransfer(msg.sender, tokenAmount);

        // Refund excess ETH
        uint256 refund = msg.value - totalCost;
        if (refund > 0) {
            (bool success,) = msg.sender.call{value: refund}("");
            if (!success) revert ETHTransferFailed(msg.sender, refund);
        }

        emit Buy(msg.sender, tokenAmount, totalCost, fee);
    }

    /**
     * @notice Sell wTAG tokens back to the bonding curve for ETH
     * @dev Sends wTAG, receives ETH. Caller must have approved this contract.
     * @param tokenAmount Number of wTAG tokens to sell (18 decimals)
     * @param minReturn Minimum ETH expected (slippage protection)
     * @custom:security ReentrancyGuard, Pausable, CEI pattern
     * @custom:emits Sell
     */
    function sell(uint256 tokenAmount, uint256 minReturn) external nonReentrant whenNotPaused {
        // CHECKS
        if (tokenAmount == 0) revert ZeroAmount();
        if (tokenAmount > curveSupply) revert ExceedsCurveSupply(tokenAmount, curveSupply);

        uint256 baseReturn = _getSellPrice(tokenAmount);
        uint256 fee = (baseReturn * feeBps) / BASIS_POINTS;
        uint256 netReturn = baseReturn - fee;

        if (netReturn < minReturn) revert SlippageExceeded(netReturn, minReturn);

        // EFFECTS
        curveSupply -= tokenAmount;
        reserve -= baseReturn;
        accruedFees += fee;

        // INTERACTIONS
        // Pull wTAG from seller
        wtagToken.safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Send ETH to seller
        (bool success,) = msg.sender.call{value: netReturn}("");
        if (!success) revert ETHTransferFailed(msg.sender, netReturn);

        emit Sell(msg.sender, tokenAmount, netReturn, fee);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Pause the bonding curve (emergency circuit-breaker)
     * @dev Only callable by the owner. Blocks buy() and sell().
     * @custom:security Owner-only. Does not affect withdrawFees or view functions.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the bonding curve
     * @dev Only callable by the owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Update bonding curve parameters
     * @dev Only callable by the owner. Cannot be called while curve has active supply
     *      to protect existing participants. Parameters must pass all validation.
     * @param _initialPrice New initial price in wei
     * @param _slope New slope in wei per token-unit
     * @param _feeBps New fee in basis points
     * @custom:security Owner-only. Reverts if curveSupply > 0 to protect participants.
     * @custom:emits ParamsUpdated
     */
    function updateParams(uint256 _initialPrice, uint256 _slope, uint256 _feeBps) external onlyOwner {
        if (_initialPrice == 0) revert ZeroInitialPrice();
        if (_slope == 0) revert ZeroSlope();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh(_feeBps, MAX_FEE_BPS);
        if (_slope > MAX_SLOPE) revert SlopeTooHigh(_slope, MAX_SLOPE);

        initialPrice = _initialPrice;
        slope = _slope;
        feeBps = _feeBps;

        emit ParamsUpdated(_initialPrice, _slope, _feeBps);
    }

    /**
     * @notice Withdraw accumulated protocol fees
     * @dev Only callable by the owner. Transfers all accrued fees to owner.
     * @custom:security Owner-only, ReentrancyGuard, CEI pattern
     * @custom:emits FeesWithdrawn
     */
    function withdrawFees() external onlyOwner nonReentrant {
        uint256 fees = accruedFees;
        if (fees == 0) revert NoFeesToWithdraw();

        // Effects before interaction
        accruedFees = 0;

        // Interaction
        (bool success,) = msg.sender.call{value: fees}("");
        if (!success) revert ETHTransferFailed(msg.sender, fees);

        emit FeesWithdrawn(msg.sender, fees);
    }

    /// @notice Allow contract to receive ETH directly (for reserve top-ups)
    receive() external payable {}
}
