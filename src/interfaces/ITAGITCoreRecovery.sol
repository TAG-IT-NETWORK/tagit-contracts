// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITAGITCoreRecovery
 * @notice READ-ONLY view of TAGITCore used by TAGITRecovery.
 * @dev SECURITY INVARIANT: this interface declares no state-changing function, by
 *      design. TAGITRecovery holds no CapabilityBadge and never mutates TAGITCore.
 *      Custody is moved exclusively by TAGITCore.resolve(), which requires
 *      RESOLVER_CAPABILITY and a 2-of-3 human approval quorum. Do not add a
 *      non-view function here.
 */
interface ITAGITCoreRecovery {
    enum State {
        NONE,
        MINTED,
        BOUND,
        ACTIVATED,
        CLAIMED,
        FLAGGED,
        RECYCLED
    }

    function getAsset(uint256 tokenId)
        external
        view
        returns (address assetOwner, uint64 timestamp, State state, uint8 flags, uint16 reserved);

    function preFlagState(uint256 tokenId) external view returns (State);

    function getResolveApprovalStatus(uint256 tokenId)
        external
        view
        returns (uint256 approvalCount, address recipient, bool quorumReached);

    function RESOLVE_QUORUM() external view returns (uint256);
}
