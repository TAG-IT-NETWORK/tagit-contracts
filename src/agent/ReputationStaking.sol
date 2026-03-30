// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IReputationStaking} from "../interfaces/IReputationStaking.sol";
import {TAGITAgentIdentity} from "./TAGITAgentIdentity.sol";

/**
 * @title ReputationStaking
 * @author TAG IT Network <dev@tagit.network>
 * @notice Agent reputation staking — credibility bond mechanism for AI agents
 * @dev Agents must stake TAGIT tokens as economic skin-in-the-game before registration.
 *
 * Design:
 * - Agents stake TAGIT tokens as a credibility bond
 * - Minimum bond (minBond) required for registration to complete
 * - Registry (owner) can slash bonds for misbehavior
 * - Registrants can unstake only after agent is decommissioned
 * - Slashed tokens are sent to treasury
 *
 * Security:
 * - ReentrancyGuard on all state-changing functions
 * - Pausable for emergency stops
 * - SafeERC20 for safe token transfers
 * - CEI pattern throughout
 * - Only owner (AgentIdentity contract) can slash
 *
 * @custom:security All state-changing functions follow CEI pattern with ReentrancyGuard
 * @custom:security-contact security@tagit.network
 */
contract ReputationStaking is IReputationStaking, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Default minimum bond: 100 TAGIT tokens (matches MIN_STAKE_FOR_REP)
    uint256 public constant DEFAULT_MIN_BOND = 100 * 1e18;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The TAGIT token contract
    IERC20 public immutable tagToken;

    /// @notice The TAGITAgentIdentity contract for agent lookups
    TAGITAgentIdentity public agentIdentity;

    /// @notice Minimum bond required for agent registration
    uint256 public minBond;

    /// @notice Treasury address for slashed tokens
    address public treasury;

    /// @notice Mapping from agent ID to staked amount
    mapping(uint256 => uint256) private _stakes;

    /// @notice Mapping from agent ID to staker address
    mapping(uint256 => address) private _stakers;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize ReputationStaking contract
     * @param _tagToken Address of the TAGIT ERC20 token
     * @param _treasury Address to receive slashed tokens
     * @param _initialOwner Contract owner (typically governance or AgentIdentity deployer)
     */
    constructor(address _tagToken, address _treasury, address _initialOwner) Ownable(_initialOwner) {
        if (_tagToken == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        tagToken = IERC20(_tagToken);
        treasury = _treasury;
        minBond = DEFAULT_MIN_BOND;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Set the AgentIdentity contract reference
     * @param _agentIdentity Address of TAGITAgentIdentity
     * @custom:security Only owner can call
     */
    function setAgentIdentity(address _agentIdentity) external onlyOwner {
        if (_agentIdentity == address(0)) revert ZeroAddress();
        agentIdentity = TAGITAgentIdentity(_agentIdentity);
    }

    /**
     * @notice Update minimum bond amount
     * @param _newMinBond New minimum bond in TAGIT tokens (with 18 decimals)
     * @custom:security Only owner can call
     * @custom:emits MinBondUpdated
     */
    function setMinBond(uint256 _newMinBond) external onlyOwner {
        uint256 oldMinBond = minBond;
        minBond = _newMinBond;
        emit MinBondUpdated(oldMinBond, _newMinBond);
    }

    /**
     * @notice Update treasury address
     * @param _newTreasury New treasury address for slashed tokens
     * @custom:security Only owner can call
     * @custom:emits TreasuryUpdated
     */
    function setTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    /**
     * @notice Pause contract (emergency stop)
     * @custom:security Only owner can call
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @custom:security Only owner can call
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // STAKING FUNCTIONS
    // ============================================

    /**
     * @notice Stake TAGIT tokens as a credibility bond for an agent
     * @dev Caller must be the agent's registrant. Tokens are transferred via safeTransferFrom.
     *      Follows Checks-Effects-Interactions pattern.
     * @param agentId The agent ID to stake for
     * @param amount Amount of TAGIT tokens to stake
     * @custom:security ReentrancyGuard + Pausable
     * @custom:emits StakeDeposited
     */
    function stake(uint256 agentId, uint256 amount) external nonReentrant whenNotPaused {
        // ============================================
        // CHECKS
        // ============================================
        if (amount == 0) revert ZeroAmount();
        if (address(agentIdentity) == address(0)) revert AgentIdentityNotSet();

        // Verify caller is the agent's registrant
        (address registrant,,,) = agentIdentity.getAgent(agentId);
        if (registrant == address(0)) revert NotAgentRegistrant(msg.sender, agentId);
        if (registrant != msg.sender) revert NotAgentRegistrant(msg.sender, agentId);

        // ============================================
        // EFFECTS
        // ============================================
        _stakes[agentId] += amount;
        _stakers[agentId] = msg.sender;

        // ============================================
        // INTERACTIONS
        // ============================================
        tagToken.safeTransferFrom(msg.sender, address(this), amount);

        emit StakeDeposited(agentId, msg.sender, amount);
    }

    /**
     * @notice Withdraw staked tokens after agent decommission
     * @dev Only the original staker (registrant) can unstake. Agent must be decommissioned.
     *      Follows Checks-Effects-Interactions pattern.
     * @param agentId The agent ID to unstake from
     * @custom:security ReentrancyGuard + Pausable
     * @custom:emits StakeWithdrawn
     */
    function unstake(uint256 agentId) external nonReentrant whenNotPaused {
        // ============================================
        // CHECKS
        // ============================================
        if (address(agentIdentity) == address(0)) revert AgentIdentityNotSet();

        uint256 stakeAmount = _stakes[agentId];
        if (stakeAmount == 0) revert NoStakeToWithdraw(agentId);

        address staker = _stakers[agentId];
        if (staker != msg.sender) revert NotAgentRegistrant(msg.sender, agentId);

        // Agent must be decommissioned to unstake
        TAGITAgentIdentity.AgentStatus status = agentIdentity.getAgentStatus(agentId);
        if (status != TAGITAgentIdentity.AgentStatus.DECOMMISSIONED) {
            revert AgentStillActive(agentId);
        }

        // ============================================
        // EFFECTS
        // ============================================
        _stakes[agentId] = 0;
        delete _stakers[agentId];

        // ============================================
        // INTERACTIONS
        // ============================================
        tagToken.safeTransfer(msg.sender, stakeAmount);

        emit StakeWithdrawn(agentId, msg.sender, stakeAmount);
    }

    /**
     * @notice Slash agent's staked tokens for misbehavior
     * @dev Only owner (governance/AgentIdentity) can slash. Slashed tokens go to treasury.
     *      Follows Checks-Effects-Interactions pattern.
     * @param agentId The agent ID to slash
     * @param amount Amount to slash
     * @custom:security Only owner, ReentrancyGuard
     * @custom:emits StakeSlashed
     */
    function slash(uint256 agentId, uint256 amount) external nonReentrant onlyOwner {
        // ============================================
        // CHECKS
        // ============================================
        if (amount == 0) revert ZeroAmount();

        uint256 currentStake = _stakes[agentId];
        if (amount > currentStake) {
            revert SlashExceedsStake(agentId, amount, currentStake);
        }

        // ============================================
        // EFFECTS
        // ============================================
        _stakes[agentId] = currentStake - amount;

        // ============================================
        // INTERACTIONS
        // ============================================
        tagToken.safeTransfer(treasury, amount);

        emit StakeSlashed(agentId, amount, msg.sender);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the staked amount for an agent
     * @param agentId The agent ID to query
     * @return Staked token amount
     */
    function getStake(uint256 agentId) external view returns (uint256) {
        return _stakes[agentId];
    }

    /**
     * @notice Get the minimum bond required for agent registration
     * @return Minimum bond amount in TAGIT tokens
     */
    function getMinBond() external view returns (uint256) {
        return minBond;
    }

    /**
     * @notice Check if agent has staked at least the minimum bond
     * @param agentId The agent ID to check
     * @return True if stake >= minBond
     */
    function hasMinBond(uint256 agentId) external view returns (bool) {
        return _stakes[agentId] >= minBond;
    }

    /**
     * @notice Get the staker address for an agent
     * @param agentId The agent ID to query
     * @return Staker address (address(0) if no stake)
     */
    function getStaker(uint256 agentId) external view returns (address) {
        return _stakers[agentId];
    }
}
