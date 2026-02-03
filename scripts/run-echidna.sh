#!/bin/bash
# Echidna Property-Based Fuzzing Runner
# Run: bash scripts/run-echidna.sh

set -e

echo "======================================"
echo "  Echidna Property-Based Fuzzing"
echo "======================================"

# Configuration
CONFIG="test/echidna/EchidnaConfig.yaml"
OUTPUT_DIR="security/echidna"
CONTRACTS=(
    "TAGITInvariants"
    "TokenInvariants"
    "GovernanceInvariants"
)

# Check if echidna is installed
if ! command -v echidna &> /dev/null; then
    echo "Echidna not found. Trying Docker..."
    USE_DOCKER=true
else
    USE_DOCKER=false
fi

mkdir -p "$OUTPUT_DIR"

# Track results
PASSED=0
FAILED=0

echo ""
echo "Running ${#CONTRACTS[@]} invariant contracts..."
echo ""

for contract in "${CONTRACTS[@]}"; do
    echo "Testing $contract..."

    SOLFILE="test/echidna/${contract}.sol"
    OUTFILE="$OUTPUT_DIR/${contract}.txt"

    if [ ! -f "$SOLFILE" ]; then
        echo "  File not found: $SOLFILE"
        ((FAILED++))
        continue
    fi

    if [ "$USE_DOCKER" = true ]; then
        docker run --rm -v "$(pwd)":/src ghcr.io/crytic/echidna/echidna:latest \
            "/src/$SOLFILE" \
            --contract "$contract" \
            --config "/src/$CONFIG" \
            2>&1 | tee "$OUTFILE"
    else
        echidna "$SOLFILE" \
            --contract "$contract" \
            --config "$CONFIG" \
            2>&1 | tee "$OUTFILE"
    fi

    # Check for failures
    if grep -q "failed!" "$OUTFILE"; then
        echo "  FAILED - Check $OUTFILE for counterexample"
        ((FAILED++))
    else
        echo "  PASSED"
        ((PASSED++))
    fi

    echo ""
done

echo "======================================"
echo "  Echidna Results"
echo "======================================"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Output: $OUTPUT_DIR/"

# Generate summary
cat > "$OUTPUT_DIR/SUMMARY.md" << EOF
# Echidna Fuzzing Results

**Date**: $(date +%Y-%m-%d)
**Config**: $CONFIG

## Results

| Contract | Status |
|----------|--------|
EOF

for contract in "${CONTRACTS[@]}"; do
    OUTFILE="$OUTPUT_DIR/${contract}.txt"
    if [ -f "$OUTFILE" ]; then
        if grep -q "failed!" "$OUTFILE"; then
            echo "| $contract | FAILED |" >> "$OUTPUT_DIR/SUMMARY.md"
        else
            echo "| $contract | PASSED |" >> "$OUTPUT_DIR/SUMMARY.md"
        fi
    else
        echo "| $contract | NOT RUN |" >> "$OUTPUT_DIR/SUMMARY.md"
    fi
done

echo ""
echo "Summary written to: $OUTPUT_DIR/SUMMARY.md"

# Exit with failure if any tests failed
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
