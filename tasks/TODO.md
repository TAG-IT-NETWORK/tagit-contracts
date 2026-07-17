# Current Task: Batch lifecycle functions (batchBind / batchActivate / batchFlag)
Date: 2026-07-16 (completed 2026-07-17)
Status: Review

## Objective
Add atomic batch variants of bindTag/activate/flag to TAGITCore for the admin assembly-line (bulk chip programming) and recall workflows.

## Plan (Approved: Yes — Artemus approved scope 2026-07-16: batchBind + batchActivate + batchFlag; batchRecycle/batchResolve deferred)
- [x] Step 1: Implement batchBind with single domain-separated oracle attestation
- [x] Step 2: Implement batchActivate (BOUND→ACTIVATED per production run)
- [x] Step 3: Implement batchFlag (recall; per-item circuit-breaker check preserved)
- [x] Step 4: Tests — 51 new (unit + fuzz + atomicity + breaker interaction + gas compare: batch 14.2% cheaper)
- [x] Step 5: slither (no new findings) + solidity-auditor (logic PASS; EIP-170 breach found→fixed) + full suite 1995/1995
- [ ] Step 6: PR, then UUPS implementation upgrade on Base Sepolia (FOUNDRY_PROFILE=deploy!) + registry update

## EIP-170 resolution (auditor finding)
Legacy codegen: 26,076 B (-1,500 vs limit) even after dedup refactor (_checkBindable/_applyBind/_activateOne/_flagOne shared by single+batch); runs=1 still -732. Resolution: `[profile.deploy]` via_ir=true → 22,601 B (+1,975). via-ir NOT global: solc CSE-caches block.timestamp across vm.warp → 13 time-dependent tests read stale time (2x-elapsed artifact; batch suite passes 51/51 via-ir). Pre-mainnet: warp-robust tests or external-library extraction.

## Files to Modify
- [x] `src/core/TAGITCore.sol` — 3 new external functions, EmptyBatch error, BATCH_BIND_DOMAIN constant (no storage layout changes — upgrade-safe)
- [ ] `test/unit/TAGITCoreBatchLifecycle.t.sol` — new test suite (agent in progress)

## Security Checklist
- [x] STRIDE: Spoofing → capability checks + oracle sig (batch digest incl. chainid+address(this) — stronger than single-bind digest); Tampering → any array mutation invalidates sig; Repudiation → per-token events unchanged (indexer-compatible); DoS → MAX_BATCH_SIZE=100 + per-item flag circuit breaker; Elevation → same capability gates as singles
- [x] ReentrancyGuard on all three
- [x] Checks-Effects-Interactions per item; batch-level checks first
- [x] Custom errors only (new: EmptyBatch)
- [x] Input validation: lengths, size cap, zero-hash, uniqueness incl. intra-batch
- [x] Events emit for all state changes (per token, same events as singles)

## Verification
- [x] `forge build` — clean
- [ ] `forge test` — full suite green (regression run done, checking; new tests pending)
- [ ] `forge coverage` — ≥85%
- [ ] `slither .` — 0 high/critical (auditor agent running)
- [ ] Gas: batch cheaper than N singles (target report in tests)

## Notes
- batchFlag deliberately calls _flagCircuitBreaker.check() per item — batching must not bypass NIST IR-4 mass-flag protection. Recalls >50/hr: raise threshold via setFlagCircuitBreakerThreshold or split.
- Digest spec (for services + admin hook parity): keccak256(abi.encode(keccak256("TAGIT_BATCH_BIND_V1"), block.chainid, address(this), tokenIds, tagHashes, responseHashes)), responseHashes[i]=keccak256(challengeResponses[i]), EIP-191 personal-sign.
- Single bindTag digest unchanged (no domain separation there) — parity kept for existing relayer; hardening it is a separate decision.

---
(Previous task HACK-T03 Paymaster deploy — COMPLETE 2026-03-02 — archived in git history of this file.)
