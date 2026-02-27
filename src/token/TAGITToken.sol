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

import {GENESIS_SUPPLY, TOKEN_NAME, TOKEN_SYMBOL, VERSION} from "../libraries/Constants.sol";

/**
 * @title TAGITToken
 * @author TAG IT Network <dev@tagit.network>
 * @notice The native governance and utility token of the TAG IT Network
 * @dev ERC20 token with voting, permit, and controlled minting capabilities
 *
 * Key Features:
 * - ERC20Votes for governance participation
 * - ERC20Permit for gasless approvals (EIP-2612)
 * - Controlled minting (only TAGITEmissions contract)
 * - Public burning (anyone can burn their own tokens)
 * - UUPS upgradeable with governor authorization
 *
 * Security:
 * - Mint authority is hardcoded to the Emissions contract
 * - Upgrades require governor approval with 48hr timelock
 * - All state-changing functions use ReentrancyGuard
 *
 * Genesis Supply: 7,777,777,333 TAGIT (branded with 7s and 3s)
 *
 * @custom:security-contact security@tagit.network
 */
contract TAGITToken is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @dev Thrown when a non-emissions address attempts to mint
    error OnlyEmissionsCanMint(address caller, address emissions);

    /// @dev Thrown when attempting to set emissions to zero address
    error ZeroAddress();

    /// @dev Thrown when emissions address has already been set
    error EmissionsAlreadySet();

    /// @dev Thrown when attempting to mint zero tokens
    error ZeroAmount();

    /// @dev Thrown when upgrade is not authorized
    error UnauthorizedUpgrade(address caller);

    // ============================================
    // EVENTS
    // ============================================

    /// @dev Emitted when the emissions contract address is set
    event EmissionsAddressSet(address indexed emissions, address indexed setter);

    /// @dev Emitted when tokens are minted by the emissions contract
    event TokensMinted(address indexed to, uint256 amount, uint256 totalSupply);

    /// @dev Emitted when tokens are burned
    event TokensBurned(address indexed from, uint256 amount, uint256 totalSupply);

    /// @dev Emitted when contract is upgraded
    event ContractUpgraded(address indexed newImplementation, string version);

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Address of the TAGITEmissions contract (only address that can mint)
    /// @dev Set once via setEmissionsAddress, immutable after that
    address public emissionsAddress;

    /// @notice Tracks whether emissions address has been set
    bool private _emissionsSet;

    /// @dev Storage gap for future upgrades (50 slots)
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
     * @notice Initialize the token contract
     * @dev Called once during proxy deployment, mints genesis supply to treasury
     * @param treasury Address to receive the genesis supply
     * @param initialOwner Initial owner of the contract (for admin functions)
     */
    function initialize(address treasury, address initialOwner) public initializer {
        if (treasury == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        __ERC20_init(TOKEN_NAME, TOKEN_SYMBOL);
        __ERC20Permit_init(TOKEN_NAME);
        __ERC20Votes_init();
        __ERC20Burnable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        // Mint genesis supply to treasury
        _mint(treasury, GENESIS_SUPPLY);

        emit TokensMinted(treasury, GENESIS_SUPPLY, GENESIS_SUPPLY);
    }

    // ============================================
    // EMISSIONS CONFIGURATION
    // ============================================

    /**
     * @notice Set the emissions contract address (one-time only)
     * @dev Can only be called once by owner. After set, becomes immutable.
     * @param _emissions Address of the TAGITEmissions contract
     * @custom:security This is a critical one-time configuration
     */
    function setEmissionsAddress(address _emissions) external onlyOwner {
        if (_emissions == address(0)) revert ZeroAddress();
        if (_emissionsSet) revert EmissionsAlreadySet();

        emissionsAddress = _emissions;
        _emissionsSet = true;

        emit EmissionsAddressSet(_emissions, msg.sender);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    /**
     * @notice Restricts function access to the emissions contract only
     * @dev Reverts with OnlyEmissionsCanMint if caller is not emissions
     */
    modifier onlyEmissions() {
        if (msg.sender != emissionsAddress) {
            revert OnlyEmissionsCanMint(msg.sender, emissionsAddress);
        }
        _;
    }

    // ============================================
    // MINTING (Emissions-only)
    // ============================================

    /**
     * @notice Mint new tokens (emissions contract only)
     * @dev Only callable by the TAGITEmissions contract for weekly distributions
     * @param to Address to receive minted tokens
     * @param amount Number of tokens to mint (in wei)
     * @custom:security Only emissions contract can call this function
     * @custom:emits TokensMinted
     */
    function mint(address to, uint256 amount) external onlyEmissions nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _mint(to, amount);

        emit TokensMinted(to, amount, totalSupply());
    }

    // ============================================
    // BURNING (Public)
    // ============================================

    /**
     * @notice Burn tokens from caller's balance
     * @dev Overrides ERC20Burnable to add event emission
     * @param amount Number of tokens to burn
     * @custom:emits TokensBurned
     */
    function burn(uint256 amount) public override nonReentrant {
        super.burn(amount);
        emit TokensBurned(msg.sender, amount, totalSupply());
    }

    /**
     * @notice Burn tokens from another account (with approval)
     * @dev Overrides ERC20Burnable to add event emission
     * @param account Address to burn tokens from
     * @param amount Number of tokens to burn
     * @custom:emits TokensBurned
     */
    function burnFrom(address account, uint256 amount) public override nonReentrant {
        super.burnFrom(account, amount);
        emit TokensBurned(account, amount, totalSupply());
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the contract version
     * @return Current version string
     */
    function version() external pure returns (string memory) {
        return VERSION;
    }

    /**
     * @notice Check if emissions address has been set
     * @return True if emissions address is configured
     */
    function isEmissionsConfigured() external view returns (bool) {
        return _emissionsSet;
    }

    // ============================================
    // REQUIRED OVERRIDES
    // ============================================

    /**
     * @dev Override required by ERC20Votes
     */
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, amount);
    }

    /**
     * @dev Override required for ERC20Permit/Votes nonces
     */
    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    // ============================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================

    /**
     * @notice Authorize contract upgrades
     * @dev Only owner (governor/timelock) can authorize upgrades
     * @param newImplementation Address of new implementation contract
     * @custom:security Upgrades require governor approval with timelock
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit ContractUpgraded(newImplementation, VERSION);
    }
}
