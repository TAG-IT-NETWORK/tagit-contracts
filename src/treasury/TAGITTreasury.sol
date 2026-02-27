// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ITAGITTreasury} from "../interfaces/ITAGITTreasury.sol";
import {DrainDetector} from "../libraries/DrainDetector.sol";

/**
 * @title TAGITTreasury
 * @author TAG IT Network <dev@tagit.network>
 * @notice Protocol treasury with allocation tracking and timelocked withdrawals
 * @dev Deploy behind TransparentUpgradeableProxy with Gnosis Safe as admin
 *
 * NIST CSF 2.0 Compliance:
 * - SI-4: Information System Monitoring - DrainDetector for anomaly detection
 * - IR-4: Incident Handling - automatic circuit breaker on drain detection
 * - AU-6: Audit Record Review - indexed events for Forta monitoring
 *
 * Fund flows:
 * - TAGITBurner routes 66.7% of fees here via deposit()
 * - TAGITGovernor creates allocations via proposals
 * - Recipients queue withdrawals, execute after timelock
 *
 * Timelock tiers:
 * - < $50k equivalent: 48 hours
 * - $50k - $250k: 72 hours
 * - > $250k: 7 days + 6/8 multisig approval
 */
contract TAGITTreasury is Initializable, ReentrancyGuard, PausableUpgradeable, ITAGITTreasury {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using DrainDetector for DrainDetector.Config;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Timelock for small withdrawals (< $50k)
    uint48 public constant TIMELOCK_SMALL = 48 hours;

    /// @notice Timelock for medium withdrawals ($50k - $250k)
    uint48 public constant TIMELOCK_MEDIUM = 72 hours;

    /// @notice Timelock for large withdrawals (> $250k)
    uint48 public constant TIMELOCK_LARGE = 7 days;

    /// @notice Threshold for medium timelock (50k TAGIT as proxy for $50k)
    uint256 public constant THRESHOLD_MEDIUM = 50_000e18;

    /// @notice Threshold for large timelock (250k TAGIT as proxy for $250k)
    uint256 public constant THRESHOLD_LARGE = 250_000e18;

    /// @notice Required signers for emergency sweep
    uint256 public constant REQUIRED_SIGNERS = 6;

    /// @notice Maximum allocation duration (2 years)
    uint48 public constant MAX_DURATION = 730 days;

    /// @notice Default spike threshold for DrainDetector (300% = 3x average)
    uint16 public constant DEFAULT_SPIKE_THRESHOLD = 3000; // 30% of balance

    /// @notice Default velocity threshold for DrainDetector (50% of balance in window)
    uint16 public constant DEFAULT_VELOCITY_THRESHOLD = 5000;

    /// @notice Default max transactions per window
    uint32 public constant DEFAULT_MAX_TXS_PER_WINDOW = 10;

    /// @notice Default window duration (1 hour)
    uint64 public constant DEFAULT_WINDOW_DURATION = 1 hours;

    /// @notice Default cooldown after trip (1 hour)
    uint64 public constant DEFAULT_COOLDOWN = 1 hours;

    /// @notice Initial tracked balance for drain detector (1M TAGIT)
    uint128 public constant INITIAL_TRACKED_BALANCE = 1_000_000e18;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice Governor contract address
    address private _governor;

    /// @notice TAGIT token address
    address private _tagitToken;

    /// @notice Total TAGIT allocated across all active allocations
    uint256 private _totalAllocated;

    /// @notice Next allocation ID
    uint256 private _nextAllocationId;

    /// @notice Next withdrawal ID
    uint256 private _nextWithdrawalId;

    /// @notice Allocations by ID
    mapping(uint256 => Allocation) private _allocations;

    /// @notice Pending withdrawals by ID
    mapping(uint256 => PendingWithdrawal) private _withdrawals;

    /// @notice Multisig signers
    mapping(address => bool) private _signers;

    /// @notice Number of active signers
    uint256 private _signerCount;

    // ============================================
    // DRAIN DETECTOR (NIST SI-4)
    // ============================================

    /// @notice Drain detector configuration and state
    DrainDetector.Config private _drainConfig;

    /// @notice Counter-based nonce for emergency sweep signature uniqueness (PATCH-08)
    uint256 private _sweepNonce;

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when drain is detected and withdrawal blocked
    event DrainDetected(uint256 indexed withdrawalId, address indexed recipient, uint256 amount, uint8 reason);

    /// @notice Emitted when drain detector is reset
    event DrainDetectorReset(address indexed admin);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Drain detected - withdrawal blocked
    error DrainBlocked(uint256 withdrawalId, address recipient, uint256 amount, uint8 reason);

    // ============================================
    // INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the treasury contract
     * @param governorAddress Governor contract address
     * @param tokenAddress TAGIT token address
     * @param initialSigners Initial multisig signers (should be 8)
     */
    function initialize(address governorAddress, address tokenAddress, address[] calldata initialSigners)
        external
        initializer
    {
        if (governorAddress == address(0)) revert ZeroAddress();
        if (tokenAddress == address(0)) revert ZeroAddress();

        __Pausable_init();

        _governor = governorAddress;
        _tagitToken = tokenAddress;
        _nextAllocationId = 1;
        _nextWithdrawalId = 1;

        // Initialize signers
        for (uint256 i = 0; i < initialSigners.length; i++) {
            if (initialSigners[i] == address(0)) revert ZeroAddress();
            if (!_signers[initialSigners[i]]) {
                _signers[initialSigners[i]] = true;
                _signerCount++;
                emit SignerUpdated(initialSigners[i], true);
            }
        }

        // Initialize drain detector (NIST SI-4)
        // Conservative defaults for treasury protection
        _drainConfig.initialize(
            DEFAULT_WINDOW_DURATION, // 1 hour window
            DEFAULT_SPIKE_THRESHOLD, // 30% spike threshold
            DEFAULT_VELOCITY_THRESHOLD, // 50% velocity threshold
            DEFAULT_MAX_TXS_PER_WINDOW, // 10 txs per window
            DEFAULT_COOLDOWN, // 1 hour cooldown
            INITIAL_TRACKED_BALANCE // Initial tracked balance
        );
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyGovernor() {
        if (msg.sender != _governor) {
            revert NotGovernor(msg.sender);
        }
        _;
    }

    // ============================================
    // DEPOSIT FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITTreasury
     */
    function deposit() external payable override nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        emit ETHDeposited(msg.sender, msg.value);
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function depositToken(address token, uint256 amount) external override nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update drain detector tracked balance for TAGIT token deposits
        if (token == _tagitToken) {
            _drainConfig.recordDeposit(amount);
        }

        emit TokenDeposited(token, msg.sender, amount);
    }

    /// @notice Receive ETH directly
    receive() external payable {
        emit ETHDeposited(msg.sender, msg.value);
    }

    // ============================================
    // ALLOCATION FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITTreasury
     */
    function createAllocation(bytes32 programId, uint256 amount, address recipient, uint48 duration)
        external
        override
        onlyGovernor
        nonReentrant
        returns (uint256 allocationId)
    {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (duration == 0 || duration > MAX_DURATION) revert InvalidDuration(duration);

        // Check available balance
        uint256 tagitBalance = IERC20(_tagitToken).balanceOf(address(this));
        uint256 available = tagitBalance > _totalAllocated ? tagitBalance - _totalAllocated : 0;
        if (amount > available) {
            revert ExceedsBalance(amount, available);
        }

        allocationId = _nextAllocationId++;

        _allocations[allocationId] = Allocation({
            programId: programId,
            amount: amount,
            spent: 0,
            recipient: recipient,
            createdAt: uint48(block.timestamp),
            expiresAt: uint48(block.timestamp) + duration,
            active: true
        });

        _totalAllocated += amount;

        emit AllocationCreated(allocationId, programId, recipient, amount, uint48(block.timestamp) + duration);
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function closeAllocation(uint256 allocationId) external override nonReentrant {
        Allocation storage alloc = _allocations[allocationId];

        if (alloc.amount == 0) revert AllocationNotFound(allocationId);
        if (!alloc.active) revert AllocationNotActive(allocationId);

        // Only governor or recipient can close
        if (msg.sender != _governor && msg.sender != alloc.recipient) {
            revert NotRecipient(msg.sender, alloc.recipient);
        }

        uint256 unspent = alloc.amount - alloc.spent;

        // Mark as inactive
        alloc.active = false;

        // Return unspent to pool
        _totalAllocated -= unspent;

        emit AllocationClosed(allocationId, unspent);
    }

    // ============================================
    // WITHDRAWAL FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITTreasury
     */
    function queueWithdrawal(uint256 allocationId, address token, uint256 amount, address to)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 withdrawalId)
    {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        Allocation storage alloc = _allocations[allocationId];

        // Validate allocation
        if (alloc.amount == 0) revert AllocationNotFound(allocationId);
        if (!alloc.active) revert AllocationNotActive(allocationId);
        if (block.timestamp >= alloc.expiresAt) {
            revert AllocationExpired(allocationId, alloc.expiresAt);
        }

        // Only recipient can queue
        if (msg.sender != alloc.recipient) {
            revert NotRecipient(msg.sender, alloc.recipient);
        }

        // PATCH-11: enforce asset matches allocated asset (TAGIT token only)
        // Allocations are tracked against TAGIT balance — only TAGIT withdrawals allowed
        if (token != _tagitToken) revert AssetMismatch(_tagitToken, token);

        // Check remaining allocation
        uint256 remaining = alloc.amount - alloc.spent;
        if (amount > remaining) {
            revert ExceedsAllocation(allocationId, amount, remaining);
        }

        // Calculate timelock
        (uint48 timelockSeconds,) = getTimelockForAmount(amount);

        withdrawalId = _nextWithdrawalId++;

        _withdrawals[withdrawalId] = PendingWithdrawal({
            allocationId: allocationId,
            amount: amount,
            token: token,
            to: to,
            queuedAt: uint48(block.timestamp),
            executesAt: uint48(block.timestamp) + timelockSeconds,
            status: WithdrawalStatus.PENDING
        });

        // Pre-commit the spend (CEI pattern)
        alloc.spent += amount;

        emit WithdrawalQueued(withdrawalId, allocationId, to, token, amount, uint48(block.timestamp) + timelockSeconds);
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function executeWithdrawal(uint256 withdrawalId) external override nonReentrant whenNotPaused {
        PendingWithdrawal storage withdrawal = _withdrawals[withdrawalId];

        if (withdrawal.amount == 0) revert WithdrawalNotFound(withdrawalId);
        if (withdrawal.status != WithdrawalStatus.PENDING) {
            revert WithdrawalNotPending(withdrawalId, withdrawal.status);
        }
        if (block.timestamp < withdrawal.executesAt) {
            revert TimelockNotPassed(withdrawalId, withdrawal.executesAt, uint48(block.timestamp));
        }

        // PATCH-07: Verify allocation hasn't expired since withdrawal was queued
        Allocation storage alloc = _allocations[withdrawal.allocationId];
        if (block.timestamp >= alloc.expiresAt) {
            revert AllocationExpired(withdrawal.allocationId, alloc.expiresAt);
        }

        // Check if large withdrawal requires multisig (handled separately)
        (, bool requiresMultisig) = getTimelockForAmount(withdrawal.amount);
        if (requiresMultisig) {
            // Large withdrawals must go through emergencySweep with signatures
            revert InsufficientApprovals(REQUIRED_SIGNERS, 0);
        }

        // NIST SI-4: Check drain detection for TAGIT token withdrawals
        if (withdrawal.token == _tagitToken || withdrawal.token == address(0)) {
            uint8 tripReason = _drainConfig.checkWithdrawal(withdrawal.amount);
            if (tripReason > 0) {
                emit DrainDetected(withdrawalId, withdrawal.to, withdrawal.amount, tripReason);
                revert DrainBlocked(withdrawalId, withdrawal.to, withdrawal.amount, tripReason);
            }
        }

        // EFFECTS: Update status before transfer
        withdrawal.status = WithdrawalStatus.EXECUTED;

        // Update total allocated
        _totalAllocated -= withdrawal.amount;

        // Update drain detector balance for TAGIT token
        if (withdrawal.token == _tagitToken) {
            _drainConfig.recordWithdrawal(withdrawal.amount);
        }

        // INTERACTIONS: Transfer funds
        if (withdrawal.token == address(0)) {
            // ETH transfer
            (bool success,) = withdrawal.to.call{value: withdrawal.amount}("");
            if (!success) revert ETHTransferFailed(withdrawal.to, withdrawal.amount);
        } else {
            // Token transfer
            IERC20(withdrawal.token).safeTransfer(withdrawal.to, withdrawal.amount);
        }

        emit WithdrawalExecuted(withdrawalId, withdrawal.to, withdrawal.token, withdrawal.amount);
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function cancelWithdrawal(uint256 withdrawalId) external override nonReentrant {
        PendingWithdrawal storage withdrawal = _withdrawals[withdrawalId];

        if (withdrawal.amount == 0) revert WithdrawalNotFound(withdrawalId);
        if (withdrawal.status != WithdrawalStatus.PENDING) {
            revert WithdrawalNotPending(withdrawalId, withdrawal.status);
        }

        Allocation storage alloc = _allocations[withdrawal.allocationId];

        // Only governor or recipient can cancel
        if (msg.sender != _governor && msg.sender != alloc.recipient) {
            revert NotRecipient(msg.sender, alloc.recipient);
        }

        // EFFECTS: Update status and restore allocation
        withdrawal.status = WithdrawalStatus.CANCELED;
        alloc.spent -= withdrawal.amount;

        emit WithdrawalCanceled(withdrawalId, msg.sender);
    }

    // ============================================
    // EMERGENCY FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITTreasury
     */
    function emergencySweep(address token, address to, bytes[] calldata signatures) external override nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (signatures.length < REQUIRED_SIGNERS) {
            revert InsufficientSigners(REQUIRED_SIGNERS, signatures.length);
        }

        // PATCH-08: Create message hash with counter-based nonce (replaces day-based)
        bytes32 messageHash =
            keccak256(abi.encodePacked("TAGIT_EMERGENCY_SWEEP", block.chainid, address(this), token, to, _sweepNonce));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();

        // Verify signatures
        uint256 validSigners = 0;
        address[] memory seenSigners = new address[](signatures.length);

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ethSignedHash.recover(signatures[i]);

            if (!_signers[signer]) {
                revert InvalidSignature(signer);
            }

            // Check for duplicate signers
            for (uint256 j = 0; j < validSigners; j++) {
                if (seenSigners[j] == signer) {
                    revert InvalidSignature(signer);
                }
            }

            seenSigners[validSigners] = signer;
            validSigners++;
        }

        if (validSigners < REQUIRED_SIGNERS) {
            revert InsufficientSigners(REQUIRED_SIGNERS, validSigners);
        }

        // Get amount to sweep
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
        } else {
            amount = IERC20(token).balanceOf(address(this));
        }

        // Note: Emergency sweep bypasses drain detection as it requires 6/8 multisig
        // The multisig approval IS the security check for this path

        // EFFECTS: Reset allocations before external calls (CEI pattern)
        _totalAllocated = 0;
        _sweepNonce++; // PATCH-08: Increment nonce to prevent signature replay

        // Emit event before external calls
        emit EmergencySweep(token, to, amount, validSigners);

        // INTERACTIONS: Execute sweep
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ============================================
    // DRAIN DETECTOR ADMIN (NIST SI-4)
    // ============================================

    /**
     * @notice Force reset the drain detector
     * @dev Use with caution - clears trip state and resets window
     */
    function resetDrainDetector() external onlyGovernor {
        _drainConfig.forceReset(msg.sender);
        emit DrainDetectorReset(msg.sender);
    }

    /**
     * @notice Update drain detector thresholds
     * @param spikeThreshold New spike threshold (basis points, e.g., 3000 = 30%)
     * @param velocityThreshold New velocity threshold (basis points, e.g., 5000 = 50%)
     * @param maxTxsPerWindow Maximum transactions per window
     */
    function setDrainThresholds(uint16 spikeThreshold, uint16 velocityThreshold, uint32 maxTxsPerWindow)
        external
        onlyGovernor
    {
        _drainConfig.updateThresholds(spikeThreshold, velocityThreshold, maxTxsPerWindow);
    }

    /**
     * @notice Enable or disable drain detector
     * @param enabled Whether to enable detection
     */
    function setDrainDetectorEnabled(bool enabled) external onlyGovernor {
        _drainConfig.setEnabled(enabled);
    }

    /**
     * @notice Sync drain detector tracked balance with actual token balance
     */
    function syncDrainDetectorBalance() external onlyGovernor {
        uint256 actualBalance = IERC20(_tagitToken).balanceOf(address(this));
        _drainConfig.setBalance(uint128(actualBalance));
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

    /**
     * @notice Add or remove a signer
     * @param signer Signer address
     * @param active Whether signer is active
     */
    function setSigner(address signer, bool active) external onlyGovernor {
        if (signer == address(0)) revert ZeroAddress();

        if (active && !_signers[signer]) {
            _signers[signer] = true;
            _signerCount++;
        } else if (!active && _signers[signer]) {
            _signers[signer] = false;
            _signerCount--;
        }

        emit SignerUpdated(signer, active);
    }

    /**
     * @notice Pause withdrawals
     */
    function pause() external onlyGovernor {
        _pause();
    }

    /**
     * @notice Unpause withdrawals
     */
    function unpause() external onlyGovernor {
        _unpause();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITTreasury
     */
    function getAllocation(uint256 allocationId) external view override returns (Allocation memory) {
        return _allocations[allocationId];
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function getWithdrawal(uint256 withdrawalId) external view override returns (PendingWithdrawal memory) {
        return _withdrawals[withdrawalId];
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function getBalance() external view override returns (uint256 eth, uint256 tagit) {
        eth = address(this).balance;
        tagit = IERC20(_tagitToken).balanceOf(address(this));
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function totalAllocated() external view override returns (uint256) {
        return _totalAllocated;
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function totalUnallocated() external view override returns (uint256) {
        uint256 tagitBalance = IERC20(_tagitToken).balanceOf(address(this));
        return tagitBalance > _totalAllocated ? tagitBalance - _totalAllocated : 0;
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function remainingAllocation(uint256 allocationId) external view override returns (uint256) {
        Allocation storage alloc = _allocations[allocationId];
        if (!alloc.active) return 0;
        return alloc.amount - alloc.spent;
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function governor() external view override returns (address) {
        return _governor;
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function tagitToken() external view override returns (address) {
        return _tagitToken;
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function isSigner(address signer) external view override returns (bool) {
        return _signers[signer];
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function requiredSigners() external pure override returns (uint256) {
        return REQUIRED_SIGNERS;
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function getTimelockForAmount(uint256 amount)
        public
        pure
        override
        returns (uint48 timelockSeconds, bool requiresMultisig)
    {
        if (amount >= THRESHOLD_LARGE) {
            return (TIMELOCK_LARGE, true);
        } else if (amount >= THRESHOLD_MEDIUM) {
            return (TIMELOCK_MEDIUM, false);
        } else {
            return (TIMELOCK_SMALL, false);
        }
    }

    /**
     * @notice Get the current sweep nonce (PATCH-08)
     * @return Current nonce value used in emergency sweep signature hash
     */
    function sweepNonce() external view returns (uint256) {
        return _sweepNonce;
    }

    /**
     * @inheritdoc ITAGITTreasury
     */
    function version() external pure override returns (string memory) {
        return "1.1.0";
    }

    // ============================================
    // DRAIN DETECTOR VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Check if drain detector is enabled
     * @return Whether detection is enabled
     */
    function isDrainDetectorEnabled() external view returns (bool) {
        return _drainConfig.isEnabled();
    }

    /**
     * @notice Get drain detector status
     * @return isTripped Whether detector is tripped
     * @return cooldownRemaining Seconds until cooldown ends
     */
    function getDrainDetectorStatus() external view returns (bool isTripped, uint256 cooldownRemaining) {
        return _drainConfig.status();
    }

    /**
     * @notice Get drain detector window statistics
     * @return outflow Cumulative outflow in current window
     * @return txCount Transaction count in current window
     * @return windowStart_ Start of current window
     * @return windowRemaining Seconds remaining in current window
     */
    function getDrainDetectorWindowStats()
        external
        view
        returns (uint256 outflow, uint32 txCount, uint64 windowStart_, uint256 windowRemaining)
    {
        return _drainConfig.windowStats();
    }

    /**
     * @notice Get remaining capacity before triggering drain detection
     * @return spikeCapacity Max single withdrawal allowed
     * @return velocityCapacity Remaining cumulative outflow allowed
     * @return txCapacity Remaining transactions allowed
     */
    function getDrainDetectorCapacity()
        external
        view
        returns (uint256 spikeCapacity, uint256 velocityCapacity, uint32 txCapacity)
    {
        return _drainConfig.remainingCapacity();
    }

    /**
     * @notice Check if a withdrawal would trigger drain detection
     * @param amount Proposed withdrawal amount
     * @return wouldTrip Whether this would trigger detection
     * @return reason 0=OK, 1=spike, 2=velocity, 3=frequency
     */
    function wouldTriggerDrainDetection(uint256 amount) external view returns (bool wouldTrip, uint8 reason) {
        return _drainConfig.wouldTrigger(amount);
    }

    /**
     * @notice Get drain detector tracked balance
     * @return Tracked balance
     */
    function getDrainDetectorBalance() external view returns (uint256) {
        return _drainConfig.getBalance();
    }
}
