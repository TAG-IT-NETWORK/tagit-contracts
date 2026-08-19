#!/usr/bin/env bash
# =============================================================================
# key-ceremony-3-strip-old.sh — T01 key ceremony, step 3 of 3: strip old key
# =============================================================================
# Usage:
#   ./key-ceremony-3-strip-old.sh [OLD_ADDRESS] <KEY_B_ADDRESS> --confirm-strip
#
#   With TWO addresses:  arg1 = OLD address, arg2 = KEY_B.
#   With ONE address:    it is KEY_B; OLD defaults to
#                        0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D.
#
# Revokes the old shared hot key's capabilities on the LIVE Base Sepolia
# CapabilityBadge — but ONLY after a pre-flight proves the cutover is real:
#   1. check-capabilities.sh confirms KEY_B holds MINTER/BINDER/RECYCLER
#   2. TAGITCore.trustedOracle() == KEY_B                (read-only cast)
#   3. the operator passed --confirm-strip
# Refuses to run otherwise. Every revoke is idempotent (read-only pre-check).
#
# Contract facts (live-verified 2026-08-14 via read-only cast calls):
#   CapabilityBadge.revokeCapability(address,uint256) onlyOwner [selector 0xe73a731c]
#     src/access/CapabilityBadge.sol line 100 (burns 1 ERC-1155 unit; reverts
#     CapabilityNotFound if balance is 0 — hence the pre-checks)
#   CapabilityBadge.owner() == the OLD key itself — so until badge ownership
#     is migrated, the old key must SEND its own strip transactions.
#   Known capability set (TAGITCore.sol lines 71-79, ids = keccak256(name)):
#     MINTER BINDER ACTIVATOR CLAIMER FLAGGER RESOLVER RECYCLER VIEWER AUDITOR
#
# Coverage rule: a capability the old key holds is revoked only when KEY_B
# holds the same capability (so the system never loses its last holder).
# Uncovered capabilities are SKIPPED with a loud warning; set
# STRIP_UNCOVERED=1 to revoke them anyway (e.g. after granting replacements
# elsewhere, or to deliberately retire a capability).
#
# Auth (never echoed): CEREMONY_SENDER_PK or CEREMONY_SENDER_KEYCHAIN_SERVICE
# (+ optional CEREMONY_SENDER_KEYCHAIN_ACCOUNT) — same as key-ceremony-2.
# The sender must be the CapabilityBadge owner.
#
# What this script does NOT automate is printed as a checklist at the end
# (Timelock role migration, badge ownership, SALE_TREASURY).
# =============================================================================
set -euo pipefail

TAGIT_CORE_PROXY="0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D"
TAGIT_ACCESS="0xb56A1D91995C212342FaA843468F03521340A1D6"
CAPABILITY_BADGE="0xb05d22706B08A3F6409601de520cf7A6dbCB573d"
TIMELOCK="0xfdA2478dB73064eF770f4e5E5b97BC83801126e1"
DEFAULT_OLD_KEY="0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D"
RPC_URL="${RPC_URL:-https://sepolia.base.org}"

# Full known capability set — TAGITCore.sol lines 71-79.
ALL_CAPS=(MINTER BINDER ACTIVATOR CLAIMER FLAGGER RESOLVER RECYCLER VIEWER AUDITOR)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
    echo "Usage: $0 [OLD_ADDRESS] <KEY_B_ADDRESS> --confirm-strip" >&2
    echo "  One address  -> it is KEY_B; OLD defaults to ${DEFAULT_OLD_KEY}" >&2
    echo "  Two addresses -> arg1 = OLD, arg2 = KEY_B" >&2
    echo "  --confirm-strip is REQUIRED — this revokes live authority." >&2
    echo "  Env: STRIP_UNCOVERED=1 also revokes capabilities KEY_B does not hold." >&2
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
CONFIRM_STRIP=0
declare -a POSITIONAL=()
for ARG in "$@"; do
    case "$ARG" in
        --confirm-strip) CONFIRM_STRIP=1 ;;
        -h|--help) usage; exit 0 ;;
        0x*) POSITIONAL+=("$ARG") ;;
        *) echo "ERROR: unknown argument '$ARG'." >&2; usage; exit 2 ;;
    esac
done

case "${#POSITIONAL[@]}" in
    1) OLD_ADDRESS="$DEFAULT_OLD_KEY"; KEY_B_ADDRESS="${POSITIONAL[0]}" ;;
    2) OLD_ADDRESS="${POSITIONAL[0]}"; KEY_B_ADDRESS="${POSITIONAL[1]}" ;;
    *) usage; exit 2 ;;
esac

