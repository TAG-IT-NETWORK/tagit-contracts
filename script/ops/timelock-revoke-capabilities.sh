#!/usr/bin/env bash
# =============================================================================
# timelock-revoke-capabilities.sh — revoke capabilities from an address through
# the Timelock (Base Sepolia 84532)
# =============================================================================
# Usage:
#   bash timelock-revoke-capabilities.sh <ACCOUNT> <CAP> [<CAP> ...]            # DRY RUN
#   bash timelock-revoke-capabilities.sh <ACCOUNT> <CAP> [<CAP> ...] --send
#   SALT=0x... bash timelock-revoke-capabilities.sh <ACCOUNT> <CAP> ... --execute-only
#
#   <CAP> is a capability name: MINTER BINDER ACTIVATOR CLAIMER FLAGGER
#   RESOLVER RECYCLER VIEWER AUDITOR.
#
# WITHOUT --send NOTHING IS SENT AND NO KEY IS READ. The dry run only reads the
# chain: it checks every condition below, simulates the revoke as the Timelock
# would make it (eth_call), and prints exactly what --send would do.
#
# Why through the Timelock: CapabilityBadge is Ownable and its owner is the
# Timelock, so batchRevokeCapabilities() can only be reached by scheduling it
# there and executing it after the delay. One operation, two transactions:
#   1. Timelock.schedule(badge, 0, batchRevokeCapabilities(account, ids), 0x0, salt, delay)
#   2. wait for the delay (getMinDelay, 60 s today)
#   3. Timelock.execute(badge, 0, same data, 0x0, same salt)
#
# Contract facts (verified against the sources in this repo):
#   CapabilityBadge.batchRevokeCapabilities(address,uint256[]) onlyOwner
#     src/access/CapabilityBadge.sol — burns 1 ERC-1155 unit per id; reverts if
#     the account does not hold one of them (hence the pre-checks: only held
#     capabilities are put in the operation).
#   Capability ids = keccak256(bare name), TAGITCore.sol lines 71-79.
#   TimelockController (OpenZeppelin): schedule / execute / hashOperation /
#     isOperationReady / getMinDelay / hasRole.
#
# Safety rules — the script stops, sending nothing, when one fails:
#   - the RPC must be chain 84532 (these addresses exist nowhere else)
#   - CapabilityBadge.owner() must be the Timelock
#   - <ACCOUNT> must not be TAGITCore.trustedOracle(): that address is the
#     services signer, and revoking from it stops minting and binding in
#     production. Override: ALLOW_SIGNER=1.
#   - coverage: a capability is revoked only while the services signer
#     (trustedOracle) holds the same capability, so the system never loses its
#     working holder by accident. Override: REVOKE_UNCOVERED=1.
#   - the simulated revoke must succeed
#   - with --send: the sender must hold PROPOSER_ROLE, and EXECUTOR_ROLE must
#     be the sender's or open to everyone
#
# Auth for --send / --execute-only (the key is never echoed; same variables as
# the key-ceremony scripts):
#   CEREMONY_SENDER_PK=<private key>                      or
#   CEREMONY_SENDER_KEYCHAIN_SERVICE=<Keychain item> [CEREMONY_SENDER_KEYCHAIN_ACCOUNT=<account>]
#
# Rehearsal on a local fork (no key at all): start
#   anvil --fork-url https://sepolia.base.org --port 8546 --block-time 2
# impersonate the proposer there (cast rpc anvil_impersonateAccount <addr>) and
# run with RPC_URL=http://127.0.0.1:8546 TIMELOCK_SENDER_UNLOCKED=<addr> --send.
# TIMELOCK_SENDER_UNLOCKED is refused for any RPC that is not on this machine.
#
# If the run stops between schedule and execute (closed terminal, network):
# the operation stays scheduled. Finish it with the SALT the run printed:
#   SALT=0x... bash timelock-revoke-capabilities.sh <same arguments> --execute-only
# =============================================================================
set -euo pipefail

