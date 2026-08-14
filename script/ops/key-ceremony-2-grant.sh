#!/usr/bin/env bash
# =============================================================================
# key-ceremony-2-grant.sh — T01 key ceremony, step 2 of 3: grant KEY_B
# =============================================================================
# Usage:
#   ./key-ceremony-2-grant.sh <KEY_B_ADDRESS> [KEY_A_ADDRESS] [--flip-oracle]
#
# Grants the ceremony capabilities to KEY_B on the LIVE Base Sepolia
# CapabilityBadge, and (only with --flip-oracle) flips TAGITCore.trustedOracle
# to KEY_B through the TimelockController.
#
# Contract facts (live-verified 2026-08-14 via read-only cast calls):
#   CapabilityBadge.grantCapability(address,uint256) onlyOwner   [selector 0x6839f140]
#     src/access/CapabilityBadge.sol line 69
#   CapabilityBadge.owner() == 0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D
#     (the OLD shared hot key — grants must be SENT BY the old key)
#   TAGITCore.setTrustedOracle(address) onlyOwner                [selector 0xb22bd298]
#     src/core/TAGITCore.sol line 1544
#   TAGITCore.owner() == TimelockController (minDelay 60s) — so the oracle
#     flip must be schedule()d then execute()d through the Timelock, exactly
#     like script/ops/timelock-set-uris.sh:
#       schedule(address,uint256,bytes,bytes32,bytes32,uint256)
#       execute(address,uint256,bytes,bytes32,bytes32)
#   Capability ids are uint256(keccak256("<NAME>")) — TAGITCore.sol lines 71-79;
#     passed verbatim, same derivation as check-capabilities.sh.
#
# Capabilities granted: MINTER, BINDER, RECYCLER, plus CLAIMER when the old
# key holds it (it does, live-verified — checked again at runtime).
# Every action is IDEMPOTENT: read-only pre-checks skip anything already true.
#
# Auth (never echoed by this script):
#   Option A: export CEREMONY_SENDER_PK=<private key>
#   Option B: export CEREMONY_SENDER_KEYCHAIN_SERVICE=<keychain service name>
#             (optional: CEREMONY_SENDER_KEYCHAIN_ACCOUNT=<account>)
#             The key is read from the macOS Keychain via
#             `security find-generic-password ... -w` straight into a variable.
#   The sender must be the CapabilityBadge owner (currently the OLD key) and,
#   for --flip-oracle, hold PROPOSER + EXECUTOR on the Timelock (the old key
#   holds both, live-verified).
# =============================================================================
set -euo pipefail

# ############################################################################
# ##                            !! WARNING !!                               ##
# ##                                                                        ##
# ##  Run --flip-oracle ONLY AFTER the Vercel/services SIGNER_PRIVATE_KEY   ##
# ##  has been rotated to KEY_B. The instant trustedOracle flips, bind      ##
# ##  signatures from the old services key stop verifying and BINDING       ##
# ##  BREAKS.                                                               ##
# ##                                                                        ##
# ##  Safe order:                                                           ##
# ##    1. this script WITHOUT --flip-oracle  (grants only — harmless)      ##
# ##    2. rotate services SIGNER_PRIVATE_KEY -> KEY_B (Vercel + AWS SM)    ##
# ##    3. this script again WITH --flip-oracle                             ##
# ############################################################################

TAGIT_CORE_PROXY="0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D"
TAGIT_ACCESS="0xb56A1D91995C212342FaA843468F03521340A1D6"
CAPABILITY_BADGE="0xb05d22706B08A3F6409601de520cf7A6dbCB573d"
TIMELOCK="0xfdA2478dB73064eF770f4e5E5b97BC83801126e1"
OLD_KEY="0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D"
RPC_URL="${RPC_URL:-https://sepolia.base.org}"
PREDECESSOR="0x0000000000000000000000000000000000000000000000000000000000000000"
DELAY=60

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
    echo "Usage: $0 <KEY_B_ADDRESS> [KEY_A_ADDRESS] [--flip-oracle]" >&2
    echo "  KEY_B_ADDRESS  new services oracle/signer (receives capabilities)" >&2
    echo "  KEY_A_ADDRESS  new contracts deployer (informational, for the summary)" >&2
    echo "  --flip-oracle  ALSO flip TAGITCore.trustedOracle -> KEY_B via Timelock" >&2
    echo "                 (separate opt-in step — read the WARNING in this script)" >&2
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
KEY_B_ADDRESS=""
KEY_A_ADDRESS=""
FLIP_ORACLE=0
for ARG in "$@"; do
    case "$ARG" in
        --flip-oracle) FLIP_ORACLE=1 ;;
        -h|--help) usage; exit 0 ;;
        0x*)
            if [[ -z "$KEY_B_ADDRESS" ]]; then KEY_B_ADDRESS="$ARG"
            elif [[ -z "$KEY_A_ADDRESS" ]]; then KEY_A_ADDRESS="$ARG"
            else echo "ERROR: too many addresses." >&2; usage; exit 2; fi
            ;;
        *) echo "ERROR: unknown argument '$ARG'." >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$KEY_B_ADDRESS" ]]; then usage; exit 2; fi
