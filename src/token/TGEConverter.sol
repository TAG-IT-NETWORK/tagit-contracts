// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TGEConverter
 * @author TAG IT Network <dev@tagit.network>
 * @notice Converts wTAG (Wrapped TAGIT) to TAG (TAGIT Token) at 1:1 ratio during TGE
 * @dev Pre-funded with TAG tokens from genesis allocation. Burns incoming wTAG
 *      and transfers TAG to the caller. Conversion window is time-bounded.
 *
 * Flow:
 *   1. Treasury funds this contract with TAG tokens (presale allocation)
 *   2. wTAG holders approve this contract to spend their wTAG
 *   3. wTAG holders call convert(amount) → wTAG burned, TAG transferred
 *   4. Owner can withdraw remaining TAG after conversion window closes
 *
 * @custom:security-contact security@tagit.network
 */
contract TGEConverter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    error ZeroAddress();
    error ZeroAmount();
    error ConversionWindowClosed();
    error ConversionWindowStillOpen();
    error InsufficientTAGBalance(uint256 requested, uint256 available);
    error ConversionWindowAlreadyStarted();

    // ============================================
    // EVENTS
    // ============================================

    /// @dev Emitted when wTAG is converted to TAG
    event Converted(address indexed holder, uint256 amount, uint256 wtagBurnedTotal, uint256 tagRemainingBalance);

    /// @dev Emitted when the conversion window starts
    event ConversionWindowOpened(uint256 startTime, uint256 endTime);

    /// @dev Emitted when remaining TAG is withdrawn after window closes
    event RemainingWithdrawn(address indexed to, uint256 amount);

    // ============================================
    // STATE
    // ============================================

    /// @notice The wTAG (Wrapped TAGIT) token to burn
    IERC20 public immutable wTAG;

    /// @notice The TAG (TAGIT) token to distribute
    IERC20 public immutable TAG;

    /// @notice Timestamp when conversion window opens
    uint256 public conversionStart;

    /// @notice Timestamp when conversion window closes
    uint256 public conversionEnd;

    /// @notice Total wTAG burned through conversions
    uint256 public totalConverted;

    /// @notice Per-address conversion tracking
    mapping(address => uint256) public convertedBy;

    /// @notice Interface for burning wTAG (bridgeBurn or standard burn)
    IWTAGBurnable private immutable _wtagBurnable;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @param _wtag Address of the wTAG (Wrapped TAGIT) token
     * @param _tag Address of the TAG (TAGIT) token
     * @param _owner Owner address for admin functions
     */
    constructor(address _wtag, address _tag, address _owner) Ownable(_owner) {
        if (_wtag == address(0)) revert ZeroAddress();
        if (_tag == address(0)) revert ZeroAddress();
        // Note: _owner == address(0) is caught by Ownable's OwnableInvalidOwner

        wTAG = IERC20(_wtag);
        TAG = IERC20(_tag);
        _wtagBurnable = IWTAGBurnable(_wtag);
    }

    // ============================================
    // CONVERSION WINDOW MANAGEMENT
    // ============================================

    /**
     * @notice Open the conversion window
     * @param duration Duration in seconds for the conversion window
     * @dev Can only be called once. Contract must be pre-funded with TAG.
     */
    function openConversionWindow(uint256 duration) external onlyOwner {
        if (conversionStart != 0) revert ConversionWindowAlreadyStarted();
        if (duration == 0) revert ZeroAmount();

        conversionStart = block.timestamp;
        conversionEnd = block.timestamp + duration;

        emit ConversionWindowOpened(conversionStart, conversionEnd);
    }

    // ============================================
    // CORE CONVERSION
    // ============================================

    /**
     * @notice Convert wTAG to TAG at 1:1 ratio
     * @param amount Amount of wTAG to convert (in wei)
     * @dev Caller must have approved this contract to spend their wTAG.
     *      wTAG is burned, TAG is transferred from this contract's balance.
     */
    function convert(uint256 amount) external nonReentrant whenNotPaused {
        // CHECKS
        if (amount == 0) revert ZeroAmount();
        if (!_isWindowOpen()) revert ConversionWindowClosed();

        uint256 tagBalance = TAG.balanceOf(address(this));
        if (tagBalance < amount) revert InsufficientTAGBalance(amount, tagBalance);

        // EFFECTS
        totalConverted += amount;
        convertedBy[msg.sender] += amount;

        // INTERACTIONS
        // 1. Transfer wTAG from caller to this contract
        wTAG.safeTransferFrom(msg.sender, address(this), amount);

        // 2. Burn the wTAG (standard ERC20Burnable burn)
        _wtagBurnable.burn(amount);

        // 3. Transfer TAG to caller
        TAG.safeTransfer(msg.sender, amount);

        emit Converted(msg.sender, amount, totalConverted, TAG.balanceOf(address(this)));
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Withdraw remaining TAG after conversion window closes
     * @param to Address to receive remaining TAG
     * @dev Only callable after conversion window has ended
     */
    function withdrawRemaining(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (_isWindowOpen()) revert ConversionWindowStillOpen();

        uint256 remaining = TAG.balanceOf(address(this));
        if (remaining == 0) revert ZeroAmount();

        TAG.safeTransfer(to, remaining);

        emit RemainingWithdrawn(to, remaining);
    }

    /**
     * @notice Pause conversions (emergency only)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause conversions
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if conversion window is currently open
     * @return True if window is open
     */
    function isWindowOpen() external view returns (bool) {
        return _isWindowOpen();
    }

    /**
     * @notice Get remaining TAG available for conversion
     * @return Amount of TAG remaining in the contract
     */
    function remainingTAG() external view returns (uint256) {
        return TAG.balanceOf(address(this));
    }

    // ============================================
    // INTERNAL
    // ============================================

    function _isWindowOpen() internal view returns (bool) {
        return conversionStart != 0 && block.timestamp >= conversionStart && block.timestamp <= conversionEnd;
    }
}

/**
 * @dev Minimal interface for burning wTAG tokens
 * Compatible with both ERC20Burnable.burn() and WrappedTAGIT.bridgeBurn()
 */
interface IWTAGBurnable {
    function burn(uint256 amount) external;
}
