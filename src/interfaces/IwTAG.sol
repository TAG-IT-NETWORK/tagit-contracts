// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IwTAG
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for the Wrapped TAG (wTAG) governance token
 * @dev wTAG is a 1:1 wrapped version of TAGIT that implements ERC20Votes (IVotes)
 *      for use with TAGITGovernor. Users wrap TAGIT → wTAG to participate in governance.
 *
 * Phase 3 Integration:
 * - IVotes interface wired to TAGITGovernor for voting power
 * - MINTER_ROLE grantable by TAGITCore for reward minting
 * - Wrap/unwrap 1:1 with TAGIT token
 */
interface IwTAG {
    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Zero amount provided
    error ZeroAmount();

    /// @notice Caller lacks MINTER_ROLE
    error OnlyMinter(address caller);

    /// @notice Insufficient TAGIT balance for wrapping
    error InsufficientBalance(address account, uint256 required, uint256 available);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when TAGIT tokens are wrapped into wTAG
    event Wrapped(address indexed account, uint256 amount);

    /// @notice Emitted when wTAG tokens are unwrapped back to TAGIT
    event Unwrapped(address indexed account, uint256 amount);

    /// @notice Emitted when tokens are minted by an authorized minter
    event MinterMinted(address indexed to, uint256 amount, address indexed minter);

    /// @notice Emitted when a minter role is granted
    event MinterGranted(address indexed minter, address indexed grantedBy);

    /// @notice Emitted when a minter role is revoked
    event MinterRevoked(address indexed minter, address indexed revokedBy);

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Wrap TAGIT tokens into wTAG 1:1
     * @dev Requires prior approval of TAGIT tokens to this contract
     * @param amount Amount of TAGIT to wrap
     */
    function wrap(uint256 amount) external;

    /**
     * @notice Unwrap wTAG back to TAGIT 1:1
     * @param amount Amount of wTAG to unwrap
     */
    function unwrap(uint256 amount) external;

    /**
     * @notice Mint wTAG tokens (restricted to authorized minters)
     * @dev Used by TAGITCore for reward minting on qualifying lifecycle actions
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external;

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Grant MINTER_ROLE to an address (e.g., TAGITCore)
     * @param minter Address to grant minting rights
     */
    function grantMinter(address minter) external;

    /**
     * @notice Revoke MINTER_ROLE from an address
     * @param minter Address to revoke minting rights
     */
    function revokeMinter(address minter) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if an address has MINTER_ROLE
     * @param account Address to check
     * @return True if account has minter role
     */
    function isMinter(address account) external view returns (bool);

    /**
     * @notice Get the underlying TAGIT token address
     * @return Address of the TAGIT token contract
     */
    function underlyingToken() external view returns (address);

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory);
}
