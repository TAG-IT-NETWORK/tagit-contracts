// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReputationStaking
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for agent reputation staking (credibility bond) mechanism
 * @dev Agents must stake TAGIT tokens as a credibility bond before registration.
 *      The bond acts as economic skin-in-the-game: misbehaving agents can be slashed.
 *
 * Lifecycle:
 *   1. Agent registrant calls stake(agentId, amount) with TAG tokens
 *   2. AgentIdentity checks hasMinBond(agentId) before completing registration
 *   3. If agent misbehaves, registry calls slash(agentId, amount)
 *   4. After decommission, registrant calls unstake(agentId) to reclaim bond
 */
interface IReputationStaking {
    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when tokens are staked as a credibility bond
    event StakeDeposited(uint256 indexed agentId, address indexed staker, uint256 amount);

    /// @notice Emitted when staked tokens are withdrawn after deregistration
    event StakeWithdrawn(uint256 indexed agentId, address indexed staker, uint256 amount);

    /// @notice Emitted when staked tokens are slashed for misbehavior
    event StakeSlashed(uint256 indexed agentId, uint256 amount, address indexed slashedBy);

    /// @notice Emitted when minimum bond amount is updated
    event MinBondUpdated(uint256 oldMinBond, uint256 newMinBond);

    /// @notice Emitted when treasury address is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when agent has no stake to withdraw
    error NoStakeToWithdraw(uint256 agentId);

    /// @notice Thrown when slash amount exceeds stake
    error SlashExceedsStake(uint256 agentId, uint256 slashAmount, uint256 currentStake);

    /// @notice Thrown when agent is still active (cannot unstake)
    error AgentStillActive(uint256 agentId);

    /// @notice Thrown when agent does not meet minimum bond
    error InsufficientBond(uint256 agentId, uint256 current, uint256 required);

    /// @notice Thrown when staker is not the agent's registrant
    error NotAgentRegistrant(address caller, uint256 agentId);

    /// @notice Thrown when agent identity contract is not set
    error AgentIdentityNotSet();

    // ============================================
    // STAKING FUNCTIONS
    // ============================================

    /**
     * @notice Stake TAGIT tokens as a credibility bond for an agent
     * @param agentId The agent ID to stake for
     * @param amount Amount of TAGIT tokens to stake
     */
    function stake(uint256 agentId, uint256 amount) external;

    /**
     * @notice Withdraw staked tokens after agent decommission
     * @param agentId The agent ID to unstake from
     */
    function unstake(uint256 agentId) external;

    /**
     * @notice Slash agent's staked tokens for misbehavior
     * @param agentId The agent ID to slash
     * @param amount Amount to slash
     */
    function slash(uint256 agentId, uint256 amount) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the staked amount for an agent
     * @param agentId The agent ID to query
     * @return Staked token amount
     */
    function getStake(uint256 agentId) external view returns (uint256);

    /**
     * @notice Get the minimum bond required for agent registration
     * @return Minimum bond amount in TAGIT tokens
     */
    function getMinBond() external view returns (uint256);

    /**
     * @notice Check if agent has staked at least the minimum bond
     * @param agentId The agent ID to check
     * @return True if stake >= minBond
     */
    function hasMinBond(uint256 agentId) external view returns (bool);
}
