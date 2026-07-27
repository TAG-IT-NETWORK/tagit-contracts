# TAG IT Network — Smart Contracts

TAG IT Network binds physical objects to on-chain identities. A physical item is fitted with an NFC
tag; a hash of that tag is bound to an ERC-721 **digital twin** held in `TAGITCore`. From that point
the object's history — manufacture, tag binding, QA, sale, loss, recall, scrap — is a state machine
on chain rather than an assertion in someone's private database. Scanning the tag and reading the
twin is how a verifier answers "is this the real thing, and where has it been".

This repository holds the Solidity source, tests, deployment scripts and security artifacts for that
system.

---

## Status

**Pre-audit. Testnet only.**

- No TAG IT contract has been deployed to any mainnet.
- This code has **never** been audited by a third party. A paid engagement with Hacken is being
  scheduled; this branch exists to prepare the repository for it.
- Before reading anything else, read **[KNOWN-ISSUES.md](./KNOWN-ISSUES.md)**. It is a deliberate,
  volunteered disclosure of 24 defects and weak controls that we found ourselves — including
  several rated High. It also withdraws two previously circulated claims (an "850/1000 security
  score" and an "87% test coverage" figure) that were not supported by measurement.

If you find a number in this repository that contradicts `deployment-addresses.json` or
`KNOWN-ISSUES.md`, those two files win and the other document is stale. Please tell us where you
found it.

---

## The 7-state asset lifecycle

The state machine lives in `TAGITCore` (`src/core/TAGITCore.sol:52`).

| State | ID | Meaning |
| --- | --- | --- |
| `NONE` | 0 | Does not exist |
| `MINTED` | 1 | Twin exists, no physical tag bound |
| `BOUND` | 2 | NFC tag hash cryptographically linked to the twin |
| `ACTIVATED` | 3 | QA passed, released for distribution |
| `CLAIMED` | 4 | Held by an end owner |
| `FLAGGED` | 5 | Lost, stolen, or under recall |
| `RECYCLED` | 6 | End of life, terminal |

Permitted transitions:

```
NONE       -> MINTED                                   mint
MINTED     -> BOUND                                    bindTag
BOUND      -> ACTIVATED                                activate
ACTIVATED  -> CLAIMED                                  claim
CLAIMED    -> CLAIMED (new owner)                      transferAsset
{BOUND|ACTIVATED|CLAIMED} -> FLAGGED                   flag
FLAGGED    -> exact pre-flag state                     resolve
{MINTED|BOUND|ACTIVATED|CLAIMED|FLAGGED} -> RECYCLED   recycle
```

The only backward movement is recovery. `resolve()` restores the exact state recorded before
`flag()` (`_preFlagState`), so a `flag()` / `resolve()` round trip is state-neutral and cannot be
used to skip a forward transition or bypass a capability check.

**Transfers do not work the way an ERC-721 integrator will expect.** `TAGITCore._update`
(`src/core/TAGITCore.sol:1410`) reverts `TransferDisabled()` on every externally initiated transfer,
while `supportsInterface(0x80ac58cd)` still returns `true` on the live proxy. Ownership moves only
through `transferAsset` (`src/core/TAGITCore.sol:1285`). This breaks `OfferEscrow._settle` and
`TAGITAccount.exportAsset`, and neither breakage is caught by CI because both suites test against
mocks. Full write-up: KI-03 in [KNOWN-ISSUES.md](./KNOWN-ISSUES.md).

---

## Deployment

**[`deployment-addresses.json`](./deployment-addresses.json) is the single source of truth for
addresses.** It was re-derived from chain state on 2026-07-27; every address in it is canonical
EIP-55 and every Base Sepolia proxy was checked against the live EIP-1967 implementation slot. Do
not trust an address that appears anywhere else in this repo, in a broadcast file, or in a doc
without checking it against that file first.

| Network | chainId | Status in manifest |
| --- | --- | --- |
| **Base Sepolia** | 84532 | `"primary"` — the live deployment |
| OP Sepolia | 11155420 | `"archived"`, deprecated 2026-06-27 |
| Arbitrum Sepolia | 421614 | `"archived"`, deprecated 2026-06-27 |
| OP Mainnet | 10 | never deployed |

Base Sepolia carries 27 contract entries: 13 UUPS/ERC-1967 proxy pairs and 14 non-upgradeable
contracts. Principal entry points:

| Contract | Address |
| --- | --- |
| `TAGITCore` proxy | `0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D` |
| `TAGITCore` implementation | `0x2377B7f33aFf34c58DDF6DeA7eD4dCaD616CA14C` |
| `TAGITAccess` (BIDGES facade) | `0xb56A1D91995C212342FaA843468F03521340A1D6` |
| `TimelockController` (owner of `TAGITCore`) | `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1` |

### Privilege, stated plainly

The live control setup is weaker than earlier TAG IT documentation described, and an auditor should
know this before opening a single file:

- `TimelockController.getMinDelay()` returns **60 seconds**, not the 48 hours our deploy scripts'
  comments claim.
- The deployer EOA `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` holds both `PROPOSER_ROLE` and
  `EXECUTOR_ROLE` on that timelock, is `TAGITCore.trustedOracle`, and owns roughly 20 contracts
  outright. The 2026-07-17 core upgrade went from `schedule` to `execute` in 75 seconds.
- The Gnosis Safe referenced in older docs, `0xAaA33C556C9c97a5430D180A1f72e8cf0fe0354e`, has **no
  code on Base Sepolia**. It exists only on archived OP Sepolia, with `getThreshold() == 1` and the
  deployer EOA as sole owner.

Net effect: one private key can upgrade or drain the protocol within a minute. See KI-01 and
[`security/PRIVILEGE-MATRIX.md`](./security/PRIVILEGE-MATRIX.md).

---

## Architecture

56 Solidity files under `src/` in the maintainer's working tree — 53 in a fresh clone, because three
are untracked (see below). Grouped as follows.

| Group | Path | Contents |
| --- | --- | --- |
| Core | `src/core/` | `TAGITCore` — ERC-721 digital twins, tag binding, the 7-state machine, UUPS upgradeable. `TAGITCoreDemo` is a hackathon demo, untested and undeployed (KI-23). |
| Access (BIDGES) | `src/access/` | `IdentityBadge` (ERC-5192 soulbound identity), `CapabilityBadge` (ERC-1155 capability grants), `TAGITAccess` (facade every other contract queries for authorisation) |
| Token | `src/token/` | `TAGITToken`, `TAGITStaking`, `TAGITEmissions`, `TAGITBurner`, `TAGITVesting`, plus `wTAG` / `wTAGStaking` (Base-only wrapped token, ERC20Capped with a 3.33% cap and 7-day lockout) |
| Governance | `src/governance/` | `TAGITGovernor` over OpenZeppelin `TimelockController` |
| Treasury | `src/treasury/` | `TAGITTreasury` — fee custody, multi-signer emergency sweep, drain detection |
| Recovery | `src/recovery/` | `TAGITRecovery` — the AIRP lost/stolen/recall flow behind `flag` and `resolve` |
| Programs | `src/programs/` | `TAGITPrograms` — loyalty and reward allocations |
| Account abstraction | `src/account/` | `TAGITAccount`, `TAGITAccountFactory`, `TAGITPaymaster` (ERC-4337, EntryPoint v0.7) |
| Agent | `src/agent/` | `TAGITAgentIdentity` (ERC-8004), `TAGITAgentReputation`, `TAGITAgentValidation`, `ReputationStaking`, `IntegrationFactory` |
| Escrow | `src/escrow/` | `VerificationEscrow` (deployed), `OfferEscrow` (**not deployed**; cannot settle a TAG IT asset — KI-03) |
| Bridge | `src/bridge/` | `CCIPAdapter` — Chainlink CCIP cross-chain messaging |
| Robotics | `src/robot/` | `RoboticAuthorizer` — machine-actor action policy, zones, safety classes |
| Mirror | `src/mirror/` | `TAGITStateAnchor` (**not deployed**) |
| Libraries | `src/libraries/` | `CircuitBreaker`, `Constants`, `DrainDetector`, `RateLimiter`, `ReplayProtection`, `RobotTypes` |
| Interfaces | `src/interfaces/` | 20 interface files |

Contracts present in `src/` but absent from the Base Sepolia manifest: `OfferEscrow`,
`TAGITStateAnchor`, `TAGITCoreDemo`, `Voucher`.

**Three production source files are currently untracked by git** and therefore will not appear in a
fresh clone: `src/token/Voucher.sol`, `src/interfaces/IVoucher.sol`, `src/interfaces/IwTAG.sol`. No
tracked file references them and a fresh clone builds without them, but they exist on the
maintainer's machine and are excluded from the audit scope by accident rather than by decision. Two
test files (155 test functions) are untracked for the same reason. See KI-15.

### Dependencies

Pinned as git submodules under `lib/`:

| Library | Pin |
| --- | --- |
| `openzeppelin-contracts` | v5.0.0 |
| `openzeppelin-contracts-upgradeable` | v5.0.0 |
| `forge-std` | v1.12.0 |
| `account-abstraction` | `1c6b669` (v0.8.0-4) |
| `ccip` | `171f9f0` |
| `chainlink-local` | v0.2.7 |

---

## Build and test

Requires [Foundry](https://book.getfoundry.sh/). Verified against `forge 1.5.1-stable`.

```bash
git clone --recurse-submodules git@github.com:TAG-IT-NETWORK/tagit-contracts.git
cd tagit-contracts
cp .env.example .env        # fill in RPC URLs; never commit a real key

forge build                 # default profile, solc 0.8.28, optimizer 200 runs, via-ir off
forge test                  # full suite; fuzz runs = 100000, so this is slow
```

`.env.example` is out of date: it lists `OP_SEPOLIA_RPC_URL` and `ARBITRUM_SEPOLIA_RPC_URL` — both
archived chains — but not `BASE_SEPOLIA_RPC_URL` or `BASESCAN_API_KEY`, which `foundry.toml` needs
for the canonical chain. Add them by hand until we fix the template.

Faster loops:

```bash
forge test --match-path 'test/unit/*' --fuzz-runs 50     # 734 tests, ~40s
forge test --match-contract TAGITCore -vvv
forge test --gas-report
forge coverage --report summary --no-match-test 'gasEfficiency'
```

Fuzz and invariant settings are in `foundry.toml`: `[fuzz] runs = 100000`, `[invariant] runs = 256,
depth = 500, fail_on_revert = true`.

### Profiles — read this before deploying

`TAGITCore` **does not fit under the default profile.**

```
$ forge build --sizes | grep TAGITCore
TAGITCore    26,076 B runtime    margin -1,500 B     # 1,500 B over the EIP-170 limit of 24,576
```

Under `FOUNDRY_PROFILE=deploy` (which enables `via_ir`) it compiles to 22,601 B, leaving 1,975 B of
margin.

```bash
FOUNDRY_PROFILE=deploy forge build --sizes | grep TAGITCore
```

> **Every deploy or upgrade broadcast that touches `TAGITCore` MUST set `FOUNDRY_PROFILE=deploy`.**
> Without it the `CREATE` reverts with max-code-size-exceeded.

The test suite deliberately runs on legacy codegen, because under via-ir solc CSE-caches
`block.timestamp` across `vm.warp()` and 13 time-dependent tests then read stale time. That is a
test-harness artifact, not a contract defect — but the consequence is that **the bytecode CI
exercises is not the bytecode that ships.** This is a real gap and is written up as KI-04.

### Deploy

Deployment scripts live in `script/` and `script/deploy/`. `script/deploy/DeployBaseSepoliaFull.s.sol`
is the full-stack script for the canonical chain.

```bash
FOUNDRY_PROFILE=deploy forge script script/deploy/DeployBaseSepoliaFull.s.sol \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast --verify
```

Single-contract upgrades use `script/UpgradeTAGITCore.s.sol`, and the same profile rule applies.
After any deploy or upgrade, update `deployment-addresses.json` from chain state — reading the
EIP-1967 implementation slot, not from the broadcast log:

```bash
cast storage <PROXY> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
    --rpc-url https://sepolia.base.org
```

---

## What the tests do and do not cover

Stated as measured, on 2026-07-27. Where we have not measured something, it says so.

| | Value | Note |
| --- | --- | --- |
| Test files | 82 under `test/` | |
| Test functions | 1,995 total; 1,840 in tracked files | the other 155 are in two untracked files (KI-15) |
| Failing tests | 0 | default profile |
| Line coverage | **63.82%** | measured in CI against an 85% threshold, so `coverage-check.yml` fails on every run (KI-11) |
| Fork / live-chain tests | **none passing** | `test/fork/ForkBase.t.sol:90` asserts `block.chainid == 10` — OP Mainnet, a chain we have never deployed to — and pins `FORK_BLOCK = 125000000`. `fork-test.yml` has failed 40 consecutive runs since 2026-06-17 (KI-06) |
| Formal verification (Halmos) | 2 of 22 properties proven | the other 20 hit Z3 resource limits (KI-20) |
| Symbolic execution (Mythril) | 2 of 56 source files scanned | every HIGH was self-triaged as a false positive by us, not by an independent reviewer (KI-21) |
| Slither | run in CI | two detectors are globally excluded and the baseline predates 10 of the contracts now in `src/` (KI-13, KI-14) |
| Gas benchmarks | not measured for this release | `forge test --gas-report` produces them; `.gas-snapshot` is currently empty |

An earlier "87% coverage" figure circulated internally and in some documents. It was false. The
documents asserting it were deleted on 2026-07-26. The measured figure is 63.82%.

CI workflows are in `.github/workflows/`: `test.yml`, `security-gate.yml`, `security.yml`,
`coverage-check.yml`, `fork-test.yml`, `gitleaks.yml`.

---

## Security

| Document | What it is |
| --- | --- |
| [SECURITY.md](./SECURITY.md) | Vulnerability disclosure policy and contact |
| [AUDIT-SCOPE.md](./AUDIT-SCOPE.md) | What is in and out of scope for the Hacken engagement, with commit pins |
| [KNOWN-ISSUES.md](./KNOWN-ISSUES.md) | 24 self-disclosed defects and control gaps, KI-01 through KI-24 |
| [security/PRIVILEGE-MATRIX.md](./security/PRIVILEGE-MATRIX.md) | Every privileged role and who holds it on the live chain |
| [security/SECURITY-ANALYSIS-SUMMARY.md](./security/SECURITY-ANALYSIS-SUMMARY.md) | Static-analysis history |
| [security/reports/](./security/reports/) | Raw Slither output |

Do not report a vulnerability in a public GitHub issue. Follow [SECURITY.md](./SECURITY.md).

---

## License

MIT. Every Solidity file under `src/` carries `SPDX-License-Identifier: MIT` — all 56, no
exceptions:

```bash
grep -rL 'SPDX-License-Identifier: MIT' src --include='*.sol'   # returns nothing
```

There is no `LICENSE` file at the repository root as of this commit; the SPDX headers are the only
statement of licence. That is being fixed.

---

## Contributing and contact

This repository is public but development is currently closed while the audit is prepared — we are
not accepting feature pull requests until the Hacken engagement completes. Bug reports and
corrections are very welcome, especially corrections to anything in
[KNOWN-ISSUES.md](./KNOWN-ISSUES.md) or [`deployment-addresses.json`](./deployment-addresses.json).

- Issues: <https://github.com/TAG-IT-NETWORK/tagit-contracts/issues>
- Security: see [SECURITY.md](./SECURITY.md) — do not open a public issue
- Email: <dev@tagit.network>
