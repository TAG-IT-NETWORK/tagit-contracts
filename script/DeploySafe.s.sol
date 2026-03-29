// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "@forge-std/Script.sol";

/**
 * @title DeploySafe
 * @author TAG IT Network <dev@tagit.network>
 * @notice Deployment script for Gnosis Safe multi-sig on OP Sepolia
 * @dev Deploys a Safe v1.4.1 proxy via the SafeProxyFactory with specified owners and threshold.
 *
 * Usage:
 *   forge script script/DeploySafe.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --private-key $PRIVATE_KEY
 *
 * Prerequisites:
 *   - Safe singleton and factory already deployed on OP Sepolia (canonical addresses)
 *   - Owner addresses finalized and verified
 *
 * @custom:security Owner addresses MUST be verified before deployment.
 *   Never deploy with placeholder addresses.
 */
contract DeploySafe is Script {
    /// @notice Safe v1.4.1 canonical singleton on OP Sepolia
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;

    /// @notice Safe proxy factory on OP Sepolia
    address constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;

    /// @notice CompatibilityFallbackHandler v1.4.1 on OP Sepolia
    address constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    /// @notice Threshold: 3 of 5 signers required
    uint256 constant THRESHOLD = 3;

    /**
     * @notice Deploy a new Gnosis Safe proxy with specified owners
     * @dev Encodes the Safe.setup() call as initializer data and passes it to
     *      SafeProxyFactory.createProxyWithNonce() for deterministic deployment.
     *
     *      The owners array MUST be populated with real signer addresses before
     *      broadcasting. This script will revert if fewer than THRESHOLD owners
     *      are provided.
     */
    function run() external {
        // ============================================
        // CONFIGURE OWNERS
        // ============================================
        // These addresses must be replaced with actual signer addresses
        // before broadcasting. Query existing Safe owners via:
        //   cast call $SAFE_ADDRESS "getOwners()(address[])" --rpc-url $OP_SEPOLIA_RPC_URL
        address[] memory owners = new address[](5);
        owners[0] = vm.envAddress("SIGNER_1"); // Founder (Artemus)
        owners[1] = vm.envAddress("SIGNER_2"); // Engineering Lead (SUDO)
        owners[2] = vm.envAddress("SIGNER_3"); // Security Officer
        owners[3] = vm.envAddress("SIGNER_4"); // Operations Lead
        owners[4] = vm.envAddress("SIGNER_5"); // Community Representative

        // ============================================
        // VALIDATE
        // ============================================
        require(owners.length >= THRESHOLD, "DeploySafe: insufficient owners for threshold");
        for (uint256 i = 0; i < owners.length; i++) {
            require(owners[i] != address(0), "DeploySafe: zero address owner");
            for (uint256 j = i + 1; j < owners.length; j++) {
                require(owners[i] != owners[j], "DeploySafe: duplicate owner");
            }
        }

        // ============================================
        // ENCODE SETUP
        // ============================================
        // Safe.setup(owners, threshold, to, data, fallbackHandler, paymentToken, payment, paymentReceiver)
        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            THRESHOLD,
            address(0), // to: no delegate call on setup
            "", // data: no delegate call data
            FALLBACK_HANDLER,
            address(0), // paymentToken: ETH
            0, // payment: 0
            payable(address(0)) // paymentReceiver: none
        );

        // ============================================
        // DEPLOY
        // ============================================
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // createProxyWithNonce(singleton, initializer, saltNonce)
        (bool success, bytes memory returnData) = SAFE_PROXY_FACTORY.call(
            abi.encodeWithSignature(
                "createProxyWithNonce(address,bytes,uint256)", SAFE_SINGLETON, initializer, block.timestamp
            )
        );
        require(success, "DeploySafe: proxy creation failed");

        address safeAddress = abi.decode(returnData, (address));

        vm.stopBroadcast();

        // ============================================
        // LOG
        // ============================================
        console.log("=== Gnosis Safe Deployed ===");
        console.log("Safe Address:", safeAddress);
        console.log("Threshold:", THRESHOLD);
        console.log("Owners:", owners.length);
        console.log("Network: OP Sepolia (11155420)");
        console.log("");
        console.log("Next steps:");
        console.log("1. Verify on block explorer");
        console.log("2. Update SAFE_ADDRESS in .env");
        console.log("3. Run TransferAgentIdentityOwnership.s.sol");
    }
}
