// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVoucher
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for the TAG IT Voucher token
 * @dev Vouchers are non-transferable reward tokens issued by TAGITCore on qualifying
 *      lifecycle actions (activation, claiming). Redeemable for wTAG governance tokens.
 *
 * Phase 3 Integration:
 * - Mint restricted to TAGITCore via onlyCore modifier
 * - Burn restricted to TAGITCore via onlyCore modifier
 * - redeem() burns voucher and triggers wTAG mint via TAGITCore
 * - VoucherProposal type in TAGITGovernor for parameter changes
 */
interface IVoucher {
    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Caller is not TAGITCore
    error OnlyCore(address caller, address core);

    /// @notice Insufficient voucher balance for redemption
    error InsufficientVouchers(address account, uint256 required, uint256 available);

    /// @notice Redemption is currently paused
    error RedemptionPaused();

    /// @notice Redemption rate is out of bounds
    error InvalidRedemptionRate(uint256 rate);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when vouchers are issued by TAGITCore
    event VoucherIssued(address indexed to, uint256 amount, uint256 indexed tokenId, string reason);

    /// @notice Emitted when vouchers are redeemed for wTAG
    event VoucherRedeemed(address indexed account, uint256 voucherAmount, uint256 wtagAmount);

    /// @notice Emitted when vouchers are burned by TAGITCore
    event VoucherBurned(address indexed from, uint256 amount);

    /// @notice Emitted when TAGITCore address is updated
    event CoreUpdated(address indexed previousCore, address indexed newCore);

    /// @notice Emitted when wTAG address is updated
    event WtagUpdated(address indexed previousWtag, address indexed newWtag);

    /// @notice Emitted when redemption rate is updated
    event RedemptionRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when redemption pause status changes
    event RedemptionPauseToggled(bool paused);

    // ============================================
    // CORE FUNCTIONS (TAGITCore only)
    // ============================================

    /**
     * @notice Issue vouchers to an address (TAGITCore only)
     * @param to Recipient address
     * @param amount Amount of vouchers to issue
     * @param tokenId Associated asset token ID
     * @param reason Reason for issuance (e.g., "activation", "claim")
     */
    function issue(address to, uint256 amount, uint256 tokenId, string calldata reason) external;

    /**
     * @notice Burn vouchers from an address (TAGITCore only)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) external;

    // ============================================
    // USER FUNCTIONS
    // ============================================

    /**
     * @notice Redeem vouchers for wTAG tokens
     * @dev Burns vouchers from caller and mints wTAG at the current redemption rate
     * @param amount Amount of vouchers to redeem
     * @return wtagAmount Amount of wTAG received
     */
    function redeem(uint256 amount) external returns (uint256 wtagAmount);

    // ============================================
    // ADMIN FUNCTIONS (Governance)
    // ============================================

    /**
     * @notice Update the redemption rate (basis points: 10000 = 1:1)
     * @param newRate New redemption rate in basis points
     */
    function setRedemptionRate(uint256 newRate) external;

    /**
     * @notice Pause or unpause redemptions
     * @param paused True to pause, false to unpause
     */
    function setRedemptionPaused(bool paused) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the TAGITCore contract address
     * @return Address of TAGITCore
     */
    function core() external view returns (address);

    /**
     * @notice Get the wTAG contract address
     * @return Address of wTAG
     */
    function wtag() external view returns (address);

    /**
     * @notice Get the current redemption rate in basis points
     * @return Redemption rate (10000 = 1:1)
     */
    function redemptionRate() external view returns (uint256);

    /**
     * @notice Check if redemptions are paused
     * @return True if paused
     */
    function isRedemptionPaused() external view returns (bool);

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory);
}