TAGIT_CORE_PROXY="0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D"
TAGIT_ACCESS="0xb56A1D91995C212342FaA843468F03521340A1D6"
CAPABILITY_BADGE="0xb05d22706B08A3F6409601de520cf7A6dbCB573d"
TIMELOCK="0xfdA2478dB73064eF770f4e5E5b97BC83801126e1"
EXPECTED_CHAIN_ID="84532"
RPC_URL="${RPC_URL:-https://sepolia.base.org}"

PREDECESSOR="0x0000000000000000000000000000000000000000000000000000000000000000"
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"

# Full known capability set — TAGITCore.sol lines 71-79.
ALL_CAPS=(MINTER BINDER ACTIVATOR CLAIMER FLAGGER RESOLVER RECYCLER VIEWER AUDITOR)

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
    cat >&2 <<EOF
Usage: bash $0 <ACCOUNT> <CAP> [<CAP> ...] [--send | --execute-only]
  Without a flag: DRY RUN. Reads only, sends nothing, reads no key.
  --send          schedule through the Timelock, wait the delay, execute, verify
  --execute-only  execute an operation that is already scheduled (needs SALT=0x...)
  Capabilities:   ${ALL_CAPS[*]}
EOF
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
MODE="dry-run"
ACCOUNT=""
declare -a CAP_NAMES=()
for ARG in "$@"; do
    case "$ARG" in
        --send) MODE="send" ;;
        --execute-only) MODE="execute-only" ;;
        -h|--help) usage; exit 0 ;;
        0x*)
            if [[ -n "$ACCOUNT" ]]; then
                echo "ERROR: more than one address given ('$ACCOUNT' and '$ARG')." >&2
                usage; exit 2
            fi
            ACCOUNT="$ARG"
            ;;
        *)
            KNOWN=0
            for C in "${ALL_CAPS[@]}"; do
                if [[ "$C" == "$ARG" ]]; then KNOWN=1; fi
            done
            if [[ "$KNOWN" -ne 1 ]]; then
                echo "ERROR: '$ARG' is not a known capability or flag." >&2
                usage; exit 2
            fi
            for C in ${CAP_NAMES[@]+"${CAP_NAMES[@]}"}; do
                if [[ "$C" == "$ARG" ]]; then
                    echo "ERROR: capability '$ARG' given twice." >&2
                    exit 2
                fi
            done
            CAP_NAMES+=("$ARG")
            ;;
    esac
done

if [[ -z "$ACCOUNT" || "${#CAP_NAMES[@]}" -eq 0 ]]; then
    usage; exit 2
