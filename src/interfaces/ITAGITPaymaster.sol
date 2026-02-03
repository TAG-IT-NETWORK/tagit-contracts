// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title ITAGITPaymaster
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for gas sponsorship paymaster
 * @dev Sponsors whitelisted operations for TAG IT users
 */
interface ITAGITPaymaster {
    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Sponsorship configuration for a function
     * @param selector Function selector to sponsor
     * @param maxGas Maximum gas to sponsor per call
     * @param dailyLimit Maximum sponsored calls per user per day (0 = unlimited)
     * @param active Whether sponsorship is active
     */
    struct SponsorshipConfig {
        bytes4 selector;
        uint256 maxGas;
        uint256 dailyLimit;
        bool active;
    }

    /**
     * @notice Brand deposit for sponsoring their product claims
     * @param brandId Brand identifier
     * @param balance Current deposit balance
     * @param totalSpent Total gas spent
     * @param active Whether brand sponsorship is active
     */
    struct BrandDeposit {
        bytes32 brandId;
        uint256 balance;
        uint256 totalSpent;
        bool active;
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Caller is not the EntryPoint
    error NotEntryPoint(address caller);

    /// @notice Caller is not the governor
    error NotGovernor(address caller);

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Zero amount not allowed
    error ZeroAmount();

    /// @notice Operation not sponsored
    error OperationNotSponsored(bytes4 selector);

    /// @notice Daily limit exceeded
    error DailyLimitExceeded(address user, bytes4 selector, uint256 limit);

    /// @notice Gas limit exceeded
    error GasLimitExceeded(uint256 requested, uint256 maxGas);

    /// @notice Insufficient brand deposit
    error InsufficientBrandDeposit(bytes32 brandId, uint256 required, uint256 available);

    /// @notice Brand not active
    error BrandNotActive(bytes32 brandId);

    /// @notice Invalid paymaster data
    error InvalidPaymasterData();

    /// @notice Deposit too low
    error DepositTooLow(uint256 required, uint256 actual);

    /// @notice Withdrawal exceeds balance
    error WithdrawalExceedsBalance(uint256 requested, uint256 balance);

    /// @notice Paymaster is paused
    error PaymasterPaused();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when paymaster is paused
    event PaymasterPausedEvent(uint256 indexed timestamp, string reason);

    /// @notice Emitted when paymaster is unpaused
    event PaymasterUnpausedEvent(uint256 indexed timestamp);

    /// @notice Emitted when sponsorship config is set
    event SponsorshipConfigSet(
        bytes4 indexed selector,
        uint256 maxGas,
        uint256 dailyLimit,
        bool active
    );

    /// @notice Emitted when operation is sponsored
    event OperationSponsored(
        address indexed user,
        bytes4 indexed selector,
        uint256 gasCost,
        bytes32 brandId
    );

    /// @notice Emitted when brand deposits funds
    event BrandDeposited(
        bytes32 indexed brandId,
        uint256 amount,
        uint256 newBalance
    );

    /// @notice Emitted when brand withdraws funds
    event BrandWithdrawn(
        bytes32 indexed brandId,
        uint256 amount,
        uint256 newBalance
    );

    /// @notice Emitted when brand status changes
    event BrandStatusChanged(
        bytes32 indexed brandId,
        bool active
    );

    /// @notice Emitted when protocol deposit is added
    event ProtocolDeposited(uint256 amount);

    /// @notice Emitted when protocol withdraws
    event ProtocolWithdrawn(uint256 amount, address to);

    /// @notice Emitted when governor is updated
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);

    // ============================================
    // SPONSORSHIP MANAGEMENT
    // ============================================

    /**
     * @notice Set sponsorship config for a selector (Governor only)
     * @param selector Function selector
     * @param config Sponsorship configuration
     */
    function setSponsorshipConfig(
        bytes4 selector,
        SponsorshipConfig calldata config
    ) external;

    /**
     * @notice Batch set sponsorship configs (Governor only)
     * @param selectors Function selectors
     * @param configs Sponsorship configurations
     */
    function batchSetSponsorshipConfig(
        bytes4[] calldata selectors,
        SponsorshipConfig[] calldata configs
    ) external;

    /**
     * @notice Check if operation is sponsored
     * @param selector Function selector
     * @return sponsored True if sponsored
     */
    function isSponsoredOperation(bytes4 selector) external view returns (bool sponsored);

    /**
     * @notice Get sponsorship config for selector
     * @param selector Function selector
     * @return config Sponsorship configuration
     */
    function getSponsorshipConfig(bytes4 selector) external view returns (SponsorshipConfig memory config);

    // ============================================
    // BRAND DEPOSITS
    // ============================================

    /**
     * @notice Deposit funds for brand sponsorship
     * @param brandId Brand identifier (keccak256 of brand name)
     */
    function depositForBrand(bytes32 brandId) external payable;

    /**
     * @notice Withdraw brand deposit
     * @param brandId Brand identifier
     * @param amount Amount to withdraw
     */
    function withdrawBrandDeposit(bytes32 brandId, uint256 amount) external;

    /**
     * @notice Set brand active status (Governor only)
     * @param brandId Brand identifier
     * @param active Whether brand is active
     */
    function setBrandActive(bytes32 brandId, bool active) external;

    /**
     * @notice Get brand deposit info
     * @param brandId Brand identifier
     * @return deposit Brand deposit info
     */
    function getBrandDeposit(bytes32 brandId) external view returns (BrandDeposit memory deposit);

    // ============================================
    // RATE LIMITING
    // ============================================

    /**
     * @notice Get user's daily usage for a selector
     * @param user User address
     * @param selector Function selector
     * @return count Number of sponsored calls today
     */
    function getUserDailyUsage(
        address user,
        bytes4 selector
    ) external view returns (uint256 count);

    /**
     * @notice Check if user can be sponsored
     * @param user User address
     * @param selector Function selector
     * @return canSponsor True if user hasn't exceeded limits
     */
    function canSponsor(
        address user,
        bytes4 selector
    ) external view returns (bool canSponsor);

    // ============================================
    // PROTOCOL OPERATIONS
    // ============================================

    /**
     * @notice Add protocol deposit for sponsoring
     */
    function depositProtocol() external payable;

    /**
     * @notice Withdraw protocol funds (Governor only)
     * @param amount Amount to withdraw
     * @param to Recipient address
     */
    function withdrawProtocol(uint256 amount, address to) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get EntryPoint address
     * @return entryPoint EntryPoint contract
     */
    function entryPoint() external view returns (address entryPoint);

    /**
     * @notice Get governor address
     * @return governor Governor address
     */
    function governor() external view returns (address governor);

    /**
     * @notice Get protocol deposit balance
     * @return balance Protocol deposit
     */
    function getProtocolDeposit() external view returns (uint256 balance);

    /**
     * @notice Get total gas sponsored
     * @return total Total gas cost sponsored
     */
    function totalGasSponsored() external view returns (uint256 total);

    /**
     * @notice Get contract version
     * @return version Version string
     */
    function version() external pure returns (string memory version);
}
