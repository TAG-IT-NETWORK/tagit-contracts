// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DrainDetector
 * @author TAG IT Network <dev@tagit.network>
 * @notice NIST SI-4 compliant anomaly detection for treasury/paymaster drain prevention
 * @dev Detects abnormal outflows via multiple heuristics
 *
 * NIST CSF 2.0 Compliance:
 * - SI-4: System Monitoring - detect anomalous transaction patterns
 * - IR-4: Incident Response - auto-pause on detected anomaly
 * - AU-6: Audit Record Review - indexed events for SIEM/Forta
 *
 * Detection Heuristics:
 * 1. Single withdrawal > X% of tracked balance (spike detection)
 * 2. Cumulative outflow > Y% of balance in window (velocity detection)
 * 3. Transaction count > Z per window (frequency detection)
 *
 * Gas Optimization:
 * - Single packed struct (2 slots)
 * - checkWithdrawal() < 5,000 gas (warm)
 * - Events indexed for efficient filtering
 *
 * @custom:security This is a defense-in-depth mechanism.
 * It should complement, not replace, proper access controls.
 */
library DrainDetector {
    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Drain detector configuration and state
     * @dev Packed into 2 storage slots
     *
     * Slot 1 (256 bits):
     * - windowDuration: 64 bits (detection window in seconds)
     * - windowStart: 64 bits (current window start timestamp)
     * - spikeThresholdBps: 16 bits (max single withdrawal as % of balance, in basis points)
     * - velocityThresholdBps: 16 bits (max cumulative outflow as % in window, in basis points)
     * - maxTxPerWindow: 32 bits (max transactions per window)
     * - enabled: 8 bits (boolean)
     * - tripped: 8 bits (boolean - detector tripped)
     * - padding: 48 bits
     *
     * Slot 2 (256 bits):
     * - trackedBalance: 128 bits (balance being monitored)
     * - windowOutflow: 128 bits (cumulative outflow in current window)
     *
     * Slot 3 (256 bits):
     * - windowTxCount: 32 bits (transactions in current window)
     * - cooldownEnds: 64 bits (when cooldown period ends)
     * - cooldownDuration: 64 bits (duration of cooldown after trip)
     * - padding: 96 bits
     */
    struct Config {
        // Slot 1 - Detection parameters
        uint64 windowDuration; // Detection window duration
        uint64 windowStart; // Current window start
        uint16 spikeThresholdBps; // Max single tx as % of balance (basis points)
        uint16 velocityThresholdBps; // Max cumulative outflow % in window
        uint32 maxTxPerWindow; // Max transactions per window
        bool enabled; // Whether detection is enabled
        bool tripped; // Whether detector has tripped
        // Slot 2 - Balance tracking
        uint128 trackedBalance; // Balance being monitored
        uint128 windowOutflow; // Cumulative outflow this window
        // Slot 3 - Transaction tracking
        uint32 windowTxCount; // Tx count this window
        uint64 cooldownEnds; // Cooldown end timestamp
        uint64 cooldownDuration; // Cooldown duration after trip
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Single withdrawal exceeds spike threshold
    /// @param amount Withdrawal amount
    /// @param threshold Maximum allowed (spike threshold)
    /// @param balance Current tracked balance
    error SpikeDetected(uint256 amount, uint256 threshold, uint256 balance);

    /// @notice Cumulative outflow exceeds velocity threshold
    /// @param totalOutflow Total outflow in window
    /// @param threshold Maximum allowed
    /// @param balance Tracked balance
    error VelocityBreached(uint256 totalOutflow, uint256 threshold, uint256 balance);

    /// @notice Too many transactions in window
    /// @param count Current transaction count
    /// @param maxAllowed Maximum allowed per window
    error FrequencyBreached(uint256 count, uint256 maxAllowed);

    /// @notice Detector is in cooldown after trip
    /// @param remaining Seconds until cooldown ends
    error DetectorCooldown(uint256 remaining);

    /// @notice Invalid configuration parameters
    /// @param reason Description of invalid parameter
    error InvalidConfig(string reason);

    // ============================================
    // EVENTS (Forta-compatible)
    // ============================================

    /**
     * @notice Emitted when a spike is detected (single large withdrawal)
     * @param timestamp When detected
     * @param amount Withdrawal amount
     * @param thresholdBps Configured threshold in basis points
     * @param balance Tracked balance at time of detection
     */
    event SpikeAlert(uint256 indexed timestamp, uint256 amount, uint16 thresholdBps, uint256 balance);

    /**
     * @notice Emitted when velocity threshold breached (cumulative outflow)
     * @param timestamp When detected
     * @param totalOutflow Total outflow in window
     * @param thresholdBps Configured threshold in basis points
     * @param balance Tracked balance
     */
    event VelocityAlert(uint256 indexed timestamp, uint256 totalOutflow, uint16 thresholdBps, uint256 balance);

    /**
     * @notice Emitted when frequency threshold breached
     * @param timestamp When detected
     * @param txCount Transaction count in window
     * @param maxAllowed Maximum allowed
     */
    event FrequencyAlert(uint256 indexed timestamp, uint256 txCount, uint256 maxAllowed);

    /**
     * @notice Emitted when approaching thresholds (early warning)
     * @param timestamp When warning issued
     * @param warningType 1=spike, 2=velocity, 3=frequency
     * @param currentValue Current metric value
     * @param threshold Configured threshold
     */
    event DrainWarning(uint256 indexed timestamp, uint8 warningType, uint256 currentValue, uint256 threshold);

    /**
     * @notice Emitted when detector trips (auto-pause)
     * @param timestamp When tripped
     * @param reason Trip reason code (1=spike, 2=velocity, 3=frequency)
     * @param cooldownEnds When cooldown ends
     */
    event DetectorTripped(uint256 indexed timestamp, uint8 reason, uint256 cooldownEnds);

    /**
     * @notice Emitted when detector resets after cooldown
     * @param timestamp When reset
     * @param previousCooldownEnd Previous cooldown end time
     */
    event DetectorReset(uint256 indexed timestamp, uint256 previousCooldownEnd);

    /**
     * @notice Emitted when admin force resets detector
     * @param timestamp When reset
     * @param admin Address that triggered reset
     */
    event DetectorForceReset(uint256 indexed timestamp, address indexed admin);

    /**
     * @notice Emitted when tracked balance is updated
     * @param oldBalance Previous balance
     * @param newBalance New balance
     */
    event BalanceUpdated(uint256 oldBalance, uint256 newBalance);

    // ============================================
    // CONSTANTS
    // ============================================

    uint16 internal constant BPS_DENOMINATOR = 10000;
    uint8 internal constant WARNING_THRESHOLD_PERCENT = 80;

    uint8 internal constant REASON_SPIKE = 1;
    uint8 internal constant REASON_VELOCITY = 2;
    uint8 internal constant REASON_FREQUENCY = 3;

    // ============================================
    // INITIALIZATION
    // ============================================

    /**
     * @notice Initialize drain detector with configuration
     * @dev Must be called before first use
     * @param self Storage reference to config
     * @param windowDuration_ Detection window duration in seconds
     * @param spikeThresholdBps_ Max single withdrawal as % of balance (basis points, e.g., 1000 = 10%)
     * @param velocityThresholdBps_ Max cumulative outflow % in window (basis points)
     * @param maxTxPerWindow_ Max transactions per window
     * @param cooldownDuration_ Cooldown duration after trip
     * @param initialBalance_ Initial tracked balance
     */
    function initialize(
        Config storage self,
        uint64 windowDuration_,
        uint16 spikeThresholdBps_,
        uint16 velocityThresholdBps_,
        uint32 maxTxPerWindow_,
        uint64 cooldownDuration_,
        uint128 initialBalance_
    ) internal {
        if (windowDuration_ == 0) revert InvalidConfig("window cannot be 0");
        if (spikeThresholdBps_ == 0 || spikeThresholdBps_ > BPS_DENOMINATOR) {
            revert InvalidConfig("spike threshold invalid");
        }
        if (velocityThresholdBps_ == 0 || velocityThresholdBps_ > BPS_DENOMINATOR) {
            revert InvalidConfig("velocity threshold invalid");
        }
        if (maxTxPerWindow_ == 0) revert InvalidConfig("maxTx cannot be 0");
        if (cooldownDuration_ == 0) revert InvalidConfig("cooldown cannot be 0");

        self.windowDuration = windowDuration_;
        self.windowStart = uint64(block.timestamp);
        self.spikeThresholdBps = spikeThresholdBps_;
        self.velocityThresholdBps = velocityThresholdBps_;
        self.maxTxPerWindow = maxTxPerWindow_;
        self.cooldownDuration = cooldownDuration_;
        self.trackedBalance = initialBalance_;
        self.windowOutflow = 0;
        self.windowTxCount = 0;
        self.cooldownEnds = 0;
        self.enabled = true;
        self.tripped = false;
    }

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Check withdrawal against drain detection rules
     * @dev Call this BEFORE processing any withdrawal.
     *
     * IMPORTANT: This function does NOT revert on anomaly detection.
     * It returns a trip reason code and sets tripped state. The CALLER
     * is responsible for checking the return value and reverting if needed.
     *
     * Detection order:
     * 1. Check cooldown status
     * 2. Reset window if needed
     * 3. Check spike (single tx)
     * 4. Check velocity (cumulative)
     * 5. Check frequency (tx count)
     * 6. Update state
     *
     * Gas costs (measured):
     * - Warm read: ~4,500 gas
     * - Cold read: ~6,000 gas
     *
     * @param self Storage reference to config
     * @param withdrawalAmount Amount being withdrawn
     * @return tripReason 0 if OK, 1-3 if tripped (spike/velocity/frequency)
     */
    function checkWithdrawal(Config storage self, uint256 withdrawalAmount) internal returns (uint8 tripReason) {
        // Skip if disabled
        if (!self.enabled) {
            return 0;
        }

        // Check if in cooldown
        if (self.tripped) {
            if (block.timestamp < self.cooldownEnds) {
                revert DetectorCooldown(self.cooldownEnds - block.timestamp);
            }
            // Cooldown expired - reset
            uint256 previousCooldown = self.cooldownEnds;
            _reset(self);
            emit DetectorReset(block.timestamp, previousCooldown);
        }

        // Reset window if needed
        if (block.timestamp >= self.windowStart + self.windowDuration) {
            self.windowStart = uint64(block.timestamp);
            self.windowOutflow = 0;
            self.windowTxCount = 0;
        }

        uint256 balance = self.trackedBalance;

        // 1. SPIKE DETECTION - single large withdrawal
        uint256 spikeThreshold = (balance * self.spikeThresholdBps) / BPS_DENOMINATOR;
        if (withdrawalAmount > spikeThreshold) {
            _trip(self, REASON_SPIKE);
            emit SpikeAlert(block.timestamp, withdrawalAmount, self.spikeThresholdBps, balance);
            return REASON_SPIKE;
        }

        // Warn at 80% of spike threshold
        uint256 spikeWarning = (spikeThreshold * WARNING_THRESHOLD_PERCENT) / 100;
        if (withdrawalAmount > spikeWarning) {
            emit DrainWarning(block.timestamp, REASON_SPIKE, withdrawalAmount, spikeThreshold);
        }

        // 2. VELOCITY DETECTION - cumulative outflow
        uint256 newOutflow = self.windowOutflow + withdrawalAmount;
        uint256 velocityThreshold = (balance * self.velocityThresholdBps) / BPS_DENOMINATOR;
        if (newOutflow > velocityThreshold) {
            _trip(self, REASON_VELOCITY);
            emit VelocityAlert(block.timestamp, newOutflow, self.velocityThresholdBps, balance);
            return REASON_VELOCITY;
        }

        // Warn at 80% of velocity threshold
        uint256 velocityWarning = (velocityThreshold * WARNING_THRESHOLD_PERCENT) / 100;
        if (newOutflow > velocityWarning && self.windowOutflow <= velocityWarning) {
            emit DrainWarning(block.timestamp, REASON_VELOCITY, newOutflow, velocityThreshold);
        }

        // 3. FREQUENCY DETECTION - tx count
        uint32 newTxCount = self.windowTxCount + 1;
        if (newTxCount > self.maxTxPerWindow) {
            _trip(self, REASON_FREQUENCY);
            emit FrequencyAlert(block.timestamp, newTxCount, self.maxTxPerWindow);
            return REASON_FREQUENCY;
        }

        // Warn at 80% of frequency threshold
        uint32 frequencyWarning = (self.maxTxPerWindow * WARNING_THRESHOLD_PERCENT) / 100;
        if (newTxCount > frequencyWarning && self.windowTxCount <= frequencyWarning) {
            emit DrainWarning(block.timestamp, REASON_FREQUENCY, newTxCount, self.maxTxPerWindow);
        }

        // Update state (passed all checks)
        self.windowOutflow = uint128(newOutflow);
        self.windowTxCount = newTxCount;

        return 0;
    }

    /**
     * @notice Record a successful withdrawal (update balance)
     * @dev Call this AFTER withdrawal completes successfully
     * @param self Storage reference to config
     * @param amount Amount that was withdrawn
     */
    function recordWithdrawal(Config storage self, uint256 amount) internal {
        uint256 oldBalance = self.trackedBalance;
        uint256 newBalance = oldBalance > amount ? oldBalance - amount : 0;
        self.trackedBalance = uint128(newBalance);
        emit BalanceUpdated(oldBalance, newBalance);
    }

    /**
     * @notice Record a deposit (update balance)
     * @dev Call this after deposits to keep balance accurate
     * @param self Storage reference to config
     * @param amount Amount deposited
     */
    function recordDeposit(Config storage self, uint256 amount) internal {
        uint256 oldBalance = self.trackedBalance;
        uint256 newBalance = oldBalance + amount;
        // Cap at uint128 max
        if (newBalance > type(uint128).max) {
            newBalance = type(uint128).max;
        }
        self.trackedBalance = uint128(newBalance);
        emit BalanceUpdated(oldBalance, newBalance);
    }

    /**
     * @notice Force reset the detector (admin function)
     * @dev Should only be called by authorized admin after investigation
     * @param self Storage reference to config
     * @param admin Address of admin performing reset
     */
    function forceReset(Config storage self, address admin) internal {
        _reset(self);
        emit DetectorForceReset(block.timestamp, admin);
    }

    /**
     * @notice Enable or disable drain detection
     * @dev Should only be called by authorized admin
     * @param self Storage reference to config
     * @param enabled_ Whether to enable detection
     */
    function setEnabled(Config storage self, bool enabled_) internal {
        self.enabled = enabled_;
    }

    /**
     * @notice Update tracked balance directly
     * @dev Use for sync after external balance changes
     * @param self Storage reference to config
     * @param newBalance New balance to track
     */
    function setBalance(Config storage self, uint128 newBalance) internal {
        uint256 oldBalance = self.trackedBalance;
        self.trackedBalance = newBalance;
        emit BalanceUpdated(oldBalance, newBalance);
    }

    /**
     * @notice Update detection thresholds
     * @dev Should only be called by authorized admin
     * @param self Storage reference to config
     * @param spikeThresholdBps_ New spike threshold (0 = no change)
     * @param velocityThresholdBps_ New velocity threshold (0 = no change)
     * @param maxTxPerWindow_ New max tx per window (0 = no change)
     */
    function updateThresholds(
        Config storage self,
        uint16 spikeThresholdBps_,
        uint16 velocityThresholdBps_,
        uint32 maxTxPerWindow_
    ) internal {
        if (spikeThresholdBps_ > 0) {
            if (spikeThresholdBps_ > BPS_DENOMINATOR) {
                revert InvalidConfig("spike threshold invalid");
            }
            self.spikeThresholdBps = spikeThresholdBps_;
        }
        if (velocityThresholdBps_ > 0) {
            if (velocityThresholdBps_ > BPS_DENOMINATOR) {
                revert InvalidConfig("velocity threshold invalid");
            }
            self.velocityThresholdBps = velocityThresholdBps_;
        }
        if (maxTxPerWindow_ > 0) {
            self.maxTxPerWindow = maxTxPerWindow_;
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get current detector status
     * @param self Storage reference to config
     * @return isTripped Whether detector is currently tripped
     * @return cooldownRemaining Seconds until cooldown ends (0 if not tripped)
     */
    function status(Config storage self) internal view returns (bool isTripped, uint256 cooldownRemaining) {
        if (!self.tripped) {
            return (false, 0);
        }

        if (block.timestamp >= self.cooldownEnds) {
            return (false, 0);
        }

        return (true, self.cooldownEnds - block.timestamp);
    }

    /**
     * @notice Check if a withdrawal would trigger detection
     * @dev View function for UI to preview
     * @param self Storage reference to config
     * @param amount Proposed withdrawal amount
     * @return wouldTrip Whether this would trigger detection
     * @return reason 0=OK, 1=spike, 2=velocity, 3=frequency
     */
    function wouldTrigger(Config storage self, uint256 amount) internal view returns (bool wouldTrip, uint8 reason) {
        if (!self.enabled || self.tripped) {
            return (false, 0);
        }

        uint256 balance = self.trackedBalance;

        // Check spike
        uint256 spikeThreshold = (balance * self.spikeThresholdBps) / BPS_DENOMINATOR;
        if (amount > spikeThreshold) {
            return (true, REASON_SPIKE);
        }

        // Check velocity (including this withdrawal)
        uint256 effectiveOutflow = self.windowOutflow;
        if (block.timestamp >= self.windowStart + self.windowDuration) {
            effectiveOutflow = 0; // Window would reset
        }
        uint256 newOutflow = effectiveOutflow + amount;
        uint256 velocityThreshold = (balance * self.velocityThresholdBps) / BPS_DENOMINATOR;
        if (newOutflow > velocityThreshold) {
            return (true, REASON_VELOCITY);
        }

        // Check frequency
        uint32 effectiveTxCount = self.windowTxCount;
        if (block.timestamp >= self.windowStart + self.windowDuration) {
            effectiveTxCount = 0;
        }
        if (effectiveTxCount + 1 > self.maxTxPerWindow) {
            return (true, REASON_FREQUENCY);
        }

        return (false, 0);
    }

    /**
     * @notice Get current window statistics
     * @param self Storage reference to config
     * @return outflow Cumulative outflow in current window
     * @return txCount Transaction count in current window
     * @return windowStart_ Start of current window
     * @return windowRemaining Seconds remaining in current window
     */
    function windowStats(Config storage self)
        internal
        view
        returns (uint256 outflow, uint32 txCount, uint64 windowStart_, uint256 windowRemaining)
    {
        // If window expired, would reset to 0
        if (block.timestamp >= self.windowStart + self.windowDuration) {
            return (0, 0, uint64(block.timestamp), self.windowDuration);
        }

        uint256 remaining = (self.windowStart + self.windowDuration) - block.timestamp;
        return (self.windowOutflow, self.windowTxCount, self.windowStart, remaining);
    }

    /**
     * @notice Get remaining capacity before triggering
     * @param self Storage reference to config
     * @return spikeCapacity Max single withdrawal allowed
     * @return velocityCapacity Remaining cumulative outflow allowed
     * @return txCapacity Remaining transactions allowed
     */
    function remainingCapacity(Config storage self)
        internal
        view
        returns (uint256 spikeCapacity, uint256 velocityCapacity, uint32 txCapacity)
    {
        if (!self.enabled || self.tripped) {
            return (type(uint256).max, type(uint256).max, type(uint32).max);
        }

        uint256 balance = self.trackedBalance;
        uint256 spikeThreshold = (balance * self.spikeThresholdBps) / BPS_DENOMINATOR;
        uint256 velocityThreshold = (balance * self.velocityThresholdBps) / BPS_DENOMINATOR;

        uint256 effectiveOutflow = self.windowOutflow;
        uint32 effectiveTxCount = self.windowTxCount;

        // If window expired, would reset
        if (block.timestamp >= self.windowStart + self.windowDuration) {
            effectiveOutflow = 0;
            effectiveTxCount = 0;
        }

        uint256 velRemaining = velocityThreshold > effectiveOutflow ? velocityThreshold - effectiveOutflow : 0;

        uint32 txRemaining = self.maxTxPerWindow > effectiveTxCount ? self.maxTxPerWindow - effectiveTxCount : 0;

        return (spikeThreshold, velRemaining, txRemaining);
    }

    /**
     * @notice Check if detector is initialized
     * @param self Storage reference to config
     * @return Whether config has been initialized
     */
    function isInitialized(Config storage self) internal view returns (bool) {
        return self.windowDuration > 0;
    }

    /**
     * @notice Check if detection is enabled
     * @param self Storage reference to config
     * @return Whether detection is enabled
     */
    function isEnabled(Config storage self) internal view returns (bool) {
        return self.enabled;
    }

    /**
     * @notice Get tracked balance
     * @param self Storage reference to config
     * @return Current tracked balance
     */
    function getBalance(Config storage self) internal view returns (uint256) {
        return self.trackedBalance;
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @dev Trip the detector and start cooldown
     */
    function _trip(Config storage self, uint8 reason) private {
        self.tripped = true;
        self.cooldownEnds = uint64(block.timestamp) + self.cooldownDuration;
        emit DetectorTripped(block.timestamp, reason, self.cooldownEnds);
    }

    /**
     * @dev Reset detector state
     */
    function _reset(Config storage self) private {
        self.tripped = false;
        self.cooldownEnds = 0;
        self.windowStart = uint64(block.timestamp);
        self.windowOutflow = 0;
        self.windowTxCount = 0;
    }
}