fi
if ! [[ "$ACCOUNT" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: '$ACCOUNT' is not a valid 20-byte hex address." >&2
    exit 2
fi
if [[ "$MODE" == "execute-only" && -z "${SALT:-}" ]]; then
    echo "ERROR: --execute-only needs the SALT of the scheduled operation (SALT=0x...)." >&2
    exit 2
fi
if [[ -n "${SALT:-}" ]] && ! [[ "$SALT" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "ERROR: SALT must be 32 bytes of hex (0x + 64 digits)." >&2
    exit 2
fi

for TOOL in cast jq; do
    if ! command -v "$TOOL" >/dev/null 2>&1; then
        echo "ERROR: required tool '$TOOL' not found in PATH." >&2
        exit 2
    fi
done

rd() {
    # read-only call: rd <address> <signature> [args...]
    local TO="$1" SIG="$2"
    shift 2
    cast call "$TO" "$SIG" "$@" --rpc-url "$RPC_URL"
}

has_cap() {
    rd "$TAGIT_ACCESS" 'hasCapability(address,uint256)(bool)' "$1" "$2"
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT — read-only. Everything here runs in every mode.
# ---------------------------------------------------------------------------
echo "Mode:        ${MODE}"
echo "Account:     ${ACCOUNT}"
echo "Revoke:      ${CAP_NAMES[*]}"
echo "RPC:         ${RPC_URL}"
echo "---"

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]]; then
    echo "STOP: the RPC is chain ${CHAIN_ID}, not ${EXPECTED_CHAIN_ID} (Base Sepolia). Nothing sent." >&2
    exit 1
fi
echo "OK  chain ${CHAIN_ID} (Base Sepolia)"

BADGE_OWNER="$(rd "$CAPABILITY_BADGE" 'owner()(address)')"
if [[ "$(lc "$BADGE_OWNER")" != "$(lc "$TIMELOCK")" ]]; then
    echo "STOP: CapabilityBadge owner is ${BADGE_OWNER}, not the Timelock ${TIMELOCK}. Nothing sent." >&2
    exit 1
fi
echo "OK  CapabilityBadge is owned by the Timelock"

SIGNER="$(rd "$TAGIT_CORE_PROXY" 'trustedOracle()(address)')"
if [[ "$(lc "$SIGNER")" == "$(lc "$ACCOUNT")" && "${ALLOW_SIGNER:-0}" != "1" ]]; then
    echo "STOP: ${ACCOUNT} is TAGITCore.trustedOracle — the services signer." >&2
    echo "  Revoking from it stops minting and binding in production." >&2
    echo "  If that is really intended, re-run with ALLOW_SIGNER=1. Nothing sent." >&2
    exit 1
fi
echo "OK  the account is not the services signer (${SIGNER})"

declare -a REVOKE_NAMES=()
declare -a REVOKE_IDS=()
UNCOVERED=0
for CAP_NAME in "${CAP_NAMES[@]}"; do
    CAP_ID="$(cast keccak "$CAP_NAME")"
    if [[ "$(has_cap "$ACCOUNT" "$CAP_ID")" != "true" ]]; then
        echo "--  ${CAP_NAME}: the account does not hold it (nothing to revoke)"
        continue
    fi
    if [[ "$(has_cap "$SIGNER" "$CAP_ID")" != "true" && "${REVOKE_UNCOVERED:-0}" != "1" ]]; then
        echo "!!  ${CAP_NAME}: held by the account, but the services signer does NOT hold it."
        echo "    Revoking could leave the system without a working holder of ${CAP_NAME}."
        echo "    Grant a replacement first, or re-run with REVOKE_UNCOVERED=1."
        UNCOVERED=$((UNCOVERED + 1))
        continue
    fi
    echo "OK  ${CAP_NAME}: held by the account, and the services signer holds it too"
    REVOKE_NAMES+=("$CAP_NAME")
    REVOKE_IDS+=("$CAP_ID")
done

if [[ "$UNCOVERED" -gt 0 ]]; then
    echo "STOP: ${UNCOVERED} capability/ies would be left uncovered (see above). Nothing sent." >&2
    exit 1
fi
if [[ "${#REVOKE_IDS[@]}" -eq 0 ]]; then
    echo "---"
    echo "Nothing to do: the account holds none of the named capabilities."
    exit 0
fi

IDS_LITERAL="[$(IFS=,; printf '%s' "${REVOKE_IDS[*]}")]"
DATA="$(cast calldata 'batchRevokeCapabilities(address,uint256[])' "$ACCOUNT" "$IDS_LITERAL")"

MIN_DELAY="$(rd "$TIMELOCK" 'getMinDelay()(uint256)' | awk '{print $1}')"
if ! [[ "$MIN_DELAY" =~ ^[0-9]+$ ]]; then
    echo "STOP: could not read the Timelock's delay (got '${MIN_DELAY}'). Nothing sent." >&2
    exit 1
fi

if [[ -z "${SALT:-}" ]]; then
    SALT="$(cast keccak "timelock-revoke-capabilities:$(lc "$ACCOUNT"):${IDS_LITERAL}:$(date +%s)")"
fi
OP_ID="$(rd "$TIMELOCK" 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' \
    "$CAPABILITY_BADGE" 0 "$DATA" "$PREDECESSOR" "$SALT")"

# The revoke itself, exactly as the Timelock will make it — as a read (eth_call).
if ! cast call "$CAPABILITY_BADGE" 'batchRevokeCapabilities(address,uint256[])' \
    "$ACCOUNT" "$IDS_LITERAL" --from "$TIMELOCK" --rpc-url "$RPC_URL" >/dev/null; then
    echo "STOP: the simulated revoke (called as the Timelock) reverted. Nothing sent." >&2
    exit 1
fi
echo "OK  simulated revoke of ${REVOKE_NAMES[*]} succeeds when called by the Timelock"

echo "---"
echo "Operation:"
echo "  target      ${CAPABILITY_BADGE} (CapabilityBadge)"
echo "  call        batchRevokeCapabilities(${ACCOUNT}, ${REVOKE_NAMES[*]})"
echo "  data        ${DATA}"
echo "  delay       ${MIN_DELAY} s"
echo "  salt        ${SALT}"
echo "  id          ${OP_ID}"

if [[ "$MODE" == "dry-run" ]]; then
    echo "---"
    echo "DRY RUN: nothing was sent and no key was read."
    echo "To do it for real, with the Timelock proposer's key in the Keychain:"
    echo "  CEREMONY_SENDER_KEYCHAIN_SERVICE=<item> CEREMONY_SENDER_KEYCHAIN_ACCOUNT=<account> \\"
    echo "    bash $0 ${ACCOUNT} ${CAP_NAMES[*]} --send"
    exit 0
fi

# ---------------------------------------------------------------------------
# Auth — key is never echoed. It lands only in a shell variable (and cast argv,
# the same accepted tradeoff as the other scripts here).
# ---------------------------------------------------------------------------
declare -a AUTH_ARGS=()
SENDER_ADDR=""
if [[ -n "${TIMELOCK_SENDER_UNLOCKED:-}" ]]; then
    case "$RPC_URL" in
        http://127.0.0.1:*|http://localhost:*) ;;
        *)
            echo "STOP: TIMELOCK_SENDER_UNLOCKED is for a local fork only (RPC on this machine). Nothing sent." >&2
            exit 2
            ;;
    esac
    if ! [[ "$TIMELOCK_SENDER_UNLOCKED" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "ERROR: TIMELOCK_SENDER_UNLOCKED is not an address." >&2
        exit 2
    fi
    SENDER_ADDR="$TIMELOCK_SENDER_UNLOCKED"
    AUTH_ARGS=(--unlocked --from "$SENDER_ADDR")
    echo "REHEARSAL on a local fork: sending as the unlocked account ${SENDER_ADDR}"
else
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

  Option A (macOS Keychain — key read directly, never echoed):
      export CEREMONY_SENDER_KEYCHAIN_SERVICE=<service name of the item>
      export CEREMONY_SENDER_KEYCHAIN_ACCOUNT=<account>   # optional

  Option B (env var):
      export CEREMONY_SENDER_PK=<private key of a Timelock proposer>

Nothing sent.
EOF
        exit 2
    fi
    SENDER_ADDR="$(cast wallet address --private-key "$SENDER_PK")"
    AUTH_ARGS=(--private-key "$SENDER_PK")
fi
echo "Sender:      ${SENDER_ADDR}"

send_tx() {
    # All args are cast send args after the auth flags; the key is never printed.
    cast send --rpc-url "$RPC_URL" "${AUTH_ARGS[@]}" "$@" --json | jq -r '.transactionHash'
}

PROPOSER_ROLE="$(cast keccak PROPOSER_ROLE)"
EXECUTOR_ROLE="$(cast keccak EXECUTOR_ROLE)"
has_role() {
    rd "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$1" "$2"
}
if [[ "$(has_role "$EXECUTOR_ROLE" "$SENDER_ADDR")" != "true" && "$(has_role "$EXECUTOR_ROLE" "$ZERO_ADDRESS")" != "true" ]]; then
    echo "STOP: sender ${SENDER_ADDR} may not execute on the Timelock (no EXECUTOR_ROLE). Nothing sent." >&2
    exit 1
fi
if [[ "$MODE" == "send" && "$(has_role "$PROPOSER_ROLE" "$SENDER_ADDR")" != "true" ]]; then
    echo "STOP: sender ${SENDER_ADDR} may not schedule on the Timelock (no PROPOSER_ROLE). Nothing sent." >&2
    exit 1
fi
echo "OK  the sender holds the Timelock roles this needs"
echo "---"

is_op() {
    # is_op <view name>: isOperation | isOperationPending | isOperationReady | isOperationDone
    rd "$TIMELOCK" "$1(bytes32)(bool)" "$OP_ID"
}

# ---------------------------------------------------------------------------
# 1. Schedule
# ---------------------------------------------------------------------------
if [[ "$MODE" == "send" ]]; then
    if [[ "$(is_op isOperation)" == "true" ]]; then
        echo "STOP: an operation with this id already exists on the Timelock." >&2
        echo "  Finish it with: SALT=${SALT} bash $0 ${ACCOUNT} ${CAP_NAMES[*]} --execute-only" >&2
        exit 1
    fi
    echo "[1/2] scheduling on the Timelock ..."
    SCHEDULE_TX="$(send_tx "$TIMELOCK" \
        'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \
        "$CAPABILITY_BADGE" 0 "$DATA" "$PREDECESSOR" "$SALT" "$MIN_DELAY")"
    echo "[1/2] scheduled: ${SCHEDULE_TX}"
    echo "      If this run stops now, finish with:"
    echo "      SALT=${SALT} bash $0 ${ACCOUNT} ${CAP_NAMES[*]} --execute-only"
else
    if [[ "$(is_op isOperationDone)" == "true" ]]; then
        echo "The operation ${OP_ID} was already executed. Nothing to do."
        exit 0
    fi
    if [[ "$(is_op isOperationPending)" != "true" ]]; then
        echo "STOP: no scheduled operation with this salt and these arguments (id ${OP_ID})." >&2
        exit 1
    fi
    echo "[1/2] already scheduled (id ${OP_ID})"
fi

# ---------------------------------------------------------------------------
# 2. Wait for the delay, then execute
# ---------------------------------------------------------------------------
WAITED=0
MAX_WAIT=$((MIN_DELAY + 180))
until [[ "$(is_op isOperationReady)" == "true" ]]; do
    if [[ "$WAITED" -ge "$MAX_WAIT" ]]; then
        echo "STOP: the operation is still not ready after ${WAITED} s. It stays scheduled." >&2
        echo "  Finish later with: SALT=${SALT} bash $0 ${ACCOUNT} ${CAP_NAMES[*]} --execute-only" >&2
        exit 1
    fi
    echo "      waiting for the Timelock delay (${WAITED}/${MIN_DELAY} s) ..."
    sleep 5
    WAITED=$((WAITED + 5))
done

echo "[2/2] executing ..."
EXECUTE_TX="$(send_tx "$TIMELOCK" \
    'execute(address,uint256,bytes,bytes32,bytes32)' \
    "$CAPABILITY_BADGE" 0 "$DATA" "$PREDECESSOR" "$SALT")"
echo "[2/2] executed: ${EXECUTE_TX}"
echo "---"

# ---------------------------------------------------------------------------
# Post-checks (read-only)
# ---------------------------------------------------------------------------
FAILED=0
for I in "${!REVOKE_NAMES[@]}"; do
    if [[ "$(has_cap "$ACCOUNT" "${REVOKE_IDS[$I]}")" == "true" ]]; then
        echo "FAIL  ${REVOKE_NAMES[$I]}: ${ACCOUNT} STILL holds it"
        FAILED=$((FAILED + 1))
    else
        echo "PASS  ${REVOKE_NAMES[$I]}: revoked from ${ACCOUNT}"
    fi
    if [[ "$(has_cap "$SIGNER" "${REVOKE_IDS[$I]}")" == "true" ]]; then
        echo "PASS  ${REVOKE_NAMES[$I]}: the services signer still holds it"
    else
        echo "NOTE  ${REVOKE_NAMES[$I]}: the services signer does not hold it"
    fi
done
if [[ "$FAILED" -gt 0 ]]; then
    echo "ERROR: ${FAILED} capability/ies were not revoked — look at ${EXECUTE_TX}." >&2
    exit 1
fi
echo "Done."
