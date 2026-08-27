// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRecovery} from "../../src/interfaces/IRecovery.sol";
import {ITAGITAccess} from "../../src/interfaces/ITAGITAccess.sol";
import {CircuitBreaker} from "../../src/libraries/CircuitBreaker.sol";
import {RateLimiter} from "../../src/libraries/RateLimiter.sol";

/**
 * @title TAGITRecoveryV1Layout
 * @notice TEST-ONLY faithful reproduction of the TAGITRecovery v1 STORAGE LAYOUT.
 * @dev Same inheritance chain and same declaration order as the pre-fix contract, ending
 *      in `uint256[37] __gap`. Used to prove the v2 implementation is a drop-in
 *      storage-compatible upgrade: values written through this contract must read back
 *      unchanged through the real TAGITRecovery after upgradeToAndCall.
 *
 *      Only ReentrancyGuard contributes sequential storage (slot 0); OwnableUpgradeable,
 *      PausableUpgradeable and UUPSUpgradeable all use ERC-7201 namespaced slots.
 */
contract TAGITRecoveryV1Layout is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
    using CircuitBreaker for CircuitBreaker.Config;
    using RateLimiter for RateLimiter.Config;

    // ---- v1 storage, verbatim order ----
    address public core; // slot 1
    ITAGITAccess public access; // slot 2
    IERC20 public token; // slot 3
    address public governor; // slot 4
    address public treasury; // slot 5
    uint256 public minimumStake; // slot 6
    uint256 public votingDuration; // slot 7
    uint256 private _nextCaseId; // slot 8
    mapping(uint256 => IRecovery.RecoveryCase) private _cases; // slot 9
    mapping(uint256 => uint256) private _tokenToCase; // slot 10
    mapping(uint256 => mapping(address => IRecovery.Vote)) private _votes; // slot 11
    mapping(uint256 => mapping(address => bool)) private _hasVoted; // slot 12
    mapping(uint256 => bool) private _quarantined; // slot 13
    uint256 public totalStakesHeld; // slot 14
    CircuitBreaker.Config private _recoveryCircuit; // slots 15-16
    RateLimiter.Config private _rateLimitConfig; // slots 17-18
    mapping(address => RateLimiter.UserState) private _rateLimitStates; // slot 19
    uint256[37] private __gap; // slots 20-56

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _core,
        address _access,
        address _token,
        address _governor,
        address _treasury,
        address initialOwner
    ) external initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __Pausable_init();

        core = _core;
        access = ITAGITAccess(_access);
        token = IERC20(_token);
        governor = _governor;
        treasury = _treasury;
        minimumStake = 100e18;
        votingDuration = 7 days;
        _nextCaseId = 1;

        _recoveryCircuit.initialize(50, 1 hours, 4 hours);
        _rateLimitConfig.initialize(3, 1 hours, 2 hours, 100);
    }

    /// @notice Write a case + votes exactly as v1 would have stored them
    function seedCase(
        uint256 tokenId,
        address claimant,
        address currentHolder,
        bytes32 evidenceHash,
        uint256 stakeBond,
        address[] calldata voters,
        uint256[] calldata weights
    ) external returns (uint256 caseId) {
        caseId = _nextCaseId++;
        _cases[caseId] = IRecovery.RecoveryCase({
            tokenId: tokenId,
            claimant: claimant,
            currentHolder: currentHolder,
            evidenceHash: evidenceHash,
            createdAt: uint48(block.timestamp),
            votingEndsAt: uint48(block.timestamp + votingDuration),
            status: IRecovery.CaseStatus.VOTING,
            stakeBond: stakeBond,
            votesFor: 0,
            votesAgainst: 0,
            voteCount: 0
        });
        _tokenToCase[tokenId] = caseId;
        _quarantined[tokenId] = true;
        totalStakesHeld += stakeBond;

        for (uint256 i = 0; i < voters.length; i++) {
            _hasVoted[caseId][voters[i]] = true;
            _votes[caseId][voters[i]] =
                IRecovery.Vote({approve: true, weight: weights[i], reasonHash: keccak256("v1-reason")});
            _cases[caseId].votesFor += weights[i];
            _cases[caseId].voteCount++;
        }
    }

    function getCase(uint256 caseId) external view returns (IRecovery.RecoveryCase memory) {
        return _cases[caseId];
    }

    function nextCaseId() external view returns (uint256) {
        return _nextCaseId;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
