// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IVoucher} from "../interfaces/IVoucher.sol";
import {IwTAG} from "../interfaces/IwTAG.sol";

/**
 * @title Voucher
 * @author TAG IT Network <dev@tagit.network>
 * @notice Non-transferable reward vouchers issued by TAGITCore for lifecycle actions
 * @dev Vouchers are minted by TAGITCore when qualifying actions occur (activation, claiming).
 *      Users redeem vouchers for wTAG governance tokens at a configurable rate.
 *
 * Phase 3 Integration Points:
 * - TAGITCore: sole authority to issue() and burnFrom() vouchers
 * - wTAG: voucher redemption mints wTAG via wTAG.mint() (Voucher must have MINTER_ROLE on wTAG)
 * - TAGITGovernor: VoucherProposal type can adjust redemptionRate and pause status
 *
 * Non-transferable Design:
 * - _update override blocks all transfers except mint/burn
 * - Prevents secondary market speculation on vouchers
 * - Vouchers represent earned participation rights, not tradeable assets
 *
 * Security:
 * - onlyCore modifier restricts mint/burn to TAGITCore
 * - ReentrancyGuard on all state-changing functions
 * - Redemption rate bounded between 1 and 20000 basis points
 * - Redemption can be paused by governance
 *
 * @custom:security-contact security@tagit.network
 */
