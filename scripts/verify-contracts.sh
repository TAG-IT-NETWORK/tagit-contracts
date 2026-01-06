#!/bin/bash
# ============================================
# TAG IT Network - Contract Verification Script
# ============================================
# Verifies deployed contracts on OP Sepolia (chainid: 11155420)
#
# Usage: ./scripts/verify-contracts.sh
#
# Requirements:
# - ETHERSCAN_API_KEY environment variable (Optimism Etherscan)
# - OP_SEPOLIA_RPC_URL environment variable (optional, has default)
# ============================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================
# DEPLOYED CONTRACT ADDRESSES (OP Sepolia)
# Deployment Date: December 2025
# ============================================
IDENTITY_BADGE="0xb3f757fca307a7feba5ca210cd7d840ec69990e8"
CAPABILITY_BADGE="0xfa7e212eec6e9214c9dde5bd29c9e1e4ef0894b6"
TAGIT_ACCESS="0xf7efefc59eb154040db4c9c2ad9417ddb10b4936"
TAGIT_CORE="0x6a58ee8f2d50d981b1793868c550727b9c58fba6"

# Chain configuration
CHAIN_ID="11155420"
CHAIN_NAME="optimism-sepolia"
RPC_URL="${OP_SEPOLIA_RPC_URL:-https://sepolia.optimism.io}"

# ============================================
# FUNCTIONS
# ============================================

print_header() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}==========================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}! $1${NC}"
}

print_info() {
    echo -e "${BLUE}→ $1${NC}"
}

check_env() {
    if [ -z "$ETHERSCAN_API_KEY" ]; then
        print_error "ETHERSCAN_API_KEY environment variable is not set"
        echo "Get an API key from: https://optimistic.etherscan.io/myapikey"
        exit 1
    fi
    print_success "ETHERSCAN_API_KEY is set"
}

verify_contract() {
    local name=$1
    local address=$2
    local contract_path=$3

    print_info "Verifying $name at $address..."

    # Use chain name for automatic verifier configuration
    local output
    output=$(forge verify-contract \
        --chain "$CHAIN_NAME" \
        --etherscan-api-key "$ETHERSCAN_API_KEY" \
        --watch \
        "$address" \
        "$contract_path" 2>&1) || true

    if echo "$output" | grep -qi "already verified\|verified\!"; then
        if echo "$output" | grep -qi "already verified"; then
            print_warning "$name is already verified"
        else
            print_success "$name verified successfully"
        fi
        return 0
    else
        echo "$output"
        print_error "Failed to verify $name"
        return 1
    fi
}

# ============================================
# MAIN
# ============================================

print_header "TAG IT Network - Contract Verification"
echo ""
echo "Chain: OP Sepolia (${CHAIN_ID})"
echo "RPC: ${RPC_URL}"
echo ""

# Check prerequisites
print_header "Checking Prerequisites"
check_env
echo ""

# Display contracts to verify
print_header "Contracts to Verify"
echo "IdentityBadge:   $IDENTITY_BADGE"
echo "CapabilityBadge: $CAPABILITY_BADGE"
echo "TAGITAccess:     $TAGIT_ACCESS"
echo "TAGITCore:       $TAGIT_CORE"
echo ""

# Verify contracts
print_header "Verifying Contracts"

FAILED=0

# 1. IdentityBadge
verify_contract "IdentityBadge" "$IDENTITY_BADGE" "src/access/IdentityBadge.sol:IdentityBadge" || FAILED=$((FAILED + 1))
echo ""

# 2. CapabilityBadge
verify_contract "CapabilityBadge" "$CAPABILITY_BADGE" "src/access/CapabilityBadge.sol:CapabilityBadge" || FAILED=$((FAILED + 1))
echo ""

# 3. TAGITAccess
verify_contract "TAGITAccess" "$TAGIT_ACCESS" "src/access/TAGITAccess.sol:TAGITAccess" || FAILED=$((FAILED + 1))
echo ""

# 4. TAGITCore
verify_contract "TAGITCore" "$TAGIT_CORE" "src/core/TAGITCore.sol:TAGITCore" || FAILED=$((FAILED + 1))
echo ""

# Summary
print_header "Verification Summary"
if [ $FAILED -eq 0 ]; then
    print_success "All contracts verified successfully!"
    echo ""
    echo "View on Etherscan:"
    echo "  IdentityBadge:   https://sepolia-optimism.etherscan.io/address/${IDENTITY_BADGE}#code"
    echo "  CapabilityBadge: https://sepolia-optimism.etherscan.io/address/${CAPABILITY_BADGE}#code"
    echo "  TAGITAccess:     https://sepolia-optimism.etherscan.io/address/${TAGIT_ACCESS}#code"
    echo "  TAGITCore:       https://sepolia-optimism.etherscan.io/address/${TAGIT_CORE}#code"
else
    print_error "$FAILED contract(s) failed verification"
    exit 1
fi

echo ""
print_success "Done!"
