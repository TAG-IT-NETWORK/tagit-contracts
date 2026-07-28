# Security Policy — tagit-contracts

**Repo:** `TAG-IT-NETWORK/tagit-contracts` (public)
**Contact:** security@tagit.network
**Last updated:** 2026-07-27

---

## Read this first

These contracts are **pre-mainnet**. Every deployment that exists today is on a testnet, holds
no real value, and is not treated by us as production. There is no mainnet deployment of any
contract in this repository on any chain — including OP Mainnet, which our older documentation
and our fork-test suite both incorrectly imply (see `KNOWN-ISSUES.md`, KI-06).

There is **no bug bounty program**. We do not pay for reports today, and we would rather say that
plainly than let a "security policy" heading imply otherwise. We will credit researchers who ask
to be credited, and we will tell you honestly what we did with your report. If a paid program is
launched before mainnet, this file is where it will be announced.

A **paid security audit by Hacken is in progress** (engagement starting the week of 2026-07-27).
Before it began we published `KNOWN-ISSUES.md` — 24 defects, gaps and weak controls that we found
ourselves and volunteered rather than let an auditor discover. Please read it before reporting;
a large share of what an external reviewer would find first is already in there, with severity,
evidence and reproduction commands.

---

## Scope

### In scope

**Source:** the 53 tracked Solidity files under `src/` at the current `main` HEAD.

**Live deployment:** Base Sepolia, chainId **84532** — the network marked `"status": "primary"`
in [`deployment-addresses.json`](./deployment-addresses.json). That file is the source of truth
for addresses; it was corrected and re-verified against chain on 2026-07-26. Twenty-seven
contract entries are listed for Base Sepolia, of which 13 are proxies verified against the live
EIP-1967 slots.

The addresses that most reports will concern:

| Contract | Address | Notes |
|---|---|---|
| `TAGITCore` (proxy) | `0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D` | UUPS |
| `TAGITCore` (implementation) | `0x2377B7f33aFf34c58DDF6DeA7eD4dCaD616CA14C` | read from the live EIP-1967 slot |
| `TimelockController` | `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1` | `getMinDelay()` returns **60** |
| Deployer EOA | `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` | holds PROPOSER + EXECUTOR, is `trustedOracle`, owns ~20 contracts |

The full list, including all proxy/implementation pairs, is in `deployment-addresses.json`.

**Also in scope:** deployment and upgrade scripts under `script/`, the CI workflows under
`.github/workflows/` insofar as they gate what reaches chain, and any secret or key material
committed to this repository.

### Not in scope

- **Archived deployments.** OP Sepolia (chainId 11155420) and Arbitrum Sepolia (chainId 421614)
  were deprecated on 2026-06-27 and are marked `"status": "archived"` in
  `deployment-addresses.json`. They are retained for historical reference only. We will not fix
  findings that exist solely on those chains. This includes the Gnosis Safe
  `0xAaA33C556C9c97a5430D180A1f72e8cf0fe0354e`, which has **no code on Base Sepolia** and exists
  only on archived OP Sepolia with `getThreshold() == 1` and the deployer EOA as sole owner. We
  do not claim it as a control; do not report it as one.
- **Findings whose only impact is loss of testnet value.** Draining faucet ETH, minting or
  burning valueless testnet tokens, or spending our testnet gas is not a finding on its own. If
  the same defect would move real funds on mainnet, report it — describe the mainnet impact and
  we will treat it on that basis.
- **Issues already listed in [`KNOWN-ISSUES.md`](./KNOWN-ISSUES.md).** KI-01 through KI-24 are
  known, written up, and being worked. A *new* exploitation path for a known issue, a materially
  worse impact than we assessed, or a working PoC for one we marked unconfirmed (KI-05) **is**
  in scope and is genuinely useful to us.
- **Third-party dependencies** under `lib/` (OpenZeppelin, account-abstraction, Chainlink CCIP)
  where the defect is upstream and unmodified. Report those upstream; tell us so we can pin or
  patch. Our *misuse* of a correct upstream primitive is in scope.
- **Off-chain systems.** The indexer, dashboard, mobile app, NFC bridge and backend services live
  in other repositories. Report those to the same address and say which system you mean, but they
  are not covered by this file.
- Automated scanner output with no manual triage, missing hardening headers on unrelated
  infrastructure, spam/social-engineering reports, and denial-of-service against public RPC
  endpoints we do not operate.

