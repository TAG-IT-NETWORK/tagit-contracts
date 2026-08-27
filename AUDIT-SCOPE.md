# TAG IT Network — Smart Contract Audit Scope

**Prepared for:** Hacken
**Prepared by:** TAG IT Network engineering
**Date:** 2026-07-27
**Repository:** `https://github.com/TAG-IT-NETWORK/tagit-contracts` (public)
**Frozen commit for this engagement:** tag **`v0.1.0-audit`** on `main`
Resolve it to a SHA with `git rev-parse v0.1.0-audit`. The tag is annotated and will not be moved; if the scope has to change mid-engagement we will cut `v0.1.1-audit` and tell you, rather than re-pointing this one.
**Toolchain:** forge 1.5.1-stable (commit `b0a9dd9`), solc 0.8.28, optimizer on, `optimizer_runs = 200`

---

## 0. How to read this document

Three rules were applied while writing it, and we would like to be held to them:

1. **Every number here was measured, and the command that measured it is given.** Where a number could
   not be measured, the document says **not measured** and states the command that would settle it.
   Nothing is estimated and then presented as fact.
2. **Weaknesses are disclosed up front, in §5 and throughout.** This includes findings that reflect
   badly on us — a treasury that can never be upgraded, a 60-second timelock whose proposer is also
   its canceller, an access-control modifier that fails open when its controller is unset (latent
   today, reachable in one owner transaction — §3.2 states the precondition precisely), and a test
   suite that exercises different bytecode than production ships. We would rather hand you the list than have you bill us
   to rediscover it.
3. **A prior version of our audit-prep material claimed 87% test coverage. That figure was false.**
   The documents asserting it were deleted on 2026-07-27. The measured figure is **63.82%** (§5.2).
   If you find any surviving artifact in this repository restating 87%, treat it as stale and tell us
   — it is a documentation defect, not a disagreement.

Companion documents in this repository, all of which are in scope for your reading:

| Path | Contents |
|---|---|
| `security/PRIVILEGE-MATRIX.md` | Actor → role → function → live on-chain holder, verified at Base Sepolia block 44702050 |
| `KNOWN-ISSUES.md` | Running list of known defects |
| `security/SECURITY-ANALYSIS-SUMMARY.md`, `security/reports/slither-findings.md` | Prior static-analysis output (see §5.5 for its limits) |
| `deployment-addresses.json` | Canonical address manifest — the source of truth for §2 |

---

## 1. Commit and scope

### 1.1 What is being audited

The audit target is the tree at tag `v0.1.0-audit` on `main`. The clone you receive contains **53 tracked `.sol` files under `src/`**.
Reproduce the list with:

```bash
git ls-files 'src/**/*.sol'
```

Of those 53, **50 are in scope** and 3 are out (§1.4).

### 1.2 nSLOC methodology — read before pricing

`cloc` is **not installed** on the machine that produced these numbers. The nSLOC column below comes
from a local script that strips `/* … */` blocks, drops blank lines, and drops lines whose first token
is `//`. It is a home-grown approximation, not a `cloc` or `scc` figure.

**If you price on `cloc`, please re-run `cloc --by-file src/` and expect small deltas.** We will accept
your count. LOC is raw `wc -l`, comments and blanks included.

### 1.3 In-scope files (50)

Pattern legend — **UUPS**: `UUPSUpgradeable` implementation behind an ERC-1967 proxy. **ERC1967-frozen**:
behind an `ERC1967Proxy` but the implementation has *no* upgrade entrypoint (§5.6). **Immutable**:
constructor-initialized, non-upgradeable. **Clone target**: EIP-1167 minimal-proxy implementation
singleton. **Library**: `library`, inlined into callers. **Types file**: file-level `constant`/`enum`/
`struct` only, emits no bytecode. **Interface**: `interface`, no bytecode.

There are **zero** `abstract contract` declarations in `src/` (`grep -rn "^abstract contract" src/ | wc -l` → 0).

#### 1.3.1 Deployed contracts — 26 files, 13,616 LOC, 5,818 nSLOC

| # | Path | Contract | Purpose | LOC | nSLOC | Pattern |
|---|---|---|---|---:|---:|---|
| 1 | `src/access/CapabilityBadge.sol` | `CapabilityBadge` | Transferable ERC-1155 capability badges — WHAT an account may do | 221 | 63 | Immutable |
| 2 | `src/access/IdentityBadge.sol` | `IdentityBadge` | Soulbound ERC-721/ERC-5192 identity badges — WHO an account is | 237 | 61 | Immutable |
| 3 | `src/access/TAGITAccess.sol` | `TAGITAccess` | Facade unifying IdentityBadge + CapabilityBadge (BIDGES) | 208 | 47 | Immutable |
| 4 | `src/account/TAGITAccount.sol` | `TAGITAccount` | ERC-4337 smart wallet: session keys, guardians, self-custody | 606 | 349 | Clone target |
| 5 | `src/account/TAGITAccountFactory.sol` | `TAGITAccountFactory` | CREATE2 factory cloning `TAGITAccount` from an email hash | 335 | 162 | UUPS |
| 6 | `src/account/TAGITPaymaster.sol` | `TAGITPaymaster` | ERC-4337 paymaster: whitelisted selectors, rate limits, drain detection | 672 | 337 | UUPS |
| 7 | `src/agent/IntegrationFactory.sol` | `IntegrationFactory` | Partner onboarding; splits x402 payments protocol-fee/partner | 467 | 255 | Immutable |
| 8 | `src/agent/ReputationStaking.sol` | `ReputationStaking` | Agent credibility bond; slashable, withdrawable | 292 | 94 | Immutable |
| 9 | `src/agent/TAGITAgentIdentity.sol` | `TAGITAgentIdentity` | ERC-8004 agent identity; soulbound ERC-721, EIP-712 registration | 748 | 280 | Immutable |
| 10 | `src/agent/TAGITAgentReputation.sol` | `TAGITAgentReputation` | ERC-8004 reputation; time-weighted on-chain feedback | 470 | 186 | Immutable |
| 11 | `src/agent/TAGITAgentValidation.sol` | `TAGITAgentValidation` | ERC-8004 validation; multi-party proofs, 3-of-5 consensus | 511 | 222 | Immutable |
| 12 | `src/bridge/CCIPAdapter.sol` | `CCIPAdapter` | Chainlink CCIP send/receive for cross-chain verification | 780 | 428 | UUPS |
| 13 | `src/core/TAGITCore.sol` | `TAGITCore` | Digital-twin registry: ERC-721 + lifecycle FSM, BIDGES gating, rate limiter, circuit breaker | 1,636 | 519 | UUPS |
| 14 | `src/escrow/VerificationEscrow.sol` | `VerificationEscrow` | Holds USDC; releases on oracle ECDSA proof that state == BOUND | 333 | 137 | Immutable |
| 15 | `src/governance/TAGITGovernor.sol` | `TAGITGovernor` | OZ Governor + 5-house weighted voting, timelock control, pausable | 675 | 389 | UUPS |
| 16 | `src/programs/TAGITPrograms.sol` | `TAGITPrograms` | Scan-reward programs, reputation tiers, customs/recall hooks | 892 | 475 | UUPS |
| 17 | `src/recovery/TAGITRecovery.sol` | `TAGITRecovery` | AIRP disputes: bonded claims, badge-weighted voting, quarantine, 50% slashing, appeals | 885 | 372 | UUPS |
| 18 | `src/robot/RoboticAuthorizer.sol` | `RoboticAuthorizer` | NFC-guided robot↔object authorization; deny-wins bitmasks, zone proofs | 528 | 204 | UUPS |
| 19 | `src/token/TAGITBurner.sol` | `TAGITBurner` | Routes fees on a configurable burn/treasury split above a 3.33% floor | 265 | 93 | UUPS |
| 20 | `src/token/TAGITEmissions.sol` | `TAGITEmissions` | Weekly-epoch 3.33% annual inflation, permissionless trigger | 391 | 160 | UUPS |
| 21 | `src/token/TAGITStaking.sol` | `TAGITStaking` | Synthetix-style time-weighted staking rewards, rate-limited | 554 | 209 | UUPS |
| 22 | `src/token/TAGITToken.sol` | `TAGITToken` | ERC-20 + Votes + Permit + Burnable; mint restricted to `TAGITEmissions` | 274 | 98 | UUPS |
| 23 | `src/token/TAGITVesting.sol` | `TAGITVesting` | Cliff + linear vesting, immutable schedules | 264 | 98 | Immutable |
| 24 | `src/token/wTAG.sol` | `wTAG` | Wrapped TAGIT: ERC20Capped at 3.33% of genesis, 7-day post-TGE lockout, 1:1 | 293 | 95 | Immutable |
| 25 | `src/token/wTAGStaking.sol` | `wTAGStaking` | Accepts wTAG, unwraps, stakes into `TAGITStaking`, passes rewards through | 288 | 99 | Immutable |
| 26 | `src/treasury/TAGITTreasury.sol` | `TAGITTreasury` | Allocation budgets, timelocked withdrawal queue, drain detection | 791 | 386 | **ERC1967-frozen** (§5.6) |

