// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IPaymaster} from "@account-abstraction/interfaces/IPaymaster.sol";
import {IEntryPoint} from "@account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "@account-abstraction/core/UserOperationLib.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITAGITPaymaster} from "../interfaces/ITAGITPaymaster.sol";
import {CircuitBreaker} from "../libraries/CircuitBreaker.sol";
import {DrainDetector} from "../libraries/DrainDetector.sol";

/**
 * @title TAGITPaymaster
 * @author TAG IT Network <dev@tagit.network>
 * @notice Gas sponsorship paymaster for TAG IT operations
 * @dev Sponsors whitelisted operations with rate limiting
 */
contract TAGITPaymaster is
    IPaymaster,
    ITAGITPaymaster,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using UserOperationLib for PackedUserOperation;
    using CircuitBreaker for CircuitBreaker.Config;
    using DrainDetector for DrainDetector.Config;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Paymaster data offset constant
    uint256 internal constant PAYMASTER_DATA_OFFSET = UserOperationLib.PAYMASTER_DATA_OFFSET;

    /// @notice Minimum deposit required
    uint256 public constant MIN_DEPOSIT = 0.01 ether;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice EntryPoint contract
    IEntryPoint private _entryPoint;

    /// @notice Governor address
    address private _governor;

    /// @notice Sponsorship configs by selector
    mapping(bytes4 => SponsorshipConfig) private _sponsorshipConfigs;

    /// @notice Brand deposits
    mapping(bytes32 => BrandDeposit) private _brandDeposits;

    /// @notice Brand owners (who can withdraw)
    mapping(bytes32 => address) private _brandOwners;

    /// @notice Daily usage: user => selector => day => count
    mapping(address => mapping(bytes4 => mapping(uint256 => uint256))) private _dailyUsage;

    /// @notice Total gas sponsored
    uint256 private _totalGasSponsored;

    /// @notice Protocol deposit balance
    uint256 private _protocolDeposit;

    // PATCH-12: pending brand ownership transfers
    mapping(bytes32 => address) private _pendingBrandOwners;

    // ============================================
    // NIST SECURITY CONTROLS (SI-4, IR-4)
    // ============================================

    /// @notice Circuit breaker for sponsorship spam protection
    CircuitBreaker.Config private _sponsorCircuit;

    /// @notice Drain detector for gas spending anomalies
    DrainDetector.Config private _drainDetector;

    /// @notice Paused state for emergency stop
    bool private _paused;

    // ============================================
    // CONSTRUCTOR & INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the paymaster
     * @param entryPointAddr EntryPoint contract address
     * @param governorAddr Governor address
     * @param initialOwner Initial owner for upgrades
     */
    function initialize(
        address entryPointAddr,
        address governorAddr,
        address initialOwner
    ) external initializer {
        if (entryPointAddr == address(0)) revert ZeroAddress();
        if (governorAddr == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        _entryPoint = IEntryPoint(entryPointAddr);
        _governor = governorAddr;

        // Initialize NIST security controls (SI-4, IR-4)
        // Circuit breaker: 500 ops/hour, 1hr window, 2hr cooldown
        _sponsorCircuit.initialize(500, 1 hours, 2 hours);
        // Drain detector: 1hr window, 10% spike, 25% velocity, 100 tx/window, 2hr cooldown, 0 initial balance
        _drainDetector.initialize(1 hours, 1000, 2500, 100, 2 hours, 0);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyEntryPoint() {
        if (msg.sender != address(_entryPoint)) {
            revert NotEntryPoint(msg.sender);
        }
        _;
    }

    modifier onlyGovernor() {
        if (msg.sender != _governor) {
            revert NotGovernor(msg.sender);
        }
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert PaymasterPaused();
        _;
    }

    // ============================================
    // IPaymaster IMPLEMENTATION
    // ============================================

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        return _validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /* userOpHash */,
        uint256 maxCost
    ) internal returns (bytes memory context, uint256 validationData) {
        // ============================================
        // NIST SECURITY CHECKS (SI-4, IR-4)
        // ============================================
        // Check if paused
        if (_paused) revert PaymasterPaused();

        // Check circuit breaker - trips on volume anomaly
        if (_sponsorCircuit.check()) {
            _paused = true;
            emit PaymasterPausedEvent(block.timestamp, "circuit_breaker");
        }

        // Extract selector from callData
        if (userOp.callData.length < 4) {
            revert InvalidPaymasterData();
        }

        // Get the account-level selector (execute, executeBatch, etc.)
        bytes4 accountSelector = bytes4(userOp.callData[:4]);

        // For execute calls, try to extract the target contract's selector
        bytes4 selector = accountSelector;

        // execute(address dest, uint256 value, bytes calldata func) signature
        bytes4 executeSelector = bytes4(keccak256("execute(address,uint256,bytes)"));

        if (accountSelector == executeSelector && userOp.callData.length >= 100) {
            // ABI: 4 (selector) + 32 (address) + 32 (value) + 32 (offset) = 100
            // The func data starts after the offset pointer
            // Simplified: assume func bytes are at fixed position after offset (68 + 32 = 100)
            // The first 32 bytes after offset is length, then data
            // For sponsorship, we check the target function's selector
            // At position 100 is the length, at 132 starts the actual func data
            if (userOp.callData.length >= 136) { // 100 + 32 (length) + 4 (selector)
                selector = bytes4(userOp.callData[132:136]);
            }
        }

        // Check if operation is sponsored
        SponsorshipConfig storage config = _sponsorshipConfigs[selector];
        if (!config.active) {
            revert OperationNotSponsored(selector);
        }

        // Check gas limit
        if (maxCost > config.maxGas * tx.gasprice) {
            revert GasLimitExceeded(maxCost, config.maxGas);
        }

        // Check daily limit
        address user = userOp.sender;
        uint256 today = block.timestamp / 1 days;
        uint256 dailyCount = _dailyUsage[user][selector][today];

        if (config.dailyLimit > 0 && dailyCount >= config.dailyLimit) {
            revert DailyLimitExceeded(user, selector, config.dailyLimit);
        }

        // Check we have sufficient deposit
        uint256 deposit = _entryPoint.balanceOf(address(this));
        if (deposit < maxCost) {
            revert DepositTooLow(maxCost, deposit);
        }

        // Increment daily usage
        _dailyUsage[user][selector][today] = dailyCount + 1;

        // Parse brand ID from paymasterData if present
        bytes32 brandId;
        if (userOp.paymasterAndData.length > PAYMASTER_DATA_OFFSET + 32) {
            brandId = bytes32(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET + 32]);
        }

        // Return context for postOp (user, selector, brandId, maxCost)
        context = abi.encode(user, selector, brandId, maxCost);
        validationData = 0; // Valid
    }

    /// @inheritdoc IPaymaster
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /* actualUserOpFeePerGas */
    ) external override onlyEntryPoint {
        (address user, bytes4 selector, bytes32 brandId, ) = abi.decode(
            context,
            (address, bytes4, bytes32, uint256)
        );

        // Track gas sponsored
        _totalGasSponsored += actualGasCost;

        // ============================================
        // NIST DRAIN DETECTION (SI-4)
        // ============================================
        // Check for anomalous gas spending
        uint8 drainTripReason = _drainDetector.checkWithdrawal(actualGasCost);
        if (drainTripReason > 0) {
            _paused = true;
            emit PaymasterPausedEvent(block.timestamp, "drain_detected");
        }
        // Record the withdrawal to update tracked balance
        _drainDetector.recordWithdrawal(actualGasCost);

        // Deduct from brand deposit if specified
        if (brandId != bytes32(0)) {
            BrandDeposit storage brand = _brandDeposits[brandId];
            if (brand.active && brand.balance >= actualGasCost) {
                brand.balance -= actualGasCost;
                brand.totalSpent += actualGasCost;
            }
        }

        emit OperationSponsored(user, selector, actualGasCost, brandId);
        (mode); // Silence unused warning
    }

    // ============================================
    // SPONSORSHIP MANAGEMENT
    // ============================================

    /// @inheritdoc ITAGITPaymaster
    function setSponsorshipConfig(
        bytes4 selector,
        SponsorshipConfig calldata config
    ) external override onlyGovernor {
        _sponsorshipConfigs[selector] = config;
        emit SponsorshipConfigSet(selector, config.maxGas, config.dailyLimit, config.active);
    }

    /// @inheritdoc ITAGITPaymaster
    function batchSetSponsorshipConfig(
        bytes4[] calldata selectors,
        SponsorshipConfig[] calldata configs
    ) external override onlyGovernor {
        if (selectors.length != configs.length) revert InvalidPaymasterData();

        for (uint256 i = 0; i < selectors.length; i++) {
            _sponsorshipConfigs[selectors[i]] = configs[i];
            emit SponsorshipConfigSet(
                selectors[i],
                configs[i].maxGas,
                configs[i].dailyLimit,
                configs[i].active
            );
        }
    }

    /// @inheritdoc ITAGITPaymaster
    function isSponsoredOperation(bytes4 selector) external view override returns (bool) {
        return _sponsorshipConfigs[selector].active;
    }

    /// @inheritdoc ITAGITPaymaster
    function getSponsorshipConfig(bytes4 selector) external view override returns (SponsorshipConfig memory) {
        return _sponsorshipConfigs[selector];
    }

    // ============================================
    // BRAND DEPOSITS
    // ============================================

    /// @inheritdoc ITAGITPaymaster
    function depositForBrand(bytes32 brandId) external payable override nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        // PATCH-13: brand must be pre-registered — no permissionless creation
        BrandDeposit storage brand = _brandDeposits[brandId];
        if (brand.brandId == bytes32(0)) revert BrandNotRegistered(brandId);

        brand.balance += msg.value;

        // Deposit to EntryPoint
        _entryPoint.depositTo{value: msg.value}(address(this));

        // Track deposit in drain detector
        _drainDetector.recordDeposit(msg.value);

        emit BrandDeposited(brandId, msg.value, brand.balance);
    }

    /// @inheritdoc ITAGITPaymaster
    /// @dev Security: No reentrancy/race risk in two-step ownership transfer.
    ///      _brandOwners[brandId] is checked against msg.sender — only the CURRENT
    ///      owner can withdraw. The pending owner (from transferBrandOwnership) is stored
    ///      in _pendingBrandOwners and only enters _brandOwners AFTER calling
    ///      acceptBrandOwnership(). Until acceptance, the pending owner has zero withdrawal
    ///      capability. No double-withdrawal window exists because ownership transfer is
    ///      atomic on acceptance: _brandOwners updates and _pendingBrandOwners clears in
    ///      the same transaction.
    function withdrawBrandDeposit(bytes32 brandId, uint256 amount) external override nonReentrant {
        // PATCH-12: proper brand owner check
        if (_brandOwners[brandId] != msg.sender) revert NotBrandOwner(brandId, msg.sender);

        BrandDeposit storage brand = _brandDeposits[brandId];
        if (brand.balance < amount) {
            revert WithdrawalExceedsBalance(amount, brand.balance);
        }

        brand.balance -= amount;

        // Withdraw from EntryPoint
        _entryPoint.withdrawTo(payable(msg.sender), amount);

        emit BrandWithdrawn(brandId, amount, brand.balance);
    }

    /// @inheritdoc ITAGITPaymaster
    function setBrandActive(bytes32 brandId, bool active) external override onlyGovernor {
        _brandDeposits[brandId].active = active;
        emit BrandStatusChanged(brandId, active);
    }

    /// @inheritdoc ITAGITPaymaster
    function getBrandDeposit(bytes32 brandId) external view override returns (BrandDeposit memory) {
        return _brandDeposits[brandId];
    }

    // ============================================
    // RATE LIMITING
    // ============================================

    /// @inheritdoc ITAGITPaymaster
    function getUserDailyUsage(
        address user,
        bytes4 selector
    ) external view override returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        return _dailyUsage[user][selector][today];
    }

    /// @inheritdoc ITAGITPaymaster
    function canSponsor(
        address user,
        bytes4 selector
    ) external view override returns (bool) {
        SponsorshipConfig storage config = _sponsorshipConfigs[selector];
        if (!config.active) return false;
        if (config.dailyLimit == 0) return true;

        uint256 today = block.timestamp / 1 days;
        return _dailyUsage[user][selector][today] < config.dailyLimit;
    }

    // ============================================
    // PROTOCOL OPERATIONS
    // ============================================

    /// @inheritdoc ITAGITPaymaster
    function depositProtocol() external payable override nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        _protocolDeposit += msg.value;
        _entryPoint.depositTo{value: msg.value}(address(this));

        // Track deposit in drain detector
        _drainDetector.recordDeposit(msg.value);

        emit ProtocolDeposited(msg.value);
    }

    /// @inheritdoc ITAGITPaymaster
    function withdrawProtocol(uint256 amount, address to) external override onlyGovernor nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > _protocolDeposit) {
            revert WithdrawalExceedsBalance(amount, _protocolDeposit);
        }

        _protocolDeposit -= amount;
        _entryPoint.withdrawTo(payable(to), amount);

        emit ProtocolWithdrawn(amount, to);
    }

    // ============================================
    // STAKE MANAGEMENT (Required by bundlers)
    // ============================================

    /**
     * @notice Add stake to EntryPoint
     * @param unstakeDelaySec Unstake delay in seconds
     */
    function addStake(uint32 unstakeDelaySec) external payable onlyGovernor {
        _entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /**
     * @notice Unlock stake
     */
    function unlockStake() external onlyGovernor {
        _entryPoint.unlockStake();
    }

    /**
     * @notice Withdraw stake after unlock
     * @param withdrawAddress Address to receive stake
     */
    function withdrawStake(address payable withdrawAddress) external onlyGovernor {
        _entryPoint.withdrawStake(withdrawAddress);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @inheritdoc ITAGITPaymaster
    function entryPoint() external view override returns (address) {
        return address(_entryPoint);
    }

    /// @inheritdoc ITAGITPaymaster
    function governor() external view override returns (address) {
        return _governor;
    }

    /// @inheritdoc ITAGITPaymaster
    function getProtocolDeposit() external view override returns (uint256) {
        return _protocolDeposit;
    }

    /// @inheritdoc ITAGITPaymaster
    function totalGasSponsored() external view override returns (uint256) {
        return _totalGasSponsored;
    }

    /**
     * @notice Get deposit balance on EntryPoint
     */
    function getDeposit() public view returns (uint256) {
        return _entryPoint.balanceOf(address(this));
    }

    /// @inheritdoc ITAGITPaymaster
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    // ============================================
    // PATCH-13: BRAND REGISTRATION (governor-gated)
    // ============================================

    /**
     * @notice Register a new brand (Governor only)
     * @dev Prevents permissionless brand squatting
     * @param brandId Brand identifier
     * @param owner Brand owner address
     */
    function registerBrand(bytes32 brandId, address owner) external onlyGovernor {
        if (owner == address(0)) revert ZeroAddress();
        if (_brandDeposits[brandId].brandId != bytes32(0)) revert BrandAlreadyRegistered(brandId);

        _brandDeposits[brandId].brandId = brandId;
        _brandDeposits[brandId].active = true;
        _brandOwners[brandId] = owner;

        emit BrandRegistered(brandId, owner, msg.sender);
    }

    // ============================================
    // PATCH-12: BRAND OWNERSHIP TRANSFER
    // ============================================

    /**
     * @notice Initiate brand ownership transfer (two-step)
     * @param brandId Brand identifier
     * @param newOwner New owner address
     */
    function transferBrandOwnership(bytes32 brandId, address newOwner) external {
        if (_brandOwners[brandId] != msg.sender) revert NotBrandOwner(brandId, msg.sender);
        if (newOwner == address(0)) revert ZeroAddress();
        _pendingBrandOwners[brandId] = newOwner;
        emit BrandOwnershipTransferInitiated(brandId, msg.sender, newOwner);
    }

    /**
     * @notice Accept brand ownership transfer
     * @param brandId Brand identifier
     */
    function acceptBrandOwnership(bytes32 brandId) external {
        if (_pendingBrandOwners[brandId] != msg.sender) revert NoPendingTransfer(brandId);
        _brandOwners[brandId] = msg.sender;
        delete _pendingBrandOwners[brandId];
        emit BrandOwnershipTransferred(brandId, msg.sender);
    }

    /**
     * @notice Get brand owner address
     * @param brandId Brand identifier
     * @return owner Brand owner
     */
    function brandOwner(bytes32 brandId) external view returns (address) {
        return _brandOwners[brandId];
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Update governor address
     * @param newGovernor New governor address
     */
    function setGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert ZeroAddress();
        address oldGovernor = _governor;
        _governor = newGovernor;
        emit GovernorUpdated(oldGovernor, newGovernor);
    }

    // ============================================
    // NIST SECURITY ADMIN FUNCTIONS (SI-4, IR-4)
    // ============================================

    /**
     * @notice Pause the paymaster
     * @dev Only governor can call
     */
    function pause() external onlyGovernor {
        _paused = true;
        emit PaymasterPausedEvent(block.timestamp, "manual");
    }

    /**
     * @notice Unpause the paymaster
     * @dev Only governor can call
     */
    function unpause() external onlyGovernor {
        _paused = false;
        emit PaymasterUnpausedEvent(block.timestamp);
    }

    /**
     * @notice Reset the circuit breaker
     * @dev Only governor can call
     */
    function resetCircuitBreaker() external onlyGovernor {
        _sponsorCircuit.forceReset(msg.sender);
    }

    /**
     * @notice Update drain detector tracked balance
     * @param newBalance New balance to track
     */
    function updateDrainBalance(uint128 newBalance) external onlyGovernor {
        _drainDetector.setBalance(newBalance);
    }

    /**
     * @notice Sync drain detector balance with actual EntryPoint deposit
     * @dev Call this after large protocol deposits to update tracking
     */
    function syncDrainBalance() external onlyGovernor {
        uint256 deposit = _entryPoint.balanceOf(address(this));
        // Cap at uint128 max
        uint128 balance = deposit > type(uint128).max ? type(uint128).max : uint128(deposit);
        _drainDetector.setBalance(balance);
    }

    /**
     * @notice Check if paymaster is paused
     */
    function paused() external view returns (bool) {
        return _paused;
    }

    /**
     * @notice Get circuit breaker state
     */
    function getCircuitBreakerState() external view returns (
        uint64 count,
        uint64 windowStart,
        bool tripped,
        uint64 cooldownEnds
    ) {
        return (
            _sponsorCircuit.count,
            _sponsorCircuit.windowStart,
            _sponsorCircuit.tripped,
            _sponsorCircuit.cooldownEnds
        );
    }

    /**
     * @notice Get drain detector state
     */
    function getDrainDetectorState() external view returns (
        uint128 trackedBalance,
        uint16 spikeThresholdBps,
        uint16 velocityThresholdBps,
        uint32 maxTxPerWindow,
        bool tripped,
        uint64 cooldownEnds
    ) {
        return (
            _drainDetector.trackedBalance,
            _drainDetector.spikeThresholdBps,
            _drainDetector.velocityThresholdBps,
            _drainDetector.maxTxPerWindow,
            _drainDetector.tripped,
            _drainDetector.cooldownEnds
        );
    }

    // ============================================
    // UUPS UPGRADE
    // ============================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============================================
    // RECEIVE
    // ============================================

    receive() external payable {
        // Accept ETH deposits
    }
}
