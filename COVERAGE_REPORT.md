# Test Coverage Report - TAG IT Contracts

**Generated:** 2026-03-30
**Repository:** tagit-contracts
**Branch:** sudo/coverage-report-verify-85
**Task:** 4H — Full coverage report and verify aggregate >85%

---

## Executive Summary

| Metric | src/ Only | Total (incl. tests) | Target | Status |
|--------|-----------|---------------------|--------|--------|
| **Lines** | **90.24%** (2968/3289) | 65.99% (3462/5246) | ≥85% | ✅ PASS |
| **Statements** | **86.94%** (3010/3462) | 63.18% (3481/5510) | ≥85% | ✅ PASS |
| **Branches** | **66.38%** (464/699) | 60.00% (492/820) | ≥85% | ❌ FAIL |
| **Functions** | **89.52%** (564/630) | 75.52% (691/915) | ≥85% | ✅ PASS |

**Verdict: Lines and Statements pass ≥85%. Branch coverage is below threshold at 66.38%.**

> Note: The "Total" column includes test helper contracts (echidna, invariant handlers, mocks) which artificially deflate numbers. The "src/ Only" column is the correct metric for production code quality.

---

## Files Below 85% Line Coverage (src/ only)

| File | Lines | Statements | Branches | Functions |
|------|-------|------------|----------|-----------|
| `src/account/TAGITAccount.sol` | 69.95% | 60.50% | 38.46% | 78.12% |
| `src/account/TAGITAccountFactory.sol` | 74.23% | 70.00% | 25.00% | 66.67% |
| `src/core/TAGITCoreDemo.sol` | 0.00% | 0.00% | 0.00% | 0.00% |
| `src/governance/TAGITGovernor.sol` | 77.30% | 76.40% | 75.00% | 62.16% |
| `src/programs/TAGITPrograms.sol` | 81.43% | 76.38% | 45.21% | 81.63% |

## Files Below 85% Branch Coverage (src/ only)

| File | Branches | Untested Branches |
|------|----------|-------------------|
| `src/account/TAGITAccount.sol` | 38.46% (20/52) | 32 missing |
| `src/account/TAGITAccountFactory.sol` | 25.00% (4/16) | 12 missing |
| `src/account/TAGITPaymaster.sol` | 65.71% (23/35) | 12 missing |
| `src/agent/IntegrationFactory.sol` | 78.95% (30/38) | 8 missing |
| `src/agent/TAGITAgentIdentity.sol` | 48.15% (13/27) | 14 missing |
| `src/agent/TAGITAgentReputation.sol` | 66.67% (14/21) | 7 missing |
| `src/agent/TAGITAgentValidation.sol` | 72.22% (13/18) | 5 missing |
| `src/bridge/CCIPAdapter.sol` | 50.00% (16/32) | 16 missing |
| `src/core/TAGITCoreDemo.sol` | 0.00% (0/3) | 3 missing |
| `src/governance/TAGITGovernor.sol` | 75.00% (21/28) | 7 missing |
| `src/libraries/RateLimiter.sol` | 82.61% (19/23) | 4 missing |
| `src/programs/TAGITPrograms.sol` | 45.21% (33/73) | 40 missing |
| `src/recovery/TAGITRecovery.sol` | 58.82% (30/51) | 21 missing |
| `src/robot/RoboticAuthorizer.sol` | 72.73% (16/22) | 6 missing |
| `src/token/TAGITStaking.sol` | 66.67% (12/18) | 6 missing |
| `src/token/TAGITVesting.sol` | 81.25% (13/16) | 3 missing |
| `src/treasury/TAGITTreasury.sol` | 44.83% (26/58) | 32 missing |

## CI Workflow Findings (`coverage-check.yml`)

| # | Finding | Severity | Details |
|---|---------|----------|---------|
| 1 | Total row includes test files | Medium | CI checks `Total` row which includes test/mock/echidna contracts, artificially lowering the reported percentage. Should filter to `src/` only. |
| 2 | No lcov artifact generated | Low | CI only produces `coverage-output.txt`. Should also generate `coverage/lcov.info` for integration with coverage tools. |
| 3 | Uses GNU grep `-P` flag | Medium | `grep -oP` requires PCRE (GNU grep). Ubuntu runners have it, but this is fragile. Should use `grep -oE` instead. |
| 4 | Threshold is 85% (correct) | Info | Matches project requirements. |

## Artifacts

- `coverage/lcov.info` — Machine-readable lcov report
- `coverage-summary-new.txt` — Full forge coverage summary output

---

## Recommendation

**Lines and Statements coverage pass the 85% threshold for production code (src/ only).**

**Branch coverage at 66.38% does NOT pass.** The biggest gaps are in:
1. `TAGITAccount.sol` / `TAGITAccountFactory.sol` — ERC-4337 account abstraction edge cases
2. `TAGITTreasury.sol` — Treasury spend path branches
3. `TAGITPrograms.sol` — Loyalty program conditional logic
4. `CCIPAdapter.sol` — Cross-chain message handling branches
5. `TAGITRecovery.sol` — Recovery protocol edge cases

**Action required before merge:** Either (a) add branch-specific tests to bring branch coverage ≥85%, or (b) document accepted risk for branch coverage gap and adjust CI threshold to check Lines/Statements only.