#### 1.3.2 Libraries and types files — 6 files, 2,066 LOC, 775 nSLOC

These emit no standalone deployed bytecode; they are inlined into the contracts above. A bug here is a
bug in every caller simultaneously.

| Path | Symbol | Purpose | LOC | nSLOC | Inlined into (deployed) |
|---|---|---|---:|---:|---|
| `src/libraries/CircuitBreaker.sol` | `CircuitBreaker` | Threshold/time-window auto-pause on incident | 325 | 115 | `TAGITCore`, `TAGITRecovery`, `RoboticAuthorizer`, `TAGITPaymaster` |
| `src/libraries/Constants.sol` | *(file-level)* | Genesis supply, 3.33% inflation, burn floor, allocations, timelock bounds | 168 | 35 | 7 deployed contracts |
| `src/libraries/DrainDetector.sol` | `DrainDetector` | Spike / velocity / frequency outflow anomaly detection | 603 | 257 | `TAGITTreasury`, `TAGITPaymaster`, `TAGITPrograms` |
| `src/libraries/RateLimiter.sol` | `RateLimiter` | Per-user and global sliding-window rate limiting | 453 | 191 | `TAGITCore`, `TAGITStaking`, `TAGITRecovery`, `RoboticAuthorizer` |
| `src/libraries/ReplayProtection.sol` | `ReplayProtection` | Per-source-chain nonce / message-ID tracking | 407 | 144 | `CCIPAdapter` — sole replay defence on the bridge |
| `src/libraries/RobotTypes.sol` | *(file-level)* | Safety-class enum, action-policy struct, action/badge bitmasks | 110 | 33 | `RoboticAuthorizer` — encodes the deny-wins invariant |

#### 1.3.3 Interfaces — 18 files, 3,713 LOC, 902 nSLOC

No bytecode; imported by deployed contracts. They carry the structs, events and custom errors, so they
are load-bearing for ABI-level reasoning even though they compile to nothing.

`ICCIPAdapter.sol` (359/96) · `ICapabilityBadge.sol` (116/13) · `IIdentityBadge.sol` (137/16) ·
`IIntegrationFactory.sol` (276/77) · `IRecovery.sol` (288/88) · `IReputationStaking.sol` (116/23) ·
`IRoboticAuthorizer.sol` (97/37) · `ITAGITAccess.sol` (136/16) · `ITAGITAccount.sol` (309/73) ·
`ITAGITAccountFactory.sol` (150/28) · `ITAGITBurner.sol` (106/20) · `ITAGITEmissions.sol` (125/26) ·
`ITAGITGovernor.sol` (233/67) · `ITAGITPaymaster.sol` (273/62) · `ITAGITPrograms.sol` (377/103) ·
`ITAGITStaking.sol` (159/34) · `ITAGITTreasury.sol` (331/94) · `ITAGITVesting.sol` (125/29)
— all under `src/interfaces/`, shown as `(LOC/nSLOC)`.

### 1.4 Scope totals

| Group | Files | LOC (`wc -l`) | nSLOC (script, **not** `cloc`) |
|---|---:|---:|---:|
| Deployed contracts | 26 | 13,616 | 5,818 |
| Libraries + types files (inlined) | 6 | 2,066 | 775 |
| Interfaces (no bytecode) | 18 | 3,713 | 902 |
| **IN SCOPE — total** | **50** | **19,395** | **7,495** |
| **IN SCOPE — excluding interfaces** | **32** | **15,682** | **6,593** |
| Out of scope (`TAGITCoreDemo`, `TAGITStateAnchor`, `OfferEscrow`) | 3 | 469 | 306 |
| All tracked `src/` | 53 | 19,864 | 7,801 |

The partition is exhaustive and non-overlapping — each of the 53 tracked files appears in exactly one
group; this was asserted programmatically, not by eye.

**Please tell us which convention you price on before we sign the SOW.** The gap between including and
excluding interfaces is 902 nSLOC (18 files). We are not trying to steer the answer; we would rather
agree the number now than argue about it later.

### 1.5 Explicitly OUT OF SCOPE

| Item | Files | Why out |
|---|---|---|
| `src/core/TAGITCoreDemo.sol` | 1 (73 LOC / 57 nSLOC) | Hackathon demo lifecycle contract with `onlyAdmin` access control. Only ever broadcast to Arbitrum Sepolia, which is archived. Absent from the Base Sepolia manifest. Not production. |
| `src/mirror/TAGITStateAnchor.sol` | 1 (132 LOC / 56 nSLOC) | No instance in the manifest and no broadcast record on any chain. `script/deploy/DeployStateAnchor.s.sol` has never been run. |
| `src/escrow/OfferEscrow.sol` | 1 (264 LOC / 193 nSLOC) | **Contested — see §5.9.** Not deployed anywhere, not imported by any deployed contract, so it is out by the stated rule. By risk it is arguably the file that most needs review. We want your opinion on whether to pull it in. |
| `test/` | 80 tracked `.sol` | Test harness. Includes `test/mocks/TAGITCoreV2Mock.sol`, `test/mocks/GnosisSafeMock.sol`, and ~20 inline mocks (`MockEntryPoint`, `MockRouter`, `MockBurner`, …). None deployed. |
| `script/` | 21 tracked `.sol` | Deploy/upgrade scripts. Not deployed contracts. Note they *are* the mechanism by which the deployment defects in §5.6 happened, so reading `script/deploy/DeployBaseSepoliaFull.s.sol` may be worth your time even though it is out of scope for findings. |
| `lib/` | 6 git submodules | Third-party dependencies, unmodified (§3.4). Pins are in scope for *version-advisory* review; the sources are not in scope for line-by-line review. |
| **3 untracked production sources** | 3 | See immediately below. |

**The three untracked files — stated plainly rather than buried:**

`src/token/Voucher.sol`, `src/interfaces/IVoucher.sol` and `src/interfaces/IwTAG.sol` exist on the
developer's disk but are **not tracked by git**, so they will not be in the clone you receive. That is
a 56-files-on-disk vs 53-files-in-git delta.

They are an **unfinished voucher feature that was never completed, never deployed, and never
integrated**. We verified before writing this:

- No tracked file references any of the three (`grep -rn "Voucher\|IwTAG" $(git ls-files 'src/**/*.sol')` → no import hits).
- A fresh clone builds with exit code 0 without them.
- Neither `Voucher` nor any voucher address appears in `deployment-addresses.json` or in `broadcast/`.

They are excluded from every LOC/nSLOC total above. We are disclosing them so that the difference
between `find src -name '*.sol'` (56) and `git ls-files 'src/**/*.sol'` (53) does not look like
concealment. If you want them in scope, say so and we will commit them — but they are not production
code today.

Related housekeeping: `src/core;C` is an empty untracked directory created 2026-03-25 by a shell-quoting
accident. It contains nothing. It is being deleted before handover; if you see it in a `tree`, that is
what it is.

---

## 2. Deployment

### 2.1 One live network, and only one

**Base Sepolia, chainId 84532.** `deployment-addresses.json` marks it `"status": "primary"`.

| Network | chainId | Status | Note |
|---|---:|---|---|
| **Base Sepolia** | **84532** | **primary** | The only live deployment. Everything in this document refers to it. |
| OP Sepolia | 11155420 | archived | Deprecated 2026-06-27. Do not audit against it. |
| Arbitrum Sepolia | 421614 | archived | Deprecated 2026-06-27. |
| OP Mainnet | 10 | **never deployed** | Referenced by dead fork-test code (§5.4). No contract of ours has ever existed there. |

No mainnet deployment of any kind exists. This is a pre-mainnet audit.

Chain-level configuration (from `deployment-addresses.json → networks["base-sepolia"].configuration`):

| Key | Value |
|---|---|
| Deployer EOA | `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` |
| `TAGITCore.owner` | `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1` (TimelockController) |
| `TAGITCore.accessController` | `0xb56A1D91995C212342FaA843468F03521340A1D6` (TAGITAccess) |
| `TAGITCore.trustedOracle` | `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` (the deployer EOA) |
| `TimelockController.delay` | **60 seconds** (`getMinDelay()` live read) |
| ERC-4337 EntryPoint | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (canonical v0.7) |
| CCIP Router | `0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93` |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Manifest `startBlock` | 39611546 |

