// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVoucherAnchorVerifier
 * @author TAG IT Network <dev@tagit.network>
 * @notice Interface for verifying Voucher state against L1-anchored L2 state roots
 * @dev Enables trustless verification of L2 Voucher balances and redemption
 *      status on L1, using Merkle proofs against state roots anchored by
 *      the IL1AnchorRegistry.
 *
 *      Verification flow:
 *        1. L2 state root is anchored on L1 (via IL1AnchorRegistry)
 *        2. User or relayer obtains a storage proof from L2 (eth_getProof)
 *        3. Proof is submitted to verifyVoucherState() on L1
 *        4. Contract validates the proof against the anchored root
 *        5. Verified state can be used for L1 claims, governance weight, etc.
 *
 * @custom:security Proofs are validated against immutable anchored roots.
 *                  Each (holder, l2BlockNumber) pair can only be verified once
 *                  to prevent replay of stale state.
 */
interface IVoucherAnchorVerifier {
    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Verified voucher state for a holder at a specific L2 block
     * @param holder Address of the voucher holder
     * @param balance Verified voucher balance on L2
     * @param redeemed Whether the voucher has been fully redeemed on L2
     * @param l2BlockNumber The L2 block at which state was proven
     * @param verifiedAt L1 timestamp of verification
     */
    struct VerifiedVoucherState {
        address holder;
        uint256 balance;
        bool redeemed;
        uint256 l2BlockNumber;
        uint64 verifiedAt;
    }

    // ============================================
    // CUSTOM ERRORS
    // ============================================

    /// @notice Holder address is zero
    error InvalidHolder();

    /// @notice Merkle proof array is empty
    error EmptyProof();

    /// @notice Anchored state root is zero or not found for the given block
    error AnchoredRootNotFound(uint256 l2BlockNumber);

    /// @notice Merkle proof verification failed against the anchored root
    error ProofVerificationFailed(address holder, bytes32 root);

    /// @notice Voucher state for this holder at this block was already verified
    error AlreadyVerified(address holder, uint256 l2BlockNumber);

    /// @notice No verified state exists for the given holder
    error NoVerifiedState(address holder);

    /// @notice The anchor registry address is zero or invalid
    error InvalidAnchorRegistry();

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when a voucher holder's L2 state is verified on L1
     * @param holder Address of the voucher holder
     * @param balance Verified balance from L2 state
     * @param redeemed Whether the voucher was redeemed on L2
     * @param l2BlockNumber L2 block number used for verification
     */
    event VoucherStateVerified(address indexed holder, uint256 balance, bool redeemed, uint256 indexed l2BlockNumber);

    /**
     * @notice Emitted when the anchor registry reference is updated
     * @param oldRegistry Previous anchor registry address
     * @param newRegistry New anchor registry address
     */
    event AnchorRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============================================
    // VERIFICATION
    // ============================================

    /**
     * @notice Verify a voucher holder's L2 state against an anchored state root
     * @dev The proof must be a valid Merkle-Patricia trie proof obtained via
     *      eth_getProof on the L2 Voucher contract's storage for the holder.
     *      The anchored root is fetched from the IL1AnchorRegistry for the
     *      given l2BlockNumber.
     *
     *      Proof structure (simplified):
     *        - proof[0..n-1]: Sibling hashes from leaf to root
     *        - leaf: keccak256(abi.encodePacked(holder, balance, redeemed))
     *        - root: Anchored state root from IL1AnchorRegistry
     *
     * @param holder Address of the voucher holder on L2
     * @param proof Merkle proof path (sibling hashes from leaf to root)
     * @param root The expected state root (must match an anchored root)
     * @return verified True if proof is valid and state has been recorded
     * @custom:security Each (holder, l2BlockNumber) pair verified at most once
     * @custom:emits VoucherStateVerified
     */
    function verifyVoucherState(address holder, bytes32[] calldata proof, bytes32 root) external returns (bool verified);

    // ============================================
    // QUERY FUNCTIONS
    // ============================================

    /**
     * @notice Get the latest verified voucher state for a holder
     * @param holder Address of the voucher holder
     * @return state The most recently verified VoucherState
     */
    function getVerifiedState(address holder) external view returns (VerifiedVoucherState memory state);

    /**
     * @notice Get a holder's verified state at a specific L2 block
     * @param holder Address of the voucher holder
     * @param l2BlockNumber The L2 block to query
     * @return state The verified VoucherState at that block
     */
    function getVerifiedStateAt(address holder, uint256 l2BlockNumber)
        external
        view
        returns (VerifiedVoucherState memory state);

    /**
     * @notice Check whether a holder's voucher state has been verified
     * @param holder Address of the voucher holder
     * @return exists True if any verified state exists for this holder
     */
    function hasVerifiedState(address holder) external view returns (bool exists);

    /**
     * @notice Check whether state has been verified for a specific block
     * @param holder Address of the voucher holder
     * @param l2BlockNumber The L2 block to check
     * @return verified True if state was verified at this block
     */
    function isVerifiedAt(address holder, uint256 l2BlockNumber) external view returns (bool verified);

    // ============================================
    // ADMIN
    // ============================================

    /**
     * @notice Update the IL1AnchorRegistry contract reference
     * @param newRegistry Address of the new anchor registry
     * @custom:security Only callable by contract owner / governance
     * @custom:emits AnchorRegistryUpdated
     */
    function setAnchorRegistry(address newRegistry) external;

    /**
     * @notice Get the current anchor registry address
     * @return registry The IL1AnchorRegistry contract address
     */
    function anchorRegistry() external view returns (address registry);
}
