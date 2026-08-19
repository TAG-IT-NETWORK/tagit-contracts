#!/usr/bin/env bash
# =============================================================================
# check-capabilities.sh — READ-ONLY capability audit against TAGITAccess
# =============================================================================
# Usage: ./check-capabilities.sh <address> [rpc-url]
#
# Checks whether <address> holds the MINTER, BINDER, and RECYCLER capabilities
# on the Base Sepolia TAGITAccess controller. Prints one PASS/FAIL line per
# capability and exits non-zero if any capability is missing.
#
# Capability derivation (verified against src/core/TAGITCore.sol lines 71-79):
#   bytes32 public constant MINTER_CAPABILITY   = keccak256("MINTER");
#   bytes32 public constant BINDER_CAPABILITY   = keccak256("BINDER");
#   bytes32 public constant RECYCLER_CAPABILITY = keccak256("RECYCLER");
# All three derive as plain keccak256 of the bare capability name — no prefix,
# no ABI encoding. TAGITAccess.hasCapability takes the id as uint256
# (src/access/TAGITAccess.sol line 130), so the bytes32 hash is passed
# verbatim as the uint256 argument.
#
# READ-ONLY: this script performs only `cast keccak` and `cast call`.
# It contains no state-changing operations.
# =============================================================================
set -euo pipefail

TAGIT_ACCESS="0xb56A1D91995C212342FaA843468F03521340A1D6"
DEFAULT_RPC="https://sepolia.base.org"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <address> [rpc-url]" >&2
    echo "  Default RPC: ${DEFAULT_RPC}" >&2
    exit 2
fi

ADDRESS="$1"
RPC_URL="${2:-$DEFAULT_RPC}"

if ! [[ "$ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: '$ADDRESS' is not a valid 20-byte hex address" >&2
    exit 2
fi

echo "TAGITAccess: ${TAGIT_ACCESS}"
echo "Account:     ${ADDRESS}"
echo "RPC:         ${RPC_URL}"
echo "---"

FAILURES=0

for CAP_NAME in MINTER BINDER RECYCLER; do
    # keccak256 of the bare capability name, per TAGITCore.sol constants
    CAP_ID="$(cast keccak "$CAP_NAME")"
    RESULT="$(cast call "$TAGIT_ACCESS" \
        'hasCapability(address,uint256)(bool)' \
        "$ADDRESS" "$CAP_ID" \
        --rpc-url "$RPC_URL")"
    if [[ "$RESULT" == "true" ]]; then
        echo "PASS  ${CAP_NAME}  (id ${CAP_ID})"
    else
        echo "FAIL  ${CAP_NAME}  (id ${CAP_ID}) — hasCapability returned: ${RESULT}"
        FAILURES=$((FAILURES + 1))
    fi
done

echo "---"
if [[ $FAILURES -gt 0 ]]; then
    echo "RESULT: ${FAILURES} capability check(s) FAILED for ${ADDRESS}"
    exit 1
fi
echo "RESULT: all capability checks passed for ${ADDRESS}"