### 2.2 Proxy → implementation map (13 proxies)

**All 13 proxies were read against their live EIP-1967 implementation slots on 2026-07-27 and match the
values below.** The manifest was corrected the same day: the `TAGITCore` implementation had been
recorded incorrectly and is now the value read from chain. Every address in `deployment-addresses.json`
is now canonical EIP-55.

| Contract | Proxy | Implementation | Proxy kind |
|---|---|---|---|
| TAGITCore | `0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D` | `0x2377B7f33aFf34c58DDF6DeA7eD4dCaD616CA14C` | UUPS |
| TAGITToken | `0x5f98B83cD7Aef769cc51D2FB739BA49D561170DE` | `0xA412b5C203F74e88F434C405E694528f04CaCf59` | UUPS |
| TAGITStaking | `0xB22F5688559D07e3a12DBB89f0481b967407F267` | `0x06861990fD9EDA0d47c8f005b09ddA502977b2Ef` | UUPS |
| TAGITGovernor | `0xCF67DF870EccBB7838c3ab7876467c89d84dce89` | `0x1FB00D79E6Baff059E1C5FA034e4D59b766E0D44` | UUPS |
| TAGITTreasury | `0xa4a3720d705334f409DD24836CC75d642125f759` | `0x3837A9bFc98F624bE5587a7F10980Cca5f68c4C8` | ERC-1967, **no upgrade entrypoint** (§5.6) |
| TAGITRecovery | `0x6BC3C69367E586810A3B317fA9F0406504e95866` | `0xE2f49Bb534894F83421cbd18E747039F3866E14f` | UUPS |
| TAGITPrograms | `0x62a3CF048E66BE0119F0ccD97Ec964B726B9a982` | `0x26D0B3B5FF2061fB38ce1aA66433a8F4439e46a8` | UUPS |
| TAGITPaymaster | `0x6fFFa92efb419E812d5c9C9D0c1B1a0f5c6fFd1C` | `0x4609a869a813E7E596bF5Bf5cBC08F8092Ce6340` | UUPS |
| TAGITAccountFactory | `0x3ed2c0E92F0e52dC68d04172aD37df4724893aD3` | `0x6122B891f27bd1C492664c6Ca1527E988A5cF8Fa` | UUPS |
| CCIPAdapter | `0x5e190F6Ebde4BD1e11a5566a1e81a933cdDf3505` | `0x26F2EBb84664EF1eF8554e15777EBEc6611256A6` | UUPS |
| RoboticAuthorizer | `0x5C38684d87e826589Ec5Ed401D94C9671caE9f40` | `0x95f35F612EE3e3F188FEf0aa272458C5d44169ED` | UUPS |
| TAGITEmissions | `0x0672fcC5b753786C2cD1805494fF094CB5d6E579` | `0x11D1EAB20030092577f23e0939c6Cbc0d9124e8A` | UUPS |
| TAGITBurner | `0xCB8AbCe0770C499B789481F8c6C20Fa0d6980d2a` | `0x6811e98Bdd40A45Cc325C8553F146945bA53E17F` | UUPS |

### 2.3 Non-proxied deployments

| Contract | Address | Note |
|---|---|---|
| IdentityBadge | `0xebdAC9A0663c02a7297681b078aaD893EF345030` | ERC-5192 soulbound |
| CapabilityBadge | `0xb05d22706B08A3F6409601de520cf7A6dbCB573d` | ERC-1155 — **transferable**, see §5.7 |
| TAGITAccess | `0xb56A1D91995C212342FaA843468F03521340A1D6` | BIDGES facade |
| TimelockController | `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1` | OpenZeppelin, unmodified. `getMinDelay() == 60` |
| TAGITAccount (singleton) | `0x2160044C7c46B08a552361595E09e8C8DDD06E85` | EIP-1167 clone target; `owner()` is `0x0` (§5.8) |
| TAGITAgentIdentity | `0x0611FE60f6E37230bDaf04c5F2Ac2dc9012130a9` | ERC-8004 |
| TAGITAgentReputation | `0x32be6C82A57d5bCe897538d7dA4109eA0eeB0aA1` | ERC-8004 |
| TAGITAgentValidation | `0x34766dBa7040C2c8817f1Ee1e448209826DD607e` | ERC-8004 |
| TAGITVesting | `0x7dd4c98a2aFE60eE06bA5c136dBeb7f93DD2699D` | Immutable schedules |
| IntegrationFactory | `0xd68919371c26700dDb8252aD1825Aa02a0381a86` | "1-of-3 multisig" — see §4.4 |
| wTAG | `0x746385e59aCB225779D64e74200e464a3f1C23d0` | Base only |
| wTAGStaking | `0xBd4c4848C9fF09B7955a193E3b96456344D9acBe` | Base only |
| VerificationEscrow | `0x4c9aACfcb64169E3BC187c227c4C0e0a5CFDA1cF` | Custodies USDC; deploy block 39003336 |
| ReputationStaking | `0x4154af74DA2B3a98096317100296966Ade15574A` | Holds user stake; deploy block 43463277 |

That is **27 deployed contracts** in the trust path (26 from `src/` plus the OpenZeppelin
`TimelockController`).

### 2.4 The Gnosis Safe does not exist on the live chain

Older documentation in this repository refers to a Gnosis Safe at
`0xAaA33C556C9c97a5430D180A1f72e8cf0fe0354e` as an admin. **That address has no code on Base Sepolia.**
It exists only on archived OP Sepolia, where `getThreshold() == 1` and its sole owner is the deployer
EOA. There is no multisig protecting the live deployment. Please do not credit any statement that says
otherwise.

### 2.5 A manifest defect we are fixing but had not fixed when this was written

`networks["base-sepolia"].note` still contains the stale prose:
`"TAGITCore implementation upgraded 2026-05-30 to 0xA7f34FD595eBc397Fe04DcE012dbcf0fbbD2A78D"`.
That address is **not** the current implementation — it is in fact the OP Sepolia `TAGITAgentIdentity`
address. The structured `implementation` field is correct and chain-verified; the prose note is wrong.
If it is still present in your clone, ignore the note and trust the structured field.

---

## 3. Architecture and trust model

### 3.1 The asset lifecycle — 7 states

`TAGITCore` is an ERC-721 registry of physical-object digital twins. Each token carries a `State`
(`src/core/TAGITCore.sol:52-59`), packed with the owner and timestamp into a single 32-byte slot:

| Value | State | Meaning |
|---:|---|---|
| 0 | `NONE` | Not created |
| 1 | `MINTED` | NFT exists, no NFC tag bound |
| 2 | `BOUND` | Tag cryptographically linked to the token |
| 3 | `ACTIVATED` | QA passed, ready for distribution |
| 4 | `CLAIMED` | Owned by an end consumer |
| 5 | `FLAGGED` | Lost / stolen / recall initiated |
| 6 | `RECYCLED` | End of life, permanently retired — terminal, no outbound transitions |

The intended graph is forward-only — `NONE → MINTED → BOUND → ACTIVATED → CLAIMED` — with two
exceptions we want you to attack specifically:

- **`FLAGGED → CLAIMED`** via `resolve()`, the recovery path (`RESOLVE_QUORUM = 2`, a 2-of-3 resolver
  quorum). `TAGITCore.sol:439-441` documents a backward-compatibility branch: tokens flagged before the
  lifecycle-FSM upgrade have no recorded pre-flag state, and `resolve()` **defaults those to `CLAIMED`**.
  That default is a guess about history baked into live code. It is exactly the kind of thing we want
  challenged.
- **`→ RECYCLED`** from several states, which is terminal and irreversible.

Binding (`bindTag`) and batch binding are gated on an ECDSA signature from `trustedOracle`
(`TAGITCore.sol:705-709`, `:807-816`). Batch attestations are domain-separated with
`BATCH_BIND_DOMAIN = keccak256("TAGIT_BATCH_BIND_V1")` to prevent cross-chain / cross-deployment replay.
`MAX_BATCH_SIZE = 100`.

### 3.2 BIDGES — the access-control model

BIDGES splits authorization in two:

- **`IdentityBadge`** (ERC-721 + ERC-5192 soulbound) — *who you are*. Non-transferable, correctly
  enforced.
- **`CapabilityBadge`** (ERC-1155) — *what you may do*. **Transferable. There is no soulbound guard and
  no `_update` override.** Privileges are bearer assets. See §5.7.