contract Voucher is ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard, IVoucher {
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum redemption rate (200% = 2:1 wTAG per voucher)
    uint256 public constant MAX_REDEMPTION_RATE = 20000;

    /// @notice Minimum redemption rate (0.01%)
    uint256 public constant MIN_REDEMPTION_RATE = 1;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice TAGITCore contract — sole authority for issue/burn
    address private _core;

    /// @notice wTAG contract — target for redemption minting
    IwTAG private _wtag;

    /// @notice Redemption rate in basis points (10000 = 1:1 voucher:wTAG)
    uint256 private _redemptionRate;

    /// @notice Whether redemptions are paused
    bool private _redemptionPaused;

    /// @dev Storage gap for future upgrades
    uint256[46] private __gap;

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
     * @notice Initialize the Voucher contract
     * @param coreAddress TAGITCore contract address (sole minter/burner)
     * @param wtagAddress wTAG contract address (redemption target)
     * @param initialOwner Initial owner (should be TimelockController)
     * @param initialRedemptionRate Initial redemption rate in basis points (10000 = 1:1)
     */
    function initialize(address coreAddress, address wtagAddress, address initialOwner, uint256 initialRedemptionRate)
        external
        initializer
    {
        if (coreAddress == address(0)) revert ZeroAddress();
        if (wtagAddress == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialRedemptionRate < MIN_REDEMPTION_RATE || initialRedemptionRate > MAX_REDEMPTION_RATE) {
            revert InvalidRedemptionRate(initialRedemptionRate);
        }

        __ERC20_init("TAG IT Voucher", "vTAG");
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        _core = coreAddress;
        _wtag = IwTAG(wtagAddress);
        _redemptionRate = initialRedemptionRate;
    }

    // ============================================
    // MODIFIERS
    // ============================================

    /// @dev Restricts function to TAGITCore contract only
    modifier onlyCore() {
        if (msg.sender != _core) revert OnlyCore(msg.sender, _core);
        _;
    }

    // ============================================
    // CORE FUNCTIONS (TAGITCore only)
    // ============================================

    /**
     * @inheritdoc IVoucher
     * @custom:security Only TAGITCore can issue vouchers
     * @custom:security ReentrancyGuard prevents reentrancy
     */
    function issue(address to, uint256 amount, uint256 tokenId, string calldata reason)
        external
        override
        onlyCore
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);

        emit VoucherIssued(to, amount, tokenId, reason);
    }

    /**
     * @inheritdoc IVoucher
     * @custom:security Only TAGITCore can burn vouchers
     * @custom:security ReentrancyGuard prevents reentrancy
     */
    function burnFrom(address from, uint256 amount) external override onlyCore nonReentrant {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = balanceOf(from);
        if (balance < amount) revert InsufficientVouchers(from, amount, balance);

        _burn(from, amount);

        emit VoucherBurned(from, amount);
    }

    // ============================================
    // USER FUNCTIONS
    // ============================================

    /**
     * @inheritdoc IVoucher
     * @dev Burns vouchers from caller, mints wTAG at current redemption rate.
     *      wTAG amount = (voucherAmount * redemptionRate) / BASIS_POINTS
     * @custom:security ReentrancyGuard prevents reentrancy via wTAG.mint callback
     * @custom:security CEI pattern: burn first, then mint wTAG
     */
    function redeem(uint256 amount) external override nonReentrant returns (uint256 wtagAmount) {
        if (_redemptionPaused) revert RedemptionPaused();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = balanceOf(msg.sender);
        if (balance < amount) revert InsufficientVouchers(msg.sender, amount, balance);

        // Calculate wTAG amount based on redemption rate
        wtagAmount = (amount * _redemptionRate) / BASIS_POINTS;
        if (wtagAmount == 0) revert ZeroAmount();

        // Effects: burn vouchers first (CEI)
        _burn(msg.sender, amount);

        // Interactions: mint wTAG to redeemer
        _wtag.mint(msg.sender, wtagAmount);

        emit VoucherRedeemed(msg.sender, amount, wtagAmount);
    }

    // ============================================
    // ADMIN FUNCTIONS (Governance)
    // ============================================

    /**
     * @inheritdoc IVoucher
     * @custom:security Only owner (governance via TimelockController) can update rate
     */
    function setRedemptionRate(uint256 newRate) external override onlyOwner {
        if (newRate < MIN_REDEMPTION_RATE || newRate > MAX_REDEMPTION_RATE) {
            revert InvalidRedemptionRate(newRate);
        }

        uint256 oldRate = _redemptionRate;
        _redemptionRate = newRate;

        emit RedemptionRateUpdated(oldRate, newRate);
    }

    /**
     * @inheritdoc IVoucher
     * @custom:security Only owner (governance via TimelockController) can toggle pause
     */
    function setRedemptionPaused(bool paused) external override onlyOwner {
        _redemptionPaused = paused;

        emit RedemptionPauseToggled(paused);
    }

    /**
     * @notice Update the TAGITCore address
     * @param newCore New TAGITCore contract address
     * @custom:security Only owner can update
     */
    function setCore(address newCore) external onlyOwner {
        if (newCore == address(0)) revert ZeroAddress();

        address previousCore = _core;
        _core = newCore;

        emit CoreUpdated(previousCore, newCore);
    }

    /**
     * @notice Update the wTAG address
     * @param newWtag New wTAG contract address
     * @custom:security Only owner can update
     */
    function setWtag(address newWtag) external onlyOwner {
        if (newWtag == address(0)) revert ZeroAddress();

        address previousWtag = address(_wtag);
        _wtag = IwTAG(newWtag);

        emit WtagUpdated(previousWtag, newWtag);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @inheritdoc IVoucher
    function core() external view override returns (address) {
        return _core;
    }

    /// @inheritdoc IVoucher
    function wtag() external view override returns (address) {
        return address(_wtag);
    }

    /// @inheritdoc IVoucher
    function redemptionRate() external view override returns (uint256) {
        return _redemptionRate;
    }

    /// @inheritdoc IVoucher
    function isRedemptionPaused() external view override returns (bool) {
        return _redemptionPaused;
    }

    /// @inheritdoc IVoucher
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    // ============================================
    // NON-TRANSFERABLE OVERRIDE
    // ============================================

    /**
     * @dev Override _update to make vouchers non-transferable.
     *      Only mint (from == address(0)) and burn (to == address(0)) are allowed.
     * @custom:security Prevents secondary market for vouchers
     */
    function _update(address from, address to, uint256 amount) internal override {
        // Allow minting (from == 0) and burning (to == 0)
        // Block all other transfers
        if (from != address(0) && to != address(0)) {
            revert("Voucher: non-transferable");
        }
        super._update(from, to, amount);
    }

    // ============================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================

    /// @dev Only owner can authorize upgrades
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
