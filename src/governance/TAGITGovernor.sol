// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    GovernorSettingsUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {
    GovernorVotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {
    GovernorTimelockControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {ITAGITStaking} from "../interfaces/ITAGITStaking.sol";
import {ITAGITGovernor} from "../interfaces/ITAGITGovernor.sol";

/**
 * @title TAGITGovernor
 * @author TAG IT Network <dev@tagit.network>
 * @notice Multi-house DAO governance with 5 weighted houses
 * @dev Extends OpenZeppelin Governor with custom house-weighted voting
 *
 * Houses:
 * - GOV_MIL (30%): Government & military badge holders
 * - ENTERPRISE (30%): Brand partners & manufacturers
 * - PUBLIC (20%): Token holders & community
 * - DEV (10%): Core development team
 * - REGULATORY (10%): Compliance & legal oversight
 */
contract TAGITGovernor is
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorVotesUpgradeable,
    GovernorTimelockControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ITAGITGovernor
{
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice House weight for Gov/Mil (30%)
    uint256 public constant HOUSE_WEIGHT_GOV_MIL = 3000;

    /// @notice House weight for Enterprise (30%)
    uint256 public constant HOUSE_WEIGHT_ENTERPRISE = 3000;

    /// @notice House weight for Public (20%)
    uint256 public constant HOUSE_WEIGHT_PUBLIC = 2000;

    /// @notice House weight for Dev (10%)
    uint256 public constant HOUSE_WEIGHT_DEV = 1000;

    /// @notice House weight for Regulatory (10%)
    uint256 public constant HOUSE_WEIGHT_REGULATORY = 1000;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Badge ID for Government/Military
    uint256 public constant BADGE_GOV_MIL = 20;

    /// @notice Badge ID for Manufacturer/Enterprise
    uint256 public constant BADGE_MANUFACTURER = 10;

    /// @notice Badge ID for Developer
    uint256 public constant BADGE_DEV = 30;

    /// @notice Badge ID for Regulatory
    uint256 public constant BADGE_REGULATORY = 40;

    /// @notice Quorum percentage in basis points (4%)
    uint256 public constant QUORUM_PERCENTAGE = 400;

    /// @notice Vote type: Against
    uint8 public constant VOTE_AGAINST = 0;

    /// @notice Vote type: For
    uint8 public constant VOTE_FOR = 1;

    /// @notice Vote type: Abstain
    uint8 public constant VOTE_ABSTAIN = 2;

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice The inherited OpenZeppelin counting path was reached, which must never happen
    /// @dev TAGITGovernor tallies through _recordHouseVote() from its own _castVote()
    ///      override. _countVote() is an abstract hook this contract is only required to
    ///      implement; a call arriving here means a refactor rerouted voting through the
    ///      base counting module, where it would be silently dropped.
    error CountVoteUnsupported(uint256 proposalId, address account);

    // ============================================
    // STORAGE
    // ============================================

    /// @custom:storage-location erc7201:tagit.storage.TAGITGovernor
    struct TAGITGovernorStorage {
        /// @notice Access control contract for badge checks
        ITAGITAccess accessControl;
        /// @notice Staking contract for proposal threshold
        ITAGITStaking staking;
        /// @notice Guardian address for emergency actions
        address guardian;
        /// @notice Vote totals per house per proposal
        mapping(uint256 proposalId => HouseVotes[5]) houseVotes;
        /// @notice Whether an address has voted on a proposal
        mapping(uint256 proposalId => mapping(address voter => bool)) hasVotedMap;
        /// @notice Total weighted votes per proposal (for, against, abstain)
        mapping(uint256 proposalId => ProposalVotes) proposalVotes;
    }

    /// @notice Aggregated weighted votes for a proposal
    struct ProposalVotes {
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
    }

    // keccak256(abi.encode(uint256(keccak256("tagit.storage.TAGITGovernor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TAGITGovernorStorageLocation =
        0x8a2b5c9f7d3e1a6b4c8f2d0e9a7b5c3d1e8f6a4b2c0d9e7f5a3b1c8d6e4f2a00;

    function _getTAGITGovernorStorage() private pure returns (TAGITGovernorStorage storage $) {
        assembly {
            $.slot := TAGITGovernorStorageLocation
        }
    }

    // ============================================
    // INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the governor contract
     * @param _token Voting token (ERC20Votes)
     * @param _timelock Timelock controller
     * @param _access Access control contract
     * @param _stakingContract Staking contract for proposal threshold
     * @param _guardian Guardian address for emergency actions
     * @param _initialOwner Initial owner address
     */
    function initialize(
        IVotes _token,
        TimelockControllerUpgradeable _timelock,
        ITAGITAccess _access,
        ITAGITStaking _stakingContract,
        address _guardian,
        address _initialOwner
    ) external initializer {
        if (address(_token) == address(0)) revert ZeroAddress();
        if (address(_timelock) == address(0)) revert ZeroAddress();
        if (address(_access) == address(0)) revert ZeroAddress();
        if (address(_stakingContract) == address(0)) revert ZeroAddress();
        if (_guardian == address(0)) revert ZeroAddress();
        if (_initialOwner == address(0)) revert ZeroAddress();

        __Governor_init("TAGITGovernor");
        __GovernorSettings_init(
            1 days, // voting delay
            7 days, // voting period
            100_000e18 // proposal threshold (100k staked TAGIT)
        );
        __GovernorVotes_init(_token);
        __GovernorTimelockControl_init(_timelock);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __Ownable_init(_initialOwner);

        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        $.accessControl = _access;
        $.staking = _stakingContract;
        $.guardian = _guardian;
    }

    // ============================================
    // CORE GOVERNANCE FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITGovernor
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(GovernorUpgradeable, ITAGITGovernor) whenNotPaused returns (uint256) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();

        // Check proposer has enough staked tokens
        uint256 stakedBalance = $.staking.stakedBalance(msg.sender);
        uint256 threshold = proposalThreshold();
        if (stakedBalance < threshold) {
            revert InsufficientStake(msg.sender, threshold, stakedBalance);
        }

        return super.propose(targets, values, calldatas, description);
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function castVote(uint256 proposalId, uint8 support)
        public
        override(GovernorUpgradeable, ITAGITGovernor)
        whenNotPaused
        returns (uint256)
    {
        return _castVote(proposalId, msg.sender, support, "", "");
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function castVoteWithReason(uint256 proposalId, uint8 support, string calldata reason)
        public
        override(GovernorUpgradeable, ITAGITGovernor)
        whenNotPaused
        returns (uint256)
    {
        return _castVote(proposalId, msg.sender, support, reason, "");
    }

    /**
     * @notice Queue by proposal ID (must use full proposal data version)
     * @dev OZ Governor doesn't store proposal data - use queue(targets, values, calldatas, descriptionHash) instead
     */
    function queue(
        uint256 /*proposalId*/
    )
        external
        pure
        override(ITAGITGovernor)
    {
        revert("Use queue(targets,values,calldatas,descriptionHash)");
    }

    /**
     * @notice Execute by proposal ID (must use full proposal data version)
     * @dev OZ Governor doesn't store proposal data - use execute(targets, values, calldatas, descriptionHash) instead
     */
    function execute(
        uint256 /*proposalId*/
    )
        external
        payable
        override(ITAGITGovernor)
    {
        revert("Use execute(targets,values,calldatas,descriptionHash)");
    }

    /**
     * @notice Cancel by proposal ID (must use full proposal data version)
     * @dev OZ Governor doesn't store proposal data - use cancel(targets, values, calldatas, descriptionHash) instead
     */
    function cancel(
        uint256 /*proposalId*/
    )
        external
        pure
        override(ITAGITGovernor)
    {
        revert("Use cancel(targets,values,calldatas,descriptionHash)");
    }

    // ============================================
    // HOUSE VOTING IMPLEMENTATION
    // ============================================

    /**
     * @dev Override base _castVote to add house tracking
     */
    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason,
        bytes memory /*params*/
    )
        internal
        virtual
        override
        returns (uint256)
    {
        // Validate proposal is in Active state
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Active) {
            revert InvalidProposalState(proposalId, uint8(currentState), uint8(ProposalState.Active));
        }

        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();

        // Check not already voted
        if ($.hasVotedMap[proposalId][account]) {
            revert AlreadyVoted(proposalId, account);
        }

        // Get voter's house and weight
        (uint256 weight, House house) = getVotingPower(account);
        if (weight == 0) {
            revert NoVotingPower(account);
        }

        // Validate vote type
        if (support > VOTE_ABSTAIN) {
            revert InvalidVoteType(support);
        }

        // Mark as voted and record vote
        $.hasVotedMap[proposalId][account] = true;
        _recordHouseVote(proposalId, house, support, weight);

        // Emit house-specific event
        emit HouseVoteCast(proposalId, account, house, support, weight);
        // Emit standard Governor event for compatibility
        emit VoteCast(account, proposalId, support, weight, reason);

        return weight;
    }

    /**
     * @dev Record vote in house and proposal storage
     */
    function _recordHouseVote(uint256 proposalId, House house, uint8 support, uint256 weight) internal {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        HouseVotes storage houseVote = $.houseVotes[proposalId][uint256(house)];
        ProposalVotes storage propVotes = $.proposalVotes[proposalId];

        // Calculate weighted vote (house weight * voter weight)
        uint256 houseWeight = _getHouseWeight(house);
        uint256 weightedVote = (weight * houseWeight) / BASIS_POINTS;

        if (support == VOTE_FOR) {
            houseVote.forVotes += weight;
            propVotes.forVotes += weightedVote;
        } else if (support == VOTE_AGAINST) {
            houseVote.againstVotes += weight;
            propVotes.againstVotes += weightedVote;
        } else {
            houseVote.abstainVotes += weight;
            propVotes.abstainVotes += weightedVote;
        }
    }

    /**
     * @dev Get the weight for a house
     */
    function _getHouseWeight(House house) internal pure returns (uint256) {
        if (house == House.GOV_MIL) return HOUSE_WEIGHT_GOV_MIL;
        if (house == House.ENTERPRISE) return HOUSE_WEIGHT_ENTERPRISE;
        if (house == House.PUBLIC) return HOUSE_WEIGHT_PUBLIC;
        if (house == House.DEV) return HOUSE_WEIGHT_DEV;
        if (house == House.REGULATORY) return HOUSE_WEIGHT_REGULATORY;
        return 0;
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function getVotingPower(address account) public view override returns (uint256 weight, House house) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();

        // Check badges in priority order (highest privilege first)
        // Badge holders get BASIS_POINTS weight to avoid integer division truncation
        // when calculating weighted votes: (weight * houseWeight) / BASIS_POINTS
        if ($.accessControl.hasIdentity(account, BADGE_GOV_MIL)) {
            return (BASIS_POINTS, House.GOV_MIL);
        }
        if ($.accessControl.hasIdentity(account, BADGE_REGULATORY)) {
            return (BASIS_POINTS, House.REGULATORY);
        }
        if ($.accessControl.hasIdentity(account, BADGE_MANUFACTURER)) {
            return (BASIS_POINTS, House.ENTERPRISE);
        }
        if ($.accessControl.hasIdentity(account, BADGE_DEV)) {
            return (BASIS_POINTS, House.DEV);
        }

        // Public house uses token balance
        uint256 votes = token().getVotes(account);
        if (votes > 0) {
            // Token votes already scaled (1e18), used directly
            return (votes, House.PUBLIC);
        }

        return (0, House.PUBLIC);
    }

    // ============================================
    // GOVERNOR OVERRIDES (Required by OZ)
    // ============================================

    /**
     * @dev Required override for counting module
     */
    function _quorumReached(uint256 proposalId) internal view virtual override returns (bool) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        ProposalVotes storage propVotes = $.proposalVotes[proposalId];

        uint256 totalVotes = propVotes.forVotes + propVotes.againstVotes + propVotes.abstainVotes;
        return totalVotes >= quorum();
    }

    /**
     * @dev Required override for counting module
     */
    function _voteSucceeded(uint256 proposalId) internal view virtual override returns (bool) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        ProposalVotes storage propVotes = $.proposalVotes[proposalId];

        return propVotes.forVotes > propVotes.againstVotes;
    }

    /**
     * @dev Required override for the OpenZeppelin counting module.
     *
     *      UNREACHABLE BY CONSTRUCTION: TAGITGovernor overrides _castVote() and tallies
     *      every vote through _recordHouseVote(), so the base Governor counting path is
     *      never entered. The hook is abstract in GovernorUpgradeable, so it cannot simply
     *      be deleted — the contract would not compile.
     *
     *      It reverts rather than doing nothing. An empty body means a future refactor
     *      that routes voting back through the OZ counting path would silently record no
     *      votes at all; reverting makes that failure loud and immediate.
     * @custom:security Fail-closed: reverts instead of silently discarding a vote
     */
    function _countVote(
        uint256 proposalId,
        address account,
        uint8, /*support*/
        uint256, /*weight*/
        bytes memory /*params*/
    )
        internal
        virtual
        override
    {
        revert CountVoteUnsupported(proposalId, account);
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function quorum() public view override(ITAGITGovernor) returns (uint256) {
        // 4% of total token supply
        return (token().getPastTotalSupply(clock() - 1) * QUORUM_PERCENTAGE) / BASIS_POINTS;
    }

    /**
     * @dev Quorum at a specific timepoint
     */
    function quorum(uint256 timepoint) public view virtual override(GovernorUpgradeable) returns (uint256) {
        return (token().getPastTotalSupply(timepoint) * QUORUM_PERCENTAGE) / BASIS_POINTS;
    }

    // ============================================
    // EMERGENCY FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITGovernor
     */
    function emergencyPause() external override {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        if (msg.sender != $.guardian) {
            revert NotGuardian(msg.sender);
        }
        _pause();
        emit EmergencyPaused(msg.sender);
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function unpause() external override(ITAGITGovernor) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        if (msg.sender != $.guardian) {
            revert NotGuardian(msg.sender);
        }
        _unpause();
        emit GovernorUnpaused(msg.sender);
    }

    /**
     * @notice Update guardian address
     * @param newGuardian New guardian address
     */
    function setGuardian(address newGuardian) external onlyGovernance {
        if (newGuardian == address(0)) revert ZeroAddress();
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        address oldGuardian = $.guardian;
        $.guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @inheritdoc ITAGITGovernor
     */
    function getHouseVotes(uint256 proposalId) external view override returns (HouseVotes[5] memory votes) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        for (uint256 i = 0; i < 5; i++) {
            votes[i] = $.houseVotes[proposalId][i];
        }
        return votes;
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function hasVoted(uint256 proposalId, address account)
        public
        view
        override(IGovernor, ITAGITGovernor)
        returns (bool)
    {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        return $.hasVotedMap[proposalId][account];
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable, ITAGITGovernor)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function guardian() external view override returns (address) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        return $.guardian;
    }

    /**
     * @inheritdoc ITAGITGovernor
     */
    function version() public pure override(GovernorUpgradeable, ITAGITGovernor) returns (string memory) {
        return "1.0.0";
    }

    /**
     * @dev Description of counting mode for ERC-165
     */
    // solhint-disable-next-line func-name-mixedcase
    function COUNTING_MODE() public pure override returns (string memory) {
        return "support=bravo&quorum=for,against,abstain&params=house";
    }

    /**
     * @notice Get weighted vote totals for a proposal
     * @param proposalId The proposal ID
     * @return forVotes Total weighted for votes
     * @return againstVotes Total weighted against votes
     * @return abstainVotes Total weighted abstain votes
     */
    function proposalVotes(uint256 proposalId)
        external
        view
        returns (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes)
    {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        ProposalVotes storage pv = $.proposalVotes[proposalId];
        return (pv.forVotes, pv.againstVotes, pv.abstainVotes);
    }

    /**
     * @notice Get access control contract
     * @return Access control contract address
     */
    function accessControl() external view returns (address) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        return address($.accessControl);
    }

    /**
     * @notice Get staking contract
     * @return Staking contract address
     */
    function stakingContract() external view returns (address) {
        TAGITGovernorStorage storage $ = _getTAGITGovernorStorage();
        return address($.staking);
    }

    // ============================================
    // REQUIRED OVERRIDES
    // ============================================

    /**
     * @dev Required override for UUPS
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Required override for multiple inheritance
     */
    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /**
     * @dev Required override for multiple inheritance
     */
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /**
     * @dev Required override for multiple inheritance
     */
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Required override for multiple inheritance
     */
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Required override for multiple inheritance
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /**
     * @dev Required override for multiple inheritance
     */
    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }
}