- **`TAGITAccess`** — the facade `TAGITCore.accessController` points at. `requireCapability()` is the
  single chokepoint.

Capability IDs in production are `uint256(keccak256("MINTER"))` and friends
(`TAGITCore.sol:71-79`): `MINTER`, `BINDER`, `ACTIVATOR`, `CLAIMER`, `FLAGGER`, `RESOLVER`, `RECYCLER`,
`VIEWER`, `AUDITOR`.

**Two disclosures about BIDGES. Both were checked against chain state; read each for whether it describes a live condition or a reachable one:**

1. **`requiresCapability` fails open — latent, not currently active.** `TAGITCore.sol:550-557` skips the
   capability check entirely when `accessController == address(0)`, and `setAccessController` (`:537`)
   accepts `address(0)` with no zero-address guard. The in-code comment calls this
   "backward compatibility."

   **On-chain state, checked 2026-07-28:** `accessController()` returns
   `0xb56A1D91995C212342FaA843468F03521340A1D6` (TAGITAccess) — **non-zero, so the bypass branch is
   not being taken today.** We are disclosing a reachable condition, not a live bypass. The exposure
   is that reaching it costs exactly one `onlyOwner` transaction, and `TAGITCore`'s owner is the
   Timelock whose `minDelay` is 60 seconds and whose PROPOSER, EXECUTOR and CANCELLER are all the
   same EOA (§4). So: one key, ~60 seconds, and mint / bind / activate / claim / flag / resolve /
   recycle become permissionless — with no second party able to cancel. We would rather state the
   precondition precisely than let the phrase "fails open" imply the system is open right now.
2. **The capability IDs documented in `CLAUDE.md` are not the ones in production.** `CLAUDE.md:384-391`
   documents numeric IDs 100–108; `balanceOf(deployer, 100..108)` is 0 across the board. The keccak IDs
   above are what is actually used. `CLAUDE.md` is wrong; `security/PRIVILEGE-MATRIX.md` §5.2 records
   this as a defect. Trust the code.

Identity badge IDs additionally **collide across contracts**: ID 1 is simultaneously `ADMIN_BADGE` and
`KYC_L1_IDENTITY` (three separate agent contracts read it); ID 10 is `BADGE_MANUFACTURER` in
`RobotTypes`, `TAGITGovernor` and `TAGITPrograms`; ID 20 is `BADGE_GOV_MIL` in `RobotTypes` and
`TAGITGovernor`; ID 30 is simultaneously `BADGE_CHEF_BOT` (`RobotTypes`) and `BADGE_DEV`
(`TAGITGovernor`); `TAGITPrograms` uses yet another numbering scheme (50/51/60). The single live
`grantIdentity(deployer, 1)` therefore conferred several unrelated privileges at once. This is a
namespace design flaw, not a one-off mistake, and we would like a recommendation on it.

`TAGITRecovery` **used to be part of this collision** — its juror ids were 1/2/10/20, which was inert
while the lookup read the transferable `CapabilityBadge` (nobody holds capability ids 1/2/10/20) but
became live the moment KI-25 correctly moved the lookup to the soulbound `IdentityBadge`, silently
making every KYC'd account an AIRP juror. It now uses a dedicated, documented **70-79** range
(`BADGE_AIRP_JUROR` 70, `BADGE_AIRP_SENIOR_JUROR` 71, `BADGE_AIRP_ARBITER` 72, `BADGE_AIRP_TRIBUNAL`
73) that collides with nothing; the registry-wide allocation table now lives in
`src/access/IdentityBadge.sol`. That is one contract removed from the collision, not a fix for the
namespace design — the rest of §3.2 still stands.

### 3.3 Upgradeability

| Mechanism | Count | Authorization |
|---|---:|---|
| UUPS behind ERC-1967, `_authorizeUpgrade` = `onlyOwner`, owner = deployer EOA, **no timelock** | 11 | Single EOA, one transaction |
| UUPS behind ERC-1967, `_authorizeUpgrade` = `onlyOwner`, owner = TimelockController (`TAGITCore` only) | 1 | 60-second timelock whose sole PROPOSER/EXECUTOR/CANCELLER is the same EOA |
| ERC-1967 proxy with **no upgrade entrypoint at all** (`TAGITTreasury`) | 1 | **None. Permanently frozen.** (§5.6) |
| Non-upgradeable by design | 14 | n/a |

`TAGITGovernor` holds **no role on the TimelockController** — PROPOSER, EXECUTOR and CANCELLER all
return `false` for it — while `Governor.timelock()` returns that timelock's address. On-chain governance
output therefore cannot currently be queued or executed. The DAO is decorative until this is fixed.

### 3.4 External dependencies

Six git submodules. Pins verified with `git submodule status` plus per-submodule
`git rev-parse HEAD` and `git describe --tags`.

| Path | Upstream | Pinned commit | Version at that commit | HEAD on an exact tag? |
|---|---|---|---|---|
| `lib/openzeppelin-contracts` | OpenZeppelin/openzeppelin-contracts | `932fddf69a699a9a80fd2396fd1a2ab91cdda123` | **v5.0.0** | yes |
| `lib/openzeppelin-contracts-upgradeable` | OpenZeppelin/openzeppelin-contracts-upgradeable | `625fb3c2b2696f1747ba2e72d1e1113066e6c177` | **v5.0.0** | yes |
| `lib/account-abstraction` | eth-infinitism/account-abstraction | `1c6b669d0eea734e09a87e095ba15e076151718a` | **v0.9.0 + 1 commit**; `package.json` = `0.9.0` | **no** |
| `lib/ccip` | smartcontractkit/ccip | `171f9f0cf249765116e3131b61f5b4157566f25f` | `contracts-ccip/v1.5.0-beta.0` **+ 674 commits** | **no** |
| `lib/chainlink-local` | smartcontractkit/chainlink-local | `a3ace4e17336e84c4d1261f2da45d5e8963af714` | **v0.2.7** | yes |
| `lib/forge-std` | foundry-rs/forge-std | `7117c90c8cf6c68e5acce4f09a6b24715cea4de6` | **v1.12.0** | yes |

Notes we expect you to care about:

- **OpenZeppelin is v5.0.0** — the initial v5 release, not v5.0.2 / v5.1.x / v5.4.x. Please check it
  against the published advisories for the v5.0.x line; we have not done that systematically.
- **`git submodule status` mis-describes `account-abstraction` as `v0.8.0-4-g1c6b669`.** That is a
  `git describe` tag-selection artifact. Authoritative: `v0.9.0..HEAD` = 1 commit, `package.json`
  version `0.9.0`. Use **v0.9.0+1**.
- **`lib/ccip` is pinned but not compiled.** The remapping is
  `@chainlink/ccip/=lib/chainlink-local/lib/chainlink-ccip/chains/evm/contracts/` — CCIP sources arrive
  through `chainlink-local`'s nested submodule. `lib/ccip` is inert dead weight (1,820 dirty working-tree
  entries). It is being removed before handover; if it is still there, it compiles nothing.
- **No library source has been locally patched.** `git status` shows all six submodules dirty, which
  looks alarming. We checked: `git -C lib/<m> diff --numstat | grep '\.sol$'` returns **0 for all six**.
  The only real diffs are nested-submodule gitlink pointers, all outside the remapping paths. The pinned
  library bytecode is pristine. Please verify this yourself rather than taking our word for it.
- **ERC-4337 version mismatch — open question, not measured.** `src/account/TAGITAccount.sol:58`
  documents the EntryPoint as canonical **v0.7**, and the configured EntryPoint
  `0x0000000071727De22E5E9d8BAf0edAc6f37da032` is the v0.7 singleton — but the submodule is pinned at
  **v0.9.0+1**. Whether the v0.9 `PackedUserOperation` / `IEntryPoint` / `IPaymaster` definitions the
  code compiles against are wire-compatible with the v0.7 EntryPoint at that address is **not measured**.
  Settling it needs a live fork test against the deployed EntryPoint, and we have no passing fork tests
  (§5.4). We flag it rather than assert either way. This is on our list of questions in §6.

Full remapping set (`foundry.toml`):

```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
@forge-std/=lib/forge-std/src/
@account-abstraction/=lib/account-abstraction/contracts/
@chainlink/ccip/=lib/chainlink-local/lib/chainlink-ccip/chains/evm/contracts/
```

---

## 4. Privilege matrix

Full detail, including the reproduction commands for every value, is in
**`security/PRIVILEGE-MATRIX.md`** (verified live at Base Sepolia block 44702050). Summary below.

### 4.1 Actors