### Known scope gap — three files are outside the audit clone

Three production source files are **untracked** and therefore absent from a fresh clone of this
repository:

```
src/token/Voucher.sol
src/interfaces/IVoucher.sol
src/interfaces/IwTAG.sol
```

Verified 2026-07-27: no tracked file references them, and a fresh clone builds (`forge build`,
exit 0) without them. Two untracked test files (`test/token/Voucher.t.sol`,
`test/token/wTAG.t.sol`) are likewise absent. If you are reviewing a clone, you are not seeing
these files, and nothing you can see depends on them. `wTAG.sol` and `wTAGStaking.sol` **are**
tracked and **are** deployed. This is tracked as KI-15.

---

## Supported versions

The first tagged release is **`v0.1.0-audit`** (superseded by `v0.1.1-audit`), cut for this audit. There is otherwise no semantic versioning of this
repository today. The only artifacts we support are:

| Artifact | Status |
|---|---|
| `main` at current HEAD | Supported — fixes land here |
| Base Sepolia deployment (84532) | Supported — the live deployment under review |
| OP Sepolia (11155420), Arbitrum Sepolia (421614) | Archived, unsupported, will not be patched |
| Any prior commit or branch | Unsupported |

When a mainnet deployment exists, this table will name the specific deployed implementation
addresses that are supported, and this sentence will be replaced.

---

## How to report

Email **security@tagit.network**.

Do **not** open a public GitHub issue or pull request for a suspected vulnerability, and do not
disclose it in a public channel, chat or conference talk before we have agreed a date (see
timeline below).

We do **not** publish a PGP key today. If you need an encrypted channel, say so in a first
message containing no technical detail and we will establish one before you send the report.
We would rather receive a plaintext report than no report — for testnet-only contracts, use your
judgement.

### What to include

The more of this you can give us, the faster we can confirm and fix:

1. **Affected contract and address** — the file path in `src/`, and the on-chain address from
   `deployment-addresses.json` if a deployed instance is affected. Please state the chainId.
2. **The commit** you reviewed (`git rev-parse HEAD`), since we have no release tags.
3. **Impact** — what an attacker gets, who loses what, and under what preconditions. State the
   impact as it would apply to a *mainnet* deployment; testnet value is not the measure.
4. **Reproduction.** A Foundry test (`forge test --match-test ...`) or a `cast` transcript is
   ideal. A written attack path is acceptable if a PoC is impractical — say which it is. Please
   note whether you built under the default profile or `FOUNDRY_PROFILE=deploy`; the two produce
   different bytecode for `TAGITCore` and that difference is itself a known issue (KI-04).
5. **Suggested fix**, if you have one. Optional, and we will not treat the absence of one as a
   weaker report.
6. **How you want to be credited** — name, handle, organisation, or not at all.

If you are unsure whether something is a vulnerability, send it anyway and label it as uncertain.
We will not penalise a wrong guess.

---

## What happens next

These are commitments, not measurements. We are a small team; if we miss one of these windows we
will tell you we missed it rather than go quiet.

| Stage | Target | What it means |
|---|---|---|
| **Acknowledgement** | **within 72 hours** of receipt | A human confirms we have your report and gives you a tracking reference. Not a triage verdict. |
| **Initial triage** | within 7 calendar days | We reproduce it or tell you we could not, and give you our severity assessment with reasoning. If we disagree with your severity, we say why — you can push back. |
| **Fix or plan** | within 30 days for Critical/High; within 90 days for Medium/Low | Either a merged fix, or a written plan with a date. For a contract that is deployed, "fixed" means the upgrade or configuration change is executed on chain, not merged. |
| **Public disclosure** | by mutual agreement, default **90 days** after triage | Whichever comes first: fix deployed, or 90 days. We will not ask you to stay quiet indefinitely. If we need longer we will ask, explain why, and accept no for an answer. |

Because everything is pre-mainnet, our default is to disclose **early and in full** — a fixed
testnet bug published today is one less bug shipped to mainnet. If you want a longer embargo for
your own reasons (coordinated multi-project disclosure, a paper), tell us and we will hold.

We will add confirmed reports to `KNOWN-ISSUES.md` with attribution, unless you ask us not to.

---

## Safe harbour

If you make a good-faith effort to comply with this policy while researching a vulnerability in
the contracts and deployments listed above, we will:

