// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BASIS_POINTS} from "../libraries/Constants.sol";

/**
 * @title RewardDistributor
 * @author TAG IT Network <dev@tagit.network>
 * @notice Distributes TAGIT token rewards for ecosystem actions, referrals,
 *         verification, and governance participation
 * @dev Funded by the ecosystem allocation from TAGITEmissions. Transfers tokens
 *      from its own balance (does not mint). Enforces a cumulative distribution
 *      cap of 5% of the token's totalSupply at time of distribution.
 *
 * Key Features:
 * - 4 reward triggers: ecosystem, referral, verification, governance
 * - Cumulative 5% of totalSupply distribution cap
 * - DISTRIBUTOR_ROLE via OpenZeppelin AccessControl
 * - Duplicate governance claim guard per proposal
 * - ReentrancyGuard on all distribution functions
 *
 * Security:
 * - Checks-Effects-Interactions pattern on all distributions
 * - Zero-address validation on all recipient parameters
 * - Zero-amount validation on all distributions
 * - Role-based access control for all trigger functions
 *
 * @custom:security-contact security@tagit.network
 */
contract RewardDistributor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Role identifier for authorized distributors
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    /// @notice Distribution cap as basis points of totalSupply (500 = 5%)
    uint256 public constant DISTRIBUTION_CAP_BPS = 500;

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @dev Thrown when cumulative distributions would exceed the 5% cap
    error MintCapExceeded(uint256 cumulativeAfter, uint256 cap);

    /// @dev Thrown when a zero address is provided as recipient
    error ZeroAddress();

    /// @dev Thrown when a zero amount is provided
    error ZeroAmount();

    /// @dev Thrown when a governance reward has already been claimed for a proposal
    error GovernanceRewardAlreadyClaimed(uint256 proposalId, address voter);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when any reward is distributed
    /// @param recipient Address receiving the reward
    /// @param amount Amount of TAGIT tokens distributed
    /// @param triggerType Type of reward trigger (ecosystem, referral, verification, governance)
    /// @param cumulativeDistributed Total cumulative distributions after this reward
    event RewardDistributed(
        address indexed recipient, uint256 amount, TriggerType indexed triggerType, uint256 cumulativeDistributed
    );

    /// @notice Emitted specifically for referral rewards with referrer/referee context
    /// @param referrer Address of the referring user
    /// @param referee Address of the referred user
    /// @param amount Amount of TAGIT tokens distributed to referrer
    event ReferralRewardDistributed(address indexed referrer, address indexed referee, uint256 amount);

    /// @notice Emitted specifically for governance rewards with proposal context
    /// @param voter Address of the governance participant
    /// @param proposalId ID of the governance proposal
    /// @param amount Amount of TAGIT tokens distributed
    event GovernanceRewardDistributed(address indexed voter, uint256 indexed proposalId, uint256 amount);

    // ============================================
    // ENUMS
    // ============================================

    /// @notice Types of reward triggers
    enum TriggerType {
        ECOSYSTEM,
        REFERRAL,
        VERIFICATION,
        GOVERNANCE
    }

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The TAGIT token contract
    IERC20 public immutable token;

    /// @notice Cumulative amount of tokens distributed across all triggers
    uint256 public cumulativeDistributed;

    /// @notice Tracks governance reward claims per proposal per voter
    /// @dev mapping(proposalId => mapping(voter => claimed))
    mapping(uint256 => mapping(address => bool)) public governanceClaimed;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize the RewardDistributor
     * @param _token Address of the TAGIT token contract
     * @param _admin Address of the admin (receives DEFAULT_ADMIN_ROLE)
     * @custom:security _token address is immutable after deployment
     */
    constructor(address _token, address _admin) {
        if (_token == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        token = IERC20(_token);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(DISTRIBUTOR_ROLE, _admin);
    }

    // ============================================
    // DISTRIBUTION FUNCTIONS
    // ============================================

    /**
     * @notice Distribute reward for ecosystem actions (scans, first-time use, etc.)
     * @param recipient Address to receive the reward
     * @param amount Amount of TAGIT tokens to distribute
     * @custom:security Requires DISTRIBUTOR_ROLE. Enforces 5% cumulative cap.
     * @custom:emits RewardDistributed
     */
    function distributeEcosystemReward(address recipient, uint256 amount)
        external
        onlyRole(DISTRIBUTOR_ROLE)
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _enforceCapAndDistribute(recipient, amount, TriggerType.ECOSYSTEM);
    }

    /**
     * @notice Distribute reward for successful referrals
     * @param referrer Address of the referring user (receives the reward)
     * @param referee Address of the referred user (must be non-zero for validation)
     * @param amount Amount of TAGIT tokens to distribute to the referrer
     * @custom:security Requires DISTRIBUTOR_ROLE. Validates both addresses.
     * @custom:emits RewardDistributed, ReferralRewardDistributed
     */
    function distributeReferralReward(address referrer, address referee, uint256 amount)
        external
        onlyRole(DISTRIBUTOR_ROLE)
        nonReentrant
    {
        if (referrer == address(0)) revert ZeroAddress();
        if (referee == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _enforceCapAndDistribute(referrer, amount, TriggerType.REFERRAL);

        emit ReferralRewardDistributed(referrer, referee, amount);
    }

    /**
     * @notice Distribute reward for verification participation
     * @param verifier Address of the verifier receiving the reward
     * @param amount Amount of TAGIT tokens to distribute
     * @custom:security Requires DISTRIBUTOR_ROLE. Enforces 5% cumulative cap.
     * @custom:emits RewardDistributed
     */
    function distributeVerificationReward(address verifier, uint256 amount)
        external
        onlyRole(DISTRIBUTOR_ROLE)
        nonReentrant
    {
        if (verifier == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _enforceCapAndDistribute(verifier, amount, TriggerType.VERIFICATION);
    }

    /**
     * @notice Distribute reward for governance participation (voting on proposals)
     * @param voter Address of the governance participant
     * @param proposalId ID of the governance proposal voted on
     * @param amount Amount of TAGIT tokens to distribute
     * @custom:security Requires DISTRIBUTOR_ROLE. Prevents duplicate claims per proposal.
     * @custom:emits RewardDistributed, GovernanceRewardDistributed
     */
    function distributeGovernanceReward(address voter, uint256 proposalId, uint256 amount)
        external
        onlyRole(DISTRIBUTOR_ROLE)
        nonReentrant
    {
        if (voter == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (governanceClaimed[proposalId][voter]) {
            revert GovernanceRewardAlreadyClaimed(proposalId, voter);
        }

        // EFFECTS: Mark as claimed before transfer
        governanceClaimed[proposalId][voter] = true;

        _enforceCapAndDistribute(voter, amount, TriggerType.GOVERNANCE);

        emit GovernanceRewardDistributed(voter, proposalId, amount);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Calculate the current distribution cap (5% of totalSupply)
     * @return The maximum cumulative amount that can be distributed
     */
    function distributionCap() public view returns (uint256) {
        return (token.totalSupply() * DISTRIBUTION_CAP_BPS) / BASIS_POINTS;
    }

    /**
     * @notice Calculate remaining distributable amount before hitting the cap
     * @return The remaining amount that can be distributed
     */
    function remainingDistributable() external view returns (uint256) {
        uint256 cap = distributionCap();
        if (cumulativeDistributed >= cap) return 0;
        return cap - cumulativeDistributed;
    }

    /**
     * @notice Check if a voter has already claimed a governance reward for a proposal
     * @param proposalId The governance proposal ID
     * @param voter The voter address
     * @return True if the voter has already claimed for this proposal
     */
    function hasClaimedGovernanceReward(uint256 proposalId, address voter) external view returns (bool) {
        return governanceClaimed[proposalId][voter];
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @dev Enforces the 5% cumulative cap, updates state, transfers tokens, and emits event
     * @param recipient Address to receive the reward
     * @param amount Amount of TAGIT tokens to distribute
     * @param triggerType The type of reward trigger
     * @custom:security Follows Checks-Effects-Interactions pattern
     */
    function _enforceCapAndDistribute(address recipient, uint256 amount, TriggerType triggerType) internal {
        // CHECKS: Verify cap is not exceeded
        uint256 cap = distributionCap();
        uint256 newCumulative = cumulativeDistributed + amount;
        if (newCumulative > cap) {
            revert MintCapExceeded(newCumulative, cap);
        }

        // EFFECTS: Update cumulative counter
        cumulativeDistributed = newCumulative;

        // INTERACTIONS: Transfer tokens
        token.safeTransfer(recipient, amount);

        // EMIT: Log the distribution
        emit RewardDistributed(recipient, amount, triggerType, newCumulative);
    }
}