| Label | Address | What it is |
|---|---|---|
| **A1** | `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` | Deployer EOA. A single private key. |
| **A2** | `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1` | TimelockController, `getMinDelay() == 60 s` |
| A3 | `0xCF67DF870EccBB7838c3ab7876467c89d84dce89` | TAGITGovernor proxy — holds no timelock role |
| A4 | `0xb56A1D91995C212342FaA843468F03521340A1D6` | TAGITAccess (BIDGES facade) |

### 4.2 Concentration — the headline finding

**A1 is the effective root of the entire live deployment.**

- `owner() == A1` on **22 of the 27** deployed contracts.
- Of the other five: `TAGITTreasury` has no `owner()` but `governor() == A1`; `wTAG` has no `owner()`
  but `DEFAULT_ADMIN_ROLE` and `MINTER_ROLE` are A1; `TimelockController` self-administers but A1 is its
  sole PROPOSER **and** EXECUTOR **and** CANCELLER; `TAGITAccount` is an uninitialised singleton;
  and `TAGITCore` — the one contract owned by the timelock — is reachable by A1 in 60 seconds.
- **24 of 27 contracts are under sole EOA control with no delay at all.** The 25th has a 60-second delay.
- **11 of the 12 UUPS contracts upgrade on a bare `onlyOwner`, with no timelock in the path.**
- A1 holds both PROPOSER and CANCELLER on the timelock, so the only party who could veto a malicious
  proposal is the party making it. The 2026-07-17 core upgrade went `schedule` → `execute` in **75
  seconds**, which is the practical demonstration.

If A1's key is compromised, an attacker owns the protocol outright within one block for 24 contracts and
within ~60 seconds for the 25th. **There is no key that stops them.** We are not asking you to be gentle
about this; we are asking for the concrete remediation design.

### 4.3 Role separations that should exist and do not

Every row is one EOA holding both sides of a check designed for two parties. All verified on chain.

| Split that should exist | Reality |
|---|---|
| Timelock proposer ≠ canceller | A1 is both. Nobody can veto A1. |
| Timelock proposer ≠ executor | A1 is both. `schedule` → `execute` is one actor. |
| Contract owner ≠ capability holder | A1 owns `CapabilityBadge` **and** holds MINTER / BINDER / ACTIVATOR / CLAIMER / FLAGGER / RESOLVER / RECYCLER. |
| Oracle signer ≠ tag binder | A1 is `trustedOracle` **and** holds `BINDER_CAPABILITY`. `bindTag` verifies a signature from the same key that sends the transaction. |
| Governor ≠ guardian | `TAGITGovernor.owner() == guardian() == A1`. The emergency pauser is the entity being guarded against. |
| Treasury governor ≠ treasury signer | A1 is `governor()`, `isSigner(A1) == true`, and `setSigner` is `onlyGovernor`. |
| Upgrade authority ≠ operator | A1 is the `onlyOwner` upgrade authority on 11 of 12 UUPS contracts *and* their day-to-day operator. The 12th resolves to the timelock A1 controls. |
| DAO ≠ deployer | `TAGITGovernor` holds no timelock role; DAO output is unexecutable. A1 is the only executor. |

### 4.4 Neither "multisig" is a multisig

- **`IntegrationFactory`**: `requiredSignatures()` returns **1**. Signers 2 and 3 are addresses derived
  from `keccak256(deployer, 1)` and `keccak256(deployer, 2)` — **nobody holds their private keys**
  (recomputed independently; they match `getSigners()` exactly). `removeSigner` reverts at `MIN_SIGNERS`,
  so they cannot be cleared either.
- **`TAGITTreasury`**: `requiredSigners()` returns **6** but the contract was initialised with one
  signer, so **`emergencySweep` is currently uncallable**. The treasury's emergency exit is dead. Combined
  with §5.6 (no upgrade path), the treasury has neither a patch route nor a working escape hatch.

### 4.5 Emergency powers, per contract

| Contract | Pause / halt | Notes |
|---|---|---|
| **TAGITCore** | **none — `pause()` does not exist** | `grep -c pause src/core/TAGITCore.sol` → 0. Not `Pausable`. `paused()` reverts. The flagship registry cannot be halted; the only lever is an upgrade through the 60-second timelock. |
| TAGITTreasury | `PausableUpgradeable` | `emergencySweep` uncallable (§4.4) |
| TAGITGovernor, TAGITPaymaster, TAGITPrograms, TAGITRecovery, CCIPAdapter, RoboticAuthorizer, wTAGStaking | pausable | Pauser is A1 in each case |

`CircuitBreaker` (auto-pause on threshold/velocity) is inlined into `TAGITCore`, `TAGITRecovery`,
`RoboticAuthorizer` and `TAGITPaymaster`, and `DrainDetector` into `TAGITTreasury`, `TAGITPaymaster` and
`TAGITPrograms`. Whether those library-level breakers actually arrest an attack in `TAGITCore` — which
has no `pause()` of its own — is a question we would like answered.

### 4.6 Two further verified oddities

- **An unexplained grant.** A1 holds identity badge **ID 10** on chain. We decoded every `grantIdentity`
  call (selector `0xbe963869`) in all `broadcast/**/84532/` artifacts: every one of them grants ID 1.
  **ID 10 has no provenance in this repository.** We do not know how it was granted. We are telling you
  rather than quietly revoking it.
- **`RESOLVER` capability balance is 2, not 1.** A single `revokeCapability` call would therefore not
  actually revoke it — an operational trap in the ERC-1155 capability model.

### 4.7 What the privilege review could not verify

`security/PRIVILEGE-MATRIX.md` §8 lists these plainly. The main one: **exhaustive enumeration of
timelock role holders and badge holders was attempted and not completed**, because
`https://sepolia.base.org` caps `eth_getLogs` at 2000 blocks — 2,546 requests were needed and the
endpoint rate-limited to failure. The values reported above are direct `hasRole` / `balanceOf` reads for
*known* addresses; there could be additional holders we have not enumerated. The archive-RPC command
that would settle it is given in that document. **Please treat the holder lists as "at least these",
not "exactly these".**

---

## 5. Known limitations, disclosed up front

Everything in this section is a weakness. None of it was discovered by an auditor; we are handing it
over so that your time goes to what we could not find ourselves.

### 5.1 The bytecode you review is not the bytecode our tests exercise

`TAGITCore` is **26,076 bytes** under the default profile — **1,500 bytes OVER the EIP-170 24,576-byte
runtime limit**. It only fits via IR-based codegen:

| Contract | Default (legacy) runtime | Margin | `FOUNDRY_PROFILE=deploy` (via-ir) runtime | Margin |
|---|---:|---:|---:|---:|
| **TAGITCore** | **26,076** | **−1,500 (OVER LIMIT)** | **22,601** | **1,975** |
| TAGITGovernor | 23,035 | 1,541 | 21,815 | 2,761 |
| TAGITPrograms | 19,254 | 5,322 | 14,996 | 9,580 |
| TAGITTreasury | 17,115 | 7,461 | 12,924 | 11,652 |
| TAGITRecovery | 16,577 | 7,999 | 12,709 | 11,867 |
| TAGITPaymaster | 15,913 | 8,663 | 12,169 | 12,407 |
| CCIPAdapter | 14,927 | 9,649 | 12,848 | 11,728 |
| TAGITAgentIdentity | 14,166 | 10,410 | 10,720 | 13,856 |
| TAGITToken | 12,435 | 12,141 | 13,235 | 11,341 |
| TAGITAccount | 11,672 | 12,904 | 10,880 | 13,696 |

Consequences, stated bluntly:

- **Production ships via-ir. The test suite runs legacy codegen.** The two codegen paths are not
  equivalently validated. Any finding that depends on optimizer behaviour needs to be checked against
  the via-ir output, not the default build.
- The reason is recorded in `foundry.toml`: under via-ir, solc CSE-caches `block.timestamp` across
  `vm.warp()`, so 13 time-dependent tests read stale time. We believe that is a test-harness artifact
  rather than a contract defect (the batch-lifecycle suite passes 51/51 under via-ir), but **we have not
  proven it**, and we would like your view.
- **Any deploy or upgrade broadcast of `TAGITCore` without `FOUNDRY_PROFILE=deploy` reverts with
  max-code-size-exceeded.** This is a live operational footgun, not a hypothetical.
- `TAGITCore`'s remaining headroom under the deploy profile is **1,975 bytes**. Any remediation you
  recommend that adds code to `TAGITCore` has to fit in that budget. Please factor it into your
  recommendations.
- No `src/` contract is within 2,048 bytes of the EIP-3860 49,152-byte initcode limit under either
  profile.

