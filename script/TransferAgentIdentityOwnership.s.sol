// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "@forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TransferAgentIdentityOwnership
 * @author TAG IT Network <dev@tagit.network>
 * @notice Transfers ownership of Agent Identity contracts to the Gnosis Safe multi-sig
 * @dev Calls transferOwnership(safeAddress) on TAGITAgentIdentity, TAGITAgentReputation,
 *      and TAGITAgentValidation contracts.
 *
 * Usage:
 *   forge script script/TransferAgentIdentityOwnership.s.sol \
 *     --rpc-url $OP_SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --private-key $PRIVATE_KEY
 *
 * Prerequisites:
 *   - PRIVATE_KEY must be the current owner of all 3 contracts
 *   - SAFE_ADDRESS must be a deployed and verified Gnosis Safe
 *   - All contracts must be deployed on OP Sepolia
 *
 * @custom:security This is a one-way operation. After transfer, the deployer EOA
 *   can no longer call onlyOwner functions. Ensure the Safe is fully operational
 *   before executing.
 */
contract TransferAgentIdentityOwnership is Script {
    /// @notice TAGITAgentIdentity contract on OP Sepolia
    address constant AGENT_IDENTITY = 0xA7f34FD595eBc397Fe04DcE012dbcf0fbbD2A78D;

    /// @notice TAGITAgentReputation contract on OP Sepolia
    address constant AGENT_REPUTATION = 0x57CCa1974DFE29593FBD24fdAEE1cD614Bfd6E4a;

    /// @notice TAGITAgentValidation contract on OP Sepolia
    address constant AGENT_VALIDATION = 0x9806919185F98Bd07a64F7BC7F264e91939e86b7;

    /**
     * @notice Transfer ownership of all 3 agent contracts to the Safe multi-sig
     * @dev Reads SAFE_ADDRESS from environment. Verifies current ownership before
     *      and after each transfer. Reverts if any verification fails.
     */
    function run() external {
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // ============================================
        // PRE-TRANSFER VERIFICATION
        // ============================================
        require(safeAddress != address(0), "TransferOwnership: SAFE_ADDRESS is zero");
        require(safeAddress != deployer, "TransferOwnership: SAFE_ADDRESS is deployer (no-op)");

        console.log("=== Agent Identity Ownership Transfer ===");
        console.log("Safe Address:", safeAddress);
        console.log("Deployer:", deployer);
        console.log("");

        // Verify current ownership
        _verifyCurrentOwner(AGENT_IDENTITY, deployer, "TAGITAgentIdentity");
        _verifyCurrentOwner(AGENT_REPUTATION, deployer, "TAGITAgentReputation");
        _verifyCurrentOwner(AGENT_VALIDATION, deployer, "TAGITAgentValidation");

        // ============================================
        // TRANSFER OWNERSHIP
        // ============================================
        vm.startBroadcast(deployerKey);

        Ownable(AGENT_IDENTITY).transferOwnership(safeAddress);
        console.log("[OK] TAGITAgentIdentity ownership transferred");

        Ownable(AGENT_REPUTATION).transferOwnership(safeAddress);
        console.log("[OK] TAGITAgentReputation ownership transferred");

        Ownable(AGENT_VALIDATION).transferOwnership(safeAddress);
        console.log("[OK] TAGITAgentValidation ownership transferred");

        vm.stopBroadcast();

        // ============================================
        // POST-TRANSFER VERIFICATION
        // ============================================
        _verifyNewOwner(AGENT_IDENTITY, safeAddress, "TAGITAgentIdentity");
        _verifyNewOwner(AGENT_REPUTATION, safeAddress, "TAGITAgentReputation");
        _verifyNewOwner(AGENT_VALIDATION, safeAddress, "TAGITAgentValidation");

        console.log("");
        console.log("=== All transfers complete and verified ===");
        console.log("Old owner (deployer) can no longer call onlyOwner functions.");
        console.log("All privileged operations now require 3-of-5 Safe signatures.");
    }

    /**
     * @notice Verify that the deployer is the current owner of the contract
     * @param contractAddr Address of the Ownable contract
     * @param expectedOwner Expected current owner
     * @param name Human-readable contract name for logging
     */
    function _verifyCurrentOwner(address contractAddr, address expectedOwner, string memory name) internal view {
        address currentOwner = Ownable(contractAddr).owner();
        if (currentOwner != expectedOwner) {
            console.log("ERROR:", name, "owner mismatch");
            console.log("  Expected:", expectedOwner);
            console.log("  Actual:", currentOwner);
            revert("TransferOwnership: deployer is not current owner");
        }
        console.log("[OK]", name, "current owner verified:", currentOwner);
    }

    /**
     * @notice Verify that ownership was successfully transferred
     * @param contractAddr Address of the Ownable contract
     * @param expectedOwner Expected new owner (Safe address)
     * @param name Human-readable contract name for logging
     */
    function _verifyNewOwner(address contractAddr, address expectedOwner, string memory name) internal view {
        address newOwner = Ownable(contractAddr).owner();
        if (newOwner != expectedOwner) {
            console.log("ERROR:", name, "transfer verification failed");
            console.log("  Expected:", expectedOwner);
            console.log("  Actual:", newOwner);
            revert("TransferOwnership: post-transfer verification failed");
        }
        console.log("[OK]", name, "new owner verified:", newOwner);
    }
}
