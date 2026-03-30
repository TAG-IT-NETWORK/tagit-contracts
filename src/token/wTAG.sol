// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {GENESIS_SUPPLY, BASIS_POINTS} from "../libraries/Constants.sol";

/**
 * @title wTAG (Wrapped TAGIT)
 * @author TAG IT Network <dev@tagit.network>
 * @notice Wrapped ERC-20 representation of TAGIT tokens for DeFi composability
 * @dev Non-upgradeable ERC20 with:
 *   - Hard cap at 3.33% of TAGIT genesis supply
 *   - AccessControl with MINTER_ROLE (multi-sig gated)
 *   - 7-day post-TGE lockout period (no transfers until lockout expires)
 *   - 1:1 wrap/unwrap against the underlying TAGIT token
 *
 * Security:
 *   - ReentrancyGuard on all state-changing functions
 *   - Checks-Effects-Interactions pattern throughout
 *   - SafeERC20 for all external token interactions
 *   - Custom errors only (no string reverts)
 *
 * @custom:security-contact security@tagit.network
 */
contract wTAG is ERC20Capped, ERC20Burnable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Role identifier for addresses authorized to mint wTAG
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice The cap percentage in basis points (333 = 3.33%)
    uint256 public constant CAP_BPS = 333;

    /// @notice Duration of the post-TGE transfer lockout (7 days)
    uint256 public constant LOCKOUT_PERIOD = 7 days;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Address of the underlying TAGIT token contract
    IERC20 public immutable tagToken;

    /// @notice Timestamp of the Token Generation Event
    /// @dev Set by admin via setTGE(); zero means TGE has not been scheduled
    uint256 public tgeTimestamp;

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @dev Thrown when a zero address is provided where a valid address is required
    error ZeroAddress();

    /// @dev Thrown when a zero amount is provided
    error ZeroAmount();

    /// @dev Thrown when transfers are attempted during the lockout period
    error TransfersDuringLockout(uint256 currentTime, uint256 lockoutEnd);

    /// @dev Thrown when TGE timestamp has already been set
    error TGEAlreadySet();

    /// @dev Thrown when TGE timestamp is in the past
    error TGETimestampInPast(uint256 provided, uint256 current);

    /// @dev Thrown when wrap/unwrap is called before TGE is set
    error TGENotSet();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when the TGE timestamp is configured
    event TGESet(uint256 timestamp, address indexed setter);

    /// @notice Emitted when TAGIT tokens are wrapped into wTAG
    event Wrapped(address indexed account, uint256 amount);

    /// @notice Emitted when wTAG tokens are unwrapped back to TAGIT
    event Unwrapped(address indexed account, uint256 amount);

    /// @notice Emitted when wTAG tokens are minted by the minter role
    event Minted(address indexed to, uint256 amount);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the wTAG token
     * @param _tagToken Address of the underlying TAGIT ERC-20 token
     * @param _admin Address receiving DEFAULT_ADMIN_ROLE (multi-sig)
     * @param _minter Address receiving MINTER_ROLE (multi-sig)
     * @dev Cap is computed as GENESIS_SUPPLY * 333 / 10000 (3.33%)
     */
    constructor(address _tagToken, address _admin, address _minter)
        ERC20("Wrapped TAGIT", "wTAG")
        ERC20Capped((GENESIS_SUPPLY * CAP_BPS) / BASIS_POINTS)
    {
        if (_tagToken == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_minter == address(0)) revert ZeroAddress();

        tagToken = IERC20(_tagToken);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _minter);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Set the Token Generation Event timestamp (one-time only)
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Cannot be changed once set.
     * @param _tgeTimestamp Unix timestamp of the TGE
     * @custom:security One-time setter — TGE is immutable after configuration
     * @custom:emits TGESet
     */
    function setTGE(uint256 _tgeTimestamp) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tgeTimestamp != 0) revert TGEAlreadySet();
        if (_tgeTimestamp <= block.timestamp) revert TGETimestampInPast(_tgeTimestamp, block.timestamp);

        tgeTimestamp = _tgeTimestamp;

        emit TGESet(_tgeTimestamp, msg.sender);
    }

    // ============================================
    // MINTING
    // ============================================

    /**
     * @notice Mint wTAG tokens to a specified address
     * @dev Only callable by MINTER_ROLE. Respects the ERC20Capped supply limit.
     * @param to Recipient address
     * @param amount Amount of wTAG to mint (in wei)
     * @custom:security Requires MINTER_ROLE. Cap enforced by ERC20Capped._update.
     * @custom:emits Minted
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);

        emit Minted(to, amount);
    }

    // ============================================
    // WRAP / UNWRAP (1:1 with TAGIT)
    // ============================================

    /**
     * @notice Wrap TAGIT tokens into wTAG at a 1:1 ratio
     * @dev Caller must have approved this contract to spend `amount` of TAGIT.
     *      Transfers TAGIT from caller to this contract, mints equivalent wTAG.
     * @param amount Amount of TAGIT to wrap (in wei)
     * @custom:security Uses SafeERC20, ReentrancyGuard, and lockout enforcement
     * @custom:emits Wrapped
     */
    function wrap(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (tgeTimestamp == 0) revert TGENotSet();

        // Effects: mint wTAG first (CEI pattern — state change before external call)
        _mint(msg.sender, amount);

        // Interactions: pull TAGIT tokens from caller
        tagToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Wrapped(msg.sender, amount);
    }

    /**
     * @notice Unwrap wTAG back to TAGIT at a 1:1 ratio
     * @dev Burns wTAG from caller, returns equivalent TAGIT from contract reserves.
     * @param amount Amount of wTAG to unwrap (in wei)
     * @custom:security Uses SafeERC20, ReentrancyGuard, and lockout enforcement
     * @custom:emits Unwrapped
     */
    function unwrap(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (tgeTimestamp == 0) revert TGENotSet();

        // Effects: burn wTAG first (CEI pattern)
        _burn(msg.sender, amount);

        // Interactions: return TAGIT tokens to caller
        tagToken.safeTransfer(msg.sender, amount);

        emit Unwrapped(msg.sender, amount);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check whether transfers are currently locked
     * @return True if the lockout period is still active
     */
    function isLocked() public view returns (bool) {
        if (tgeTimestamp == 0) return true;
        return block.timestamp < tgeTimestamp + LOCKOUT_PERIOD;
    }

    /**
     * @notice Get the timestamp when the lockout period ends
     * @return Unix timestamp of lockout end, or 0 if TGE not set
     */
    function lockoutEnd() external view returns (uint256) {
        if (tgeTimestamp == 0) return 0;
        return tgeTimestamp + LOCKOUT_PERIOD;
    }

    // ============================================
    // INTERNAL OVERRIDES
    // ============================================

    /**
     * @dev Override _update to enforce both the ERC20Capped supply check
     *      and the post-TGE lockout period on transfers.
     *
     *      Lockout exemptions:
     *        - Minting (from == address(0)): allowed so minter can pre-distribute
     *        - Burning (to == address(0)): allowed so unwrap can function
     *
     *      All other transfers revert during the lockout window.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        // Enforce lockout on regular transfers (not mint/burn)
        if (from != address(0) && to != address(0)) {
            if (isLocked()) {
                revert TransfersDuringLockout(block.timestamp, tgeTimestamp + LOCKOUT_PERIOD);
            }
        }

        // Delegate to ERC20Capped._update (which handles cap check on mint)
        super._update(from, to, value);
    }

    /**
     * @dev Required override for AccessControl + ERC20 supportsInterface
     */
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