### 5.2 Test coverage is 63.82%, not 87%

**63.82%** line coverage, measured in CI by `.github/workflows/coverage-check.yml`:

```bash
forge coverage --report summary --no-match-test 'gasEfficiency'
```

(The `gasEfficiency` benchmarks are excluded because `forge coverage` disables the optimizer.)

Documents in this repository previously claimed 87%. **That number was never measured and was false.**
The documents asserting it were deleted on 2026-07-27. We are stating this in writing because an
auditor who later found the discrepancy would be right to distrust everything else we say.

Per-file coverage is **not measured**. To produce it: `forge coverage --report lcov` and split
`lcov.info` by `src/` path.

Test suite size, measured:

```bash
# Count only TRACKED files, so the number reproduces on the clone you receive.
git ls-files 'test/**/*.sol' | xargs grep -hoE 'function (test|testFuzz|test_)[A-Za-z0-9_]*' | wc -l   # 1805
git ls-files 'test/**/*.sol' | xargs grep -hoE 'function invariant_[A-Za-z0-9_]*' | wc -l              #   12
```

→ **1,817 test functions** across 79 tracked test files. (This is DOWN from 1,840 across 80: the KI-25
remediation deleted tests that asserted the pre-fix behaviour, and its replacements are not committed
yet. A working tree that still holds this branch's untracked source files also carries 5 untracked test
files — including the three AIRP suites the KI-25 work added — and reports 2,045 test functions; that
number does not reproduce on a clone and should be ignored.) The suite reports **2,082 passed, 0
failed** across 77 suites on the default profile in the working tree described in §5.10; verify with
`forge test`. Fuzzing is configured at `runs = 100000`,
`max_test_rejects = 65536`, `seed = 0x333`; invariants at `runs = 256`, `depth = 500`,
`fail_on_revert = true`.

### 5.3 High test count, moderate coverage — read them together

1840 tests against 63.82% coverage means the tests are concentrated. We have not measured which
contracts are thin. If you want a targeted starting point, the per-file lcov split above is the fastest
way to find where the tests are not.

### 5.4 There are no passing live-chain fork tests, and the fork suite is pointed at the wrong chain

This is the single largest gap in our own assurance.

- `test/fork/ForkBase.t.sol:90` asserts `block.chainid == 10` — **OP Mainnet**, a chain we have **never
  deployed to**.
- `test/fork/ForkBase.t.sol:56` pins `FORK_BLOCK = 125000000`, an OP Mainnet block height.
- `.github/workflows/fork-test.yml` runs the suite against **OP Sepolia** (chainId 11155420, archived),
  so the chainid assertion cannot pass by construction.
- **`fork-test.yml` has failed 40 consecutive scheduled runs since 2026-06-17.**
- Four fork test files exist (`ForkBase.t.sol`, `CCIPFork.t.sol`, `EntryPointFork.t.sol`,
  `TokenFork.t.sol`) and **none of them currently pass**.

Net effect: **nothing in our automated suite has ever validated our contracts against real Base Sepolia
state, the real CCIP router, or the real EntryPoint.** The ERC-4337 v0.7/v0.9 question in §3.4 is
unresolved precisely because of this. If you have budget for one thing beyond static review, we would
spend it here.

### 5.5 Formal and symbolic tooling — partial, and the artifacts are not all committed

| Tool | Result | Caveat |
|---|---|---|
| Halmos | **2 of 22 properties proven**; the other 20 hit Z3 solver limits | The raw Halmos output is **not committed to this repository** — we found no Halmos artifact directory. Treat 2/22 as our report of a run, not as an artifact you can inspect. Re-run it if you need it. |
| Mythril | **only 2 of 56 contracts scanned** | `security/mythril/` **is an empty directory**. 54 contracts have never been through Mythril. |
| Slither | Output committed | `security/reports/slither-findings.md`, `security/slither-extended/full-analysis.json` and `post-fix-analysis.json`, all dated 2025-12-27 / 2026-03-25 — **months stale relative to the current tree**. |
| Echidna | `security/echidna/RESULTS.md`, dated 2026-03-25 | Also stale. |

We are flagging the empty/absent artifact directories rather than letting the tool names imply coverage
that does not exist. **Assume the symbolic and fuzz-oracle layer is essentially unexercised.**

### 5.6 `TAGITTreasury` can never be upgraded, and its emergency exit is dead

`TAGITTreasury` inherits `Initializable, ReentrancyGuard, PausableUpgradeable, ITAGITTreasury`
(`src/treasury/TAGITTreasury.sol:35`). It does **not** inherit `UUPSUpgradeable`, has no
`_authorizeUpgrade`, no `upgradeToAndCall`, and no `ERC1967Utils` import. It was nonetheless deployed
behind a bare `ERC1967Proxy` (`script/deploy/DeployBaseSepoliaFull.s.sol:275-280`):

```solidity
TAGITTreasury impl = new TAGITTreasury();
treasuryImpl = address(impl);
bytes memory init = abi.encodeCall(TAGITTreasury.initialize, (deployer, tokenProxy, signers));
treasuryProxy = address(new ERC1967Proxy(treasuryImpl, init));
```

`ERC1967Proxy` has no admin and no upgrade function of its own; the entrypoint must live on the
implementation, and it does not. Verified on chain: `proxiableUUID()` reverts, `upgradeToAndCall()`
reverts, the admin slot is `0x0`.

**The implementation at `0x3837A9bFc98F624bE5587a7F10980Cca5f68c4C8` is permanently frozen behind proxy
`0xa4a3720d705334f409DD24836CC75d642125f759`.** If you find a bug in the treasury, there is no upgrade
remedy — and per §4.4, `emergencySweep` is uncallable because `requiredSigners()` is 6 against one
initialised signer. The remaining lever is `pause()`.

Compounding it: the contract's own NatSpec at line 18 says *"Deploy behind TransparentUpgradeableProxy
with Gnosis Safe as admin."* That is not what was deployed, and the Safe has no code on Base Sepolia
(§2.4). The manifest labels the entry `"type": "ERC1967"`, which is literally true but reads as
"upgradeable."

We have not yet decided whether to redeploy the treasury as genuine UUPS before mainnet. **We would like
your recommendation on that specific question** (§6).

### 5.7 Capability badges are bearer assets

`CapabilityBadge` is a plain transferable ERC-1155 — no soulbound guard, no `_update` override.
`IdentityBadge` implements ERC-5192 correctly and is non-transferable; the capability side is not. Any
holder of `MINTER`, `BINDER`, `FLAGGER` etc. can transfer that privilege to an arbitrary address without
any administrative action. Combined with the ID-collision issue in §3.2 and the fail-open modifier in
§3.2, the BIDGES layer is where we most expect you to find severity.

### 5.8 `TAGITAccount` singleton is uninitialised and claimable

`owner()` on the implementation singleton `0x2160044C7c46B08a552361595E09e8C8DDD06E85` returns `0x0`.
`initialize` carries **no `initializer` modifier** and the constructor never calls
`_disableInitializers()`. An `eth_call` to `initialize` from an arbitrary sender succeeds.

We rate this **low** — EIP-1167 clones have separate storage, so seizing the singleton does not seize
user wallets — and we are disclosing it at that rating rather than inflating or hiding it. If you think
low is wrong, tell us why; there may be a delegatecall or selfdestruct-adjacent path we have not
considered.

### 5.9 `OfferEscrow` — out of scope by rule, arguably the riskiest file we own

`src/escrow/OfferEscrow.sol` (264 LOC / 193 nSLOC, 5,848 B runtime) does atomic NFT↔USDC settlement with
EIP-712 buyer offers, `SignatureChecker` (so ERC-1271 contract signatures are accepted), an
NFC-chip-signature path via `acceptOfferByTap`, and timeout refunds. It has a unit test file
(`test/unit/escrow/OfferEscrow.t.sol`) but **no deployment on any chain** and **no import from any
deployed contract** — verified against `deployment-addresses.json` and the entire `broadcast/` tree.

By the deployment rule it is out of scope. By risk profile — signature-verified value transfer with a
delegated authorization path — it is the most dangerous unaudited file in the repository. Adding it costs
**+193 nSLOC (+2.9% on the 6,593 base)**. We would rather pay for it now than ship it unaudited.
**Please quote it as a line item.**

### 5.10 AIRP was rebuilt after this document was written — read KI-25 before reviewing `src/recovery/`

An externally reported defect, **TAGIT-VDP-2026-001**, was confirmed and remediated on branch
`meta/t19-ops-scripts` after the scope freeze. It is material to how you should read
`src/recovery/TAGITRecovery.sol`, `src/interfaces/IRecovery.sol` and the recovery path in
`src/core/TAGITCore.sol`. The full write-up is `KNOWN-ISSUES.md` **KI-25**; the summary:

