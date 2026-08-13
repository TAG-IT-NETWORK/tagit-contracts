#!/usr/bin/env bash
# =============================================================================
# timelock-set-uris.sh — schedule + execute setBaseURI / setRedactedURI on
# TAGITCore via TimelockController (Base Sepolia)
# =============================================================================
#
# ############################################################################
# ##  DO NOT RUN before the META-T16 gateway cutover is LIVE.               ##
# ##  The PREFLIGHT below will refuse anyway (it requires                   ##
# ##  https://api.tagit.network/v1/meta/5 to return HTTP 200 JSON), but do  ##
# ##  not bypass it. Also ensure Timelock event monitoring is in place      ##
# ##  (REQ-S-17) before scheduling any Timelock operation.                  ##
# ############################################################################
#
# What it does (two ops, each scheduled then executed after the 60s delay):
#   1. TAGITCore.setBaseURI("https://api.tagit.network/v1/meta/")
#   2. TAGITCore.setRedactedURI("https://media.tagit.network/static/redacted-v1.json")
#
# Timelock signatures (verified against
# lib/openzeppelin-contracts/contracts/governance/TimelockController.sol):
#   schedule(address target, uint256 value, bytes data, bytes32 predecessor,
#            bytes32 salt, uint256 delay)                       [line 266]
#   execute(address target, uint256 value, bytes payload, bytes32 predecessor,
#           bytes32 salt)                                        [line 358]
#
# Auth: export TIMELOCK_SENDER_PK with the proposer/executor key. The key is
# passed to cast via --private-key and is NEVER echoed by this script.
# Alternatively use a cast keystore wallet (instructions printed if unset).
# =============================================================================
set -euo pipefail

TAGIT_CORE_PROXY="0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D"
TIMELOCK="0xfdA2478dB73064eF770f4e5E5b97BC83801126e1"
RPC_URL="${RPC_URL:-https://sepolia.base.org}"

BASE_URI="https://api.tagit.network/v1/meta/"
REDACTED_URI="https://media.tagit.network/static/redacted-v1.json"

PREDECESSOR="0x0000000000000000000000000000000000000000000000000000000000000000"
DELAY=60
CHECK_TOKEN_ID=5
PREFLIGHT_URL="https://api.tagit.network/v1/meta/${CHECK_TOKEN_ID}"

# ---------------------------------------------------------------------------
# Auth guard — never echo the key
# ---------------------------------------------------------------------------
if [[ -z "${TIMELOCK_SENDER_PK:-}" ]]; then
    cat >&2 <<'EOF'
ERROR: TIMELOCK_SENDER_PK is not set.

Option A (env var, key never echoed):
    export TIMELOCK_SENDER_PK=<proposer/executor private key>
    ./timelock-set-uris.sh

Option B (cast keystore wallet, recommended):
    cast wallet import timelock-sender --interactive
    then edit this script's SEND() helper to use:
        cast send --account timelock-sender ...
    instead of --private-key.
EOF
    exit 2
fi

send_tx() {
    # All args are cast send args after the auth flags; key is never printed.
    cast send --rpc-url "$RPC_URL" --private-key "$TIMELOCK_SENDER_PK" "$@"
}

# ---------------------------------------------------------------------------
# PREFLIGHT (mandatory): gateway must be live and serving JSON metadata
# ---------------------------------------------------------------------------
echo "PREFLIGHT: fetching ${PREFLIGHT_URL} ..."
if ! BODY="$(curl -fsS "$PREFLIGHT_URL")"; then
    echo "PREFLIGHT FAILED: ${PREFLIGHT_URL} did not return HTTP 200." >&2
    echo "The META-T16 gateway cutover is not live. Aborting — no transactions sent." >&2
    exit 1
fi

if ! META_NAME="$(printf '%s' "$BODY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["name"])' 2>/dev/null)"; then
    echo "PREFLIGHT FAILED: response is not JSON with a 'name' field. Aborting — no transactions sent." >&2
    echo "Raw response (first 300 chars): ${BODY:0:300}" >&2
    exit 1
fi

echo "PREFLIGHT OK: token ${CHECK_TOKEN_ID} metadata name = '${META_NAME}'"
echo "  (operator: eyeball that name above looks correct before proceeding)"
echo "---"

# ---------------------------------------------------------------------------
# Schedule + execute each op through the Timelock
# ---------------------------------------------------------------------------
declare -a SUMMARY=()

run_timelock_op() {
    local OP_NAME="$1" CALLDATA="$2"
    local SALT SCHEDULE_TX EXECUTE_TX

    # Deterministic per-op salt derived from the op name
    SALT="$(cast keccak "TAGIT-META-T19:${OP_NAME}")"

    echo "[${OP_NAME}] scheduling (salt ${SALT}, delay ${DELAY}s) ..."
    SCHEDULE_TX="$(send_tx "$TIMELOCK" \
        'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \
        "$TAGIT_CORE_PROXY" 0 "$CALLDATA" "$PREDECESSOR" "$SALT" "$DELAY" \
        --json | jq -r '.transactionHash')"
    echo "[${OP_NAME}] scheduled: ${SCHEDULE_TX}"

    echo "[${OP_NAME}] waiting $((DELAY + 5))s for timelock delay ..."
    sleep $((DELAY + 5))

    echo "[${OP_NAME}] executing ..."
    EXECUTE_TX="$(send_tx "$TIMELOCK" \
        'execute(address,uint256,bytes,bytes32,bytes32)' \
        "$TAGIT_CORE_PROXY" 0 "$CALLDATA" "$PREDECESSOR" "$SALT" \
        --json | jq -r '.transactionHash')"
    echo "[${OP_NAME}] executed: ${EXECUTE_TX}"

    SUMMARY+=("${OP_NAME}: schedule=${SCHEDULE_TX} execute=${EXECUTE_TX}")
}

CALLDATA_BASE_URI="$(cast calldata 'setBaseURI(string)' "$BASE_URI")"
CALLDATA_REDACTED="$(cast calldata 'setRedactedURI(string)' "$REDACTED_URI")"

run_timelock_op "setBaseURI" "$CALLDATA_BASE_URI"
run_timelock_op "setRedactedURI" "$CALLDATA_REDACTED"

# ---------------------------------------------------------------------------
# POST-CHECK (read-only)
# ---------------------------------------------------------------------------
echo "---"
echo "POST-CHECK: tokenURI(${CHECK_TOKEN_ID}) from the default (unauthorized) sender"
TOKEN_URI="$(cast call "$TAGIT_CORE_PROXY" \
    'tokenURI(uint256)(string)' "$CHECK_TOKEN_ID" \
    --rpc-url "$RPC_URL")"
echo "  returned:  ${TOKEN_URI}"
echo "  expected:  \"${REDACTED_URI}\"  (redacted URL — caller is unauthorized)"
if [[ "$TOKEN_URI" == "\"${REDACTED_URI}\"" || "$TOKEN_URI" == "$REDACTED_URI" ]]; then
    echo "  POST-CHECK PASS: unauthorized caller receives the redacted URI."
else
    echo "  POST-CHECK WARNING: returned value does not match the redacted URI." >&2
fi
echo
echo "NOTE: an authorized-context tokenURI read is not possible read-only"
echo "(authorization is msg.sender-based). For manual verification, the full"
echo "URI an authorized caller (owner/VIEWER/AUDITOR) should see is:"
echo "  ${BASE_URI}${CHECK_TOKEN_ID}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "---"
echo "SUMMARY (tx hashes):"
for LINE in "${SUMMARY[@]}"; do
    echo "  ${LINE}"
done
echo "Done."
