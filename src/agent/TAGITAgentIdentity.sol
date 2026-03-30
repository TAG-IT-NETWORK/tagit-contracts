// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ITAGITAccess} from "../interfaces/ITAGITAccess.sol";
import {IReputationStaking} from "../interfaces/IReputationStaking.sol";

/**
 * @title TAGITAgentIdentity
 * @author TAG IT Network <dev@tagit.network>
 * @notice ERC-8004 Agent Identity Registry — soulbound ERC-721 for AI agent registration
 * @dev Implements agent identity as non-transferable NFTs with BIDGES access control.
 *
 * Each registered AI agent receives a soulbound token containing:
 * - Agent URI (IPFS metadata: name, description, capabilities, model info)
 * - Agent wallet address (the address the agent uses to transact)
 * - Arbitrary key-value metadata for extensibility
 * - Registration timestamp and status
 *
 * Access Control:
 * - Registration requires KYC_L1 identity badge via BIDGES
 * - GOV_MIL defense guard prevents unauthorized military/governance agents
 * - Pausable for emergency stops
 *
 * EIP-712:
 * - Typed structured data for agent wallet verification signatures
 *
 * @custom:security Soulbound — transfers are disabled after mint
 * @custom:security All state-changing functions follow CEI pattern with ReentrancyGuard
 */