`TAGITRecovery.executeResolution()` ran a complete bonded dispute — 100e18 TAGIT bond,
badge-weighted voting, 66% threshold, 3-vote minimum, 7-day period, **50% slashing of a losing
claimant** — and never moved the NFT. The pre-fix source said so in a comment. A winning claimant got
nothing but their bond back; a losing claimant was really slashed for a process that structurally
could never have delivered the asset. Quarantine was decorative, a sub-quorum case was permanently
locked with its bond, and the vote weighting read the **transferable** `CapabilityBadge` (§5.7), so
one badge walked through three addresses produced a unanimous verdict.

**The security claim to falsify.** The remediation makes AIRP an adjudicator rather than a custodian:

> **TAGITRecovery holds ZERO capabilities in TAGITCore and makes ZERO state-changing calls into
> TAGITCore.** It calls only `getAsset`, `preFlagState`, `getResolveApprovalStatus`,
> `RESOLVE_QUORUM` and `IERC721.ownerOf` — all `view`.

That is a one-sentence claim you can attack with a grep. The read-only surface is pinned by
`src/interfaces/ITAGITCoreRecovery.sol` (which declares no state-changing function, deliberately), the
invariant is machine-checked by `test_trustBoundary_recoveryHoldsNoCapability`, and the deploy script
`script/deploy/UpgradeRecoveryVerdict.s.sol` aborts if TAGITRecovery ever holds a capability. **If you
can break that claim, that is the highest-value finding in this file.**

Custody now moves only through `TAGITCore.resolve()` and its 2-of-3 human quorum. A case is admitted
only over an asset that is **already** `FLAGGED` (so AIRP never creates a freeze it cannot release), an
approved verdict lands in a new non-terminal `ENFORCING` status with the bond still escrowed, and
`finalizeResolution()` observes what Core actually did before settling. **Slashing** — 50%, on the
`REJECTED` path — happens **only** on an actual adverse vote; every machinery failure refunds 100%.
Vote weight moved to the soulbound `IdentityBadge`.

Two economic rules sit on top of that and are **not** slashing; price them separately (KI-25 items 12
and 13):

- A case that expires having drawn **fewer than two** votes (`FEE_EXEMPT_MIN_VOTES`) pays a **10%
  anti-squat fee** (`SQUAT_FEE_RATE`) to the treasury and keeps the rest, emitting
  `AntiSquatFeeCharged`. Opening a case takes an asset's only dispute slot for the whole voting
  period; a 100% refund on no engagement made squatting free and infinitely repeatable. The threshold
  is **two, not zero**: `vote()` excludes only the claimant and the current holder, so one juror seat a
  griefer controls could buy the exemption one vote at a time (KI-25 item 14). A case that drew **two**
  votes is still below `MINIMUM_VOTES`, still `EXPIRES`, and still refunds **in full** — voter apathy
  is not claimant conduct. **Two colluding seats can still exempt a decoy; that residual is disclosed
  in KI-25 item 12 and we want you to price it.**
- A `REJECTED` case **keeps** its token's dispute slot for a bounded **appeal window** (default 7 days,
  governor-settable within `[1 day, 30 days]`) so a third party cannot front-run the freed slot and
  grief away an appeal right the claimant just paid a 50% slash to earn. The stale link is released
  **lazily** by the next `initiateRecovery`, so no keeper is required. `isQuarantined()` therefore
  stays true across that window. The window counts **unpaused seconds only**: `appeal()` is
  `whenNotPaused`, so a pause outlasting a wall-clock window would have consumed a right the claimant
  had already paid for (KI-25 item 15). `appealDeadlineEffective(caseId)` is the instant the contract
  enforces; `appealDeadline(caseId)` is the raw value recorded at rejection, and the two differ by
  accrued pause credit. **The cost this buys is that a rejected griefer holds a token's dispute slot
  for 14 days at defaults rather than 7, at the same 50%-of-bond price — price that too.**

**Scope deltas you should price:**

| Item | Change |
|---|---|
| `src/interfaces/ITAGITCoreRecovery.sol` | **New file**, 37 lines. View-only interface. |
| `src/recovery/TAGITRecovery.sol` | Substantially rewritten. **885 → 1,861 LOC** (§1.3.1 row 17 shows the frozen 885). Runtime 12,709 → **17,709** B (EIP-170 margin **6,867**); §5.1 shows the frozen pre-change 12,709. |
| `src/interfaces/IRecovery.sol` | **288 → 558 LOC.** `CaseStatus` gains members 6/7/8 (appended); **13 new errors, 9 new events, 8 new views** and 3 new state-changing functions (`expireEnforcement`, `finalizeResolution`, `abandonEnforcement`); `QuarantineReleased` and **8 declared-but-unreachable errors deleted** (see KI-25 "ABI/indexer impact"). Recount: `grep -c '^\s*error ' src/interfaces/IRecovery.sol` reads **25** against **20** at `HEAD`, and `grep -c '^\s*event '` reads **26** against **18**. |
| `src/core/TAGITCore.sol` | **Exactly one** new member: `preFlagState(uint256) view`. Runtime 22,601 → **22,664** B (**+63**), EIP-170 margin **1,912**. `forge inspect TAGITCore storage-layout` is **byte-identical** before and after. |
| `src/governance/TAGITGovernor.sol` | `_countVote` empty override replaced with an explicit revert (KI-29). |
| Tests | **37** tests in `test/recovery/TAGITRecoveryVerdict.t.sol`, plus **36** of its own in `test/recovery/TAGITRecoveryRegression.t.sol` — **73** when that suite runs, since it inherits the verdict fixture. Whole suite: **2,082 passed, 0 failed** across 77 suites. |

`TAGITRecovery`'s storage is strictly append-only — slots 0–19 unchanged, eight new slots 20–27
(`_enforcementWindow`, `_enforcementEndsAt`, `_caseRound`, `_appealWindow`, `_appealDeadline`,
`_pausedAt`, `_pauseCredit`, `_pauseCreditAtRejection`), `__gap[37] -> [29]`, still ending at slot 56
for an unchanged 57-slot footprint — and is pinned by `test_storageUpgradeSafety_v1LayoutToV2`, which
upgrades a proxy from a faithful reproduction of the v1 layout and compares raw slots.

**A second remediation round followed.** Two further independent adversarial reviews found eight
defects in the FIRST cut of the KI-25 fix — including a reintroduced permanent bond lock in `appeal()`
and the badge-namespace error above. All eight are fixed and each is pinned by an inverted PoC in
`test/recovery/TAGITRecoveryRegression.t.sol`. KI-25 items 4-9 in `KNOWN-ISSUES.md` describe them.
**Read that list before reviewing `appeal()`, the active-case guard, or `_getVoteWeight`.**

**And a third.** A later review proved two more, both rooted in the SAME line — the `EXPIRED` branch
refunding 100% below `MINIMUM_VOTES`, which is itself the fix for the original permanent lock and
which made a decoy case **free**: (a) zero-cost, infinitely repeatable case-slot squatting, closed by
the 10% anti-squat fee on a low-engagement expiry, and (b) the appeal right being griefable away,
closed by the bounded appeal window. Both are KI-25 items **12 and 13**. This is the shape of finding
we most want more of: not a broken check, but a **remediation whose own economics were wrong**. Note in
particular that (a) was a regression in cost-to-grief that a passing test suite reported as a fix.

**And a fourth, entirely inside those two economic rules.** KI-25 items **14, 15 and 16**: (a) the
anti-squat fee was keyed on `voteCount == 0`, so **one** vote from a single juror seat a griefer
controls exempted every decoy and squatting was free again — a **spec** defect, since the code did
exactly what the spec said; the threshold is now `FEE_EXEMPT_MIN_VOTES = 2`; (b) `appeal()` is
`whenNotPaused` while the new appeal deadline was absolute wall-clock, so a pause spanning the window —
including one the **circuit breaker trips by itself**, which no cooldown clears — permanently destroyed
an appeal right the claimant had paid a 50% slash to earn; the window now counts unpaused seconds; and
(c) `setMinimumStake` had no floor, so any value below 10 wei truncated the fee to zero with no revert
and no event, silently un-pricing the squat while every document still claimed 10%. **Two of the three
were defects in what the specification asked for, not in how it was implemented. That is the class we
are least able to catch ourselves and most want you to hunt.**

