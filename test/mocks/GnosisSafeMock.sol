// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GnosisSafeMock
 * @notice Minimal mock simulating a 3-of-5 Gnosis Safe multisig
 * @dev NOT a real Safe — just enough to test the proposer/executor flow through
 *      TimelockController with multi-signer approval. Signers approve a transaction
 *      hash, and once the threshold is met, anyone can trigger execution.
 */
contract GnosisSafeMock {
    uint256 public constant THRESHOLD = 3;
    uint256 public constant MAX_SIGNERS = 5;

    address[5] public signers;
    uint256 public signerCount;

    /// @notice Tracks approvals per transaction hash: txHash => signer => approved
    mapping(bytes32 => mapping(address => bool)) public approvals;

    /// @notice Number of approvals per transaction hash
    mapping(bytes32 => uint256) public approvalCount;

    /// @notice Whether a transaction has been executed
    mapping(bytes32 => bool) public executed;

    event ApproveHash(bytes32 indexed txHash, address indexed signer);
    event ExecutionSuccess(bytes32 indexed txHash);
    event ExecutionFailure(bytes32 indexed txHash);

    error NotASigner(address caller);
    error AlreadyApproved(bytes32 txHash, address signer);
    error ThresholdNotMet(uint256 current, uint256 required);
    error AlreadyExecuted(bytes32 txHash);
    error ExecutionFailed(bytes32 txHash);

    constructor(address[5] memory _signers) {
        for (uint256 i = 0; i < MAX_SIGNERS; i++) {
            signers[i] = _signers[i];
        }
        signerCount = MAX_SIGNERS;
    }

    modifier onlySigner() {
        bool found = false;
        for (uint256 i = 0; i < signerCount; i++) {
            if (signers[i] == msg.sender) {
                found = true;
                break;
            }
        }
        if (!found) revert NotASigner(msg.sender);
        _;
    }

    /// @notice Compute the transaction hash for a given call
    function getTransactionHash(address to, uint256 value, bytes memory data) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(to, value, data));
    }

    /// @notice Approve a transaction hash (signer only)
    function approveHash(bytes32 txHash) external onlySigner {
        if (approvals[txHash][msg.sender]) revert AlreadyApproved(txHash, msg.sender);

        approvals[txHash][msg.sender] = true;
        approvalCount[txHash]++;

        emit ApproveHash(txHash, msg.sender);
    }

    /// @notice Execute a transaction if threshold is met
    function execTransaction(address to, uint256 value, bytes memory data) external returns (bool) {
        bytes32 txHash = getTransactionHash(to, value, data);

        if (executed[txHash]) revert AlreadyExecuted(txHash);
        if (approvalCount[txHash] < THRESHOLD) revert ThresholdNotMet(approvalCount[txHash], THRESHOLD);

        executed[txHash] = true;

        (bool success,) = to.call{value: value}(data);
        if (success) {
            emit ExecutionSuccess(txHash);
        } else {
            emit ExecutionFailure(txHash);
            revert ExecutionFailed(txHash);
        }
        return success;
    }

    /// @notice Allow Safe to receive ETH
    receive() external payable {}
}