for A in "$OLD_ADDRESS" "$KEY_B_ADDRESS"; do
    if ! [[ "$A" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "ERROR: '$A' is not a valid 20-byte hex address." >&2
        exit 2
    fi
done
if [[ "$(lc "$OLD_ADDRESS")" == "$(lc "$KEY_B_ADDRESS")" ]]; then
    echo "ERROR: OLD and KEY_B are the same address." >&2
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

echo "OLD key (strip target): ${OLD_ADDRESS}"
echo "KEY_B  (replacement):   ${KEY_B_ADDRESS}"
echo "RPC:                    ${RPC_URL}"
echo "---"

# ---------------------------------------------------------------------------
# PRE-FLIGHT — all three gates must pass or NOTHING is sent
# ---------------------------------------------------------------------------
echo "PRE-FLIGHT 1/3: KEY_B must hold MINTER/BINDER/RECYCLER (check-capabilities.sh)"
if ! "$SCRIPT_DIR/check-capabilities.sh" "$KEY_B_ADDRESS" "$RPC_URL"; then
    echo "PRE-FLIGHT FAILED: KEY_B is missing capabilities." >&2
    echo "  Run key-ceremony-2-grant.sh first. No transactions sent." >&2
    exit 1
fi

echo "PRE-FLIGHT 2/3: TAGITCore.trustedOracle() must equal KEY_B"
CURRENT_ORACLE="$(cast call "$TAGIT_CORE_PROXY" 'trustedOracle()(address)' --rpc-url "$RPC_URL")"
if [[ "$(lc "$CURRENT_ORACLE")" != "$(lc "$KEY_B_ADDRESS")" ]]; then
    echo "PRE-FLIGHT FAILED: trustedOracle is ${CURRENT_ORACLE}, not KEY_B." >&2
    echo "  Flip it first: ./key-ceremony-2-grant.sh ${KEY_B_ADDRESS} --flip-oracle" >&2
    echo "  (after rotating services SIGNER_PRIVATE_KEY). No transactions sent." >&2
    exit 1
fi
echo "  OK: trustedOracle == KEY_B"

echo "PRE-FLIGHT 3/3: operator confirmation"
if [[ "$CONFIRM_STRIP" -ne 1 ]]; then
    echo "PRE-FLIGHT FAILED: --confirm-strip not passed." >&2
    echo "  This step revokes live on-chain authority from ${OLD_ADDRESS}." >&2
    echo "  Re-run with --confirm-strip when you mean it. No transactions sent." >&2
    exit 1
fi
echo "  OK: --confirm-strip"
echo "---"

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

Until CapabilityBadge ownership is migrated, the owner IS the old key —
it strips itself.
EOF
    exit 2
fi

SENDER_ADDR="$(cast wallet address --private-key "$SENDER_PK")"
echo "Sender: ${SENDER_ADDR}"

send_tx() {
    # All args are cast send args after the auth flags; key is never printed.
    cast send --rpc-url "$RPC_URL" --private-key "$SENDER_PK" "$@"
}

BADGE_OWNER="$(cast call "$CAPABILITY_BADGE" 'owner()(address)' --rpc-url "$RPC_URL")"
if [[ "$(lc "$BADGE_OWNER")" != "$(lc "$SENDER_ADDR")" ]]; then
    echo "ERROR: sender ${SENDER_ADDR} is not the CapabilityBadge owner." >&2
    echo "  CapabilityBadge ${CAPABILITY_BADGE} owner is ${BADGE_OWNER}." >&2
    echo "  revokeCapability() is onlyOwner — no transactions sent." >&2
    exit 1
fi
echo "---"

# ---------------------------------------------------------------------------
# Strip (idempotent, coverage-gated)
# ---------------------------------------------------------------------------
has_cap() {
    local WHO="$1" CAP_ID="$2"
    cast call "$TAGIT_ACCESS" 'hasCapability(address,uint256)(bool)' \
        "$WHO" "$CAP_ID" --rpc-url "$RPC_URL"
}

declare -a SUMMARY=()
UNCOVERED=0

for CAP_NAME in "${ALL_CAPS[@]}"; do
    CAP_ID="$(cast keccak "$CAP_NAME")"
    if [[ "$(has_cap "$OLD_ADDRESS" "$CAP_ID")" != "true" ]]; then
        echo "[${CAP_NAME}] SKIP — old key does not hold it."
        SUMMARY+=("${CAP_NAME}: not held by old key (nothing to revoke)")
        continue
    fi
    if [[ "$(has_cap "$KEY_B_ADDRESS" "$CAP_ID")" != "true" && "${STRIP_UNCOVERED:-0}" != "1" ]]; then
        echo "[${CAP_NAME}] !! SKIPPED — old key holds it but KEY_B does NOT."
        echo "    Revoking now would leave NO ceremony holder of ${CAP_NAME}."
        echo "    Grant a replacement first, or re-run with STRIP_UNCOVERED=1."
        SUMMARY+=("${CAP_NAME}: STILL HELD by old key (uncovered — manual decision)")
        UNCOVERED=$((UNCOVERED + 1))
        continue
    fi
    echo "[${CAP_NAME}] revoking from old key (id ${CAP_ID}) ..."
    TX="$(send_tx "$CAPABILITY_BADGE" \
        'revokeCapability(address,uint256)' \
        "$OLD_ADDRESS" "$CAP_ID" \
        --json | jq -r '.transactionHash')"
    if [[ "$(has_cap "$OLD_ADDRESS" "$CAP_ID")" == "true" ]]; then
        echo "ERROR: post-check failed — old key still holds ${CAP_NAME} after ${TX}." >&2
        exit 1
    fi
    echo "[${CAP_NAME}] revoked: ${TX}"
    SUMMARY+=("${CAP_NAME}: REVOKED tx=${TX}")
done

echo "---"
echo "STRIP SUMMARY for ${OLD_ADDRESS}:"
for LINE in "${SUMMARY[@]}"; do
    echo "  - ${LINE}"
done
if [[ "$UNCOVERED" -gt 0 ]]; then
    echo "  !! ${UNCOVERED} capability/ies remain on the old key (uncovered — see above)."
fi

# ---------------------------------------------------------------------------
# What this script does NOT automate — remaining manual cutover items
# ---------------------------------------------------------------------------
cat <<EOF
=============================================================================
 REMAINING MANUAL ITEMS — the old key is NOT fully retired until ALL done
=============================================================================
 [ ] 1. Timelock PROPOSER/EXECUTOR/CANCELLER migration to KEY_A
     The old key holds PROPOSER + EXECUTOR + CANCELLER on the Timelock
     (${TIMELOCK}).
     DEFAULT_ADMIN_ROLE is held ONLY by the Timelock itself (live-verified),
     so grantRole/revokeRole revert unless msg.sender is the Timelock —
     i.e. every role change must be SCHEDULED THROUGH THE TIMELOCK'S OWN
     QUEUE (target = the Timelock, like timelock-set-uris.sh but self-call):

       # grant each role to KEY_A (repeat for EXECUTOR_ROLE, CANCELLER_ROLE):
       DATA=\$(cast calldata 'grantRole(bytes32,address)' \\
              "\$(cast keccak PROPOSER_ROLE)" <KEY_A>)
       cast send ${TIMELOCK} \\
         'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \\
         ${TIMELOCK} 0 "\$DATA" \\
         0x0000000000000000000000000000000000000000000000000000000000000000 \\
         <unique-salt> 60
       # wait >= 60s, then:
       cast send ${TIMELOCK} \\
         'execute(address,uint256,bytes,bytes32,bytes32)' \\
         ${TIMELOCK} 0 "\$DATA" \\
         0x0000000000000000000000000000000000000000000000000000000000000000 \\
         <unique-salt>

     ORDER MATTERS: grant KEY_A's roles and VERIFY (hasRole) that KEY_A can
     schedule+execute BEFORE scheduling revokeRole for the old key — the
     schedule/execute txs above are still sent by the OLD key (it is the
     only proposer/executor today). Revoking it first with no replacement
     bricks the Timelock permanently, and TAGITCore is owner-locked to it.
       # then revoke from the old key (same pattern, calldata:)
       cast calldata 'revokeRole(bytes32,address)' \\
              "\$(cast keccak PROPOSER_ROLE)" ${OLD_ADDRESS}

 [ ] 2. CapabilityBadge + TAGITAccess ownership migration
     BOTH are Ownable and owned by the OLD key (live-verified) — until moved,
     the "stripped" key can silently re-grant itself everything:
       cast send ${CAPABILITY_BADGE} 'transferOwnership(address)' <KEY_A or Timelock>
       cast send ${TAGIT_ACCESS} 'transferOwnership(address)' <KEY_A or Timelock>

 [ ] 3. SALE_TREASURY migration (tagit-services env, src/sale/sale-relayer.ts)
     SALE_TREASURY currently points at the old key. Update it to the new
     treasury address in Vercel env AND AWS Secrets Manager
     tagit/services/prod (READ-MODIFY-WRITE the JSON — see runbook).

 [ ] 4. Retire the key material
     Drain remaining Base Sepolia ETH to KEY_A, then delete the old key from
     every env/secret store. It remains the historical deployer — nothing
     on-chain to revoke for that.
=============================================================================
Done.
EOF