**Four adjacent findings were deliberately NOT absorbed** into that fix and remain open —
`KNOWN-ISSUES.md` KI-26 through KI-29: the `approveResolve` first-approver-binds-recipient deadlock, the
`TAGITRecovery` proxy owner still being a hot EOA rather than the Timelock, empty `RESOLVER`/`FLAGGER`
rosters that leave the whole path inert, and the governor counting hook. Our reasoning for each
deferral is in that file; please tell us where you disagree.

**Exposure:** `nextCaseId()` read **1** on the live deployment — zero cases were ever opened, so there is
no migration burden and no live case to preserve.

### 5.11 Documentation defects we know about

- `CLAUDE.md:371-378` and `:384-391` document BIDGES identity and capability IDs that **do not match
  production** (§3.2). `security/PRIVILEGE-MATRIX.md` §9 lists these as defects; `CLAUDE.md` has not been
  corrected yet.
- `deployment-addresses.json → networks["base-sepolia"].note` contains a wrong implementation address in
  prose (§2.5).
- `src/treasury/TAGITTreasury.sol:18` NatSpec describes a deployment topology that was not used (§5.6).
- Slither and Echidna artifacts under `security/` are months stale (§5.5).

Where documentation and code disagree, **the code is authoritative**. Please report the disagreements as
findings; we want them fixed.

---

## 6. What we want from this audit

Ranked. If the engagement runs short, work down this list in order.

1. **The privilege-concentration remediation, concretely.** We know A1 is a single point of total
   failure (§4.2). What we do not have is a migration design: what the target topology should be
   (multisig? which threshold? which roles split across which signers?), what the timelock delay should
   be per role class, and the **safe ordering of transactions** to get from here to there without
   bricking a contract or locking ourselves out mid-migration. This is the deliverable we most need.
2. **The BIDGES access layer, attacked as a system.** Specifically: the fail-open
   `accessController == address(0)` branch (`TAGITCore.sol:550-557`), the transferability of
   `CapabilityBadge` (§5.7), the ID namespace collisions (§3.2), and the `RESOLVER` balance-of-2 revoke
   trap (§4.6). Is the split-identity/capability model salvageable as designed, or does it need
   restructuring before mainnet?
3. **The lifecycle state machine.** Can any sequence of `mint` / `bindTag` / `batchBind` / `activate` /
   `claim` / `flag` / `resolve` / `recycle` reach a state the FSM forbids, or strand an asset? We are
   most suspicious of the `FLAGGED → CLAIMED` recovery path, the 2-of-3 `RESOLVE_QUORUM`, and the
   legacy-flag default-to-`CLAIMED` branch at `TAGITCore.sol:439-441`.
4. **Oracle trust.** `trustedOracle` is the same EOA that holds `BINDER_CAPABILITY`, so `bindTag`
   verifies a signature from the key that sends the transaction (§4.3). What does a correct oracle trust
   boundary look like here, given the physical NFC-tag workflow? `VerificationEscrow` has the same
   property and holds USDC.
5. **`TAGITTreasury`: redeploy as UUPS, or not?** Given §5.6 — frozen implementation, dead
   `emergencySweep`, funds custodied — is `pause()` an acceptable sole remedy pre-mainnet, or is a
   redeployment mandatory? A yes/no with reasoning is worth more to us than a paragraph of options.
6. **ERC-4337 v0.9-compiled code against a v0.7 EntryPoint** (§3.4). Wire-compatible or not? We could not
   determine this without fork tests. If incompatible, what breaks and where.
7. **The cross-chain surface.** `CCIPAdapter` (428 nSLOC) plus `ReplayProtection` (144 nSLOC) — is
   per-source-chain nonce tracking sufficient against replay and reordering given the CCIP router's
   delivery guarantees? `ReplayProtection` is the bridge's only replay defence.
8. **Economic invariants.** `Constants.sol` compiles into 7 deployed contracts. Can the 3.33% burn floor
   be evaded through `TAGITBurner`'s configurable split? Can `TAGITEmissions`' permissionless epoch
   trigger be gamed for extra issuance? Is the `wTAG` ↔ `TAGITStaking` accounting across `wTAGStaking`
   sound in both directions?
9. **The legacy-vs-via-ir codegen split** (§5.1). Does anything in the via-ir output differ semantically
   from what our legacy-codegen tests validated? And is the `block.timestamp` CSE behaviour we blamed for
   the 13 test failures actually a harness artifact, as we assume?
10. **Whether we should be reporting anything we are not.** If you see a claim in this document or in
    `security/PRIVILEGE-MATRIX.md` that we assert more confidently than the evidence supports, we want
    that called out as a finding in its own right.

Deliberately not asked for: a gas-optimization pass. We will take gas findings if they are free, but we
are not buying them.

---

## 7. How to build and test

### 7.1 Clone

```bash
git clone --recurse-submodules https://github.com/TAG-IT-NETWORK/tagit-contracts.git
cd tagit-contracts
git checkout v0.1.0-audit
git submodule update --init --recursive
```

Submodules are mandatory — the six libraries in §3.4 are all git submodules, and nothing compiles
without them.

### 7.2 Build

```bash
# Test/development build — legacy codegen. TAGITCore will report 26,076 B, over the EIP-170 limit.
forge build

# PRODUCTION build — via-ir. This is what is deployed. Use this for any size- or
# optimizer-dependent analysis.
FOUNDRY_PROFILE=deploy forge build
```

```bash
# Contract sizes under each profile
forge build --sizes
FOUNDRY_PROFILE=deploy forge build --sizes
```

**`FOUNDRY_PROFILE=deploy` is not optional for deployment or upgrade of `TAGITCore`.** Without it,
`CREATE` reverts with max-code-size-exceeded. Every broadcast script that touches `TAGITCore` must be run
under that profile.

### 7.3 Test

```bash
forge test                                   # full suite, default (legacy) codegen
forge test -vvv                              # with traces
forge test --match-contract TAGITCoreTest    # single contract
forge test --match-test test_bindTag         # single test

# Coverage, as CI measures it (63.82%)
forge coverage --report summary --no-match-test 'gasEfficiency'

# Per-file coverage — not currently measured; this is how to produce it
forge coverage --report lcov
```

Fuzz and invariant settings come from `foundry.toml` (`fuzz.runs = 100000`, `invariant.runs = 256`,
`invariant.depth = 500`, `fail_on_revert = true`). A full run is slow by design; `--fuzz-runs 1000`
locally is reasonable for iteration.

### 7.4 Fork tests — currently broken, do not expect them to pass

```bash
export BASE_SEPOLIA_RPC_URL=...   # the live network
forge test --match-path 'test/fork/*'
```

Per §5.4, `ForkBase.t.sol` asserts `block.chainid == 10` (OP Mainnet) and pins an OP Mainnet block
height, while CI runs it against OP Sepolia. It cannot pass as written. Fixing it — repointing at Base
Sepolia 84532 and choosing a real Base Sepolia fork block — is on our list; if you would rather we fix it
before the engagement starts, tell us and we will.

### 7.5 Verifying the deployment against chain

```bash
export BASE_SEPOLIA_RPC_URL=...

# EIP-1967 implementation slot for any proxy in §2.2
cast storage <PROXY> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $BASE_SEPOLIA_RPC_URL

# Timelock delay (returns 60)
cast call 0xfdA2478dB73064eF770f4e5E5b97BC83801126e1 "getMinDelay()(uint256)" \
  --rpc-url $BASE_SEPOLIA_RPC_URL

# Ownership of any contract in §2
cast call <ADDRESS> "owner()(address)" --rpc-url $BASE_SEPOLIA_RPC_URL
```

Every live value in §2 and §4 was produced this way. `security/PRIVILEGE-MATRIX.md` §0 lists the exact
command for each individual value in that document. Please re-run them — we would rather you verify than
trust us.

### 7.6 Environment

`foundry.toml` reads these from the environment; only the Base Sepolia one is needed for the live chain:

```
BASE_SEPOLIA_RPC_URL    # required for any live verification
BASESCAN_API_KEY        # contract verification only
OP_SEPOLIA_RPC_URL      # archived network
ARBITRUM_SEPOLIA_RPC_URL# archived network
OP_MAINNET_RPC_URL      # referenced by dead fork-test config; we have never deployed to OP Mainnet
```

---

## 8. Contact and change control

The tag `v0.1.0-audit` is frozen for the duration of the engagement. If we need to change anything in
`src/` mid-audit we will raise it with you first and re-tag rather than moving the branch under you.

Corrections to this document are welcome and will be treated as findings. If any statement here turns out
to be wrong, we would rather hear it from you during the engagement than defend it afterwards.

**Contact:** info@tagit.network
