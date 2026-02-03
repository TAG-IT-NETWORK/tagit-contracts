// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITGovernor
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for multi-house DAO governance
 * @dev Extends OpenZeppelin Governor with 5-house weighted voting
 */
interface ITAGITGovernor {
    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice The 5 governance houses
     */
    enum House {
        GOV_MIL,      // 0 - Government & Military (30%)
        ENTERPRISE,   // 1 - Brand partners & manufacturers (30%)
        PUBLIC,       // 2 - Token holders & community (20%)
        DEV,          // 3 - Core development team (10%)
        REGULATORY    // 4 - Compliance & legal oversight (10%)
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Vote totals per house for a proposal
     */
    struct HouseVotes {
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
    }

    /**
     * @notice Voter info including house and weight
     */
    struct VoterInfo {
        House house;
        uint256 weight;
        bool hasVoted;
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Proposer doesn't meet stake threshold
    error InsufficientStake(address proposer, uint256 required, uint256 actual);

    /// @notice Voter has already voted on this proposal
    error AlreadyVoted(uint256 proposalId, address voter);

    /// @notice Voter has no voting power (no badge or tokens)
    error NoVotingPower(address voter);

    /// @notice Proposal is not in the expected state
    error InvalidProposalState(uint256 proposalId, uint8 currentState, uint8 expectedState);

    /// @notice Caller is not the guardian
    error NotGuardian(address caller);

    /// @notice Guardian action requires higher threshold
    error InsufficientGuardianApprovals(uint256 required, uint256 actual);

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Invalid vote type
    error InvalidVoteType(uint8 support);

    /// @notice Arrays length mismatch
    error ArrayLengthMismatch();

    /// @notice Proposal doesn't exist
    error ProposalNotFound(uint256 proposalId);

    /// @notice Timelock operation failed
    error TimelockOperationFailed(uint256 proposalId);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when proposal is created
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        string description,
        uint256 voteStart,
        uint256 voteEnd
    );

    /// @notice Emitted when vote is cast with house info
    event HouseVoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        House house,
        uint8 support,
        uint256 weight
    );

    /// @notice Emitted when guardian triggers emergency pause
    event EmergencyPaused(
        address indexed guardian
    );

    /// @notice Emitted when guardian unpauses (uses different signature than Pausable)
    event GovernorUnpaused(
        address indexed guardian
    );

    /// @notice Emitted when guardian is updated
    event GuardianUpdated(
        address indexed oldGuardian,
        address indexed newGuardian
    );

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Create a new proposal
     * @param targets Target addresses for calls
     * @param values ETH values for calls
     * @param calldatas Encoded function calls
     * @param description Proposal description
     * @return proposalId The created proposal ID
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256 proposalId);

    /**
     * @notice Cast a vote on a proposal
     * @param proposalId The proposal ID
     * @param support Vote type: 0=Against, 1=For, 2=Abstain
     * @return weight The voting weight applied
     */
    function castVote(
        uint256 proposalId,
        uint8 support
    ) external returns (uint256 weight);

    /**
     * @notice Cast a vote with reason
     * @param proposalId The proposal ID
     * @param support Vote type: 0=Against, 1=For, 2=Abstain
     * @param reason Vote rationale
     * @return weight The voting weight applied
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) external returns (uint256 weight);

    /**
     * @notice Queue a succeeded proposal for timelock execution
     * @param proposalId The proposal ID
     */
    function queue(uint256 proposalId) external;

    /**
     * @notice Execute a queued proposal after timelock delay
     * @param proposalId The proposal ID
     */
    function execute(uint256 proposalId) external payable;

    /**
     * @notice Cancel a proposal
     * @param proposalId The proposal ID
     */
    function cancel(uint256 proposalId) external;

    // ============================================
    // EMERGENCY FUNCTIONS
    // ============================================

    /**
     * @notice Emergency pause - requires guardian
     */
    function emergencyPause() external;

    /**
     * @notice Unpause after emergency - requires guardian
     */
    function unpause() external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get vote totals per house for a proposal
     * @param proposalId The proposal ID
     * @return votes Array of HouseVotes for each house
     */
    function getHouseVotes(uint256 proposalId) external view returns (HouseVotes[5] memory votes);

    /**
     * @notice Get voting power and house for an address
     * @param account The address to check
     * @return weight Voting power
     * @return house The voter's house
     */
    function getVotingPower(address account) external view returns (uint256 weight, House house);

    /**
     * @notice Check if address has voted on proposal
     * @param proposalId The proposal ID
     * @param account The address to check
     * @return True if voted
     */
    function hasVoted(uint256 proposalId, address account) external view returns (bool);

    /**
     * @notice Get minimum tokens required to propose
     * @return Proposal threshold in tokens
     */
    function proposalThreshold() external view returns (uint256);

    /**
     * @notice Get quorum required for proposal to pass
     * @return Quorum as absolute number
     */
    function quorum() external view returns (uint256);

    /**
     * @notice Get guardian address
     * @return Guardian address
     */
    function guardian() external view returns (address);

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external view returns (string memory);
}
