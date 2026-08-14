#!/usr/bin/env bash
# =============================================================================
# key-ceremony-1-generate.sh — T01 key ceremony, step 1 of 3: generate keys
# =============================================================================
# Generates TWO fresh keypairs with `cast wallet new`:
#   KEY_A — new contracts-deployer        (Keychain: tagit-ceremony-key-a / deployer)
#   KEY_B — new services oracle/signer    (Keychain: tagit-ceremony-key-b / services-signer)
#
# The private keys go DIRECTLY into the macOS Keychain via
# `security add-generic-password`. They are NEVER printed, echoed, logged,
# or written to any file. Only the two public ADDRESSES are printed.
#
# Refuses to overwrite existing Keychain items unless FORCE=1 is set
# (overwriting would orphan keys that may already hold on-chain authority).
#
# Retrieval later (prints the key to YOUR terminal — do this only when needed):
#   security find-generic-password -s tagit-ceremony-key-a -a deployer -w
#   security find-generic-password -s tagit-ceremony-key-b -a services-signer -w
#
# NOTE on process args: the key transits `security ... -w "$PK"` argv for the
# lifetime of that one process (visible to local `ps`). Same tradeoff as the
# existing ops scripts' `--private-key` usage; accepted on a single-user Mac.
# It never lands in stdout/stderr or on disk outside the Keychain.
# =============================================================================
set -euo pipefail

# Portable lowercase (macOS default bash is 3.2 — no ${var,,})
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

KEY_A_SERVICE="tagit-ceremony-key-a"
KEY_A_ACCOUNT="deployer"
KEY_B_SERVICE="tagit-ceremony-key-b"
KEY_B_ACCOUNT="services-signer"

# ---------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------
for TOOL in cast security; do
    if ! command -v "$TOOL" >/dev/null 2>&1; then
        echo "ERROR: required tool '$TOOL' not found in PATH." >&2
        echo "  cast     -> install Foundry (~/.foundry/bin)" >&2
        echo "  security -> macOS built-in (/usr/bin/security)" >&2
        exit 2
    fi
done

# ---------------------------------------------------------------------------
# Overwrite guard — refuse to clobber existing ceremony keys unless FORCE=1
# (find-generic-password WITHOUT -w does not reveal the secret; all output
# is discarded anyway.)
# ---------------------------------------------------------------------------
check_existing() {
    local SERVICE="$1" ACCOUNT="$2"
    if security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
        if [[ "${FORCE:-0}" != "1" ]]; then
            echo "ERROR: Keychain item '${SERVICE}' (account '${ACCOUNT}') already exists." >&2
            echo "  An earlier ceremony key is stored there and may already hold" >&2
            echo "  on-chain authority. Refusing to overwrite." >&2
            echo "  If you REALLY intend to replace it, re-run with FORCE=1." >&2
            exit 1
        fi
        echo "WARNING: overwriting existing Keychain item '${SERVICE}' (FORCE=1 set)." >&2
    fi
}

check_existing "$KEY_A_SERVICE" "$KEY_A_ACCOUNT"
check_existing "$KEY_B_SERVICE" "$KEY_B_ACCOUNT"

# ---------------------------------------------------------------------------
# Generate + store one keypair. Prints ONLY the address (via stdout capture
# by the caller). The private key lives in shell variables and the Keychain
# — nowhere else.
#
# `cast wallet new` output format (verified against cast 7.x):
#   Successfully created new keypair.
#   Address:     0x<40 hex>
#   Private key: 0x<64 hex>
# ---------------------------------------------------------------------------
generate_and_store() {
    local SERVICE="$1" ACCOUNT="$2" LABEL="$3"
    local RAW ADDR PK

    RAW="$(cast wallet new)"
    ADDR="$(printf '%s\n' "$RAW" | awk '/^Address:/ {print $2}')"
    PK="$(printf '%s\n' "$RAW" | awk '/^Private key:/ {print $3}')"
    unset RAW

    if ! [[ "$ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || ! [[ "$PK" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
        echo "ERROR: unexpected 'cast wallet new' output format — nothing stored." >&2
        echo "  (Parsed address: '${ADDR:-<empty>}'. Key material NOT shown.)" >&2
        exit 1
    fi

    # -U updates in place when the item exists (only reachable with FORCE=1).
    security add-generic-password -U \
        -s "$SERVICE" \
        -a "$ACCOUNT" \
        -j "TAG IT T01 key ceremony: ${LABEL} (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))" \
        -w "$PK"
    unset PK

    printf '%s' "$ADDR"
}

echo "Generating KEY_A (contracts-deployer) ..."
KEY_A_ADDRESS="$(generate_and_store "$KEY_A_SERVICE" "$KEY_A_ACCOUNT" "KEY_A contracts-deployer")"
echo "Generating KEY_B (services oracle/signer) ..."
KEY_B_ADDRESS="$(generate_and_store "$KEY_B_SERVICE" "$KEY_B_ACCOUNT" "KEY_B services oracle/signer")"

if [[ "$(lc "$KEY_A_ADDRESS")" == "$(lc "$KEY_B_ADDRESS")" ]]; then
    echo "ERROR: KEY_A and KEY_B resolved to the same address — aborting." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Summary — ADDRESSES ONLY. No key material below this line.
# ---------------------------------------------------------------------------
cat <<EOF
=============================================================================
 T01 KEY CEREMONY — STEP 1 COMPLETE (addresses only; keys are in Keychain)
=============================================================================
 KEY_A  (contracts-deployer):     ${KEY_A_ADDRESS}
        Keychain item:            ${KEY_A_SERVICE} / ${KEY_A_ACCOUNT}

 KEY_B  (services oracle/signer): ${KEY_B_ADDRESS}
        Keychain item:            ${KEY_B_SERVICE} / ${KEY_B_ACCOUNT}
=============================================================================
 NEXT STEPS (see script/ops/README.md, "Key ceremony runbook"):
   1. Fund BOTH addresses with Base Sepolia ETH (faucet or transfer).
   2. Grant capabilities to KEY_B (harmless — does not change the oracle):
        ./key-ceremony-2-grant.sh ${KEY_B_ADDRESS} ${KEY_A_ADDRESS}
   3. Rotate services SIGNER_PRIVATE_KEY -> KEY_B (Vercel env + AWS
      Secrets Manager tagit/services/prod; READ-MODIFY-WRITE the JSON).
      Also rotate API_KEY (openssl rand -hex 32) and drop the leaked
      tagit-hack-2026-key. Probe until the old values return 401.
   4. ONLY THEN flip the oracle:
        ./key-ceremony-2-grant.sh ${KEY_B_ADDRESS} --flip-oracle
   5. Strip the old shared hot key:
        ./key-ceremony-3-strip-old.sh 0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D \\
            ${KEY_B_ADDRESS} --confirm-strip
=============================================================================
EOF