if ! [[ "$KEY_B_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: '$KEY_B_ADDRESS' is not a valid 20-byte hex address." >&2
    exit 2
fi
if [[ -n "$KEY_A_ADDRESS" ]] && ! [[ "$KEY_A_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: '$KEY_A_ADDRESS' is not a valid 20-byte hex address." >&2
    exit 2
fi
if [[ "$(lc "$KEY_B_ADDRESS")" == "$(lc "$OLD_KEY")" ]]; then
    echo "ERROR: KEY_B is the OLD shared hot key — the ceremony exists to retire it." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------
for TOOL in cast jq; do
    if ! command -v "$TOOL" >/dev/null 2>&1; then
        echo "ERROR: required tool '$TOOL' not found in PATH." >&2
        exit 2
    fi
done

# ---------------------------------------------------------------------------
# Auth — key is never echoed. Lands only in a shell variable (and cast argv,
# same accepted tradeoff as timelock-set-uris.sh).
# ---------------------------------------------------------------------------
SENDER_PK=""
if [[ -n "${CEREMONY_SENDER_PK:-}" ]]; then
    SENDER_PK="$CEREMONY_SENDER_PK"
elif [[ -n "${CEREMONY_SENDER_KEYCHAIN_SERVICE:-}" ]]; then
    if ! command -v security >/dev/null 2>&1; then
        echo "ERROR: 'security' (macOS Keychain CLI) not found." >&2
        exit 2
    fi
    KC_ARGS=(-s "$CEREMONY_SENDER_KEYCHAIN_SERVICE")
    if [[ -n "${CEREMONY_SENDER_KEYCHAIN_ACCOUNT:-}" ]]; then
        KC_ARGS+=(-a "$CEREMONY_SENDER_KEYCHAIN_ACCOUNT")
    fi
    if ! SENDER_PK="$(security find-generic-password "${KC_ARGS[@]}" -w)"; then
        echo "ERROR: could not read Keychain item '${CEREMONY_SENDER_KEYCHAIN_SERVICE}'." >&2
        exit 2
    fi
else
    cat >&2 <<'EOF'
ERROR: no sender key configured. Provide ONE of:

  Option A (env var):
      export CEREMONY_SENDER_PK=<private key of the CapabilityBadge owner>

  Option B (macOS Keychain — key read directly, never echoed):
      export CEREMONY_SENDER_KEYCHAIN_SERVICE=<service name of the item>
      export CEREMONY_SENDER_KEYCHAIN_ACCOUNT=<account>   # optional

The sender must be the current CapabilityBadge owner (today: the OLD shared
hot key 0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D).
EOF
    exit 2
fi

SENDER_ADDR="$(cast wallet address --private-key "$SENDER_PK")"
echo "Sender:          ${SENDER_ADDR}"
echo "KEY_B (grantee): ${KEY_B_ADDRESS}"
[[ -n "$KEY_A_ADDRESS" ]] && echo "KEY_A (info):    ${KEY_A_ADDRESS}"
echo "RPC:             ${RPC_URL}"
echo "---"

send_tx() {
    # All args are cast send args after the auth flags; key is never printed.
    cast send --rpc-url "$RPC_URL" --private-key "$SENDER_PK" "$@"
}

declare -a SUMMARY=()

# ---------------------------------------------------------------------------
# Pre-check: sender must be the CapabilityBadge owner (grant is onlyOwner)
# ---------------------------------------------------------------------------
BADGE_OWNER="$(cast call "$CAPABILITY_BADGE" 'owner()(address)' --rpc-url "$RPC_URL")"
if [[ "$(lc "$BADGE_OWNER")" != "$(lc "$SENDER_ADDR")" ]]; then
    echo "ERROR: sender ${SENDER_ADDR} is not the CapabilityBadge owner." >&2
    echo "  CapabilityBadge ${CAPABILITY_BADGE} owner is ${BADGE_OWNER}." >&2
    echo "  grantCapability() is onlyOwner — no transactions sent." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the grant set: MINTER/BINDER/RECYCLER always; CLAIMER only if the
# old key holds it (the constant exists — TAGITCore.sol line 74 — and the
# old key holds it, live-verified; re-checked here read-only).
# ---------------------------------------------------------------------------
has_cap() {
    local WHO="$1" CAP_ID="$2"
    cast call "$TAGIT_ACCESS" 'hasCapability(address,uint256)(bool)' \
        "$WHO" "$CAP_ID" --rpc-url "$RPC_URL"
}

GRANT_SET=(MINTER BINDER RECYCLER)
CLAIMER_ID="$(cast keccak "CLAIMER")"
if [[ "$(has_cap "$OLD_KEY" "$CLAIMER_ID")" == "true" ]]; then
    GRANT_SET+=(CLAIMER)
else
    echo "NOTE: old key does not hold CLAIMER — not granting it."
    SUMMARY+=("CLAIMER: not granted (old key does not hold it)")
fi

# ---------------------------------------------------------------------------
# Grants (idempotent)
# ---------------------------------------------------------------------------
for CAP_NAME in "${GRANT_SET[@]}"; do
    CAP_ID="$(cast keccak "$CAP_NAME")"
    if [[ "$(has_cap "$KEY_B_ADDRESS" "$CAP_ID")" == "true" ]]; then
        echo "[${CAP_NAME}] SKIP — KEY_B already holds it."
        SUMMARY+=("${CAP_NAME}: already granted (skipped)")
        continue
    fi
    echo "[${CAP_NAME}] granting to KEY_B (id ${CAP_ID}) ..."
    TX="$(send_tx "$CAPABILITY_BADGE" \
        'grantCapability(address,uint256)' \
        "$KEY_B_ADDRESS" "$CAP_ID" \
        --json | jq -r '.transactionHash')"
    if [[ "$(has_cap "$KEY_B_ADDRESS" "$CAP_ID")" != "true" ]]; then
        echo "ERROR: post-check failed — KEY_B still lacks ${CAP_NAME} after ${TX}." >&2
        exit 1
    fi
    echo "[${CAP_NAME}] granted: ${TX}"
    SUMMARY+=("${CAP_NAME}: GRANTED tx=${TX}")
done

# ---------------------------------------------------------------------------
# Oracle flip (opt-in via --flip-oracle) — Timelock schedule -> wait -> execute
# ---------------------------------------------------------------------------
CURRENT_ORACLE="$(cast call "$TAGIT_CORE_PROXY" 'trustedOracle()(address)' --rpc-url "$RPC_URL")"
if [[ "$FLIP_ORACLE" -eq 1 ]]; then
    if [[ "$(lc "$CURRENT_ORACLE")" == "$(lc "$KEY_B_ADDRESS")" ]]; then
        echo "[trustedOracle] SKIP — already ${KEY_B_ADDRESS}."
        SUMMARY+=("trustedOracle: already KEY_B (skipped)")
    else
        # Sender needs PROPOSER (schedule) + EXECUTOR (execute) on the Timelock.
        PROPOSER_ROLE="$(cast keccak "PROPOSER_ROLE")"
        EXECUTOR_ROLE="$(cast keccak "EXECUTOR_ROLE")"
        for ROLE_PAIR in "PROPOSER:${PROPOSER_ROLE}" "EXECUTOR:${EXECUTOR_ROLE}"; do
            ROLE_NAME="${ROLE_PAIR%%:*}"; ROLE_HASH="${ROLE_PAIR#*:}"
            HAS_ROLE="$(cast call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' \
                "$ROLE_HASH" "$SENDER_ADDR" --rpc-url "$RPC_URL")"
            if [[ "$HAS_ROLE" != "true" ]]; then
                echo "ERROR: sender ${SENDER_ADDR} lacks Timelock ${ROLE_NAME} role." >&2
                echo "  Cannot schedule/execute setTrustedOracle. Grants above are done." >&2
                exit 1
            fi
        done

        CALLDATA="$(cast calldata 'setTrustedOracle(address)' "$KEY_B_ADDRESS")"
        # Deterministic salt; bump SALT_NONCE to re-run an op id already consumed.
        SALT="$(cast keccak "TAGIT-T01:setTrustedOracle:${KEY_B_ADDRESS}:${SALT_NONCE:-0}")"
        OP_ID="$(cast call "$TIMELOCK" \
            'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' \
            "$TAGIT_CORE_PROXY" 0 "$CALLDATA" "$PREDECESSOR" "$SALT" \
            --rpc-url "$RPC_URL")"

        NEED_SCHEDULE=1
        if [[ "$(cast call "$TIMELOCK" 'isOperationDone(bytes32)(bool)' "$OP_ID" --rpc-url "$RPC_URL")" == "true" ]]; then
            echo "ERROR: Timelock op ${OP_ID} already executed but trustedOracle is" >&2
            echo "  ${CURRENT_ORACLE} — the oracle changed since. Re-run with SALT_NONCE=1." >&2
            exit 1
        elif [[ "$(cast call "$TIMELOCK" 'isOperationPending(bytes32)(bool)' "$OP_ID" --rpc-url "$RPC_URL")" == "true" ]]; then
            echo "[trustedOracle] already scheduled (op ${OP_ID}) — skipping schedule."
            NEED_SCHEDULE=0
        fi

        if [[ "$NEED_SCHEDULE" -eq 1 ]]; then
            echo "[trustedOracle] scheduling setTrustedOracle(${KEY_B_ADDRESS}) (delay ${DELAY}s) ..."
            SCHEDULE_TX="$(send_tx "$TIMELOCK" \
                'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \
                "$TAGIT_CORE_PROXY" 0 "$CALLDATA" "$PREDECESSOR" "$SALT" "$DELAY" \
                --json | jq -r '.transactionHash')"
            echo "[trustedOracle] scheduled: ${SCHEDULE_TX}"
            SUMMARY+=("trustedOracle: schedule tx=${SCHEDULE_TX}")
        fi

        if [[ "$(cast call "$TIMELOCK" 'isOperationReady(bytes32)(bool)' "$OP_ID" --rpc-url "$RPC_URL")" != "true" ]]; then
            echo "[trustedOracle] waiting $((DELAY + 5))s for timelock delay ..."
            sleep $((DELAY + 5))
        fi

        echo "[trustedOracle] executing ..."
        EXECUTE_TX="$(send_tx "$TIMELOCK" \
            'execute(address,uint256,bytes,bytes32,bytes32)' \
            "$TAGIT_CORE_PROXY" 0 "$CALLDATA" "$PREDECESSOR" "$SALT" \
            --json | jq -r '.transactionHash')"
        echo "[trustedOracle] executed: ${EXECUTE_TX}"
        SUMMARY+=("trustedOracle: execute tx=${EXECUTE_TX}")

        CURRENT_ORACLE="$(cast call "$TAGIT_CORE_PROXY" 'trustedOracle()(address)' --rpc-url "$RPC_URL")"
        if [[ "$(lc "$CURRENT_ORACLE")" != "$(lc "$KEY_B_ADDRESS")" ]]; then
            echo "ERROR: post-check failed — trustedOracle is ${CURRENT_ORACLE}, not KEY_B." >&2
            exit 1
        fi
        echo "[trustedOracle] POST-CHECK PASS: trustedOracle == KEY_B."
    fi
else
    echo "[trustedOracle] NOT flipped (no --flip-oracle). Current: ${CURRENT_ORACLE}"
    echo "  Flip it ONLY after rotating services SIGNER_PRIVATE_KEY to KEY_B:"
    echo "    $0 ${KEY_B_ADDRESS} --flip-oracle"
    SUMMARY+=("trustedOracle: UNCHANGED (${CURRENT_ORACLE}) — flip deferred")
fi

# ---------------------------------------------------------------------------
# Final audit: independent read-only capability check for KEY_B
# ---------------------------------------------------------------------------
echo "---"
echo "Running check-capabilities.sh for KEY_B ..."
"$SCRIPT_DIR/check-capabilities.sh" "$KEY_B_ADDRESS" "$RPC_URL"

echo "---"
echo "CHECKLIST — what changed this run:"
for LINE in "${SUMMARY[@]}"; do
    echo "  - ${LINE}"
done
echo "Done."
