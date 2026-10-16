# `test/compliance/` — Digital Product Passport (DPP) on-chain conformance

Machine-checkable tests that assert the **on-chain** invariants an EU Digital Product Passport
depends on. They are the contract-layer slice of the broader conformance effort in
[`docs/compliance/`](../../docs/compliance/dpp-requirements-to-tests.md).

## What these tests DO and do NOT prove

- **DO:** prove that specific DPP invariants hold in `TAGITCore` (unique identifier, carrier↔twin
  binding, uniform passport resolution, immutable hash-linked provenance, tamper-evident anchor,
  terminal end-of-life, operator write-authorisation, no on-chain PII, soulbound-to-the-good).
- **DO NOT:** make TAG IT legally DPP-compliant. Conformance ≠ legal compliance, and nothing here is
  legal advice. Most DPP obligations are **off-chain** (data schema, GS1 URL, access tiers, durable
  persistence) and are not covered here — see the gap analysis. Report results as "conforms to the DPP
  data model", never "DPP-compliant".

## Coverage

| Test file | IDs | Invariant |
|---|---|---|
| `DPPIdentityCarrier.t.sol` | C-01/02/03 | unique identifier · carrier↔twin binding · uniform `tokenURI` |
| `DPPProvenanceIntegrity.t.sol` | C-04/05/06 | hash-linked custody chain · tamper-evident anchor · terminal recycle |
| `DPPAccessDataProtection.t.sol` | C-07/08/09 | capability-gated writes · no on-chain PII · soulbound token |
| `DPPComplianceBase.t.sol` | — | shared harness (mirrors `test/unit/TAGITCore.t.sol`) |

## Run

```bash
forge test --match-path "test/compliance/*" -vv
```

Use the **default** profile. Do **not** run with `FOUNDRY_PROFILE=deploy`: under via-ir solc
CSE-caches `block.timestamp` across `vm.warp`, which these tests do not need but the repo convention
keeps tests on legacy codegen. Forge's test EVM does not enforce EIP-170, so `TAGITCore` deploys fine
here without the deploy profile.

See [`dpp-requirements-to-tests.md`](../../docs/compliance/dpp-requirements-to-tests.md) for the full
requirement→test mapping and [`dpp-metadata-gap-analysis.md`](../../docs/compliance/dpp-metadata-gap-analysis.md)
for the off-chain gaps.
