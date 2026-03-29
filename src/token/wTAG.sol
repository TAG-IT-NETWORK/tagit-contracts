// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IwTAG} from "../interfaces/IwTAG.sol";

/**
 * @title wTAG (Wrapped TAG)
 * @author TAG IT Network <dev@tagit.network>
 * @notice Wrapped governance token implementing ERC20Votes (IVotes) for TAGITGovernor
 * @dev Users wrap TAGIT → wTAG for governance voting. wTAG implements IVotes which is
 *      consumed by TAGITGovernor for voting power delegation and tallying.
 *
 * Phase 3 Integration Points:
 * - TAGITGovernor: uses wTAG as IVotes token for quorum & voting power
 * - TAGITCore: granted MINTER_ROLE for reward minting on qualifying actions
 * - Voucher: redeemed into wTAG via minter-authorized mint
 *
 * Security:
 * - MINTER_ROLE restricted to owner-approved addresses (TAGITCore, Voucher)
 * - UUPS upgradeable with owner authorization
 * - ReentrancyGuard on all state-changing functions
 * - SafeERC20 for underlying token transfers
 *
 * @custom:security-contact security@tagit.network
 */
contract wTAG is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IwTAG
{
    using SafeERC20 for IERC20;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice The underlying TAGIT token
    IERC20 public tagitToken;

    /// @notice Authorized minters (TAGITCore, Voucher contract)
    mapping(address => bool) private _minters;

    /// @dev Storage gap for future upgrades
    uint256[48] private __gap;

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
     * @notice Initialize the wTAG contract
     * @param _tagitToken Address of the underlying TAGIT token
     * @param _initialOwner Initial owner (should be TimelockController)
     */
    function initialize(address _tagitToken, address _initialOwner) external initializer {
        if (_tagitToken == address(0)) revert ZeroAddress();
        if (_initialOwner == address(0)) revert ZeroAddress();

        __ERC20_init("Wrapped TAG", "wTAG");
        __ERC20Permit_init("Wrapped TAG");
        __ERC20Votes_init();
        __ERC20Burnable_init();
        __Ownable_init(_initialOwner);
        __UUPSUpgradeable_init();

        tagitToken = IERC20(_tagitToken);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    /// @dev Restricts function to authorized minters only
    modifier onlyMinter() {
        if (!_minters[msg.sender]) revert OnlyMinter(msg.sender);
        _;
    }

    // ============================================
    // WRAP / UNWRAP
    // ============================================

    /**
     * @inheritdoc IwTAG
     * @dev Transfers TAGIT from caller, mints equal wTAG. Requires prior approval.
     * @custom:security SafeERC20 prevents silent transfer failures
     * @custom:security ReentrancyGuard prevents reentrancy via token callbacks
     */
    function wrap(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Transfer TAGIT from caller to this contract
        tagitToken.safeTransferFrom(msg.sender, address(this), amount);

        // Mint equal wTAG to caller
        _mint(msg.sender, amount);

        emit Wrapped(msg.sender, amount);
    }

    /**
     * @inheritdoc IwTAG
     * @dev Burns wTAG from caller, transfers equal TAGIT back.
     * @custom:security ReentrancyGuard prevents reentrancy
     * @custom:security Burns before transfer (CEI pattern)
     */
    function unwrap(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 balance = balanceOf(msg.sender);
        if (balance < amount) revert InsufficientBalance(msg.sender, amount, balance);

        // Effects: burn wTAG first
        _burn(msg.sender, amount);

        // Interactions: transfer TAGIT back
        tagitToken.safeTransfer(msg.sender, amount);

        emit Unwrapped(msg.sender, amount);
    }

    // ============================================
    // MINTING (Authorized minters only)
    // ============================================

    /**
     * @inheritdoc IwTAG
     * @dev Mints wTAG without requiring underlying TAGIT deposit.
     *      Used for reward minting by TAGITCore and Voucher redemption.
     * @custom:security Only addresses with MINTER_ROLE can call
     * @custom:security ReentrancyGuard prevents reentrancy
     */
    function mint(address to, uint256 amount) external override onlyMinter nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);

        emit MinterMinted(to, amount, msg.sender);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @inheritdoc IwTAG
     * @custom:security Only owner (TimelockController) can grant minter role
     */
    function grantMinter(address minter) external override onlyOwner {
        if (minter == address(0)) revert ZeroAddress();

        _minters[minter] = true;

        emit MinterGranted(minter, msg.sender);
    }

    /**
     * @inheritdoc IwTAG
     * @custom:security Only owner (TimelockController) can revoke minter role
     */
    function revokeMinter(address minter) external override onlyOwner {
        if (minter == address(0)) revert ZeroAddress();

        _minters[minter] = false;

        emit MinterRevoked(minter, msg.sender);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @inheritdoc IwTAG
    function isMinter(address account) external view override returns (bool) {
        return _minters[account];
    }

    /// @inheritdoc IwTAG
    function underlyingToken() external view override returns (address) {
        return address(tagitToken);
    }

    /// @inheritdoc IwTAG
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    // ============================================
    // REQUIRED OVERRIDES
    // ============================================

    /// @dev Override required by ERC20Votes
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, amount);
    }

    /// @dev Override required for ERC20Permit/Votes nonces
    function nonces(address owner_) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner_);
    }

    /// @dev UUPS upgrade authorization — owner only
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