contract TAGITAgentIdentity is ERC721, ERC721URIStorage, Ownable, Pausable, ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;

    // ============================================
    // BIDGES CAPABILITIES (Access Control)
    // ============================================

    /// @notice Capability required to register an agent (KYC Level 1)
    bytes32 public constant AGENT_REGISTRAR_CAPABILITY = keccak256("AGENT_REGISTRAR");

    /// @notice Identity badge level required (KYC_L1)
    uint256 public constant KYC_L1_IDENTITY = 1;

    /// @notice Defense guard capability — holders are blocked from agent registration
    bytes32 public constant GOV_MIL_CAPABILITY = keccak256("GOV_MIL");

    // ============================================
    // EIP-712 TYPE HASHES
    // ============================================

    /// @notice EIP-712 typehash for agent wallet verification
    bytes32 public constant AGENT_WALLET_TYPEHASH =
        keccak256("AgentWallet(uint256 agentId,address wallet,uint256 nonce)");

    // ============================================
    // DATA STRUCTURES
    // ============================================

    /**
     * @notice Agent registration record
     * @dev Stores core agent identity data on-chain
     */
    struct Agent {
        address registrant; // Address that registered the agent (human operator)
        address wallet; // Agent's operational wallet address
        uint64 registeredAt; // Registration timestamp
        bool active; // Whether agent is currently active
    }

    /**
     * @notice Agent status enum for lifecycle management
     */
    enum AgentStatus {
        INACTIVE,
        ACTIVE,
        SUSPENDED,
        DECOMMISSIONED
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Agent ID does not exist
    error AgentNotFound(uint256 agentId);

    /// @notice Caller is not the agent's registrant
    error NotRegistrant(address caller, uint256 agentId);

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Invalid URI (empty string)
    error InvalidURI();

    /// @notice Agent wallet already registered to another agent
    error WalletAlreadyRegistered(address wallet);

    /// @notice Caller holds GOV_MIL capability (defense guard)
    error DefenseGuardBlocked(address caller);

    /// @notice Caller lacks KYC_L1 identity
    error MissingKYCIdentity(address caller);

    /// @notice Invalid EIP-712 signature
    error InvalidSignature();

    /// @notice Soulbound token — transfers are disabled
    error SoulboundTransferDisabled();

    /// @notice Invalid metadata key (empty)
    error InvalidMetadataKey();

    /// @notice Access controller not set
    error AccessControllerNotSet();

    /// @notice Agent does not meet minimum credibility bond
    error InsufficientCredibilityBond(uint256 agentId);

    /// @notice Agent is not active
    error AgentNotActive(uint256 agentId);

    /// @notice Agent is already in requested status
    error AgentAlreadyInStatus(uint256 agentId, AgentStatus status);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when a new agent is registered
    event AgentRegistered(uint256 indexed agentId, address indexed registrant, address indexed wallet, string uri);

    /// @notice Emitted when agent URI is updated
    event AgentURIUpdated(uint256 indexed agentId, string newURI);

    /// @notice Emitted when agent wallet is updated
    event AgentWalletUpdated(uint256 indexed agentId, address indexed oldWallet, address indexed newWallet);

    /// @notice Emitted when agent metadata key-value is set
    event AgentMetadataSet(uint256 indexed agentId, string key, string value);

    /// @notice Emitted when agent status changes
    event AgentStatusChanged(uint256 indexed agentId, AgentStatus oldStatus, AgentStatus newStatus);

    /// @notice Emitted when access controller is updated
    event AccessControllerUpdated(address indexed previousController, address indexed newController);

    /// @notice Emitted when reputation staking contract is updated
    event ReputationStakingUpdated(address indexed previousStaking, address indexed newStaking);

    /// @notice Emitted when registration fee is updated
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);

    // ============================================
    // STORAGE
    // ============================================

    /// @notice TAGITAccess controller for BIDGES capability checks
    ITAGITAccess public accessController;

    /// @notice Counter for next agent ID (starts at 1)
    uint256 private _nextAgentId;

    /// @notice Total number of registered agents
    uint256 private _totalAgents;

    /// @notice Mapping from agent ID to Agent record
    mapping(uint256 => Agent) private _agents;

    /// @notice Mapping from agent ID to status
    mapping(uint256 => AgentStatus) private _agentStatus;

    /// @notice Mapping from agent wallet address to agent ID (ensures uniqueness)
    mapping(address => uint256) private _walletToAgent;

    /// @notice Mapping from agent ID to metadata (key => value)
    mapping(uint256 => mapping(string => string)) private _metadata;

    /// @notice Mapping from registrant to their agent IDs
    mapping(address => uint256[]) private _registrantAgents;

    /// @notice EIP-712 nonce per agent for wallet verification
    mapping(uint256 => uint256) private _walletNonces;

    /// @notice Registration fee in wei (can be 0)
    uint256 public registrationFee;

    /// @notice Optional reputation staking contract for credibility bond enforcement
    IReputationStaking public reputationStaking;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize TAGITAgentIdentity contract
     * @dev Sets ERC721 name/symbol, EIP-712 domain, initializes counters
     */
    constructor() ERC721("TAGIT Agent Identity", "TAGIT-AGENT") Ownable(msg.sender) EIP712("TAGITAgentIdentity", "1") {
        _nextAgentId = 1; // Start at 1 (0 reserved for "none")
    }

    // ============================================
    // ACCESS CONTROL
    // ============================================

    /**
     * @notice Set the TAGITAccess controller
     * @param controller Address of the TAGITAccess controller
     * @custom:security Only owner can call
     * @custom:emits AccessControllerUpdated
     */
    function setAccessController(address controller) external onlyOwner {
        address previousController = address(accessController);
        accessController = ITAGITAccess(controller);
        emit AccessControllerUpdated(previousController, controller);
    }

    /**
     * @notice Set the ReputationStaking contract for credibility bond enforcement
     * @param stakingContract Address of the ReputationStaking contract (address(0) to disable)
     * @custom:security Only owner can call
     * @custom:emits ReputationStakingUpdated
     */
    function setReputationStaking(address stakingContract) external onlyOwner {
        address previousStaking = address(reputationStaking);
        reputationStaking = IReputationStaking(stakingContract);
        emit ReputationStakingUpdated(previousStaking, stakingContract);
    }

    /**
     * @notice Set registration fee
     * @param fee New registration fee in wei
     * @custom:security Only owner can call
     * @custom:emits RegistrationFeeUpdated
     */
    function setRegistrationFee(uint256 fee) external onlyOwner {
        uint256 oldFee = registrationFee;
        registrationFee = fee;
        emit RegistrationFeeUpdated(oldFee, fee);
    }

    /**
     * @notice Modifier requiring BIDGES KYC_L1 identity and no GOV_MIL flag
     * @dev Checks: (1) access controller is set, (2) has KYC_L1 identity, (3) no GOV_MIL capability
     */
    modifier requiresKYC() {
        // Check access controller is configured
        if (address(accessController) == address(0)) revert AccessControllerNotSet();

        // Check KYC_L1 identity
        if (!accessController.hasIdentity(msg.sender, KYC_L1_IDENTITY)) {
            revert MissingKYCIdentity(msg.sender);
        }

        // Defense guard: block GOV_MIL capability holders
        if (accessController.hasCapability(msg.sender, uint256(GOV_MIL_CAPABILITY))) {
            revert DefenseGuardBlocked(msg.sender);
        }
        _;
    }

    /**
     * @notice Modifier requiring caller to be agent registrant
     * @param agentId The agent ID to check ownership for
     */
    modifier onlyRegistrant(uint256 agentId) {
        Agent storage agent = _agents[agentId];
        if (agent.registrant == address(0)) revert AgentNotFound(agentId);
        if (agent.registrant != msg.sender) revert NotRegistrant(msg.sender, agentId);
        _;
    }

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Register a new AI agent
     * @dev Mints a soulbound ERC-721 token for the agent. Requires KYC_L1.
     *      Registration fee (if any) is collected and held for routing via TAGITBurner.
     *      Follows Checks-Effects-Interactions pattern.
     * @param wallet The agent's operational wallet address
     * @param uri IPFS URI for agent metadata (name, description, capabilities, model info)
     * @return agentId The ID of the newly registered agent
     * @custom:security ReentrancyGuard + Pausable + KYC check
     * @custom:security Soulbound — token cannot be transferred after mint
     * @custom:emits AgentRegistered, AgentStatusChanged
     */
    function register(address wallet, string calldata uri)
        external
        payable
        nonReentrant
        whenNotPaused
        requiresKYC
        returns (uint256 agentId)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (wallet == address(0)) revert ZeroAddress();
        if (bytes(uri).length == 0) revert InvalidURI();
        if (_walletToAgent[wallet] != 0) revert WalletAlreadyRegistered(wallet);
        if (msg.value < registrationFee) {
            revert(); // Insufficient fee
        }

        // ============================================
        // EFFECTS
        // ============================================
        agentId = _nextAgentId++;
        _totalAgents++;

        _agents[agentId] =
            Agent({registrant: msg.sender, wallet: wallet, registeredAt: uint64(block.timestamp), active: true});

        _agentStatus[agentId] = AgentStatus.ACTIVE;
        _walletToAgent[wallet] = agentId;
        _registrantAgents[msg.sender].push(agentId);

        // Mint soulbound ERC-721 token to registrant
        _mint(msg.sender, agentId);
        _setTokenURI(agentId, uri);

        // ============================================
        // CREDIBILITY BOND CHECK
        // ============================================
        // If reputation staking is configured, require minimum bond
        if (address(reputationStaking) != address(0)) {
            if (!reputationStaking.hasMinBond(agentId)) {
                revert InsufficientCredibilityBond(agentId);
            }
        }

        // ============================================
        // INTERACTIONS
        // ============================================
        emit AgentRegistered(agentId, msg.sender, wallet, uri);
        emit AgentStatusChanged(agentId, AgentStatus.INACTIVE, AgentStatus.ACTIVE);
    }

    /**
     * @notice Update agent metadata URI
     * @dev Only the agent's registrant can update. Agent must be active.
     *      Follows Checks-Effects-Interactions pattern.
     * @param agentId The agent ID to update
     * @param newURI New IPFS URI for agent metadata
     * @custom:security Only registrant, ReentrancyGuard, Pausable
     * @custom:emits AgentURIUpdated
     */
    function setAgentURI(uint256 agentId, string calldata newURI)
        external
        nonReentrant
        whenNotPaused
        onlyRegistrant(agentId)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (bytes(newURI).length == 0) revert InvalidURI();
        if (_agentStatus[agentId] == AgentStatus.DECOMMISSIONED) {
            revert AgentNotActive(agentId);
        }

        // ============================================
        // EFFECTS
        // ============================================
        _setTokenURI(agentId, newURI);

        // ============================================
        // INTERACTIONS
        // ============================================
        emit AgentURIUpdated(agentId, newURI);
    }

    /**
     * @notice Set agent metadata key-value pair
     * @dev Arbitrary extensible metadata. Only registrant can set.
     *      Follows Checks-Effects-Interactions pattern.
     * @param agentId The agent ID
     * @param key Metadata key
     * @param value Metadata value
     * @custom:security Only registrant, ReentrancyGuard, Pausable
     * @custom:emits AgentMetadataSet
     */
    function setMetadata(uint256 agentId, string calldata key, string calldata value)
        external
        nonReentrant
        whenNotPaused
        onlyRegistrant(agentId)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (bytes(key).length == 0) revert InvalidMetadataKey();
        if (_agentStatus[agentId] == AgentStatus.DECOMMISSIONED) {
            revert AgentNotActive(agentId);
        }

        // ============================================
        // EFFECTS
        // ============================================
        _metadata[agentId][key] = value;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit AgentMetadataSet(agentId, key, value);
    }

    /**
     * @notice Update agent wallet address with EIP-712 signature verification
     * @dev The new wallet must sign an EIP-712 message proving ownership.
     *      Follows Checks-Effects-Interactions pattern.
     * @param agentId The agent ID
     * @param newWallet New wallet address
     * @param signature EIP-712 signature from the new wallet
     * @custom:security EIP-712 typed data prevents replay attacks
     * @custom:security Only registrant, ReentrancyGuard, Pausable
     * @custom:emits AgentWalletUpdated
     */
    function setAgentWallet(uint256 agentId, address newWallet, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        onlyRegistrant(agentId)
    {
        // ============================================
        // CHECKS
        // ============================================
        if (newWallet == address(0)) revert ZeroAddress();
        if (_walletToAgent[newWallet] != 0) revert WalletAlreadyRegistered(newWallet);
        if (_agentStatus[agentId] == AgentStatus.DECOMMISSIONED) {
            revert AgentNotActive(agentId);
        }

        // Verify EIP-712 signature from new wallet
        uint256 nonce = _walletNonces[agentId];
        bytes32 structHash = keccak256(abi.encode(AGENT_WALLET_TYPEHASH, agentId, newWallet, nonce));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != newWallet) revert InvalidSignature();

        // ============================================
        // EFFECTS
        // ============================================
        address oldWallet = _agents[agentId].wallet;
        delete _walletToAgent[oldWallet];
        _walletToAgent[newWallet] = agentId;
        _agents[agentId].wallet = newWallet;
        _walletNonces[agentId] = nonce + 1;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit AgentWalletUpdated(agentId, oldWallet, newWallet);
    }

    /**
     * @notice Suspend an agent (admin action)
     * @dev Only contract owner can suspend agents. Reversible.
     * @param agentId The agent ID to suspend
     * @custom:security Only owner, ReentrancyGuard
     * @custom:emits AgentStatusChanged
     */
    function suspendAgent(uint256 agentId) external nonReentrant onlyOwner {
        // ============================================
        // CHECKS
        // ============================================
        if (_agents[agentId].registrant == address(0)) revert AgentNotFound(agentId);
        AgentStatus currentStatus = _agentStatus[agentId];
        if (currentStatus == AgentStatus.SUSPENDED) {
            revert AgentAlreadyInStatus(agentId, AgentStatus.SUSPENDED);
        }
        if (currentStatus == AgentStatus.DECOMMISSIONED) {
            revert AgentAlreadyInStatus(agentId, AgentStatus.DECOMMISSIONED);
        }

        // ============================================
        // EFFECTS
        // ============================================
        _agentStatus[agentId] = AgentStatus.SUSPENDED;
        _agents[agentId].active = false;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit AgentStatusChanged(agentId, currentStatus, AgentStatus.SUSPENDED);
    }

    /**
     * @notice Reactivate a suspended agent (admin action)
     * @dev Only contract owner can reactivate. Only works on SUSPENDED agents.
     * @param agentId The agent ID to reactivate
     * @custom:security Only owner, ReentrancyGuard
     * @custom:emits AgentStatusChanged
     */
    function reactivateAgent(uint256 agentId) external nonReentrant onlyOwner {
        // ============================================
        // CHECKS
        // ============================================
        if (_agents[agentId].registrant == address(0)) revert AgentNotFound(agentId);
        if (_agentStatus[agentId] != AgentStatus.SUSPENDED) {
            revert AgentAlreadyInStatus(agentId, _agentStatus[agentId]);
        }

        // ============================================
        // EFFECTS
        // ============================================
        _agentStatus[agentId] = AgentStatus.ACTIVE;
        _agents[agentId].active = true;

        // ============================================
        // INTERACTIONS
        // ============================================
        emit AgentStatusChanged(agentId, AgentStatus.SUSPENDED, AgentStatus.ACTIVE);
    }

    /**
     * @notice Decommission an agent permanently (registrant action)
     * @dev Only the registrant can decommission. This is irreversible.
     * @param agentId The agent ID to decommission
     * @custom:security Only registrant, ReentrancyGuard
     * @custom:emits AgentStatusChanged
     */
    function decommissionAgent(uint256 agentId) external nonReentrant onlyRegistrant(agentId) {
        // ============================================
        // CHECKS
        // ============================================
        AgentStatus currentStatus = _agentStatus[agentId];
        if (currentStatus == AgentStatus.DECOMMISSIONED) {
            revert AgentAlreadyInStatus(agentId, AgentStatus.DECOMMISSIONED);
        }

        // ============================================
        // EFFECTS
        // ============================================
        _agentStatus[agentId] = AgentStatus.DECOMMISSIONED;
        _agents[agentId].active = false;

        // Free the wallet for reuse
        address wallet = _agents[agentId].wallet;
        delete _walletToAgent[wallet];

        // ============================================
        // INTERACTIONS
        // ============================================
        emit AgentStatusChanged(agentId, currentStatus, AgentStatus.DECOMMISSIONED);
    }

    // ============================================
    // PAUSE FUNCTIONS
    // ============================================

    /// @notice Pause contract (emergency stop)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause contract
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get agent record
     * @param agentId The agent ID to query
     * @return registrant The address that registered the agent
     * @return wallet The agent's operational wallet
     * @return registeredAt Registration timestamp
     * @return active Whether agent is active
     */
    function getAgent(uint256 agentId)
        external
        view
        returns (address registrant, address wallet, uint64 registeredAt, bool active)
    {
        Agent memory agent = _agents[agentId];
        return (agent.registrant, agent.wallet, agent.registeredAt, agent.active);
    }

    /**
     * @notice Get agent status
     * @param agentId The agent ID to query
     * @return Current agent status
     */
    function getAgentStatus(uint256 agentId) external view returns (AgentStatus) {
        return _agentStatus[agentId];
    }

    /**
     * @notice Get agent metadata value
     * @param agentId The agent ID
     * @param key Metadata key
     * @return Metadata value (empty string if not set)
     */
    function getMetadata(uint256 agentId, string calldata key) external view returns (string memory) {
        return _metadata[agentId][key];
    }

    /**
     * @notice Get agent ID by wallet address
     * @param wallet The wallet address to look up
     * @return agentId The agent ID (0 if not found)
     */
    function getAgentByWallet(address wallet) external view returns (uint256) {
        return _walletToAgent[wallet];
    }

    /**
     * @notice Get all agent IDs registered by an address
     * @param registrant The registrant address
     * @return Array of agent IDs
     */
    function getAgentsByRegistrant(address registrant) external view returns (uint256[] memory) {
        return _registrantAgents[registrant];
    }

    /**
     * @notice Get total number of registered agents
     * @return Total agent count
     */
    function totalAgents() external view returns (uint256) {
        return _totalAgents;
    }

    /**
     * @notice Check if an agent exists and is active
     * @param agentId The agent ID to check
     * @return True if agent exists and is active
     */
    function isActiveAgent(uint256 agentId) external view returns (bool) {
        return _agents[agentId].registrant != address(0) && _agentStatus[agentId] == AgentStatus.ACTIVE;
    }

    /**
     * @notice Get EIP-712 wallet nonce for an agent
     * @param agentId The agent ID
     * @return Current nonce value
     */
    function walletNonce(uint256 agentId) external view returns (uint256) {
        return _walletNonces[agentId];
    }

    // ============================================
    // FEE WITHDRAWAL
    // ============================================

    /**
     * @notice Withdraw collected registration fees
     * @dev Only owner can withdraw. In production, route through TAGITBurner.
     * @param to Destination address
     * @custom:security Only owner, ReentrancyGuard
     */
    function withdrawFees(address to) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        (bool success,) = to.call{value: balance}("");
        require(success);
    }

    // ============================================
    // SOULBOUND ENFORCEMENT
    // ============================================

    /**
     * @notice Override ERC721 _update to enforce soulbound (non-transferable) tokens
     * @dev Allows minting (from == address(0)) but blocks all transfers
     */
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721) returns (address) {
        address from = _ownerOf(tokenId);
        // Allow minting (from zero address) and burning, block transfers
        if (from != address(0) && to != address(0)) {
            revert SoulboundTransferDisabled();
        }
        return super._update(to, tokenId, auth);
    }

    // ============================================
    // REQUIRED OVERRIDES
    // ============================================

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
