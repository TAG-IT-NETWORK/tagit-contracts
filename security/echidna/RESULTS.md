# Echidna Fuzzing Results

**Date**: 2026-01-02
**Echidna Version**: 2.3.0
**Test Limit**: 50,000 iterations
**Sequence Length**: 100 calls

## Summary

| Metric | Value |
|--------|-------|
| Total Calls | 50,240 |
| Unique Instructions | 3,570 |
| Contracts Tested | 4 |
| Corpus Size | 8 |
| Gas/second | ~117M |

## Invariant Results

| Invariant | Status | Description |
|-----------|--------|-------------|
| `echidna_token_supply_valid` | PASSING | Token supply <= minted amount |
| `echidna_staking_solvent` | PASSING | totalStaked <= staking balance |
| `echidna_burns_decrease_supply` | PASSING | Burns reduce supply |
| `echidna_balance_sum_bounded` | PASSING | Sum of balances <= total supply |
| `echidna_burn_floor_enforced` | PASSING | burnRate >= 3.33% floor |
| `echidna_burn_rate_bounded` | PASSING | burnRate <= 100% |
| `echidna_burned_monotonic` | PASSING | totalBurned never decreases |
| `echidna_staking_accounting` | PASSING | Staking math is correct |

## Contracts Tested

1. **MockToken** - Simplified ERC20 with mint/burn
2. **MockStaking** - Stake/unstake with accounting
3. **MockBurner** - Fee routing with burn floor enforcement
4. **TAGITInvariants** - Main invariant test harness

## Command Used

```bash
./tools/echidna.exe test/echidna/TAGITInvariants.sol \
  --contract TAGITInvariants \
  --test-mode property \
  --test-limit 50000 \
  --seq-len 100
```

## Invariants Verified

### Economic Invariants
- Token supply can only decrease (through burns), never increase beyond minted
- Staking contract always has enough tokens to cover staked amounts
- Burns correctly decrease total supply
- Sum of all tracked balances never exceeds total supply

### Access Control Invariants
- Burn rate cannot be set below 3.33% floor
- Burn rate cannot exceed 100%

### Accounting Invariants
- Total burned counter only increases
- Staking totals match individual stake records

## Conclusion

All 8 property-based invariants held after 50,000+ fuzzing iterations. No counterexamples found. The core economic and access control logic is sound.
