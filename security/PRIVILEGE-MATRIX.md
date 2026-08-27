# TAG IT Network — Privilege Matrix (Actor → Role → Function → Current Holder)

**Status:** pre-audit disclosure document, prepared for Hacken.
**Chain of record:** Base Sepolia, chainId **84532** (`"status": "primary"` in `deployment-addresses.json`).
**All on-chain reads performed at block 44702050** via `https://sepolia.base.org`.
**Source of truth for addresses:** `/deployment-addresses.json`, `networks["base-sepolia"]`.

OP Sepolia (11155420) and Arbitrum Sepolia (421614) are marked `archived` (deprecated 2026-06-27) and are
**not** covered by this matrix. There is no OP Mainnet or Base Mainnet deployment.

---

## 0. How to reproduce every value in this document

```bash
export ETH_RPC_URL=https://sepolia.base.org
cast chain-id                                  # -> 84532
cast call <addr> 'owner()(address)'
cast call 0xfdA2478dB73064eF770f4e5E5b97BC83801126e1 'getMinDelay()(uint256)'
cast call 0xfdA2478dB73064eF770f4e5E5b97BC83801126e1 'hasRole(bytes32,address)(bool)' \
     $(cast keccak "PROPOSER_ROLE") 0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D
cast call 0xb05d22706B08A3F6409601de520cf7A6dbCB573d 'balanceOf(address,uint256)(uint256)' \
     0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D $(cast to-dec $(cast keccak "MINTER"))
```

Every "CURRENT HOLDER" cell below is the literal return value of one of those calls. Anything that could
not be read from chain is marked **UNVERIFIED** with the reason and the command that would settle it.

---

## 1. Actors

| # | Actor | Address | Type | Verified |
|---|---|---|---|---|
| A1 | **Deployer EOA** ("the key") | `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` | EOA — `cast code` returns `0x`; nonce 298 | yes |
| A2 | **TimelockController** | `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1` | OZ TimelockController, `getMinDelay() == 60` (seconds) | yes |
| A3 | **TAGITGovernor** (proxy) | `0xCF67DF870EccBB7838c3ab7876467c89d84dce89` | on-chain DAO — **holds no role on A2** (see §3) | yes |
| A4 | **Gnosis Safe** (claimed 3-of-5) | `0xAaA33C556C9c97a5430D180A1f72e8cf0fe0354e` | **DOES NOT EXIST on Base Sepolia** — `cast code` returns `0x` | yes |
| A5 | Phantom signer #1 | `0x3e25b6AB5331C1c0cF2DA7Df0fD2D8e947707AE9` | derived, no known private key (§6.2) | yes |
| A6 | Phantom signer #2 | `0xfe8D0633EFfeb354e3a35355c6ca9471B8b14D82` | derived, no known private key (§6.2) | yes |

