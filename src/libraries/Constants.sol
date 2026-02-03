// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Constants
 * @author TAG IT Network <dev@tagit.network>
 * @notice Immutable constants for the TAGIT tokenomics model
 * @dev These values are sacred — branded with 7s and 3s throughout
 *
 * The TAGIT tokenomics follows a deflationary-inflationary hybrid model:
 * - Fixed genesis supply distributed at TGE
 * - 3.33% annual inflation via TAGITEmissions (weekly epochs)
 * - Minimum 3.33% burn floor on all protocol fees (immutable)
 * - Default 33.3% burn rate (governance adjustable above floor)
 *
 * @custom:security These constants are compile-time values and cannot be modified.
 * Any changes require redeployment of dependent contracts.
 */

// ============================================
// TOKEN SUPPLY CONSTANTS
// ============================================

/// @dev Genesis supply minted at Token Generation Event
/// 7,777,777,333 tokens (7s and 3s brand alignment)
uint256 constant GENESIS_SUPPLY = 7_777_777_333 * 1e18;

/// @dev Maximum theoretical supply after infinite time
/// Used for sanity checks only - practical cap is much lower
uint256 constant MAX_SUPPLY = type(uint256).max;

// ============================================
// INFLATION CONSTANTS
// ============================================

/// @dev Annual inflation rate in basis points (333 = 3.33%)
/// Applied weekly: (totalSupply * INFLATION_RATE) / (BASIS_POINTS * EPOCHS_PER_YEAR)
uint256 constant INFLATION_RATE = 333;

/// @dev Number of distribution epochs per year (weekly)
uint256 constant EPOCHS_PER_YEAR = 52;

/// @dev Duration of one epoch in seconds (1 week)
uint256 constant EPOCH_DURATION = 7 days;

/// @dev Time for supply to double at constant inflation rate
/// Approximately 21 years (3 × 7 years) at 3.33% annual
uint256 constant DOUBLE_TIME_YEARS = 21;

// ============================================
// BURN CONSTANTS
// ============================================

/// @dev Minimum burn rate floor in basis points (333 = 3.33%)
/// IMMUTABLE - governance cannot reduce below this floor
/// SECURITY CRITICAL: This is a core tokenomics invariant
uint256 constant BURN_FLOOR = 333;

/// @dev Default burn rate in basis points (3330 = 33.3%)
/// Governance can adjust between BURN_FLOOR and BASIS_POINTS
uint256 constant DEFAULT_BURN_RATE = 3330;

/// @dev Basis points denominator (10000 = 100%)
uint256 constant BASIS_POINTS = 10000;

// ============================================
// STAKING CONSTANTS
// ============================================

/// @dev Minimum stake required for reputation boost
/// 100 TAGIT tokens (with 18 decimals)
uint256 constant MIN_STAKE_FOR_REP = 100 * 1e18;

/// @dev Cooldown period for unstaking
/// 7 days to prevent flash loan attacks on governance
uint256 constant UNSTAKE_COOLDOWN = 7 days;

/// @dev Minimum staking duration for rewards
uint256 constant MIN_STAKE_DURATION = 1 days;

// ============================================
// VESTING CONSTANTS
// ============================================

/// @dev Standard cliff period for team/advisor vesting
/// 1 year cliff before any tokens unlock
uint256 constant STANDARD_CLIFF = 365 days;

/// @dev Standard vesting duration after cliff
/// 4 years total vesting (1 year cliff + 3 years linear)
uint256 constant STANDARD_VESTING_DURATION = 4 * 365 days;

/// @dev Maximum vesting duration allowed
uint256 constant MAX_VESTING_DURATION = 10 * 365 days;

// ============================================
// GOVERNANCE TIMELOCK CONSTANTS
// ============================================

/// @dev Minimum delay for governance execution
/// 48 hours for critical operations
uint256 constant MIN_TIMELOCK_DELAY = 48 hours;

/// @dev Maximum delay for governance execution
uint256 constant MAX_TIMELOCK_DELAY = 30 days;

/// @dev Default timelock delay
uint256 constant DEFAULT_TIMELOCK_DELAY = 48 hours;

// ============================================
// ALLOCATION PERCENTAGES (Genesis Distribution)
// ============================================

/// @dev Ecosystem incentives allocation (35%)
uint256 constant ALLOC_ECOSYSTEM = 3500;

/// @dev Presale + Liquidity allocation (20%)
uint256 constant ALLOC_PRESALE = 2000;

/// @dev Treasury allocation (15%)
uint256 constant ALLOC_TREASURY = 1500;

/// @dev DAO Governance allocation (15%)
uint256 constant ALLOC_DAO = 1500;

/// @dev Development allocation (10%)
uint256 constant ALLOC_DEVELOPMENT = 1000;

/// @dev Team + Advisors allocation (5%)
uint256 constant ALLOC_TEAM = 500;

// ============================================
// ROLE IDENTIFIERS (for TAGITAccess integration)
// ============================================

/// @dev Role identifier for emissions contract
bytes32 constant ROLE_EMISSIONS = keccak256("EMISSIONS");

/// @dev Role identifier for burner contract
bytes32 constant ROLE_BURNER = keccak256("BURNER");

/// @dev Role identifier for governor contract
bytes32 constant ROLE_GOVERNOR = keccak256("GOVERNOR");

/// @dev Role identifier for treasury contract
bytes32 constant ROLE_TREASURY = keccak256("TREASURY");

/// @dev Role identifier for vesting admin
bytes32 constant ROLE_VESTING_ADMIN = keccak256("VESTING_ADMIN");

/// @dev Role identifier for staking rewards distributor
bytes32 constant ROLE_STAKING_REWARDS = keccak256("STAKING_REWARDS");

// ============================================
// UTILITY CONSTANTS
// ============================================

/// @dev Token decimals (standard ERC20)
uint8 constant TOKEN_DECIMALS = 18;

/// @dev Token name
string constant TOKEN_NAME = "TAG IT Token";

/// @dev Token symbol
string constant TOKEN_SYMBOL = "TAGIT";

/// @dev Contract version for upgrades
string constant VERSION = "1.0.0";
