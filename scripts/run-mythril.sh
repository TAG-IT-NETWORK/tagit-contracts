#!/bin/bash
# Mythril Symbolic Execution Analysis Script
# Run: bash scripts/run-mythril.sh

set -e

# Contract list with correct paths
CONTRACTS=(
    "src/core/TAGITCore.sol"
    "src/access/TAGITAccess.sol"
    "src/recovery/TAGITRecovery.sol"
    "src/programs/TAGITPrograms.sol"
    "src/token/TAGITToken.sol"
    "src/token/TAGITEmissions.sol"
    "src/token/TAGITBurner.sol"
    "src/token/TAGITVesting.sol"
    "src/token/TAGITStaking.sol"
    "src/governance/TAGITGovernor.sol"
    "src/treasury/TAGITTreasury.sol"
    "src/account/TAGITPaymaster.sol"
    "src/account/TAGITAccountFactory.sol"
    "src/account/TAGITAccount.sol"
    "src/bridge/CCIPAdapter.sol"
)

OUTPUT_DIR="security/mythril"
REMAPPINGS_FILE="remappings.json"
TIMEOUT=300
MAX_DEPTH=22

echo "🔍 Mythril Symbolic Execution Analysis"
echo "======================================="
echo "Contracts: ${#CONTRACTS[@]}"
echo "Timeout: ${TIMEOUT}s per contract"
echo "Max depth: ${MAX_DEPTH}"
echo ""

mkdir -p "$OUTPUT_DIR"

# Track results
HIGH_COUNT=0
CRITICAL_COUNT=0
ANALYZED=0
FAILED=0

for contract in "${CONTRACTS[@]}"; do
    name=$(basename "$contract" .sol)
    echo "🔍 Analyzing $name..."

    if [ ! -f "$contract" ]; then
        echo "⚠️  $contract not found, skipping..."
        ((FAILED++))
        continue
    fi

    # Run Mythril
    if myth analyze "$contract" \
        --solc-json "$REMAPPINGS_FILE" \
        --execution-timeout "$TIMEOUT" \
        --max-depth "$MAX_DEPTH" \
        -o json > "$OUTPUT_DIR/${name}.json" 2>&1; then

        ((ANALYZED++))

        # Check for HIGH/CRITICAL findings
        if grep -q '"severity": "High"' "$OUTPUT_DIR/${name}.json"; then
            echo "⚠️  $name has HIGH findings!"
            ((HIGH_COUNT++))
        fi
        if grep -q '"severity": "Critical"' "$OUTPUT_DIR/${name}.json"; then
            echo "🚨 $name has CRITICAL findings!"
            ((CRITICAL_COUNT++))
        fi
        if ! grep -q '"severity"' "$OUTPUT_DIR/${name}.json"; then
            echo "✅ $name passed (no findings)"
        fi
    else
        echo "❌ $name analysis failed"
        ((FAILED++))
    fi

    echo ""
done

echo "======================================="
echo "🏁 Mythril Analysis Complete"
echo "======================================="
echo "Analyzed: $ANALYZED / ${#CONTRACTS[@]}"
echo "Failed: $FAILED"
echo "HIGH findings: $HIGH_COUNT contracts"
echo "CRITICAL findings: $CRITICAL_COUNT contracts"
echo ""
echo "Results saved to: $OUTPUT_DIR/"

# Generate summary
cat > "$OUTPUT_DIR/SUMMARY.md" << EOF
# Mythril Analysis Summary

Date: $(date +%Y-%m-%d)
Contracts Analyzed: $ANALYZED / ${#CONTRACTS[@]}
Solc Version: 0.8.28
Timeout: ${TIMEOUT}s
Max Depth: ${MAX_DEPTH}

## Results Overview

| Metric | Count |
|--------|-------|
| Analyzed | $ANALYZED |
| Failed | $FAILED |
| HIGH findings | $HIGH_COUNT |
| CRITICAL findings | $CRITICAL_COUNT |

## Contract Results

| Contract | Status | Findings |
|----------|--------|----------|
EOF

for contract in "${CONTRACTS[@]}"; do
    name=$(basename "$contract" .sol)
    if [ -f "$OUTPUT_DIR/${name}.json" ]; then
        if grep -q '"severity": "Critical"' "$OUTPUT_DIR/${name}.json"; then
            echo "| $name | ⚠️ | CRITICAL |" >> "$OUTPUT_DIR/SUMMARY.md"
        elif grep -q '"severity": "High"' "$OUTPUT_DIR/${name}.json"; then
            echo "| $name | ⚠️ | HIGH |" >> "$OUTPUT_DIR/SUMMARY.md"
        elif grep -q '"severity"' "$OUTPUT_DIR/${name}.json"; then
            echo "| $name | ℹ️ | Low/Medium |" >> "$OUTPUT_DIR/SUMMARY.md"
        else
            echo "| $name | ✅ | Clean |" >> "$OUTPUT_DIR/SUMMARY.md"
        fi
    else
        echo "| $name | ❌ | Not analyzed |" >> "$OUTPUT_DIR/SUMMARY.md"
    fi
done

echo ""
echo "📄 Summary written to: $OUTPUT_DIR/SUMMARY.md"
EOF