A4 is referenced throughout the NatSpec (`TAGITCore.initialize`: *"Owner should be a TimelockController
controlled by Gnosis Safe 3-of-5"*). **On the primary chain that Safe has no code.** It exists only on the
archived OP Sepolia deployment, where `getThreshold()` is 1 and its sole owner is A1. There is no
multisig anywhere in the live system.

---

## 2. Bottom line before the table

**A1 — a single externally-owned key — is the effective root of the entire live deployment.**

- 22 of the 27 deployed Base Sepolia contracts return `owner() == A1`.
- Of the 5 that do not: `TAGITTreasury` has no `owner()` but `governor() == A1`; `wTAG` has no `owner()`
  but `DEFAULT_ADMIN_ROLE` and `MINTER_ROLE` are held by A1; `TimelockController` self-administers but A1
  is its sole PROPOSER, EXECUTOR **and** CANCELLER; `TAGITAccount` is an uninitialised implementation
  singleton (§7.4); and `TAGITCore` — the only contract owned by the timelock — is reachable by A1 in 60
  seconds.
- **No timelock stands in front of any UUPS upgrade except TAGITCore's.** The other 11 UUPS contracts
  all declare `_authorizeUpgrade(address) internal override onlyOwner {}` and their owner is A1.
  (`TAGITTreasury` is the odd one out in the opposite direction — it sits behind an ERC1967 proxy whose
  implementation has no upgrade mechanism at all and can never be patched; see §7.1.)
- The one timelock that exists has a 60-second delay and A1 holds every role on it, including
  CANCELLER — so the only party who could veto a malicious proposal is the party proposing it.
  The 2026-07-17 core upgrade went `schedule` → `execute` in 75 seconds, which is the practical
  demonstration of this.

If A1's private key is compromised, an attacker owns the protocol outright within one block for 24 of
27 contracts and within ~60 seconds for the 25th. There is no key that stops them.

---

## 3. TimelockController — `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1`

`getMinDelay()` = **60** (seconds).

The contract is **not** `AccessControlEnumerable` — `getRoleMemberCount(bytes32)` reverts. Holders below
were therefore established two ways: (a) `hasRole` against every candidate address, and (b) reading the
four `RoleGranted` events emitted at deployment (blocks 39611546–39611547, tx
`0x6c4db597110969b3546af975e50a3f2d9b363073a8517a8f1cf1ab40d7109562`).

| Role | Role hash | A1 deployer | A3 Governor | A4 Safe | Timelock itself | `address(0)` (open) |
|---|---|---|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `0x00…00` | **false** | false | false | **true** | false |
| `PROPOSER_ROLE` | `0xb09aa5ae…` | **TRUE** | false | false | false | false |
| `EXECUTOR_ROLE` | `0xd8aa0f31…` | **TRUE** | false | false | false | false |
| `CANCELLER_ROLE` | `0xfd643c72…` | **TRUE** | false | false | false | false |
| `TIMELOCK_ADMIN_ROLE` (legacy) | `0x5f58e3a2…` | false | false | false | false | false |

Exactly four `RoleGranted` events were emitted at deployment: DEFAULT_ADMIN→self, and
PROPOSER/EXECUTOR/CANCELLER→A1. Each of those three roles has, as far as we can establish, exactly one
member and it is the same key.

**What this role set can do:** schedule and execute any call the timelock is authorised to make. Today
that is: everything `onlyOwner` on `TAGITCore` (upgrade, `setAccessController`, `setTrustedOracle`,
`setBaseURI`, `setRedactedURI`, circuit-breaker resets, rate-limit toggles), plus `updateDelay` on the
timelock itself.

**Worst case if A1 is compromised:** attacker schedules `TAGITCore.upgradeToAndCall(evilImpl)`, waits
60 seconds, executes. They can also schedule `TimelockController.updateDelay(0)` and remove the delay
entirely, or `grantRole(PROPOSER_ROLE, attacker)` — DEFAULT_ADMIN is held by the timelock, and the
timelock does whatever A1 tells it to. The 60-second window is the entire defence.

**Does a timelock or multisig stand in the way?** A 60-second timelock, controlled by the same key.
No multisig. **No.**

**Governance is not a fallback.** `TAGITGovernor` (A3) holds **none** of PROPOSER / EXECUTOR / CANCELLER
on this timelock (all three verified `false`). `TAGITGovernor.timelock()` returns this same address, so
a successful DAO vote produces a proposal that **cannot be queued or executed**. On-chain governance is
non-functional today. Governor parameters, for the record: `votingDelay()` 86400, `votingPeriod()`
604800, `quorum()` 311111093320000000000000000, `proposalThreshold()` 100000000000000000000000.

**Design intent vs. reality:** `src/libraries/Constants.sol:102` declares
`MIN_TIMELOCK_DELAY = 48 hours` and `DEFAULT_TIMELOCK_DELAY = 48 hours`. The deployed delay is 60
seconds. `script/deploy/DeployBaseSepoliaFull.s.sol:501-508` shows the deploy runs at delay 0 and then
sets 60 as its last zero-delay operation. The constant is not enforced anywhere against the deployed
timelock.

---

## 4. TAGITCore — proxy `0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D`

Implementation (EIP-1967 slot, read live): `0x2377B7f33aFf34c58DDF6DeA7eD4dCaD616CA14C`.
`src/core/TAGITCore.sol` — `Initializable, ERC721Upgradeable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard`.

| Function | Guard (source) | Current holder (verified) | What it can do | Worst case if key compromised | Timelock/multisig in the way? |
|---|---|---|---|---|---|
| `_authorizeUpgrade` → `upgradeToAndCall` | `onlyOwner` — `TAGITCore.sol:513` | `owner()` = **A2 timelock** | replace all logic and storage semantics of the asset registry | total control of every TAG IT digital twin; mint, reassign, unflag at will | **60-second timelock, sole proposer/executor/canceller = A1.** Nominal only. |
| `setAccessController(address)` | `onlyOwner` — `:537` | A2 timelock | repoint or **disable** all BIDGES capability checks | see fail-open below | 60s timelock |
| `setTrustedOracle(address)` | `onlyOwner` — `:1544` | A2 timelock; `trustedOracle()` = **A1** | designate who signs NFC bind attestations | forge tag-binding attestations for any asset | 60s timelock |
| `setBaseURI` / `setRedactedURI` | `onlyOwner` — `:1380`, `:1461` | A2 timelock | redirect all metadata | mass metadata substitution | 60s timelock |
| `resetFlagCircuitBreaker()` | `onlyOwner` — `:1561` | A2 timelock | clear NIST IR-4 flag breaker | disable anti-mass-flag protection | 60s timelock |
| `unlockMinter(address)` | `onlyOwner` — `:1572` | A2 timelock | clear a user's mint rate-limit cooldown | bypass AC-7 mint rate limiting | 60s timelock |
| `setFlagCircuitBreakerThreshold(uint32)` | `onlyOwner` — `:1583` | A2 timelock | retune breaker | as above | 60s timelock |
| `setMintRateLimitEnabled(bool)` | `onlyOwner` — `:1594` | A2 timelock | switch off mint rate limiting entirely | unbounded minting velocity | 60s timelock |
| `mint`, `batchMint` | `requiresCapability(MINTER_CAPABILITY)` — `:578`, `:634` | **A1** holds the badge | create asset NFTs | counterfeit digital twins | none |
| `bindTag`, `batchBind` | `requiresCapability(BINDER_CAPABILITY)` + oracle sig — `:697`, `:791` | **A1** holds the badge **and is the oracle** | bind NFC tags to assets (irreversible) | A1 satisfies both sides of the check alone | none |
| `activate`, `batchActivate` | `requiresCapability(ACTIVATOR_CAPABILITY)` — `:838`, `:891` | **A1** | QA-approve assets into circulation | activate counterfeits | none |
| `claim` | `requiresCapability(CLAIMER_CAPABILITY)` — `:928` | **A1** | assign custody to an arbitrary `newOwner` | reassign ownership of any claimable asset | none |
| `flag`, `batchFlag` | `requiresCapability(FLAGGER_CAPABILITY)` — `:979`, `:1048` | **A1** | mark assets suspicious | mass-DoS the asset base (bounded by the flag circuit breaker, which A1 can also reset via A2) | none |
| `resolve`, resolution vote | `requiresCapability(RESOLVER_CAPABILITY)` — `:1080`, `:1147` | **A1** (badge balance 2) | resolve flags, set `newOwner` | launder a flagged asset to a chosen address | none |
| `recycle` | `requiresCapability(RECYCLER_CAPABILITY)` — `:1234` | **A1** | terminal-state assets | destroy provenance | none |
| `setMetadataHash` | asset owner **or** `MINTER_CAPABILITY` — `:1358-1363` | **A1** via capability | rewrite metadata integrity hash for **any** token | break the integrity guarantee the product sells | none |
| `tokenURI` full-detail path | `VIEWER_CAPABILITY` or `AUDITOR_CAPABILITY` — `:1436`, `:1442` | **nobody** — both badge balances are 0 for A1 | read unredacted metadata | n/a | n/a |

### 4.1 `pause()` does not exist on TAGITCore

`grep -c pause src/core/TAGITCore.sol` returns **0**. TAGITCore is not `Pausable`, imports no pausable
module, and exposes no emergency stop. `cast call <core> 'paused()(bool)'` reverts.

The flagship contract — the ERC-721 asset registry the whole product depends on — **cannot be halted**.
The only mitigation for a live exploit is a UUPS upgrade through the 60-second timelock. We are
disclosing this rather than letting it be found.

### 4.2 The capability modifier fails **open**

```solidity
modifier requiresCapability(bytes32 capability) {
    // Bypass capability checks if accessController not set (backward compatibility)
    if (address(accessController) != address(0)) {
        accessController.requireCapability(msg.sender, uint256(capability));
    }
    _;
}
```
`src/core/TAGITCore.sol:550-557`

If `accessController` is ever `address(0)`, **every** capability-gated function on TAGITCore becomes
permissionless — public mint, public bind, public flag, public claim, public resolve, public recycle.
`setAccessController` explicitly permits `address(0)` (`:537`, no zero-check, and the NatSpec says so).

Currently `accessController()` = `0xb56A1D91995C212342FaA843468F03521340A1D6` (TAGITAccess), so the
checks are live. But the path from "correct" to "the asset registry is fully permissionless" is one
`onlyOwner` call through a 60-second timelock whose only proposer is A1. This should be a fail-closed
revert, not a bypass.

---

## 5. BIDGES — TAGITAccess / CapabilityBadge / IdentityBadge

| Contract | Address | `owner()` (verified) |
|---|---|---|
| TAGITAccess (facade) | `0xb56A1D91995C212342FaA843468F03521340A1D6` | **A1 deployer EOA** |
| CapabilityBadge (ERC-1155) | `0xb05d22706B08A3F6409601de520cf7A6dbCB573d` | **A1 deployer EOA** |
| IdentityBadge (ERC-5192 soulbound) | `0xebdAC9A0663c02a7297681b078aaD893EF345030` | **A1 deployer EOA** |

### 5.1 The timelock on TAGITCore is bypassable through BIDGES

`TAGITCore.setAccessController` is behind the timelock. `TAGITAccess.setCapabilityBadge` and
`TAGITAccess.setIdentityBadge` are **`onlyOwner` on a contract owned directly by A1**
(`src/access/TAGITAccess.sol:69`, `:97`). `CapabilityBadge.grantCapability` /
`batchGrantCapabilities` are likewise `onlyOwner` = A1 (`src/access/CapabilityBadge.sol:69`, `:135`).

So: A1 can grant itself, or anyone else, any capability in **one transaction with no delay**, or swap
the entire capability contract for an attacker-controlled one that returns `true` unconditionally. The
60-second timelock in front of TAGITCore protects the upgrade path and nothing about who is allowed to
mint, bind, flag or resolve. **Putting Core behind a timelock while leaving its access controller under
a bare EOA is the central structural weakness of this deployment.**

### 5.2 Capability IDs actually used in production are **not** the documented ones

`CLAUDE.md:384-391` documents a BIDGES table: `100 CAP_MINT`, `101 CAP_BIND`, `102 CAP_ACTIVATE`,
`104 CAP_FLAG`, `105 CAP_RECOVERY_INIT`, `106 CAP_RECOVERY_APPROVE`, `107 CAP_FREEZE`, `108 CAP_DAO_VOTE`.

**Those constants do not exist in `src/`.** Production uses keccak-derived IDs declared at
`src/core/TAGITCore.sol:71-79`:

| Constant | `uint256` capability ID (= `uint256(keccak256(name))`) | A1 balance on-chain |
|---|---|---|
| `MINTER_CAPABILITY` | `0xf0887ba65ee2024ea881d91b74c2450ef19e1557f03bed3ea9f16b037cbe2dc9` | **1** |
| `BINDER_CAPABILITY` | `0xfb704bbb91710a3d3aa055227458d7964a0bf804c27b8e17cd0128dc8a05cfa4` | **1** |
| `ACTIVATOR_CAPABILITY` | `0xce1f15692823e8a9d77ca8c1b7a2cc145ffd008750ee9d3f8604f9c52eeea73c` | **1** |
| `CLAIMER_CAPABILITY` | `0xe5667d34d7ea8d6fdb3aa71a0a5b85e4cf7f68356dd003cd638556b0eea2bce5` | **1** |
| `FLAGGER_CAPABILITY` | `0xa36818ac366968e07c7f93f4d790b0dddd8d47093b859e75c114eaceb14cd609` | **1** |
| `RESOLVER_CAPABILITY` | `0x17a55417373800620b4c2ceaa9f76c02df2e2dd329b9cb9a7cf849712c108f6f` | **2** |
| `RECYCLER_CAPABILITY` | `0xed9a180fc7f150727f3614f70f00ff77e8e514eb7a73979e612e1539666ab910` | **1** |
| `VIEWER_CAPABILITY` | `0xdfb118e7fb180cb21baebdc5d0b33ccc34c8e0be422c1a4f57131ff74b98ca6e` | 0 |
| `AUDITOR_CAPABILITY` | `0xd8994f6d76f930dc5ea8c60e38e6334a87bb8539cc3082ac6828681c33316e3d` | 0 |

Verified: `balanceOf(A1, id)` for documented IDs 100, 101, 102, 103, 104, 105, 106, 107, 108, 120, 121,
122, 123, 124 all return **0**. Auditors reading `CLAUDE.md` will look for holders of ID 100 and find
none. **`CLAUDE.md`'s BIDGES table is wrong and should be treated as non-authoritative.**
Source of truth: `src/core/TAGITCore.sol:71-79`, `src/libraries/RobotTypes.sol:71-75`.

`RESOLVER_CAPABILITY` balance is 2, not 1 — a second grant landed on the same address. `grantCapability`
mints without checking for an existing balance, so the badge is a counter, not a flag. Functionally
harmless (`hasCapability` tests `>= 1`), but it means `revokeCapability` once leaves the holder still
authorised. Disclosed as a real revocation bug: **one `revokeCapability(A1, RESOLVER)` call does not
revoke A1's resolver rights.**

### 5.3 Capability badges are freely transferable

`CapabilityBadge` is a plain `ERC1155, Ownable` (`src/access/CapabilityBadge.sol:34`). It overrides
nothing — no `_update` guard, no soulbound restriction, no `setApprovalForAll` block. Any holder of
`MINTER_CAPABILITY` can `safeTransferFrom` it to an arbitrary address, or `setApprovalForAll` an
operator over all their capabilities, with no involvement from the owner. Privileges are bearer assets.

`IdentityBadge` does the opposite and does it correctly — it overrides `approve`, `setApprovalForAll`
and `_update` to enforce soulbound behaviour (`src/access/IdentityBadge.sol:196`, `:216`, `:230`).

### 5.4 Identity badge ID namespace collides across contracts

> **Scope of this section.** The table and the on-chain reads below describe the **deployed** Base
> Sepolia implementation. On branch `meta/t19-ops-scripts`, `TAGITRecovery` has been moved OFF this
> namespace onto a dedicated, documented **70-79** range (`BADGE_AIRP_JUROR` 70,
> `BADGE_AIRP_SENIOR_JUROR` 71, `BADGE_AIRP_ARBITER` 72, `BADGE_AIRP_TRIBUNAL` 73) — so the
> `TAGITRecovery` column below is historical for ids 1/2/10/20 and the registry-wide allocation table
> now lives in `src/access/IdentityBadge.sol`. Every other collision in the table is unchanged and the
> section's conclusion stands. See `KNOWN-ISSUES.md` KI-25 item 5.

There is no single registry of identity badge IDs. Each contract declares its own, and they disagree:

| ID | `TAGITRecovery` | `TAGITPrograms` | `TAGITGovernor` | `RobotTypes` | agent stack | deploy script |
|---|---|---|---|---|---|---|
| 1 | `BADGE_VERIFIER` | — | — | — | `KYC_L1_IDENTITY` | `ADMIN_BADGE` |
| 2 | `BADGE_CERTIFIED_VERIFIER` | — | — | — | — | — |
| 10 | `BADGE_MANUFACTURER` | `BADGE_MANUFACTURER` | `BADGE_MANUFACTURER` | `BADGE_MANUFACTURER` | — | — |
| 20 | `BADGE_GOVERNANCE` | — | `BADGE_GOV_MIL` | `BADGE_GOV_MIL` | — | — |
| 30 | — | — | `BADGE_DEV` | — | — | — |
| 40 | — | — | `BADGE_REGULATORY` | — | — | — |
| 50 / 51 / 60 | — | `BADGE_BASIC_VERIFIER` / `BADGE_CERTIFIED_VERIFIER` / `BADGE_GOVERNANCE` | — | — | — | — |

Sources: `src/recovery/TAGITRecovery.sol:79-88`, `src/programs/TAGITPrograms.sol:57-66`,
`src/governance/TAGITGovernor.sol:72-81`, `src/libraries/RobotTypes.sol:82-83`,
`src/agent/TAGITAgentIdentity.sol:48`, `src/agent/TAGITAgentValidation.sol:39`,
`src/agent/TAGITAgentReputation.sol:38`, `script/deploy/DeployBaseSepoliaFull.s.sol:88`.

**Verified consequence.** `hasIdentity(A1, id)` on-chain: **id 1 = true, id 10 = true**; ids 0, 2, 3, 4,
5, 6, 7, 8, 9, 11, 12, 20, 100 = false. The deploy script granted only `ADMIN_BADGE = 1`
(`DeployBaseSepoliaFull.s.sol:484`). Because ID 1 is simultaneously `ADMIN_BADGE`, `BADGE_VERIFIER` and
`KYC_L1_IDENTITY`, that single grant silently made A1 a Recovery-weighted verifier and a KYC-L1-verified
agent registrant across `TAGITAgentIdentity`, `TAGITAgentReputation` and `TAGITAgentValidation`.
Badge ID 51 means "certified verifier" in Programs and nothing in Recovery; ID 20 means "governance" in
Recovery and "gov/military" in Governor.

**Unexplained grant — disclosed.** A1 also holds **identity badge ID 10 = `BADGE_MANUFACTURER`**, and we
cannot account for it. We decoded every `grantIdentity(address,uint256)` call (selector `0xbe963869`) in
every tracked broadcast artifact under `broadcast/**/84532/`: **every one of them grants ID 1**. No
tracked script or broadcast record grants ID 10 on Base Sepolia, yet
`hasIdentity(A1, 10) == true` on chain. It was granted out-of-band — most likely a manual `cast send`
that was never committed. We are flagging it rather than quietly omitting it: **there is at least one
privilege grant in this deployment with no reproducible provenance in the repository.** An auditor
should assume there may be others we have not detected, and §8.3 explains why we could not rule that out.

**This namespace needs to be unified into one library before
mainnet.** We consider it a live privilege-escalation surface, not a naming nit.

### 5.5 Recovery vote weight reads the wrong badge contract

> **Scope of this section.** Describes the **deployed** implementation. On branch
> `meta/t19-ops-scripts` `_getVoteWeight` reads `hasIdentity()` on the soulbound `IdentityBadge`, and on
> AIRP-specific ids 70-73 rather than the shared 1/2/10/20 — reading the soulbound registry on the
> shared ids would have made every KYC'd account an AIRP juror. See `KNOWN-ISSUES.md` KI-25 item 5.

`TAGITRecovery._getVoteWeight` (`src/recovery/TAGITRecovery.sol:856-876`) computes AIRP recovery voting
power via `access.hasCapability(voter, BADGE_GOVERNANCE|MANUFACTURER|CERTIFIED_VERIFIER|VERIFIER)` —
i.e. it queries the **transferable ERC-1155 CapabilityBadge** using **identity** badge IDs 20/10/2/1.
Recovery vote weight is therefore a purchasable bearer token, not a soulbound credential.

Verified current state: `CapabilityBadge.balanceOf(A1, id)` for ids 1, 2, 10, 20, 30, 40, 50, 51, 60 all
return **0**. So no address is currently known to carry recovery vote weight, and `_getVoteWeight`
returns 0 for A1 today. But A1 owns CapabilityBadge and can mint itself weight 4 in one transaction.

---

## 6. Per-contract owner / admin matrix (all 27 Base Sepolia contracts)

`owner()` values below are live reads. "Upgrade auth" is the guard on `_authorizeUpgrade`.

| Contract | Address (proxy where applicable) | `owner()` / admin | Secondary admin | Upgrade auth | Timelock in path? |
|---|---|---|---|---|---|
| **TAGITCore** | `0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D` | **A2 timelock** | `trustedOracle` = **A1** | `onlyOwner` (`:513`) | yes — 60 s, A1 sole proposer |
| **TimelockController** | `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1` | self (`DEFAULT_ADMIN`) | A1 = PROPOSER+EXECUTOR+CANCELLER | n/a | n/a |
| TAGITAccess | `0xb56A1D91995C212342FaA843468F03521340A1D6` | **A1** | — | non-upgradeable | **no** |
| CapabilityBadge | `0xb05d22706B08A3F6409601de520cf7A6dbCB573d` | **A1** | — | non-upgradeable | **no** |
| IdentityBadge | `0xebdAC9A0663c02a7297681b078aaD893EF345030` | **A1** | — | non-upgradeable | **no** |
| TAGITToken | `0x5f98B83cD7Aef769cc51D2FB739BA49D561170DE` | **A1** | `emissionsAddress()` = `0x0` | `onlyOwner` (`:271`) | **no** |
| TAGITStaking | `0xB22F5688559D07e3a12DBB89f0481b967407F267` | **A1** | `governor()` = **A1**; `emissions()` = `0x0` | `onlyOwner` (`:553`) | **no** |
| TAGITGovernor | `0xCF67DF870EccBB7838c3ab7876467c89d84dce89` | **A1** | `guardian()` = **A1** | `onlyOwner` (`:600`) | **no** |
| TAGITTreasury | `0xa4a3720d705334f409DD24836CC75d642125f759` | *no `owner()`* | `governor()` = **A1** | see §7.1 | **no** |
| TAGITRecovery | `0x6BC3C69367E586810A3B317fA9F0406504e95866` | **A1** | `governor()` = TAGITGovernor proxy | `onlyOwner` (`:884`) | **no** |
| TAGITPrograms | `0x62a3CF048E66BE0119F0ccD97Ec964B726B9a982` | **A1** | `governor()` = **A1** | `onlyOwner` (`:891`) | **no** |
| TAGITPaymaster | `0x6fFFa92efb419E812d5c9C9D0c1B1a0f5c6fFd1C` | **A1** | `governor()` = **A1** | `onlyOwner` (`:663`) | **no** |
| TAGITAccountFactory | `0x3ed2c0E92F0e52dC68d04172aD37df4724893aD3` | **A1** | `governor()` = **A1**; `protocolGuardian()` = **A1** | `onlyOwner` (`:334`) | **no** |
| TAGITAccount (singleton) | `0x2160044C7c46B08a552361595E09e8C8DDD06E85` | **`0x0` — uninitialised** (§7.4) | — | n/a (EIP-1167 clone target) | n/a |
| CCIPAdapter | `0x5e190F6Ebde4BD1e11a5566a1e81a933cdDf3505` | **A1** | `governor()` = **A1**; `isPaused()` = false | `onlyOwner` (`:772`) | **no** |
| RoboticAuthorizer | `0x5C38684d87e826589Ec5Ed401D94C9671caE9f40` | **A1** | `accessController()` = TAGITAccess | `onlyOwner` (`:170`) | **no** |
| TAGITEmissions | `0x0672fcC5b753786C2cD1805494fF094CB5d6E579` | **A1** | `governor()` = **A1** | `onlyOwner` (`:390`) | **no** |
| TAGITBurner | `0xCB8AbCe0770C499B789481F8c6C20Fa0d6980d2a` | **A1** | `governor()` = **A1**; `treasury()` = Treasury proxy | `onlyOwner` (`:264`) | **no** |
| TAGITVesting | `0x7dd4c98a2aFE60eE06bA5c136dBeb7f93DD2699D` | **A1** | — | non-upgradeable | **no** |
| IntegrationFactory | `0xd68919371c26700dDb8252aD1825Aa02a0381a86` | **A1** | 1-of-3 "multisig" (§6.2) | non-upgradeable | **no** |
| wTAG | `0x746385e59aCB225779D64e74200e464a3f1C23d0` | *no `owner()`* | `DEFAULT_ADMIN_ROLE` = **A1**, `MINTER_ROLE` = **A1** | non-upgradeable | **no** |
| wTAGStaking | `0xBd4c4848C9fF09B7955a193E3b96456344D9acBe` | **A1** | `paused()` = false | non-upgradeable | **no** |
| VerificationEscrow | `0x4c9aACfcb64169E3BC187c227c4C0e0a5CFDA1cF` | **A1** | `trustedOracle()` = **A1** | non-upgradeable | **no** |
| ReputationStaking | `0x4154af74DA2B3a98096317100296966Ade15574A` | **A1** | `treasury()` = Treasury proxy; `agentIdentity()` = AgentIdentity | non-upgradeable | **no** |
| TAGITAgentIdentity | `0x0611FE60f6E37230bDaf04c5F2Ac2dc9012130a9` | **A1** | — | non-upgradeable | **no** |
| TAGITAgentReputation | `0x32be6C82A57d5bCe897538d7dA4109eA0eeB0aA1` | **A1** | — | non-upgradeable | **no** |
| TAGITAgentValidation | `0x34766dBa7040C2c8817f1Ee1e448209826DD607e` | **A1** | — | non-upgradeable | **no** |

**Count: `owner() == A1` on 22 contracts. Plus Treasury (governor) and wTAG (DEFAULT_ADMIN) = 24 of 27
contracts under sole EOA control, with the 25th (TAGITCore) reachable in 60 seconds.**

### 6.1 Roles that should be split and are not

Every one of these is a **single EOA holding both sides of a check that was designed to have two parties**:

| Split that should exist | Reality (verified) |
|---|---|
| Timelock proposer ≠ timelock canceller | A1 is both. Nobody can veto A1. |
| Timelock proposer ≠ timelock executor | A1 is both. `schedule`→`execute` is one actor. |
| Contract owner ≠ operational capability holder | A1 owns CapabilityBadge **and** holds MINTER/BINDER/ACTIVATOR/CLAIMER/FLAGGER/RESOLVER/RECYCLER. |
| Oracle signer ≠ tag binder | A1 is `trustedOracle` **and** holds `BINDER_CAPABILITY`. `bindTag` verifies a signature from a key that also sends the transaction. |
| Governor ≠ guardian | `TAGITGovernor.owner()` = `TAGITGovernor.guardian()` = A1. The emergency pauser is the entity being guarded against. |
| Treasury governor ≠ treasury signer | A1 is `governor()` and `isSigner(A1) == true`, and `setSigner` is `onlyGovernor`. |
| Upgrade authority ≠ operator | A1 is `_authorizeUpgrade` owner on 12 UUPS proxies **and** the day-to-day operator. |
| DAO ≠ deployer | `TAGITGovernor` holds no timelock role; DAO output is unexecutable. A1 is the only executor. |

### 6.2 The "multisigs" are not multisigs

**IntegrationFactory** (`0xd68919371c26700dDb8252aD1825Aa02a0381a86`). On-chain:
`requiredSignatures()` = **1**; `getSigners()` =
`[0x458B4d0c…Cb3D, 0x3e25b6AB…7AE9, 0xfe8D0633…4D82]`.

`script/deploy/DeployBaseSepoliaFull.s.sol:439-441` constructs signers 2 and 3 as
`address(uint160(uint256(keccak256(abi.encodePacked(deployer, uint256(1))))))` and `…uint256(2)`. We
recomputed both hashes locally and they match the on-chain signer list exactly. **No private key exists
for either address — they can never sign anything.** So `emergencyPause`, `emergencyUnpause`,
`setMaxPayment`, `addSigner`, `removeSigner` and `reactivate` are all gated by a "3-signer multisig"
that is one EOA. Worse, `removeSigner` reverts when `_signerList.length <= MIN_SIGNERS` (= 3,
`src/agent/IntegrationFactory.sol:50`, `:297`), so the two dead signers can never be removed to make
room for real ones without first adding new signers.

**TAGITTreasury** (`0xa4a3720d705334f409DD24836CC75d642125f759`). `requiredSigners()` = **6**;
`REQUIRED_SIGNERS` constant = 6 (`src/treasury/TAGITTreasury.sol:61`). The deploy script initialises the
signer set with a **single** entry — `signers[0] = deployer`, `DeployBaseSepoliaFull.s.sol:276-280`.
`isSigner(A1)` = true; the two IntegrationFactory phantoms return false.

**Consequence: `emergencySweep()` is currently uncallable.** It requires 6 unique valid signatures
(`TAGITTreasury.sol:493-536`) and there is at most one eligible signer. The treasury's only emergency
exit is dead. `setSigner(address,bool)` is `onlyGovernor` (`:585`) and `governor()` is A1 — so A1 can
add five addresses it controls and then sweep the entire treasury (all ETH and all ERC-20) to any
address in two transactions, bypassing the DrainDetector entirely (the code comment at `:504` even says
*"Emergency sweep bypasses drain detection as it requires 6/8 multisig"* — there is no 6/8 multisig).

We could **not** enumerate the full treasury signer set on-chain: there is no `signerCount()` getter and
no `SignerUpdated` index. `isSigner` was checked against A1, A5, A6 only.
**UNVERIFIED: whether any address other than A1 is a treasury signer.** Command to settle it, with an
archive/indexed RPC: `cast logs --address 0xa4a3720d705334f409DD24836CC75d642125f759 'SignerUpdated(address,bool)' --from-block 39611546`.

---

## 7. Emergency powers inventory — every `pause` / `freeze` / `sweep` / `withdraw`

| Contract | Emergency function | Guard (source) | Current holder | Live state | Worst case | Timelock/multisig? |
|---|---|---|---|---|---|---|
| **TAGITCore** | **none — no `pause()` exists** | — | — | n/a | live exploit cannot be halted; only a 60 s UUPS upgrade | **no** |
| TAGITStaking | `pause()` / `unpause()` | `onlyGovernor` (`:322`, `:329`) | **A1** | `paused()` = false | freeze all staking/unstaking indefinitely | no |
| TAGITPrograms | `pause()` / `unpause()` | `onlyGovernor` (`:758`, `:765`) | **A1** | `paused()` = false | freeze rewards | no |
| TAGITPrograms | `resetDrainDetector()` | `onlyOwner` (`:793`) | **A1** | — | clear SI-4 anomaly state, then drain | no |
| TAGITPrograms | `updateDrainBalance` / `syncDrainBalance` | `onlyGovernor` (`:777`, `:784`) | **A1** | — | falsify the drain baseline | no |
| TAGITTreasury | **`emergencySweep(token,to,sigs)`** | 6 unique signer sigs (`:493`) | **uncallable today** (1 signer, 6 required) | — | after `setSigner`×5 by A1: total treasury drain, drain-detector bypassed | nominally 6-of-N; **effectively A1 in 2 txs** |
| TAGITTreasury | `pause()` / `unpause()` | `onlyGovernor` (`:602`, `:609`) | **A1** | `paused()` = false | freeze all allocations/withdrawals | no |
| TAGITTreasury | `resetDrainDetector` / `setDrainThresholds` / `setDrainDetectorEnabled` / `syncDrainDetectorBalance` | `onlyGovernor` (`:531`, `:542`, `:553`, `:560`) | **A1** | — | **switch off drain detection entirely**, then withdraw normally | no |
| TAGITTreasury | `setGovernor(address)` | `onlyGovernor` (`:573`) | **A1** | — | hand the treasury to an attacker in one tx | no |
| TAGITGovernor | `emergencyPause()` / `unpause()` | `msg.sender == guardian` (`:462`, `:474`) | **A1** | `paused()` = false | halt governance | no |
| TAGITGovernor | `setGuardian(address)` | `onlyGovernance` (`:487`) | DAO — **unreachable**, Governor holds no timelock role | — | guardian cannot be rotated by governance today; A1 can rotate it by upgrading the proxy | no |
| TAGITRecovery | `pause()` / `unpause()` | `onlyOwner` (`:727`, `:735`) | **A1** | `paused()` = false | freeze AIRP recovery | no |
| TAGITRecovery | `forceResetCircuitBreaker()` | `onlyOwner` (`:760`) | **A1** | — | clear breaker state | no |
| TAGITRecovery | `setGovernor` / `setTreasury` / `setCore` / `setToken` | `onlyOwner` (`:651`, `:664`, `:677`, `:690`) | **A1** | `governor()` = Governor proxy | repoint recovery at attacker contracts | no |
| TAGITPaymaster | `pause()` / `unpause()` | `onlyGovernor` (`:574`, `:583`) | **A1** | `paused()` = false | halt gas sponsorship | no |
| TAGITPaymaster | **`withdrawProtocol(amount,to)`** | `onlyGovernor` (`:419`) | **A1** | — | drain the protocol EntryPoint deposit to any address | no |
| TAGITPaymaster | **`withdrawStake(address)`** / `unlockStake()` | `onlyGovernor` (`:454`, `:446`) | **A1** | — | withdraw the entire EntryPoint stake | no |
| TAGITPaymaster | `resetCircuitBreaker` / `updateDrainBalance` / `syncDrainBalance` | `onlyGovernor` (`:592`, `:600`, `:608`) | **A1** | — | neutralise drain detection | no |
| CCIPAdapter | `pause()` / `unpause()` | inline `msg.sender != _governor` (`:560`, `:569`) | **A1** | `isPaused()` = false | halt cross-chain messaging | no — code comment says *"in production would use multisig voting"*; it does not |
| CCIPAdapter | `setChainNonce` / `setReplayProtectionEnabled` | `onlyGovernor` (`:602`, `:593`) | **A1** | — | **disable CCIP replay protection**, rewind nonces | no |
| CCIPAdapter | `setGovernor(address)` | `onlyGovernor` (`:761`) | **A1** | — | hand over the bridge in one tx | no |
| wTAGStaking | `pause()` / `unpause()` | `onlyOwner` (`:222`, `:229`) | **A1** | `paused()` = false | freeze wTAG staking | no |
| ReputationStaking | `pause()` / `unpause()` | `onlyOwner` (`:130`, `:138`) | **A1** | — | freeze agent bonds | no |
| ReputationStaking | **`slash(agentId,amount)`** | `onlyOwner` (`:230`) | **A1** | `treasury()` = Treasury proxy | confiscate any agent's bond at will | no |
| ReputationStaking | `setTreasury(address)` | `onlyOwner` (`:119`) | **A1** | — | redirect slashed funds to an attacker address | no |
| TAGITAgentIdentity / Reputation / Validation | `pause()` / `unpause()` | `onlyOwner` (`:610`/`:615`, `:209`/`:214`, `:258`/`:263`) | **A1** | — | halt the agent stack | no |
| IntegrationFactory | `emergencyPause(sigs)` / `emergencyUnpause(sigs)` | 1-of-3 sigs, 2 signers unusable (`:320`, `:331`) | **A1** | `paused()` = false | halt integrations | nominally multisig, **effectively A1** |
| RoboticAuthorizer | `resetRobotCircuitBreaker()` / `setRobotRateLimitEnabled(bool)` | `onlyOwner` (`:360`, `:370`) | **A1** | — | disable robotic-action rate limiting | no |
| RoboticAuthorizer | `setAccessController` / `setCoreContract` | `onlyOwner` (`:395`, `:381`) | **A1** | `accessController()` = TAGITAccess | repoint robot authorisation at an attacker contract | no |
| TAGITAccountFactory | `setImplementation(address)` | `onlyGovernor` (`:244`) | **A1** | `accountImplementation()` = `0x2160044C…6E85` | **all future smart accounts get attacker logic** | no |
| TAGITAccountFactory | `setProtocolGuardian(address)` | `onlyGovernor` (`:254`) | **A1**, current guardian = **A1** | — | protocol guardian is a recovery participant on every account (threshold 1, 2-day delay) | no |
| TAGITToken | `setEmissionsAddress(address)` | `onlyOwner`, **one-shot** (`:147-155`) | **A1**; `emissionsAddress()` = `0x0` | mint currently uncallable | A1 has one unused shot at naming the unlimited minter (`MAX_SUPPLY = type(uint256).max`, `Constants.sol:30`) | no |
| wTAG | `mint(to,amount)` | `onlyRole(MINTER_ROLE)` (`:183`) | **A1** | `cap()` = 258999985188900000000000000 | mint wTAG up to the ERC20Capped ceiling | no — NatSpec `:114-115` says *"multi-sig"*; it is an EOA |
| wTAG | `setTGE` / `setTagToken` | `onlyRole(DEFAULT_ADMIN_ROLE)` (`:145`, `:162`) | **A1** | — | set/skip the 7-day lockout, repoint the wrapped asset | no |
| VerificationEscrow | `setTrustedOracle(address)` | `onlyOwner` (`:302`) | **A1**, oracle = **A1** | — | forge escrow verification attestations | no |

No `freeze()` and no `emergencyWithdraw()` exist anywhere in `src/`. The nearest equivalents are
`TAGITTreasury.emergencySweep` and `TAGITPaymaster.withdrawProtocol` / `withdrawStake`, all listed above.
`grep -rn "selfdestruct" src/` returns nothing.

### 7.1 TAGITTreasury sits behind an upgradeable proxy that has **no upgrade mechanism**

`TAGITTreasury` is deployed behind an `ERC1967Proxy` (`DeployBaseSepoliaFull.s.sol:275-280`, manifest
`"type": "ERC1967"`) with implementation `0x3837A9bFc98F624bE5587a7F10980Cca5f68c4C8` (read live from
the EIP-1967 implementation slot).

The implementation does **not** inherit `UUPSUpgradeable` — `src/treasury/TAGITTreasury.sol:35` declares
`contract TAGITTreasury is Initializable, ReentrancyGuard, PausableUpgradeable, ITAGITTreasury` — and
there is no `_authorizeUpgrade` override anywhere in the file.

Verified on-chain: `proxiableUUID()` **reverts**, `upgradeToAndCall(address,bytes)` **reverts**, and the
EIP-1967 admin slot `0xb531…6103` is `0x0` (no ProxyAdmin — it is not a transparent proxy either).

**The treasury implementation is frozen. Nobody can upgrade it — not A1, not the timelock, not
governance.** Combined with §6.2 (`emergencySweep` needs 6 signatures and the contract was initialised
with 1 signer), the treasury has an emergency exit that cannot currently be used and logic that cannot
be patched. The only remedy is `setSigner` (`onlyGovernor` = A1) to appoint five more signers, or
migrating funds to a fresh deployment. This should be near the top of the audit scope.

### 7.2 EIP-1967 slot spot-checks

Three proxies re-read from the raw slot `0x360894a1…382bbc` and matched the manifest exactly:
CCIPAdapter → `0x26f2ebb84664ef1ef8554e15777ebec6611256a6`, TAGITGovernor →
`0x1fb00d79e6baff059e1c5fa034e4d59b766e0d44`, TAGITPaymaster →
`0x4609a869a813e7e596bf5bf5cbc08f8092ce6340`. The CCIPAdapter/IdentityBadge address coincidence across
chains is deterministic CREATE by the same deployer, as the manifest note states — not a manifest error.

### 7.3 The trusted oracle is the deployer, on both oracle surfaces

`TAGITCore.trustedOracle()` = A1 and `VerificationEscrow.trustedOracle()` = A1. A1 also holds
`BINDER_CAPABILITY`. `bindTag` (`src/core/TAGITCore.sol:697-712`) recovers a signature and requires
`recovered == trustedOracle` — a check A1 satisfies against itself. The oracle attestation adds no
independent assurance in the current configuration. The deploy scripts are explicit about this
(`DeployBaseSepoliaFull.s.sol:481`: *"setTrustedOracle done (oracle = deployer)"*), so it is a known
testnet shortcut — but it must be split before mainnet, and it should be scoped as such.

### 7.4 TAGITAccount implementation singleton is uninitialised and open

`accountImplementation()` on the factory returns `0x2160044C7c46B08a552361595E09e8C8DDD06E85`.
`owner()` on that address returns `0x0000000000000000000000000000000000000000`.

`TAGITAccount.initialize` (`src/account/TAGITAccount.sol:130-152`) is guarded only by a plain
`bool _initialized` — it carries **no `initializer` modifier**, and the constructor
(`:115-117`) sets only `_entryPoint`; it does **not** call `_disableInitializers()`.

We confirmed by `eth_call` from an arbitrary sender that `initialize(...)` on the singleton **does not
revert** — the singleton is genuinely uninitialised and any address can claim `_owner` of it. We did not
send the transaction.

Impact assessment: accounts are EIP-1167 minimal clones (`cloneDeterministic`,
`TAGITAccountFactory.sol:128`), so each user account has independent storage and taking the singleton
does **not** compromise deployed accounts. The exposure is confined to the singleton address itself,
whose `execute()` / `executeBatch()` an attacker could then drive. It holds no assets. We rate this low
but are disclosing it because it is a real unguarded initialiser on a live address, and because the same
missing-`initializer` pattern would be severe if the factory ever moved to per-account proxies.

---

## 8. What we could not verify, stated plainly

1. **Exhaustive timelock role membership.** `TimelockController` is not enumerable
   (`getRoleMemberCount` reverts). We verified `hasRole` for A1, A3, A4, the timelock itself and
   `address(0)` across all five roles, and read the four `RoleGranted` events emitted at deployment.
   A full historical `RoleGranted`/`RoleRevoked` scan over blocks 39611000→44702050 was **attempted and
   abandoned**: `sepolia.base.org` caps `eth_getLogs` at 2000 blocks, requiring 2546 requests, and
   rate-limited the run to failure. **UNVERIFIED: whether any address we did not test holds a timelock
   role.** Settle it with an archive provider:
   `cast logs --address 0xfdA2478dB73064eF770f4e5E5b97BC83801126e1 'RoleGranted(bytes32,address,address)' --from-block 39611546 --to-block latest`
2. **Full TAGITTreasury signer set** — see §6.2. No enumeration getter exists.
3. **Full CapabilityBadge / IdentityBadge holder set.** Neither contract uses `ERC1155Supply` or a holder
   index, so holders cannot be enumerated by call — only by log replay, which hit the same 2000-block
   cap. All balances reported here are point queries against A1, A2 and the Core proxy.
   **UNVERIFIED: whether any address other than A1 holds a production capability badge.** Settle with
   `cast logs --address 0xb05d22706B08A3F6409601de520cf7A6dbCB573d 'TransferSingle(address,address,address,uint256,uint256)' --from-block 39611546` on an archive RPC.
4. **TAGITTreasury upgrade authority** — see §7.1.
5. **Off-chain key custody.** Where A1's private key lives, whether it is in an HSM, and who has access
   to it are **not** on-chain facts and are **not asserted here**.

---

## 9. Known documentation defects this exercise surfaced

These are wrong in the repo as of this commit. They are listed so Hacken does not have to find them.

| Location | Claim | Reality (verified) |
|---|---|---|
| `CLAUDE.md:384-391` | BIDGES capability IDs are 100–108 | Production uses `uint256(keccak256("MINTER"))` etc. — `src/core/TAGITCore.sol:71-79`. All of 100–108 have zero balance on-chain. |
| `src/core/TAGITCore.sol:465` (NatSpec) | *"Owner should be a TimelockController controlled by Gnosis Safe 3-of-5"* | The referenced Safe has **no code** on Base Sepolia. No multisig exists anywhere in the live system. |
| `src/core/TAGITCore.sol:533` (NatSpec) | *"goes through TimelockController 48hr delay"* | `getMinDelay()` = **60 seconds**. |
| `src/libraries/Constants.sol:102,108` | `MIN_TIMELOCK_DELAY` / `DEFAULT_TIMELOCK_DELAY` = 48 hours | Deployed delay is 60 seconds; the constant is not enforced against the deployed timelock. |
| `src/core/TAGITCore.sol:511` (NatSpec) | *"UpgradeScheduled event enables 48hr monitoring window"* | The real monitoring window is 60 seconds. The 2026-07-17 core upgrade completed `schedule`→`execute` in 75 s. |
| `src/treasury/TAGITTreasury.sol:504` (comment) | *"Emergency sweep bypasses drain detection as it requires 6/8 multisig"* | There is no 6/8 multisig. `requiredSigners()` = 6 with 1 known signer, so the function is uncallable; the governor (A1) can appoint the remaining signers unilaterally. |
| `src/token/wTAG.sol:20,114-115` (NatSpec) | `MINTER_ROLE` and `DEFAULT_ADMIN_ROLE` are *"multi-sig gated"* / *"(multi-sig)"* | Both are held by the deployer EOA. |
| `src/bridge/CCIPAdapter.sol:561,570` (comment) | *"in production would use multisig voting"* | Ships as a single `msg.sender != _governor` check; governor is an EOA. |
| `src/access/CapabilityBadge.sol:25-28` (comment) | Capability ranges 100-109 / 110-119 / 120-129 | Matches `CLAUDE.md`, not the production keccak IDs. |
| `CLAUDE.md` identity-badge table | `1 KYC_L1`, `2 KYC_L2`, `3 KYC_L3`, `10 MANUFACTURER`, `11 RETAILER`, `20 GOV_MIL`, `21 LAW_ENFORCEMENT` | Only ID 10 is consistent with `src/`. ID 1 is also `BADGE_VERIFIER` (Recovery) and `ADMIN_BADGE` (deploy script); ID 2 is `BADGE_CERTIFIED_VERIFIER` (Recovery); ID 20 is `BADGE_GOVERNANCE` (Recovery) *and* `BADGE_GOV_MIL` (Governor). Programs uses a fourth scheme entirely (50/51/60). See §5.4. |
| Repository provenance | all privileged grants are reproducible from `script/` | Identity badge ID 10 is held on-chain by A1 with **no** corresponding call in any tracked script or broadcast artifact. See §5.4. |

---

## 10. What we would fix before mainnet, in priority order

1. Move `TAGITAccess`, `CapabilityBadge` and `IdentityBadge` ownership behind the timelock — otherwise
   TAGITCore's timelock is decorative (§5.1).
2. Split A1. At minimum: PROPOSER ≠ CANCELLER ≠ EXECUTOR; oracle signer ≠ binder; governor ≠ guardian;
   upgrade authority ≠ operator.
3. Raise `getMinDelay()` to the 48 hours the code already documents, and put a real multisig behind
   PROPOSER before doing so.
4. Make `requiresCapability` fail **closed** and reject `address(0)` in `setAccessController` (§4.2).
5. Add `Pausable` to `TAGITCore` with a guardian distinct from the upgrade authority (§4.1).
6. Fix the treasury signer set so `emergencySweep` is callable by a real quorum, and remove the two
   unsignable IntegrationFactory signers (§6.2).
7. Unify identity/capability badge IDs into a single library and delete the per-contract redeclarations
   (§5.4).
8. Make `CapabilityBadge` non-transferable, or state explicitly that capabilities are bearer assets and
   design around it (§5.3).
9. Make `grantCapability` idempotent so one `revokeCapability` actually revokes (§5.2).
10. Add `_disableInitializers()` to the `TAGITAccount` constructor and an `initializer` modifier to
    `initialize` (§7.4).

---

*Prepared on branch `audit-prep/p0-manifest-and-false-evidence`. Every on-chain value read at Base
Sepolia block 44702050. Nothing in this document is estimated or inferred from documentation — values
either come from a `cast` call reproduced in §0, from a cited source line, or are labelled UNVERIFIED.*