- consider your research **authorised** under any anti-hacking or anti-circumvention law we could
  otherwise invoke (including but not limited to the CFAA and its non-US equivalents), and under
  the terms of service of any TAG IT Network property;
- not pursue or support civil or criminal action against you, and not report you to law
  enforcement, for that research;
- if a third party brings action against you for activity conducted under this policy, make it
  known publicly and to that third party that your actions were authorised.

"Good faith" means, concretely:

- You keep your testing on the **testnets in scope** (Base Sepolia, 84532). Do not test against
  any mainnet, and do not target systems belonging to other parties.
- You do not access, modify, exfiltrate or destroy data that is not yours, and you do not
  degrade a service for other users. Testnet gas exhaustion, spamming public RPC endpoints, and
  DoS of shared infrastructure are out of bounds.
- You take **only the minimum action needed to demonstrate the issue**. Prove you can move funds;
  do not move more than you must. If you obtain anything of value, return it.
- You do not use social engineering, phishing, or physical intrusion against TAG IT Network
  staff, users, or vendors, and you do not attempt to obtain credentials.
- You give us reasonable time to respond before disclosing, per the timeline above.

If you are unsure whether a specific action is in bounds, ask first at security@tagit.network.
We would rather answer a question than argue about it afterwards. Acting in good faith on a
mistaken belief about scope is not something we will treat as bad faith.

This safe harbour is not a waiver of rights against anyone acting in bad faith — extortion,
ransom demands, deliberate destruction of data, or exploiting a finding for gain rather than
reporting it are outside it entirely.

---

## What we already know about our own security posture

Reporting is more useful when you know where we stand. Summarised from `KNOWN-ISSUES.md`, all
measured:

- **Coverage is 63.82%** (CI-measured), against an 85% threshold that the Coverage Check workflow
  therefore fails on every run. A previously circulated 87% figure was **false**; the documents
  asserting it were deleted on 2026-07-26. If you see 87% anywhere, it is wrong — please tell us
  where so we can delete that too.
- **1,995 test functions, 0 failing** (1,840 of them tracked; 155 are in the two untracked test
  files above). Fuzz `runs = 100000`; invariant `runs = 256`, `depth = 500` (`foundry.toml`).
- **No fork or live-chain test passes.** `test/fork/ForkBase.t.sol:90` asserts
  `block.chainid == 10` (OP Mainnet, where we have never deployed) and line 56 pins
  `FORK_BLOCK = 125000000`. `.github/workflows/fork-test.yml` has failed 40 consecutive runs
  since 2026-06-17.
- **Formal verification is thin.** Halmos: 2 of 22 properties proven, 20 hit Z3 limits. Mythril:
  2 of 56 source files scanned. Both runs are from February 2026 and are stale.
- **`TAGITCore` is at the EIP-170 ceiling.** 26,076 bytes under the default profile — 1,500 bytes
  **over** the 24,576 limit — and 22,601 bytes under `FOUNDRY_PROFILE=deploy` (via-ir). Tests run
  legacy codegen; production ships via-ir. The tested bytecode is not the deployed bytecode
  (KI-04).
- **Privilege is concentrated.** One EOA holds PROPOSER and EXECUTOR on a timelock with a
  60-second minimum delay, is the trusted oracle, and owns roughly 20 contracts. The 2026-07-17
  core upgrade went from `schedule` to `execute` in 75 seconds. There is no functioning multisig
  on the primary chain (KI-01, KI-02).
- A prior **"850/1000 EVMbench security score" is withdrawn** — it was self-graded by our own
  tooling against our own code. Do not rely on it.

None of the above is a claim that anything else is safe. We publish no list of "issues we are
confident do not exist", because we do not have the evidence to make that claim.

---

## Reporting something that is not a contract vulnerability

- **Leaked key or credential in this repo or its history** — email security@tagit.network with
  the commit SHA and path. Treat it as urgent even though the chains are testnets; the same
  operator keys may be reused.
- **A documentation claim you believe is false** — please report it. We have found and withdrawn
  several of our own (the 87% coverage figure, the EVMbench score, a "6-of-8 multisig" that has
  one registered signer). Finding another one is a real contribution, and we would rather hear it
  from you than from an auditor's report.

---

*Related: [`KNOWN-ISSUES.md`](./KNOWN-ISSUES.md) — our own pre-audit disclosure.
[`deployment-addresses.json`](./deployment-addresses.json) — canonical, chain-verified addresses.*
