# Echidna Property-Based Fuzzing

Property-based fuzzing for TAG IT smart contracts using [Echidna](https://github.com/crytic/echidna).

## Overview

Echidna tests **invariants** - properties that must always hold true regardless of the sequence of transactions. This complements Foundry's fuzz testing by:

- Testing longer transaction sequences (100+ calls)
- Exploring more state space combinations
- Finding edge cases that random unit tests miss

## Installation

### Option A: pip (Linux/WSL/macOS)
```bash
pip install crytic-compile slither-analyzer
pip install echidna
```

### Option B: Docker (Works everywhere)
```bash
docker pull ghcr.io/crytic/echidna/echidna:latest
```

### Option C: Prebuilt binaries
Download from [Echidna releases](https://github.com/crytic/echidna/releases)

## Test Contracts

| Contract | Description | Invariants |
|----------|-------------|------------|
| `TAGITInvariants.sol` | Core system invariants | Supply, staking, state machine |
| `TokenInvariants.sol` | Token economics | Minting, burning, vesting |
| `GovernanceInvariants.sol` | DAO governance | Proposals, voting, treasury |

## Running Tests

### Native Echidna
```bash
# Core invariants
echidna test/echidna/TAGITInvariants.sol \
  --contract TAGITInvariants \
  --config test/echidna/EchidnaConfig.yaml

# Token invariants
echidna test/echidna/TokenInvariants.sol \
  --contract TokenInvariants \
  --config test/echidna/EchidnaConfig.yaml

# Governance invariants
echidna test/echidna/GovernanceInvariants.sol \
  --contract GovernanceInvariants \
  --config test/echidna/EchidnaConfig.yaml
```

### Docker
```bash
docker run -v $(pwd):/src ghcr.io/crytic/echidna/echidna:latest \
  /src/test/echidna/TAGITInvariants.sol \
  --contract TAGITInvariants \
  --config /src/test/echidna/EchidnaConfig.yaml
```

### Run All Tests
```bash
bash scripts/run-echidna.sh
```

## Invariants Tested

### Core Invariants (`TAGITInvariants.sol`)
- `echidna_token_supply_consistent` - Supply is non-negative and bounded
- `echidna_staking_solvent` - Staking contract has enough tokens
- `echidna_burner_monotonic` - Burned amount never decreases
- `echidna_core_supply_consistent` - NFT supply matches minted count
- `echidna_tag_binding_unique` - No duplicate tag bindings
- `echidna_state_forward_only` - State machine only moves forward
- `echidna_minted_no_tag` - MINTED state has no tag
- `echidna_bound_has_tag` - BOUND+ states have tag bound

### Token Invariants (`TokenInvariants.sol`)
- `echidna_supply_equals_minted_minus_burned` - Supply accounting
- `echidna_burns_decrease_supply` - Burns reduce supply
- `echidna_staking_always_solvent` - Staking solvency
- `echidna_rewards_payable` - Rewards can be paid out
- `echidna_burn_floor_always_enforced` - 3.33% minimum burn
- `echidna_burn_rate_max_100` - Burn rate <= 100%
- `echidna_vested_not_exceed_grant` - Vesting accounting
- `echidna_allocations_sum_100` - Emission allocations sum to 100%

### Governance Invariants (`GovernanceInvariants.sol`)
- `echidna_voting_power_bounded` - Voting power <= total supply
- `echidna_quorum_bounded` - Quorum is reasonable
- `echidna_no_double_execution` - No proposal re-execution
- `echidna_cancelled_not_executable` - Cancelled stays cancelled
- `echidna_treasury_solvent` - Treasury has sufficient balance
- `echidna_timelock_delay_positive` - Timelock has delay
- `echidna_guardian_exists` - Guardian address is set

## Configuration

See `EchidnaConfig.yaml` for full configuration:

```yaml
testMode: "property"      # Test echidna_* functions
testLimit: 50000          # Number of test sequences
seqLen: 100               # Max calls per sequence
shrinkLimit: 5000         # Shrinking attempts for counterexamples
coverage: true            # Generate coverage report
```

## Success Criteria

All `echidna_*` functions must return `true` after 50,000 iterations.

## Interpreting Results

### Passing
```
echidna_staking_solvent: passing
```

### Failing (with counterexample)
```
echidna_staking_solvent: failed!
  Call sequence:
    stake(1000000000000000000)
    unstake(2000000000000000000)
```

## Coverage Report

After running, check `echidna-corpus/` for:
- `covered.*.txt` - Covered code paths
- `corpus/` - Interesting inputs found

## Troubleshooting

### Compilation errors
Ensure remappings in `EchidnaConfig.yaml` match `foundry.toml`

### Slow tests
Reduce `testLimit` or `seqLen` for faster iteration

### Memory issues
Use Docker with memory limits:
```bash
docker run -m 8g ...
```
