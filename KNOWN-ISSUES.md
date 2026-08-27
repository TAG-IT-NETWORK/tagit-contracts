# KNOWN ISSUES — tagit-contracts

**Prepared for:** Hacken, pre-engagement disclosure
**Prepared:** 2026-07-27
**Branch:** `audit-prep/p0-manifest-and-false-evidence`
**Repo:** `TAG-IT-NETWORK/tagit-contracts` (public)
**Live deployment under review:** Base Sepolia, chainId 84532 (`deployment-addresses.json`, `"status": "primary"`)

---

## Why this document exists

This is a list of defects, gaps and weak controls that **we** know about and are handing you
before you start. It is deliberately volunteered. Nothing here was found by an auditor; every
item below is something we would rather disclose than have you discover and score against us.

Three things you should know up front, because they change how you should read our older
material:

1. **A prior "850/1000 EVMbench security score" is withdrawn.** It was self-graded by our own
   tooling against our own codebase. The score is meaningless; the five findings it deducted
   points for are real and are written up below (KI-08, KI-10, KI-16, KI-17, KI-19). The source
   document still exists at `tagit-security/evmbench/results/evmbench-final-score.md` — treat its
   number, its "Security posture: STRONG" conclusion, and its "0 successful fund-drain exploits"
   table as unsupported.
2. **A previously circulated "87% test coverage" figure was false and the documents asserting it
   were deleted on 2026-07-26.** The last measured figure is **63.82%** (see KI-11). If you find
   87% anywhere in a doc, artifact or README, it is stale and wrong — please tell us where so we
   can delete that too.
3. **Some security controls that our own documentation describes do not exist on the live chain.**
   The clearest case is the treasury "6-of-8 multisig" (KI-02): the deployed contract has exactly
   one registered signer. We found this while preparing this document.

**Verification convention.** Every number below was measured. Where we could not measure
something, it says **"not measured"** and gives the command that would measure it. Where a claim
comes from a source we do not independently trust (an LLM-generated report, a stale summary), it
says so and the status field says whether we confirmed it.

**Chain reads in this document** were performed on 2026-07-27 against
`https://sepolia.base.org` and are reproducible with the `cast` commands shown.

**Severity is our own honest assessment**, using the impact if the issue were reached on a
production mainnet deployment. We have not down-graded anything on the grounds that it is
"only testnet". Where we think a prior report over-stated something, we say so and give the
lower severity with reasoning — we are not quietly dropping it.

---

## Index

| ID | Severity | Title |
|----|----------|-------|
| KI-01 | Critical | Deployer EOA is a single point of total protocol compromise; timelock delay is 60 seconds |
| KI-02 | High | `TAGITTreasury.emergencySweep` is unexecutable on the live deployment: 1 registered signer vs `REQUIRED_SIGNERS = 6` |
| KI-03 | High | ERC-721 transfers are globally disabled while `supportsInterface(0x80ac58cd)` returns true; two integration paths are dead and are tested only against mocks |
| KI-04 | High | The bytecode the test suite exercises is not the bytecode that is deployed (legacy codegen vs via-ir) |
| KI-05 | High | `TAGITPaymaster` reads the sponsored selector from a hardcoded calldata offset — spoofable (unconfirmed, no PoC) |
| KI-06 | High | No passing fork / live-chain tests; the fork suite targets a chain we have never deployed to |
| KI-07 | Medium | `TAGITAccount.exportAllAssets` transfers nothing and emits a success event |
| KI-08 | Medium | Emergency-sweep signatures never expire and do not bind an amount (residual after PATCH-08) |
| KI-09 | Medium | `IntegrationFactory` multi-sig digests are not domain-separated across the three deployments |
| KI-10 | Medium | Paymaster circuit breaker counts only successful validations and does not reject the operation that trips it |
| KI-11 | Medium | Measured coverage is 63.82% against a CI threshold of 85%; the Coverage Check job fails on every run |
| KI-12 | Medium | Two tests assert nothing — one of them is a named invariant |
| KI-13 | Medium | Two Slither detectors are globally excluded; the CI gate that uses that config cannot block, and a second CI job runs Slither with different settings |
| KI-14 | Medium | The Slither baseline is ~5 months stale and predates 10 of the contracts now in `src/` |
| KI-15 | Medium | Three production source files and 155 test functions are untracked and therefore outside the audit clone |
| KI-16 | Low | Allocation-expiration bypass — remediated (PATCH-07), disclosed for completeness |
| KI-17 | Low | Epoch-skip emissions loss — remediated (PATCH-10); residual compounding drift and a 12-epoch cap |
| KI-18 | Low | ERC-721 ownership desync was closed by prohibiting transfers, not by synchronising state |
| KI-19 | Low | `TAGITTreasury.depositToken` is permissionless and feeds the drain detector's baseline (never remediated, never scored) |
| KI-20 | Low | Formal verification: 2 of 22 properties proven; 20 unresolved (all named below) |
| KI-21 | Low | Mythril covered 2 of 56 source files; every HIGH was self-triaged as a false positive |
| KI-22 | Low | `IntegrationFactory` enforces no minimum fee rate; the live signer set is 1-of-3 with two unowned addresses |
| KI-23 | Informational | `src/core/TAGITCoreDemo.sol` is a hackathon demo contract with no tests and no deployment |
| KI-24 | Informational | TODO/FIXME/XXX/HACK sweep results |
| KI-25 | Critical — **REMEDIATED** | TAGIT-VDP-2026-001: AIRP ran a full bonded dispute and never moved the asset. Fixed; four adjacent findings remain open and are listed as KI-26..KI-29 |
| KI-26 | Medium | `TAGITCore.approveResolve` first-approver-binds-recipient deadlock — no way to reset a resolve round |
| KI-27 | Medium | The `TAGITRecovery` proxy owner is the deployer EOA, not the TimelockController |
| KI-28 | Medium | `RESOLVER_CAPABILITY` and `FLAGGER_CAPABILITY` rosters are unpopulated — the whole recovery path is inert |
| KI-29 | Low | `TAGITGovernor._countVote` was an empty-bodied override of an abstract OZ hook (hardened in the same change) |

---

# CRITICAL

## KI-01 — Deployer EOA is a single point of total protocol compromise; timelock delay is 60 seconds

**Severity:** Critical

**Location:**
- `deployment-addresses.json` → `networks.base-sepolia.contracts.TimelockController` = `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1`
- `script/Deploy.s.sol:80-81`
- `script/deploy/DeployBaseSepoliaFull.s.sol:277-279`

**Description.**
A single externally-owned account, `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D`, holds both the
`PROPOSER` and `EXECUTOR` roles on the TimelockController, is the registered `trustedOracle`, and
owns roughly 20 of the deployed contracts. The timelock's minimum delay is 60 seconds:

```
$ cast call 0xfdA2478dB73064eF770f4e5E5b97BC83801126e1 "getMinDelay()(uint256)" \
    --rpc-url https://sepolia.base.org
60
```

The 2026-07-17 TAGITCore upgrade went from `schedule` to `execute` in 75 seconds. A 60-second
delay provides no window for anyone to observe a malicious upgrade and react.

The deploy scripts state the intent plainly and never delivered on it:

```solidity
// script/Deploy.s.sol:80-81
proposers[0] = deployer; // TODO: Replace with Gnosis Safe 3-of-5 address
executors[0] = deployer; // TODO: Replace with Gnosis Safe 3-of-5 address
```

The Gnosis Safe referenced in our architecture material,
`0xAaA33C556C9c97a5430D180A1f72e8cf0fe0354e`, **has no code on Base Sepolia**. It exists only on
the archived OP Sepolia deployment, where `getThreshold()` returns 1 and its sole owner is the
same deployer EOA. There is no multi-party control anywhere in the live system.

**Impact.**
Compromise of one private key yields: arbitrary UUPS upgrade of every proxy (60-second delay),
arbitrary oracle attestations into `bindTag`, and owner-level control of ~20 contracts. This is
total protocol compromise. Every "protected by governance" and "trusted role" justification in our
older security documents reduces to "protected by this one key".

**Status.** Open. Confirmed on-chain 2026-07-27. Not remediated.

**Planned remediation.**
Deploy a real Safe on the target chain and hand it `PROPOSER`; give `EXECUTOR` to a separate
address or to `address(0)` (open execution); revoke both roles from the deployer EOA; raise
`getMinDelay()` to a value that permits reaction (we are targeting 48 hours for mainnet, to be
confirmed with Hacken); move `trustedOracle` to a dedicated signer with its own key custody.
This is a pre-mainnet blocker on our side, not a post-audit item.

---

# HIGH

## KI-02 — `emergencySweep` is unexecutable on the live deployment: 1 registered signer vs `REQUIRED_SIGNERS = 6`

**Severity:** High

**Location:**
- `src/treasury/TAGITTreasury.sol:61` (`uint256 public constant REQUIRED_SIGNERS = 6;`)
- `src/treasury/TAGITTreasury.sol:459-521` (`emergencySweep`)
- `src/treasury/TAGITTreasury.sol:110-113` (`_signers`, `_signerCount`)
- `script/deploy/DeployBaseSepoliaFull.s.sol:277-279` (initialised with a one-element signer array)

**Description.**
`emergencySweep` requires six distinct signatures from addresses registered in `_signers`. The
live Base Sepolia treasury (`0xa4a3720d705334f409DD24836CC75d642125f759`) was initialised with a
single signer — the deployer — and no signers have been added since:

```
$ cast storage 0xa4a3720d705334f409DD24836CC75d642125f759 9 --rpc-url https://sepolia.base.org
0x0000000000000000000000000000000000000000000000000000000000000001   # _signerCount == 1

$ cast call 0xa4a3720d705334f409DD24836CC75d642125f759 "REQUIRED_SIGNERS()(uint256)" \
    --rpc-url https://sepolia.base.org
6
```

(Slot 9 is `_signerCount`, per `forge inspect src/treasury/TAGITTreasury.sol:TAGITTreasury
storageLayout`.)

The emergency recovery path therefore cannot execute, and cannot execute until `setSigner`
(governor-gated, `TAGITTreasury.sol:588-593`) registers five more addresses.

**Impact.**
Two distinct problems:

1. **Availability.** The treasury has no working emergency recovery path. If funds need to be
   evacuated, they cannot be.
2. **Our documentation asserts a control that does not exist.** `tagit-security/reports/slither-baseline-summary.md:26`
   justifies accepting a HIGH `arbitrary-send-eth` finding on `emergencySweep` with "Protected by
   multisig quorum requirement". `.github/workflows/security.yml:42` justifies a **global Slither
   detector exclusion** with "TAGITTreasury.emergencySweep → 6/8 multisig over a hash binding `to`
   + nonce". The withdrawn EVMbench scorecard lists "E4 Emergency sweep drain — BLOCKED by 6/8
   multisig". On the live deployment that quorum is a single key, which is the same key described
   in KI-01. Please treat every "6-of-8 multisig" statement in our material as unverified until we
   re-issue it.

Note also that "6/8" appears nowhere in the code — the contract has a threshold of 6 and no
concept of a signer-set size. The "of 8" was never real.

**Status.** Open. Discovered and confirmed on-chain 2026-07-27 while preparing this document.

**Planned remediation.**
Register a real signer set before mainnet and add a deploy-time assertion that
`_signerCount >= REQUIRED_SIGNERS` so this cannot ship again. Correct the two justification texts
above. We are also considering whether `REQUIRED_SIGNERS` should be a configurable threshold
validated against `_signerCount` rather than a hardcoded constant.

---

## KI-03 — ERC-721 transfers are globally disabled while the contract still advertises ERC-721; two integration paths are dead and tested only against mocks

**Severity:** High

**Location:**
- `src/core/TAGITCore.sol:1410-1413` (`_update` override, PATCH-09)
- `src/escrow/OfferEscrow.sol:250-259` (`_settle`)
- `src/account/TAGITAccount.sol:538-544` (`exportAsset`)
- `test/unit/escrow/OfferEscrow.t.sol:23,83` (`MockNFT`)
- `test/account/TAGITAccount.t.sol:52,102` (`MockTAGITCore`)

**Description.**
PATCH-09 blocks every externally initiated ERC-721 transfer:

```solidity
// src/core/TAGITCore.sol:1410
function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
    if (auth != address(0)) revert TransferDisabled();
    return super._update(to, tokenId, auth);
}
```

This is live. Verified against the deployed proxy:

```
$ cast call 0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D \
    "transferFrom(address,address,uint256)" \
    0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D 0x...dEaD 1 \
    --from 0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D --rpc-url https://sepolia.base.org
Error: execution reverted, data: "0xa24e573d"      # TransferDisabled()

$ cast call 0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D \
    "supportsInterface(bytes4)(bool)" 0x80ac58cd --rpc-url https://sepolia.base.org
true
```

Three consequences:

1. **Interface non-compliance.** The contract reports ERC-721 support while `transferFrom`,
   `safeTransferFrom`, `approve` and `setApprovalForAll` are inert or reverting. Any wallet,
   indexer, bridge or marketplace that trusts `supportsInterface` will mis-handle these tokens.
   The only sanctioned owner-to-owner path is `transferAsset` (`TAGITCore.sol:1285`), which is
   non-standard and unknown to third parties.
2. **`OfferEscrow` cannot settle a TAG IT asset.** `_settle` calls
   `IERC721(st.nft).safeTransferFrom(st.seller, st.buyer, st.tokenId)` with the escrow as `auth`,
   which reverts. The P2P marketplace escrow is a dead path for the only NFT the protocol issues.
3. **`TAGITAccount.exportAsset` cannot export a TAG IT asset.** Same mechanism. Assets are not
   permanently stuck — the account can still reach `transferAsset` through `execute` — but the
   documented self-custody export function always reverts.

**Neither dead path is caught by the test suite, because neither test uses the real contract.**
`OfferEscrow.t.sol` instantiates `MockNFT` (a plain OpenZeppelin ERC-721) at line 83.
`TAGITAccount.t.sol` instantiates `MockTAGITCore` at line 102 and
`test_exportAsset_transfersNFT` (line 420) asserts a successful transfer against that mock. Both
tests pass. Both would fail against `TAGITCore`.

**Impact.**
The marketplace settlement path and the account-abstraction export path do not work against the
deployed core. More broadly, the codebase has a class of tests that validate behaviour against
mocks that do not share the real contract's restrictions, so integration regressions of this shape
are invisible to CI.

**Status.** Open. Confirmed on-chain and by reading the tests, 2026-07-27. PATCH-09 itself is
intentional (see KI-18); the integration breakage it caused was not noticed.

**Planned remediation.**
Decide and document the intended transfer model — either drop the ERC-721 interface claim, or add
an allowlist of authorised movers (escrow, account) to the `_update` gate. Then replace `MockNFT`
and `MockTAGITCore` with the real `TAGITCore` in `OfferEscrow.t.sol` and `TAGITAccount.t.sol`, and
add an integration test that asserts an end-to-end escrow settlement of a real asset. We would
value Hacken's view on which model is correct before we implement it.

---

## KI-04 — The bytecode the test suite exercises is not the bytecode that is deployed

**Severity:** High

**Location:** `foundry.toml:1-30` (see the comment block at lines 10-20)

**Description.**
`TAGITCore` exceeds the EIP-170 24,576-byte runtime limit under the default profile. Per the
comment at `foundry.toml:11-13`, it measures **26,076 bytes** under legacy codegen — 1,500 bytes
over the limit — and **22,601 bytes** under `FOUNDRY_PROFILE=deploy` (via-ir). The deployed
implementation confirms the via-ir figure exactly:

```
$ C=$(cast code 0x2377B7f33aFf34c58DDF6DeA7eD4dCaD616CA14C --rpc-url https://sepolia.base.org)
$ echo $(( (${#C} - 2) / 2 ))
22601
```

The test suite runs on the default profile (`via_ir = false`, `foundry.toml:8`). Production ships
via-ir. The reason the suite is not simply moved to via-ir is recorded at `foundry.toml:14-16`:
under via-ir, solc CSE-caches `block.timestamp` across `vm.warp()`, and **13 time-dependent tests
read stale time** and fail. We believe this is a test-harness artifact rather than a contract
defect (the batch-lifecycle suite passes 51/51 under via-ir), but we have not proven that, and it
is exactly the sort of belief an auditor should not take on trust.

**Impact.**
Every test result, gas figure and coverage number we can give you describes a build that is never
deployed. Optimiser-sensitive behaviour — and the 1,500-byte difference is not marginal — is
untested in the shipped form. A deployment or upgrade performed without `FOUNDRY_PROFILE=deploy`
reverts with max-code-size-exceeded, which is a live operational footgun documented only in a
`foundry.toml` comment.

**Impact on your engagement specifically:** if you run `forge test` or `forge coverage` out of the
box, you are analysing the legacy-codegen build.

**Status.** Open. Deployed size verified on-chain 2026-07-27. The 26,076-byte legacy figure is
taken from the `foundry.toml` comment and was **not re-measured** for this document; to re-measure:
`forge build --sizes | grep TAGITCore`.

**Planned remediation.**
Make the suite warp-robust so via-ir can be the global profile, or extract the per-item lifecycle
helpers into an external library so the contract fits under legacy codegen. Until then, we will
run and publish a second CI job that executes the full suite under `FOUNDRY_PROFILE=deploy` and
reports the 13 failures explicitly rather than hiding them behind a profile switch.

---

## KI-05 — `TAGITPaymaster` reads the sponsored selector from a hardcoded calldata offset

**Severity:** High (unconfirmed — no proof-of-concept written)

**Location:** `src/account/TAGITPaymaster.sol:190-210`

**Description.**
To decide whether an operation is sponsored, the paymaster extracts the inner function selector
from an `execute(address,uint256,bytes)` call by indexing a fixed position, without ever reading
the ABI offset word:

```solidity
// src/account/TAGITPaymaster.sol:193-203
if (accountSelector == executeSelector && userOp.callData.length >= 100) {
    // Simplified: assume func bytes are at fixed position after offset (68 + 32 = 100)
    if (userOp.callData.length >= 136) {
        selector = bytes4(userOp.callData[132:136]);
    }
}
```

Byte 132 is where the inner calldata begins **only if** the `bytes` offset word equals `0x60`.
The offset word is attacker-controlled. A caller can set it to any larger value, place the real
inner calldata there, and leave a sponsored selector sitting at bytes 132-136 as a decoy. The
account's own `execute` decodes with the real offset and calls the real target; the paymaster has
already approved sponsorship based on the decoy.

**Impact.**
If exploitable as described, the sponsorship allowlist at
`_sponsorshipConfigs[selector]` (line 207) can be bypassed: the paymaster would fund arbitrary
calls. Per-operation exposure is bounded by `config.maxGas * tx.gasprice` (line 213) and
`config.dailyLimit` (line 222), but the daily limit is keyed on
`(user, selector, day)`, so an attacker controlling many accounts scales linearly against the
paymaster's EntryPoint deposit.

**We are explicitly not claiming this is proven.** We identified it by reading the code on
2026-07-27. We have not written an exploit test, we have not confirmed the account's `execute`
decodes the way we assume, and we have not measured how much of the deposit is reachable. We are
disclosing it at the confidence level we actually have.

**Status.** Open, unconfirmed. No test exists. Not previously reported by any tool — Slither,
Mythril, Halmos and the EVMbench run all missed it, which is itself informative about the coverage
of our tooling.

**Planned remediation.**
Decode the `bytes` argument properly (`abi.decode` on the calldata slice, or read the offset word
and bounds-check it) instead of indexing a constant. We would like this specific function
prioritised in your review, since our own confidence in the surrounding parsing logic is now low.

---

## KI-06 — No passing fork / live-chain tests; the fork suite targets a chain we have never deployed to

**Severity:** High

**Location:**
- `test/fork/ForkBase.t.sol:56` (`uint256 public constant FORK_BLOCK = 125000000;`)
- `test/fork/ForkBase.t.sol:86-90`
- `.github/workflows/fork-test.yml`

**Description.**
The fork test base asserts it is running on OP **Mainnet**:

```solidity
// test/fork/ForkBase.t.sol:90
assertEq(block.chainid, 10, "Should be OP Mainnet (chainId 10)");
```

We have never deployed to OP Mainnet. `FORK_BLOCK` is pinned to 125000000, a block that does not
correspond to our deployment on any chain. The workflow is named "Fork Tests (OP Sepolia)", which
matches neither the assertion nor the live network. The live network is Base Sepolia (84532);
OP Sepolia (11155420) and Arbitrum Sepolia (421614) were archived on 2026-06-27.

The workflow runs daily on cron and fails every time:

```
$ gh run list --workflow=fork-test.yml --limit 60 --json conclusion,createdAt
# 60 runs returned, 60 failures, no successes
# newest 2026-07-27T10:01:25Z, oldest in the streak 2026-05-29T07:33:40Z
```

Sixty consecutive failures is only the extent of what the API returned in one page; the streak
predates 2026-05-29.

**Impact.**
Nothing in CI has ever exercised the deployed contracts against real chain state. Proxy wiring,
role assignments, oracle configuration, cross-contract integration and upgrade correctness on the
live deployment are all **unverified by automated testing**. KI-02 (one signer where six are
required) and KI-03 (escrow settlement reverts against the real core) are both examples of
defects that a working live-chain test would have caught immediately.

A daily red job that nobody fixes for two months is also a process finding in its own right.

**Status.** Open. Failure count measured 2026-07-27.

**Planned remediation.**
Retarget `ForkBase.t.sol` to chainId 84532, unpin `FORK_BLOCK` (or pin it to a Base Sepolia block
after the 2026-07-17 core upgrade), rename the workflow, and add assertions against the addresses
in `deployment-addresses.json` — proxy implementation slots, timelock roles, treasury signer
count, oracle address. Until that lands, please treat "the deployment matches the source" as
unverified except where this document shows a specific `cast` read.

---

# MEDIUM

## KI-07 — `TAGITAccount.exportAllAssets` transfers nothing and emits a success event

**Severity:** Medium

**Location:** `src/account/TAGITAccount.sol:547-556`

**Current blast radius — checked on chain 2026-07-28.** `TAGITAccountFactory.totalAccounts()` on
Base Sepolia returns **0**: no `TAGITAccount` clone has been deployed, so no user can call this
today. The severity is Medium rather than High for that reason alone. It becomes a
user-funds-visible correctness bug the moment the first account is created, because the caller
receives an `AllAssetsExported` event and reasonably concludes their assets moved.

**Description.**

```solidity
function exportAllAssets(address destination) external override onlyOwner nonReentrant {
    if (destination == address(0)) revert ZeroAddress();
    if (_tagitCore == address(0)) revert ZeroAddress();

    uint256 balance = IERC721(_tagitCore).balanceOf(address(this));
    // Note: This requires enumerable extension or tracking owned tokens
    // For now, emit event - actual implementation would iterate tokens
    emit AllAssetsExported(destination);
}
```

The function reads a balance, discards it, transfers nothing, and emits `AllAssetsExported` as if
it had succeeded. It is a declared interface function (`ITAGITAccount`), not internal scaffolding,
and the comment concedes it is unimplemented.

**Impact.**
A user who calls this to evacuate their assets receives a successful transaction and a success
event, and their assets have not moved. Any off-chain system that indexes `AllAssetsExported` —
support tooling, a wallet UI, an accounting pipeline — will record an export that never happened.
Silent no-ops behind success events are worse than reverts.

Note that even if it were implemented, it would revert against the real core for the reason in
KI-03.

**Status.** Open. Never reported by any prior review. Found while reading `TAGITAccount.sol` on
2026-07-27.

**Planned remediation.** Implement it (requires owned-token tracking, since `TAGITCore` is not
`ERC721Enumerable`) or remove it from the interface. Shipping it as a no-op is not acceptable in
either case. We lean toward removal.

---

## KI-08 — Emergency-sweep signatures never expire and do not bind an amount

**Severity:** Medium
*(This is the "emergency sweep same-day replay" finding, T3, re-written. The original is
remediated; this is the residual.)*

**Location:** `src/treasury/TAGITTreasury.sol:465-468`, `:496-509`

**Original finding (T3).** The pre-PATCH-08 signature digest used `block.timestamp / 1 days` as
its nonce, so a valid set of six signatures could be replayed any number of times within the same
UTC day. Source: `tagit-security/evmbench/results/detect-treasury-postpatch.md`.

**Current state.** Remediated by PATCH-08. The digest now uses a monotonic counter:

```solidity
// src/treasury/TAGITTreasury.sol:466-467
bytes32 messageHash = keccak256(abi.encodePacked(
    "TAGIT_EMERGENCY_SWEEP", block.chainid, address(this), token, to, _sweepNonce));
```

`_sweepNonce` increments on every successful sweep (line 509). Regression tests exist:
`test/security/EVMbenchFixes.t.sol:230-277` (`test_PATCH08_sweepNonce_startsAtZero`,
`test_PATCH08_emergencySweep_incrementsNonce`,
`test_PATCH08_emergencySweep_revert_replayWithOldNonce`,
`test_PATCH08_emergencySweep_succeedsWithNewNonce`). Live state confirms the patched code is
deployed:

```
$ cast call 0xa4a3720d705334f409DD24836CC75d642125f759 "sweepNonce()(uint256)" \
    --rpc-url https://sepolia.base.org
0
```

**Residual, which we are disclosing as the open part:**

1. **Signatures have no expiry.** A signature collected for nonce *N* stays valid until a sweep
   actually consumes nonce *N*. If signers approve a sweep and then change their minds, the only
   way to invalidate the collected signatures is to execute some other sweep. There is no deadline
   field and no cancel path.
2. **The digest does not bind an amount.** `emergencySweep` always transfers the *entire* balance
   (lines 496-502). Signers approving a sweep at one balance are, in effect, approving it at any
   future balance. Combined with (1), a set of signatures gathered when the treasury held a small
   amount authorises the sweep of an arbitrarily larger amount later.
3. The digest correctly includes `block.chainid` and `address(this)`, so it is not replayable
   across chains or deployments. (Contrast with KI-09, where the same care was not taken.)

**Impact.** Bounded by the signer set, which today is one address (KI-02). On a properly
configured signer set, the residual is that approval is open-ended in both time and amount.

**Status.** Original finding closed. Residual open, not yet tracked as work.

**Planned remediation.** Add a `deadline` to the signed digest and validate it; add an expected
`amount` (or a maximum) to the digest; consider a `bumpSweepNonce()` governor function so pending
approvals can be revoked without executing a transfer.

---

## KI-09 — `IntegrationFactory` multi-sig digests are not domain-separated across the three deployments

**Severity:** Medium

**Location:** `src/agent/IntegrationFactory.sol:247-248`, `:268-271`, `:281-299`, `:318-332`, `:438-465`

**Description.**
Every multi-sig-gated function in `IntegrationFactory` builds its digest from an action string, its
arguments and a contract-local `_nonce`, with no chain ID and no contract address:

```solidity
// src/agent/IntegrationFactory.sol:321
_verifyMultiSig(keccak256(abi.encodePacked("EMERGENCY_PAUSE", _nonce)), signatures);
```

`IntegrationFactory` is a non-upgradeable contract deployed independently on three networks by the
same deployer, with the same signer-derivation logic (`DeployBaseSepoliaFull.s.sol:438-442`), and
therefore the same signer set:

| Network | Address |
|---|---|
| Base Sepolia (primary) | `0xd68919371c26700dDb8252aD1825Aa02a0381a86` |
| OP Sepolia (archived) | `0xac3687df5A09a5FeD697eb40B6dB22a98cC7B0a8` |
| Arbitrum Sepolia (archived) | `0x7580f30625730C8Ad1086bC36eeB1258472430EA` |

A signature produced for `EMERGENCY_PAUSE` / `ADD_SIGNER` / `SET_MAX_PAYMENT` / `REACTIVATE` on
one deployment is valid on the others whenever their `_nonce` values coincide — which they do at
deployment, since all three start at the same value.

The affected actions are `reactivateIntegration`, `setMaxPayment`, `addSigner`, `removeSigner`,
`emergencyPause`, `emergencyUnpause`.

**Impact.**
Cross-deployment signature replay on administrative actions, including signer-set modification
(`addSigner`). Materially reduced today because the live threshold is 1 and the signer is the
deployer (KI-22), and because two of the three deployments are archived — but the pattern is wrong
and will be wrong on mainnet.

The same codebase gets this right elsewhere: `TAGITTreasury.emergencySweep` includes both
`block.chainid` and `address(this)`. The inconsistency is the finding.

**Status.** Open. Found 2026-07-27. Not previously reported.

**Planned remediation.** Add `block.chainid` and `address(this)` to every `_verifyMultiSig`
digest, or move the contract to EIP-712 with a proper domain separator. We prefer EIP-712 for
consistency.

---

## KI-10 — Paymaster circuit breaker counts only successful validations and does not reject the operation that trips it

**Severity:** Medium
*(This is the "paymaster circuit-breaker bypass" finding, R4, re-written. Our assessment differs
from the original report's; both are given.)*

**Location:** `src/account/TAGITPaymaster.sol:171-182`; `src/libraries/CircuitBreaker.sol:152-183`

**Original finding (R4).** From
`tagit-security/evmbench/results/detect-remaining-postpatch.md`: an attacker sends userOps with
`callData.length < 4`; these pass the circuit-breaker check but revert at the length check, so the
breaker's counter is never incremented, "potentially draining the paymaster's deposit with
unlimited sponsored operations." Recommended fix: move the length check before the breaker.

**Our assessment of the original claim.** The drain conclusion does not hold. Validation reverts
propagate to the EntryPoint, the userOp is dropped, and the paymaster's deposit is not charged.
Reordering the two checks also changes nothing on-chain, because a revert rolls back the counter
increment either way. We are stating this rather than quietly carrying the finding at its original
severity.

**What is actually wrong, and remains open.**

1. **The counter only records successful validations.** `_sponsorCircuit.check()`
   (`TAGITPaymaster.sol:174`) increments `self.count` (`CircuitBreaker.sol:169`), but every
   downstream failure path — `InvalidPaymasterData` (line 181), `OperationNotSponsored` (line 209),
   `GasLimitExceeded` (line 214), `DailyLimitExceeded` (line 223), `DepositTooLow` (line 229) —
   reverts and rolls that increment back. An adversary probing the paymaster with thousands of
   rejected operations is completely invisible to the anomaly detector. The breaker is documented
   as a volume-anomaly detector; it is in fact a successful-sponsorship counter.
2. **A tripped breaker still sponsors the operation that tripped it.** When `check()` returns
   true, the paymaster sets `_paused = true` and emits an event (lines 174-177) but does not
   revert; validation continues and the operation is sponsored. The pause takes effect one
   operation late.

The configured threshold is 500 sponsorships per 1-hour window with a 2-hour cooldown
(`TAGITPaymaster.sol:116`).

**Impact.** The circuit breaker provides materially less protection than our documentation claims
— it cannot see hostile traffic that fails validation, which is precisely the traffic an anomaly
detector exists to see.

**Status.** Open. Not remediated. Our re-assessment dated 2026-07-27.

**Planned remediation.** Record rejected validation attempts in a way that survives the revert
(the EntryPoint's validation rules restrict what state a paymaster may write during validation, so
this needs design work — likely counting in `postOp`, plus off-chain monitoring for rejected ops).
Make a trip reject the tripping operation. Correct the documentation either way.

---

## KI-11 — Measured coverage is 63.82% against a CI threshold of 85%; the Coverage Check job fails on every run

**Severity:** Medium

**Location:** `.github/workflows/coverage-check.yml:26,39-45`

**Description.**
The gate is set at 85%:

```yaml
# .github/workflows/coverage-check.yml:39
THRESHOLD=85
```

The last measured figure is **63.82%** line coverage, from CI running
`forge coverage --report summary --no-match-test 'gasEfficiency'`. The job consequently fails, and
has failed on every run we can see:

```
$ gh run list --workflow=coverage-check.yml --limit 8
# 8 runs returned, 8 failures, back to 2026-05-12
```

A previously circulated **87%** figure was false. The documents asserting it were deleted on
2026-07-26. Please treat any surviving 87% claim as withdrawn.

We did **not** re-run coverage while writing this document. To reproduce:
`forge coverage --report summary --no-match-test 'gasEfficiency'`. Note that per KI-04 this
measures the legacy-codegen build, and per KI-15 it measures a working tree that contains
untracked test files the audit clone will not have.

Suite size, measured 2026-07-27 by grep over git-tracked test files
(`git ls-files 'test/*.sol' | xargs grep -hE "^\s*function (test|invariant|check)" | wc -l`):

| Metric | Count |
|---|---|
| `test*` / `invariant_*` / `check_*` declarations, tracked files | 1,865 |
| Same, including the two untracked test files | 2,020 |
| `testFuzz_*` functions, tracked | 80 |
| `invariant_*` functions | 12 |
| `check_*` (Halmos) functions | 22 |
| Test files, tracked | 80 |

Fuzz configuration is `runs = 100000` (`foundry.toml:34`); invariant configuration is
`runs = 256, depth = 500, fail_on_revert = true` (`foundry.toml:38-41`). The last recorded CI
result is 0 failing tests; we did not re-run the suite for this document.

Note that our older documents describe "20 fuzz tests × 10,000 runs". Both halves of that are now
stale — there are 80 `testFuzz_` functions in tracked files (88 including the
two untracked ones) and the configured run count is 100,000.

**Impact.**
Roughly a third of the codebase's lines are unexercised, and we do not currently have a
per-contract breakdown of *which* third — that is the number that matters to you, and we have not
produced it.

**Status.** Open. The gate has never passed.

**Planned remediation.** Produce and publish a per-contract coverage table so the gaps are
visible rather than averaged away; set the threshold to a number we actually meet and ratchet it
upward; prioritise coverage on the contracts holding value (`TAGITTreasury`, `TAGITStaking`,
`TAGITEmissions`, `OfferEscrow`, `VerificationEscrow`).

---

## KI-12 — Two tests assert nothing, and one of them is a named invariant

**Severity:** Medium

**Location:**
- `test/invariant/TAGITCore.invariant.t.sol:390`
- `test/fork/CCIPFork.t.sol:314`

**Description.**
Verified by reading both files on 2026-07-27. The exact lines:

```solidity
// test/invariant/TAGITCore.invariant.t.sol:384-391
function invariant_stateTransitionsValid() public view {
    // Verify bind operations came from minted tokens
    // Verify activate operations came from bound tokens
    // This is implicitly tested by the handler logic

    // The handler maintains proper state tracking
    assertTrue(true, "State transitions validated by handler");
}
```

```solidity
// test/fork/CCIPFork.t.sol:311-315
} catch {
    // Expected - CCIP router doesn't support this route
    // This is valid behavior - the adapter correctly delegates to router
    assertTrue(true, "Router correctly rejected unsupported route");
}
```

`assertTrue(true, ...)` is unconditionally true. Neither line can fail.

The first is the more serious of the two. `invariant_stateTransitionsValid` is one of ten
`invariant_*` functions in that file
(`TAGITCore.invariant.t.sol:342,352,359,368,384,396,408,422,438,455`) and it appears in test
output and in our reporting as a passing invariant covering state-transition validity. It covers
nothing. The comment "This is implicitly tested by the handler logic" is an assertion about the
handler, not a check of it.

The second is inside a fork test that has never run (KI-06), so its practical effect is nil, but
the pattern — a `catch` block that "passes" whatever happened — is the same.

A repo-wide sweep found exactly these two:
`git ls-files 'test/*.sol' | xargs grep -n "assertTrue(true"` → 2 results.

**Impact.**
Our invariant count over-states what is actually verified. Please discount
`invariant_stateTransitionsValid` entirely when assessing our state-machine coverage. Forward-only
state-transition enforcement is, as far as we can currently show, unverified at the invariant
level.

**Status.** Open. Verified 2026-07-27.

**Planned remediation.** Implement `invariant_stateTransitionsValid` as a real check — the handler
already records transition history, so the invariant should read it and assert no illegal edge
occurred (forward-only, except FLAGGED → CLAIMED via `resolve`). Replace the `CCIPFork` catch
block with an assertion on the specific expected revert. Add a lint rule rejecting
`assertTrue(true`.

---

## KI-13 — Two Slither detectors are globally excluded; the gate that uses that config cannot block, and a second CI job runs Slither differently

**Severity:** Medium

**Location:** `slither.config.json`; `.github/workflows/security.yml:33-47`; `.github/workflows/security-gate.yml:48-72`

**Description.**
The full contents of `slither.config.json`:

```json
{
  "detectors_to_exclude": "arbitrary-send-eth,arbitrary-send-erc20",
  "filter_paths": "lib/,test/,script/",
  "exclude_informational": false,
  "exclude_low": false,
  "exclude_medium": false,
  "exclude_high": false
}
```

Taking each risk acceptance in turn:

**`arbitrary-send-eth` — excluded globally. Written justification: yes, but only as a CI comment.**
The justification lives at `.github/workflows/security.yml:38-46` and names five call sites:
`TAGITAccount._call`, `TAGITAccount._payPrefund`, `OfferEscrow.fundOffer`,
`TAGITTreasury.emergencySweep`, `CCIPAdapter._sendResponse`. A second, partially overlapping
justification for four sites is at `tagit-security/reports/slither-baseline-summary.md:20-27` and
`security/SECURITY-ANALYSIS-SUMMARY.md:19`. Neither justification is in `slither.config.json`
itself, where a reader of the repo would look. **One of the five justifications is now known to be
false**: the `emergencySweep` entry claims "6/8 multisig over a hash binding `to` + nonce", and the
live contract has one signer against a threshold of six (KI-02).

**`arbitrary-send-erc20` — excluded globally. Written justification: none specific to this
detector.** It is covered only by inclusion in the same comment block; no document names the
detector or enumerates its hits. `tagit-security/reports/slither-baseline-summary.md` does not
mention it at all. We are marking this **no written justification** and are not going to construct
one retroactively.

**The scope of both exclusions is the problem.** These are *global* suppressions across all 56
files in `src/`, not per-finding triage. Five sites were reviewed once, in February; every
arbitrary-send introduced since then, in any contract, is silently unreported. `OfferEscrow.sol`
(added 2026-05-13) and `ReputationStaking.sol` (added 2026-05-23) both post-date that review.

**`filter_paths` excludes `script/`.** Deploy scripts are never statically analysed. Those scripts
are where the timelock roles are assigned (KI-01), where the treasury is initialised with one
signer (KI-02), and where the `IntegrationFactory` signer set is derived from `keccak256` (KI-22).
Excluding `lib/` and `test/` is normal; excluding `script/` in a repo whose deploy scripts
configure the entire trust model is a real gap.

**Neither CI gate can block on this configuration.**
- `.github/workflows/security.yml:47` runs `slither . --config-file slither.config.json
  --exclude-dependencies --fail-high` — it uses the config above but fails only on HIGH. The
  comment at lines 34-36 states ~180 low/informational results are "reviewed in the log, not
  blockers".
- `.github/workflows/security-gate.yml:48-72` runs a **different** Slither invocation
  (`crytic/slither-action@v0.4.0`, `--filter-paths "test|script|lib"`,
  `--exclude naming-convention,solc-version,pragma`) that does **not** load
  `slither.config.json` and does **not** exclude the arbitrary-send detectors — but the job is
  `continue-on-error: true` (line 51), so it can never fail the build.

So: the config that suppresses findings is used by the job that gates, and the job that does not
suppress them cannot gate.

**Status.** Open. All statements above verified by reading the files on 2026-07-27.

**Planned remediation.** Move to per-finding triage (`--triage-mode` / an explicit
`slither.db.json`) so suppressions are individually attributable and new hits surface; delete the
global `detectors_to_exclude`; write the justifications into the repo rather than into a workflow
comment; correct the `emergencySweep` justification; add `script/` back into scope; consolidate the
two Slither jobs into one that can actually fail.

---

## KI-14 — The Slither baseline is ~5 months stale and predates 10 of the contracts now in `src/`

**Severity:** Medium

**Location:** `tagit-security/reports/slither-baseline-summary.md`, `tagit-security/reports/slither-baseline.json`

**Description.**
The baseline is dated **2026-02-20** and was produced with Slither **0.11.3**. CI now pins
**0.11.5** (`.github/workflows/security.yml:31`), so the baseline is not reproducible with the
version currently in use.

Counts, re-measured from `slither-baseline.json` on 2026-07-27 (151 detector results total):

| Impact | Count | Detectors |
|---|---|---|
| High | 4 | `arbitrary-send-eth` ×4 |
| Medium | 36 | `unused-return` ×24, `uninitialized-local` ×7, `divide-before-multiply` ×2, `reentrancy-no-eth` ×2, `incorrect-equality` ×1 |
| Low | 55 | — |
| Informational | 54 | — |
| Optimization | 2 | — |

Note the summary document's own table says "Medium 34" while its section heading says "MEDIUM
Findings (36)". The JSON says 36. The discrepancy is the two `reentrancy-no-eth` findings that
were fixed on 2026-03-30 and subtracted from the table but not from the heading or the JSON. Our
summary is internally inconsistent; the JSON is the authority.

**Ten non-interface contracts were added to `src/` after the baseline date** and are therefore not
covered by it (creation dates from `git log --diff-filter=A`):

| Added | File |
|---|---|
| 2026-02-24 | `src/agent/IntegrationFactory.sol` |
| 2026-03-06 | `src/core/TAGITCoreDemo.sol` |
| 2026-03-12 | `src/robot/RoboticAuthorizer.sol` |
| 2026-03-12 | `src/libraries/RobotTypes.sol` |
| 2026-03-17 | `src/escrow/VerificationEscrow.sol` |
| 2026-03-26 | `src/mirror/TAGITStateAnchor.sol` |
| 2026-03-30 | `src/token/wTAG.sol` |
| 2026-03-30 | `src/token/wTAGStaking.sol` |
| 2026-05-13 | `src/escrow/OfferEscrow.sol` |
| 2026-05-23 | `src/agent/ReputationStaking.sol` |

Three of these — `VerificationEscrow`, `wTAG`, `wTAGStaking` — hold or move value and are
deployed on Base Sepolia. `OfferEscrow` handles NFT-for-USDC settlement.

The baseline also predates PATCH-07 through PATCH-16, i.e. most of the security changes described
elsewhere in this document.

**Impact.** The static-analysis evidence we can hand you does not describe the code you will be
auditing.

**Status.** Open. A current baseline has **not** been produced. To produce one:
`slither . --config-file slither.config.json --exclude-dependencies --json slither-current.json`
(Slither 0.11.5 is installed locally).

**Planned remediation.** Regenerate the baseline against HEAD with the pinned version before the
engagement starts and hand you both the JSON and a per-finding triage, not a prose summary.

---

## KI-15 — Three production source files and 155 test functions are untracked and therefore outside the audit clone

**Severity:** Medium

**Location:** the maintainer's working tree (untracked; not present in any clone)

**Description.**
`git status --porcelain src/` shows three untracked production files:

```
?? src/interfaces/IVoucher.sol
?? src/interfaces/IwTAG.sol
?? src/token/Voucher.sol
```

These do not exist in the repository and will not exist in a clone. Verified: no tracked file
references them, and a fresh clone builds successfully (`forge build`, exit 0) without them.

Two test files are also untracked:

| File | Test functions |
|---|---|
| `test/token/wTAG.t.sol` | 101 |
| `test/token/Voucher.t.sol` | 54 |

**This matters most for `wTAG`.** `src/token/wTAG.sol` **is** tracked and **is** deployed on Base
Sepolia at `0x746385e59aCB225779D64e74200e464a3f1C23d0`, but its 101-test file is not tracked. The
audit clone therefore contains a live, value-holding wrapper contract with **no direct test file**
— the only tracked test touching it is `test/token/wTAGStaking.t.sol`, which exercises it
indirectly. `wTAGStaking.sol` (`0xBd4c4848C9fF09B7955a193E3b96456344D9acBe`) is in the same
position with respect to direct coverage of its dependency.

Any coverage figure measured in this working tree (including the 63.82% in KI-11) is measured with
those 155 tests present. The clone you receive will measure lower.

**Impact.** Two production files that exist on the developer's machine are invisible to the audit.
A deployed contract ships to you with its test file removed. Coverage numbers do not transfer
between the working tree and the clone.

**Status.** Open; this is being handled as part of the same audit-prep effort as this document
(see the P0 manifest work on this branch). `Voucher.sol` / `IVoucher.sol` / `IwTAG.sol` are not
deployed and not referenced; the open decision is whether to commit them or delete them.

**Planned remediation.** Commit `test/token/wTAG.t.sol` and `test/token/Voucher.t.sol`
unconditionally — deployed code must ship with its tests. Decide `Voucher` in or out and act on it.
Re-measure coverage from a clean clone and republish the number.

---

# LOW

## KI-16 — Allocation-expiration bypass (remediated; disclosed for completeness)

**Severity:** Low (as it stands today; was High before PATCH-07)

**Location:** `src/treasury/TAGITTreasury.sol:381-385`; original at `:312-328` and `:370`

**Original finding (T5).** From
`tagit-security/evmbench/results/detect-treasury-postpatch.md`: `queueWithdrawal` checked
allocation expiry at queue time, `executeWithdrawal` did not re-check it. A recipient could queue
a withdrawal on day 29 of a 30-day allocation with a 7-day timelock and execute it on day 36,
after the allocation should have lapsed.

**Current state.** Remediated by PATCH-07:

```solidity
// src/treasury/TAGITTreasury.sol:381-385
// PATCH-07: Verify allocation hasn't expired since withdrawal was queued
Allocation storage alloc = _allocations[withdrawal.allocationId];
if (block.timestamp >= alloc.expiresAt) {
    revert AllocationExpired(withdrawal.allocationId, alloc.expiresAt);
}
```

Regression tests: `test/security/EVMbenchFixes.t.sol:180`
(`test_PATCH07_executeWithdrawal_revert_allocationExpired`) and `:207`
(`test_PATCH07_executeWithdrawal_succeeds_beforeExpiry`).

**Residual we have not resolved.** The fix makes an expired allocation's queued withdrawals
permanently unexecutable, but nothing cancels them or restores `alloc.spent`. They sit as PENDING
forever unless someone calls `cancelWithdrawal` (`:440-449`), which the governor or recipient can
do. Accounting drift is possible if nobody does. This is a bookkeeping issue, not a fund-loss one.

**Status.** Original closed. Residual open, low priority.

**Planned remediation.** Either auto-cancel on the expiry check or expose a permissionless sweep
that cancels expired-allocation withdrawals and restores the accounting.

---

## KI-17 — Epoch-skip emissions loss (remediated; residual compounding drift and a 12-epoch cap)

**Severity:** Low (as it stands today; was High before PATCH-10)

**Location:** `src/token/TAGITEmissions.sol:132-180`, `:62-64`

**Original finding (K1).** From
`tagit-security/evmbench/results/detect-token-postpatch.md`: `distributeEpoch` set
`_lastDistributedEpoch = epoch` (the current epoch) while distributing only that one epoch, so any
epochs skipped because nobody called the function had their inflation permanently lost.

**Current state.** Remediated by PATCH-10, which added a catch-up loop:

```solidity
// src/token/TAGITEmissions.sol:141-144,177
uint256 pendingEpochs = current - _lastDistributedEpoch;
uint256 epochsToDistribute = pendingEpochs > MAX_CATCH_UP_EPOCHS ? MAX_CATCH_UP_EPOCHS : pendingEpochs;
uint256 startEpoch = _lastDistributedEpoch + 1;
...
_lastDistributedEpoch = startEpoch + epochsToDistribute - 1;
```

`_lastDistributedEpoch` now advances only by the number actually distributed, so nothing is
skipped. Regression tests: `test/security/EVMbenchFixes.t.sol:393-476` (10 `test_PATCH10_*`
functions, including `test_PATCH10_cappedAtMaxCatchUpEpochs` and
`test_PATCH10_multiCallCatchUp`). Deployed state confirms the patch is live:

```
$ cast call 0x0672fcC5b753786C2cD1805494fF094CB5d6E579 "MAX_CATCH_UP_EPOCHS()(uint256)" \
    --rpc-url https://sepolia.base.org
12
```

**Residual we are disclosing.**

1. **Catch-up is capped at 12 epochs (~3 months) per call** (`TAGITEmissions.sol:62-64`). Missing
   more than 12 epochs requires repeated calls. Nothing is lost, but the contract can be behind
   for an unbounded period and no mechanism guarantees anyone calls it — `distributeEpoch` is
   permissionless but unincentivised.
2. **Late distribution is not equal to on-time distribution.** Each loop iteration recomputes
   `weeklyAmount` from the *then-current* `totalSupply` (line 150), so the amounts minted for a
   set of caught-up epochs differ from what would have been minted had each been distributed on
   schedule. The code comments this as intentional ("Compounds: each iteration uses updated
   totalSupply"). We are flagging it because it means the realised inflation schedule depends on
   *when* someone calls the function, which is an economic property worth an auditor's eye rather
   than a bug we are claiming.

**Status.** Original closed. Residual open, low priority.

**Planned remediation.** Add a keeper or a small caller incentive so the cap is never approached.
We would appreciate Hacken's view on whether the compounding behaviour matches the intended 3.33%
annual schedule.

---

## KI-18 — ERC-721 ownership desync was closed by prohibiting transfers, not by synchronising state

**Severity:** Low (as a finding in its own right; the mitigation's side effects are KI-03, High)

**Location:** `src/core/TAGITCore.sol:1410-1413`; original at `:844-894` (`claim`) and `:1010-1073` (`resolve`)

**Original finding (C1 / C2 / C4).** From
`tagit-security/evmbench/results/detect-core-postpatch.md`: `TAGITCore` maintained an internal
`asset.owner` alongside ERC-721 ownership and did not override transfer hooks, so a standard
`transferFrom` desynchronised the two. `claim` and `resolve` then read the stale internal owner and
called `_transfer(previousOwner, newOwner, tokenId)` against an owner who no longer held the token.
The recommended remediation was to override `_update` to **synchronise** `asset.owner` on every
transfer.

**What we actually did.** PATCH-09 overrides `_update` to **revert** on any externally initiated
transfer, so the desync cannot arise because the transfer cannot happen. The internal owner and
ERC-721 owner now move only through lifecycle functions (`claim`, `resolve`, `transferAsset`),
which update both.

We want to be explicit that this is a different fix from the one recommended, and that we chose
prohibition over synchronisation. The desync is genuinely closed — PATCH-09 regression tests at
`test/security/EVMbenchFixes.t.sol:282-388` cover `transferFrom`, `safeTransferFrom`,
`approve`-then-`transferFrom`, and confirm mint/claim/resolve/full-lifecycle still work.

**The cost of that choice is KI-03** — ERC-721 interface non-compliance and two broken integration
paths that no test caught. If your review concludes that the synchronising override was the right
call, we would rather hear that now than after mainnet.

Note also that the original C1/C2 write-ups over-stated the vulnerability: they claimed a caller
with `CLAIMER_CAPABILITY` could steal a desynced asset, but `_transfer` would have reverted on the
ownership mismatch rather than transferring the wrong token. The internal-state corruption was
real; the theft path as described was not.

**Status.** Closed by PATCH-09; verified live (see the `cast` output in KI-03). Design decision
open for review.

---

## KI-19 — `TAGITTreasury.depositToken` is permissionless and feeds the drain detector's baseline

**Severity:** Low

**Location:** `src/treasury/TAGITTreasury.sol:219-231`

**Description.**
This is finding **T1** from the EVMbench detect run. It was triaged as INVESTIGATE, was **never
assigned a score deduction**, was **never tracked as work**, and has **never been remediated**. We
are including it because "triaged and then forgotten" is exactly the category an auditor should
know about.

```solidity
function depositToken(address token, uint256 amount) external override nonReentrant {
    if (token == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    if (token == _tagitToken) {
        _drainConfig.recordDeposit(amount);
    }
    emit TokenDeposited(token, msg.sender, amount);
}
```

Anyone may deposit TAGIT, and doing so raises the drain detector's tracked balance, against which
percentage-based velocity and spike thresholds are computed.

**Impact as originally claimed:** an attacker inflates the tracked balance and then withdraws
amounts that would otherwise trip detection. **Our assessment:** the attacker must supply real
tokens to inflate the baseline, and withdrawals still require an allocation and a timelock
(`queueWithdrawal` → `executeWithdrawal`), so this is not a self-financing attack. The realistic
concern is threshold dilution — the detector's sensitivity is controllable by an unprivileged
party — rather than a drain. Hence Low rather than High.

Related and also unremediated: `syncDrainDetectorBalance` (governor-gated, `:594-597`) can set the
tracked balance directly; this was filed as T4/R3 and dismissed as "by design (governor is
trusted)". Per KI-01, "trusted governor" currently means the deployer EOA.

**Status.** Open. Never remediated, never scheduled.

**Planned remediation.** Restrict `depositToken`'s drain-detector side effect to authorised
protocol depositors, or compute thresholds from a governance-set reference balance instead of one
any caller can move.

---

## KI-20 — Formal verification: 2 of 22 properties proven; 20 unresolved

**Severity:** Low (as an issue); important as scope information

**Location:** `test/invariant/StateInvariants.t.sol` (22 `check_*` functions);
`tagit-security/reports/halmos-results-summary.md`; `tagit-security/reports/halmos-results.txt`

**Description.**
Halmos 0.2.0 / Z3 4.12.6.0, run 2026-02-20. Of 22 symbolic properties, **2 were proven** and **20
terminated with `Z3Exception: b'parser error'`**. Zero counterexamples were found. A parser error
is not a proof of anything — these properties are neither proven nor disproven.

**Proven (2):**
- `check_StateTransition_NoSkip_mint(bytes32)` — `mint()` always produces MINTED, 3 paths.
- `check_OwnershipConsistency_afterMint()` — internal owner matches `ownerOf()` after mint, 2 paths.

**Unproven (20), named in full:**

*State transitions (7)*
1. `check_StateTransition_NoSkip_bind`
2. `check_StateTransition_NoSkip_activate`
3. `check_StateTransition_NoSkip_claim`
4. `check_StateTransition_NoSkip_flag`
5. `check_StateTransition_NoSkip_resolve`
6. `check_StateTransition_NoSkip_recycle_fromClaimed`
7. `check_StateTransition_NoSkip_recycle_fromFlagged`

*Quorum (4)*
8-11. `check_FlaggedResolve_RequiresQuorum_*` (all four variants; all require ECDSA state setup)

*Batch mint (3)*
12. `check_BatchMint_Bounded`
13. `check_BatchMint_Bounded_validSize`
14. `check_BatchMint_Bounded_arrayMismatch`

*Terminal state (4)*
15-18. `check_RecycledIsTerminal_*` (all four variants)

*Other (2)*
19. `check_OwnershipConsistency_afterClaim`
20. `check_TagBinding_Unique`

The reported causes are ECDSA operations (`vm.sign`, `ECDSA.recover`), ERC-1967 packed proxy
storage, deep multi-call storage reads, and `keccak256` over symbolic concatenated data.

**What we are not claiming.** Our summary document asserts these are "comprehensively covered" by
fuzz and STRIDE tests. Fuzz testing samples; it does not prove. The honest statement is that **20
of our 22 formal properties are unverified**, including every property about quorum enforcement on
`resolve`, tag-binding uniqueness, and the terminality of RECYCLED. Two of those — tag-binding
uniqueness and resolve quorum — are core to the protocol's security claims.

**Status.** Open. Not re-run since 2026-02-20. Newer Halmos releases exist; we have not tested
whether they resolve the Z3 failures. Halmos is installed locally; to re-run:
`halmos --contract StateInvariants`.

**Planned remediation.** Re-run on current Halmos; for properties that remain unresolvable,
either restructure them to avoid symbolic ECDSA (e.g. abstract the oracle behind an assumption) or
evaluate Certora. We are not going to describe unresolved properties as covered again.

---

## KI-21 — Mythril covered 2 of 56 source files; every HIGH was self-triaged as a false positive

**Severity:** Low (as an issue); important as scope information

**Location:** `tagit-security/reports/mythril-core-report.md`,
`tagit-security/reports/mythril-treasury-report.md`

**Description.**
Two Mythril reports exist, both dated 2026-02-24, both with a 120-second execution timeout:
`TAGITCore.sol` (2 findings) and `TAGITTreasury.sol` (8 findings). `find src -name '*.sol' | wc -l`
returns **56**. So symbolic execution covered 2 of 56 files — roughly 4% — and neither run has been
repeated in five months.

A 120-second timeout on contracts of this size means even the two files analysed were almost
certainly not explored to any depth. The reports do not state a path-coverage figure and we do not
have one.

Every HIGH finding in both reports (7 × SWC-101, integer under/overflow) was triaged by us as a
false positive on the grounds that Solidity 0.8.23 inserts checked arithmetic. That reasoning is
generally sound, but it was applied by us, to our own code, without an independent check of any
individual site. The SWC-123 (requirement violation) and SWC-116 (`block.timestamp` in control
flow) findings were dismissed as "expected behavior" and "by design" respectively, again by us.

Note the reports say Solidity 0.8.23 while `foundry.toml:5` pins `solc = "0.8.28"`. The reports
describe a build we no longer produce.

**Status.** Open. Mythril is not currently installed on the build machine (`which myth` → not
found), so these results are not currently reproducible here.

**Planned remediation.** Either run Mythril across all 56 files with a realistic timeout and hand
you the full output, or drop the claim of symbolic-execution coverage entirely. We would rather
tell you we have 4% coverage from one tool than imply we have more.

---

## KI-22 — `IntegrationFactory` enforces no minimum fee rate; the live signer set is 1-of-3 with two unowned addresses

**Severity:** Low

**Location:** `src/agent/IntegrationFactory.sol:140-171`, `:100-113`;
`script/deploy/DeployBaseSepoliaFull.s.sol:437-444`

**Description.** Two related configuration issues.

**(a) No minimum fee rate.** `deployIntegration` validates only an upper bound:

```solidity
// src/agent/IntegrationFactory.sol:151
if (feeRate > uint96(BASIS_POINTS)) revert InvalidFeeRate(feeRate);
```

`feeRate = 0` is accepted, and `processPayment` then routes 100% of the payment to the partner and
0 to the burner (lines 188-205).

A prior report (`tagit-security/evmbench/results/audit.md`) framed this as "a malicious partner
could call `deployIntegration` with `feeRate=0`". **That premise is wrong** — `deployIntegration`
is `onlyOwner` (line 142), so a partner cannot self-deploy. The real residual is a missing
invariant: nothing prevents an owner from misconfiguring an integration to zero protocol revenue,
and nothing alerts if one is. Low, not High.

**(b) The live "multi-sig" is one key.** The Base Sepolia factory was constructed as:

```solidity
// script/deploy/DeployBaseSepoliaFull.s.sol:438-442
address[] memory signers = new address[](3);
signers[0] = deployer;
signers[1] = address(uint160(uint256(keccak256(abi.encodePacked(deployer, uint256(1))))));
signers[2] = address(uint160(uint256(keccak256(abi.encodePacked(deployer, uint256(2))))));
IntegrationFactory factory = new IntegrationFactory(burnerProxy, deployer, signers, 1);
```

Signers 2 and 3 are hash-derived addresses for which **no private key exists**, and the required
signature count is **1**. The functions this "multi-sig" gates — `emergencyPause`,
`emergencyUnpause`, `addSigner`, `removeSigner`, `setMaxPayment`, `reactivateIntegration` — are
therefore controlled by the deployer alone. The script comment ("use deployer + two deterministic
addresses for testnet") shows this was a deliberate testnet shortcut; it is recorded here so that
nobody reads `MIN_SIGNERS` in the source and concludes multi-party control exists.

See also KI-09 for the missing domain separation in the same signature scheme.

**Status.** Open. Verified by reading the deploy script 2026-07-27.

**Planned remediation.** Add a governance-set `MIN_FEE_RATE` floor. Replace the derived signer set
with real signers and a threshold > 1 before mainnet, and add a deploy-time assertion that every
signer is an address with known custody.

---

# INFORMATIONAL

## KI-23 — `src/core/TAGITCoreDemo.sol` is a hackathon demo contract with no tests and no deployment

**Severity:** Informational

**Location:** `src/core/TAGITCoreDemo.sol` (added 2026-03-06)

**Description.** The file's own header:

```solidity
/// @title TAGITCoreDemo
/// @notice Simplified demo contract for Arbitrum Open House NYC hackathon
/// @dev Stripped-down lifecycle contract with onlyAdmin access control
```

It is tracked, it sits in `src/`, and it will therefore be inside the audit clone and inside your
scope and your invoice. It has **no test file** (`git ls-files 'test/*.sol' | xargs grep -l
TAGITCoreDemo` → no results) and **no deployment** on any network in `deployment-addresses.json`.

It duplicates the `State` enum and lifecycle shape of `TAGITCore` with weaker access control, so
it is also a plausible source of confusion when reading the codebase.

**Status.** Open. Flagged for scope exclusion.

**Planned remediation.** Delete it, or move it to a `demo/` directory that is excluded from the
audit scope statement. We would rather not pay you to review hackathon code, and you should not
have to reason about which core contract is the real one. We will confirm the decision before the
engagement starts.

---

## KI-24 — TODO/FIXME/XXX/HACK sweep

**Severity:** Informational

**Description.** Run 2026-07-27:

```
$ grep -rnE "TODO|FIXME|XXX|HACK" src/ --include="*.sol" | wc -l
0
```

**Zero** such markers in `src/`. We want to be clear about what this does and does not mean: it
means no developer left a marker, not that the code is complete. This document contains several
unfinished or incorrect implementations in `src/` that carry no marker — `exportAllAssets`
(KI-07) is an unimplemented function whose comment says "For now, emit event" without using any of
the four keywords, and the paymaster's fixed-offset parse (KI-05) is marked only with the word
"Simplified". Do not treat a clean TODO grep as evidence.

`script/` has 4 matches, and two of them are material:

```
script/Deploy.s.sol:80:  proposers[0] = deployer; // TODO: Replace with Gnosis Safe 3-of-5 address
script/Deploy.s.sol:81:  executors[0] = deployer; // TODO: Replace with Gnosis Safe 3-of-5 address
script/deploy/DeployPaymasterArbitrum.s.sol:52:  console2.log("HACK-T03: TAGITPaymaster - Arbitrum Sepolia");
script/deploy/DeployPaymasterArbitrum.s.sol:91:  console2.log("HACK-T03 Deployment Complete!");
```

The first two are the governance gap in KI-01, left unresolved in the deploy script since it was
written. The other two are a hackathon task label in a log string, not a code smell.

**Status.** Informational. `Deploy.s.sol:80-81` is tracked as part of KI-01.

---

# REMEDIATED IN THIS BRANCH

## KI-25 — TAGIT-VDP-2026-001: AIRP ran a complete bonded dispute and then never moved the asset

**Severity:** Critical. **Status: REMEDIATED** on branch `meta/t19-ops-scripts`. Disclosed in full
because the defect was live on Base Sepolia and because the remediation changes semantics.

**Reported by:** **jackbone** — the handle the reporter asked to be credited under, in their own
words: *"No org, no GitHub link, just the handle."* Reported 2026-08-22 via `info@tagit.network`,
after `security@tagit.network` — the address this policy published — bounced. KI-25 through KI-29 all
trace to that one report. They also supplied a working Foundry PoC for the no-op on request, and
accepted our severity reassessments, including correcting their own impact figure on KI-28.

**The defect.** `TAGITRecovery.executeResolution()` ran the entire AIRP flow — a 100e18 TAGIT bonded
claim, badge-weighted voting, a 66% approval threshold, a 3-vote minimum, a 7-day period, 50%
slashing of a losing claimant's bond and quarantine bookkeeping — and then did not transfer the NFT.
The pre-fix source carried the admission verbatim at `src/recovery/TAGITRecovery.sol:473-474`:

```solidity
// Note: In production, this would call TAGITCore.resolve()
// to transfer the NFT to the claimant
winner = claimant;
```

The local `winner` variable fed only the `CaseResolved` event. A claimant who **won** got their bond
back and the asset stayed with the current holder. A claimant who **lost** was slashed 50% of a
100e18 bond for a process that structurally could never have delivered the asset.

Three structural reasons the missing call could not simply be added: `TAGITCore.resolve()` requires
(a) `State.FLAGGED`, which `initiateRecovery()` never established, (b) `_resolveApprovalCount >= 2`,
a deliberate 2-of-3 human multisig, and (c) `RESOLVER_CAPABILITY`, which TAGITRecovery does not hold.

**Adjacent defects fixed in the same change:**

- *Quarantine was decorative.* `_quarantined[tokenId]` was read by nothing outside TAGITRecovery, and
  the declared error `CannotTransferQuarantined` was never used anywhere — dead code proving
  enforcement was never wired. `TAGITCore.transferAsset()` is owner-gated on `state == CLAIMED` and
  never consulted it, so a disputed asset could be sold to a third party mid-vote.
- *A permanent lock.* `vote()` closes at `votingEndsAt`, `executeResolution()` reverted
  `QuorumNotReached` forever below 3 votes, and `appeal()` only accepts `REJECTED`. A case that never
  reached quorum could never leave `VOTING`: the bond stayed in `totalStakesHeld` and
  `_tokenToCase[tokenId]` stayed set, both permanently.
- *A sybil in the vote.* `_getVoteWeight` read the **transferable** `CapabilityBadge` (a plain
  ERC-1155 with no `_update` override) while `_hasVoted` is keyed by address. One badge walked through
  three EOAs produced a unanimous verdict.
- *False NatSpec.* `TAGITRecovery.sol:230` claimed `initiateRecovery` "flags in TAGITCore" (it did
  not); `IRecovery.sol:222` claimed `executeResolution` "Transfers asset or slashes stake" (it did not
  transfer). Both are now true statements of what the code does.

**The remediation — "AIRP is an adjudicator, not a custodian."**

The governing invariant, verifiable with one grep:

> **TAGITRecovery holds ZERO capabilities in TAGITCore and makes ZERO state-changing calls into
> TAGITCore.** It calls only four `view` functions (`getAsset`, `preFlagState`,
> `getResolveApprovalStatus`, `RESOLVE_QUORUM`) plus `IERC721.ownerOf`.

The read-only surface is pinned by `src/interfaces/ITAGITCoreRecovery.sol`, which declares no
state-changing function by design. The invariant is machine-checked by
`test_trustBoundary_recoveryHoldsNoCapability` and re-asserted as a deployment gate in
`script/deploy/UpgradeRecoveryVerdict.s.sol`, which aborts if TAGITRecovery ever holds a capability.

Mechanism:

1. **Flag-gated admission.** `initiateRecovery` now requires the asset to be **already** `FLAGGED` in
   TAGITCore, with a pre-flag marker of `CLAIMED` or `NONE` (see item 9 — `NONE` is a legacy
   token flagged before `_preFlagState` shipped, which `TAGITCore.resolve()` itself treats as
   `CLAIMED`; `BOUND` and `ACTIVATED` are still rejected). AIRP neither creates nor releases the freeze — *entry to
   quarantine is exactly as hard as exit*, so AIRP can never create a freeze it cannot release. This is
   the deliberate cost of the design: a claimant can no longer open a case unilaterally, and a FLAGGER
   must act first (see KI-28).
2. **Quarantine is real.** Quarantine IS `FLAGGED`. `transferAsset()` requires `CLAIMED` and the
   `_update()` override blocks every external ERC-721 transfer, so the mid-vote resale is closed by
   Core's own rules rather than by bookkeeping. Pinned by
   `test_quarantineIsReal_resaleBlockedDuringCase`, which shows the same call succeeding pre-flag.
3. **Verdict-bound execution.** An approved verdict no longer claims to be a transfer. It moves the
   case to the new non-terminal `ENFORCING` status, keeps the bond escrowed, and emits
   `ResolutionPending` as an instruction to the 2-of-3 resolver quorum. `finalizeResolution()` then
   *observes* what TAGITCore actually did and settles: `RESOLVED` if the claimant holds the asset,
   `VOIDED` (100% refund) if the resolvers diverged. `expireEnforcement()` / `abandonEnforcement()`
   release the escrow if the quorum never acts. **Slashing now happens only on an actual adverse vote**;
   every machinery failure refunds 100%. All four of those paths are reached only from an APPROVED
   verdict, so `voteCount >= MINIMUM_VOTES` holds and the item-12 anti-squat fee — which is a fee, not
   a slash, and applies only below `FEE_EXEMPT_MIN_VOTES`, i.e. on an expiry that drew **fewer than
   two** votes — is unreachable on any of them.
4. **No more permanent lock.** Below `MINIMUM_VOTES` the case terminates as `EXPIRED` and is never
   slashed. It refunds **in full** from **two** votes up — voter apathy is not claimant fraud — and
   refunds all but `SQUAT_FEE_RATE` when **fewer than two** votes were cast; see item 12, which is the
   defect that the unconditional 100% refund written here originally created, and item 14, which is
   the defect that pricing it on a **zero**-vote test then left open.
   **This holds for appealed cases too**, which
   it did not in the first cut of this fix: `appeal()` ACCUMULATED the new bond onto the already-spent
   one (recorded 3x while holding 2x), so every round-two exit path underflowed `totalStakesHeld` and
   reverted with a checked-arithmetic panic — including after a WON appeal where Core had already
   delivered the asset. `appeal()` now SETS `stakeBond` and asserts
   `token.balanceOf(address(this)) >= totalStakesHeld` immediately after collecting. Pinned by
   `test_regression_wonAppealFinalizesAndRefundsInFull`,
   `test_regression_rejectedAppealSettlesCleanly` and
   `test_regression_appealWithNoQuorumExpiresAndPaysTheFeeOnTheDoubledBond`. That last one was
   **renamed** when item 12 made the refund on that path conditional: its former name promised a full
   refund, which is behaviour the code no longer has, and this citation went stale for one round
   because the rename was not followed through here.
5. **Soulbound voting, on a dedicated namespace.** `_getVoteWeight` reads `hasIdentity()` on the
   soulbound `IdentityBadge` (ERC-5192), never `hasCapability()`. Claimant and current holder are
   excluded from voting. The seat ids are **70-73**, a range reserved protocol-wide for AIRP. The first
   cut of this fix kept the old ids 1/2/10/20, which were inert under the CapabilityBadge lookup
   (nobody holds capability ids 1/2/10/20) but are `KYC_L1`, `KYC_L2`, `MANUFACTURER` and `GOV_MIL` in
   the single flat IdentityBadge registry — so the sybil fix silently made every KYC'd account in the
   protocol an AIRP juror able to vote a claimant's bond away. Pinned by
   `test_regression_plainKycUsersAreNotAirpJurors`.
6. **Exit paths are deliberately not `whenNotPaused`,** so a tripped circuit breaker can never trap an
   escrowed bond, while `initiateRecovery` / `vote` / `appeal` stay paused. True for appealed escrow
   too — see item 4; pinned by `test_regression_pausedContractStillReleasesAnAppealedBond`. A pause
   could nonetheless still destroy an appeal *right* once item 13 put a wall-clock deadline on it,
   precisely because `appeal()` is `whenNotPaused` — that is item 15, and the window now counts
   **unpaused seconds only**.
7. **Appeals open a NEW voting round.** `_caseRound[caseId]` increments and the vote records are keyed
   by `(caseId, round)`. Resetting the tally alone was not enough: the per-voter records are keyed by
   address, so every round-one juror stayed locked out and an appealed case could never reach
   `MINIMUM_VOTES` again — it necessarily fell into the `EXPIRED` branch and hit the underflow in item
   4. Pinned by `test_regression_appealOpensANewRoundAndUnlocksTheRoster`.
8. **The active-case guard covers every non-terminal status.** `ENFORCING` and `APPEALED` were missing
   from it, so a decoy case could open over a token with a live ENFORCING verdict, repoint
   `_tokenToCase`, and then erase the live case's link and switch `isQuarantined()` off — at **zero
   cost**, because at the time a decoy with no votes EXPIRED with a 100% refund. That refund was
   itself a defect and is now items 12 and 14: an expiry that drew **fewer than two** votes costs 10%,
   so the decoy is no longer free even where a guard does not stop it outright. Independently, every clear of
   `_tokenToCase` now goes through `_unlinkToken()`, which only clears a link that still points at the
   terminating case. Pinned by `test_regression_secondCaseCannotOpenWhileFirstIsEnforcing` and
   `test_regression_terminalPathNeverUnlinksAnotherCasesToken`.
9. **The pre-flag gate mirrors `resolve()`'s own predicate.** `resolve()` computes
   `restored = (stored is BOUND|ACTIVATED|CLAIMED) ? stored : CLAIMED`, so a marker of `NONE` — a token
   flagged before `_preFlagState` shipped — is treated as `CLAIMED` and **is** deliverable.
   `initiateRecovery` accepts `CLAIMED` or `NONE` and still rejects `BOUND`/`ACTIVATED`. Requiring
   strictly `CLAIMED` locked every legacy-flagged asset out of AIRP for no reason. Pinned by
   `test_regression_legacyFlaggedTokenIsAdmittedAndDeliverable`.
10. **Names and comments now state what the code does.** The original defect was *a comment promising
    behaviour the code does not deliver*, and the first cut of the fix left survivors. All corrected:
    `vote()` reverts the new `VotingPeriodEnded` instead of `VotingStillActive` (whose name said the
    opposite of the condition it fired on); the "Quarantine the asset" / "Re-quarantine the asset"
    comments now say that AIRP mirrors a freeze a FLAGGER already created and that AIRP can neither
    create nor release one; `AssetQuarantined` and `CaseResolved` NatSpec no longer claim a freeze is
    applied or that the event is terminal; and the contract header no longer claims "ReentrancyGuard on
    all state-changing functions" — it now names the eight guarded functions and states that the
    owner/governor-only configuration setters are unguarded **because none of them makes an external
    call**, so there is no reentrancy surface to close. Eight declared-but-unreachable errors were
    deleted; see "ABI/indexer impact" for the full list and the policy now written into
    `IRecovery.sol`. Pinned by `test_regression_voteAfterDeadlineRevertsVotingPeriodEnded`.
11. **`enforcementWindow()` reports the window that is actually enforced.** The zero-fallback is still
    the right call over a `reinitializer(2)`, but the public auto-getter leaked the unwritten slot, so
    an upgraded proxy reported `0` — "no enforcement window configured" — while it was in fact
    enforcing 30 days. The getter keeps its selector and now returns `_window()`; the raw slot is
    exposed separately as `configuredEnforcementWindow()`. Pinned by
    `test_enforcementWindow_zeroFallbackAfterUpgradeFromV1` and
    `test_storageUpgradeSafety_v1LayoutToV2`.

**A THIRD adversarial review then proved two more defects, both rooted in the same line.** The
`EXPIRED` branch refunded **100%** whenever `voteCount < MINIMUM_VOTES`. That fix removed the
permanent lock (item 4) and in doing so made a decoy case **free**, which is the root cause of both
of the following. Each was demonstrated with a passing PoC before it was fixed.

12. **A decoy case was zero-cost and infinitely repeatable (`SQUAT_FEE_RATE`).** Anyone who is not the
    current holder could bond over a `FLAGGED` asset, cast no votes, and take the **whole** bond back
    after `votingDuration` — having locked the real owner out of AIRP for 7 days — and then repeat
    forever, for gas. Letting the decoy be *approved* first stretched one cycle to 37 days (7-day vote
    + 30-day enforcement), still at zero net cost. This is a **regression in cost-to-grief introduced
    by the item-4 fix**: before it, a no-quorum case reverted `QuorumNotReached` and could never leave
    `VOTING`, so the same squat permanently trapped the squatter's own 100 TAGIT.

    A case that expires having drawn **fewer than `FEE_EXEMPT_MIN_VOTES` (2)** votes now pays
    `SQUAT_FEE_RATE` (**1000 bp = 10%**) of its recorded bond to the treasury and keeps the rest, and
    emits the dedicated `AntiSquatFeeCharged` event — **not** `StakeSlashed`, whose meaning is "a jury
    voted against you". A case that drew **two** votes is still below `MINIMUM_VOTES`, still `EXPIRES`,
    and still refunds **in full**: that is voter apathy rather than claimant conduct, and preserving
    the distinction is the whole point of the fee. **The threshold was first written as `voteCount == 0`
    and that was a spec defect**, closed by item 14 — one vote is purchasable from one juror seat, so a
    zero-vote test let a griefer buy the exemption. The rule lives in the single private
    `_releaseEscrowAsExpired()`, which is now the ONE settlement path for every `EXPIRED` exit
    (`executeResolution`'s no-quorum branch, `expireEnforcement`, `abandonEnforcement`), so the fee
    cannot be present on one expiry path and quietly missing from another. On the two enforcement
    exits it is unreachable by construction rather than by a second condition — `ENFORCING` is only
    entered past the `voteCount >= MINIMUM_VOTES` test. The fee is a **rate on the recorded bond**, so
    it scales to the 2x appeal bond automatically. Pinned by
    `test_regression_repeatedSquattingNowCostsTheGrieferEveryCycle`,
    `test_regression_oneColludingVoteNoLongerExemptsADecoy`,
    `test_regression_twoVotesExemptADecoyButOneDoesNot` — **renamed** when item 14 moved the
    threshold, because its former name asserted that any non-zero vote count refunded in full, which
    is exactly the exemption item 14 removed — and
    `test_regression_bondAccountingIsExactOnEveryTerminalPath`.

    **Residuals, disclosed deliberately — what the fee does and does not buy.** The fee prices exactly
    one thing: a decoy that drew no plural engagement. It does not make decoys impossible, and item 14
    did not change that. Two residuals stand.

    *(a) Two colluding seats still exempt a decoy.* `FEE_EXEMPT_MIN_VOTES` is a bar, not a proof of
    honesty. A griefer who controls, rents or bribes **two** independently-granted AIRP seats (ids
    70-73) can put two votes on every decoy, land in the apathy carve-out, and squat for gas again —
    the same cycle item 14 closed against **one** seat, at twice the price of entry. Two is where we
    set the bar because one seat is individually cheap while two demands collusion between two
    separately granted seats; it is **not** the point at which the grief becomes impossible. Raising it
    further is not free either: `MINIMUM_VOTES` is 3 and the threshold must stay strictly below quorum,
    or the carve-out stops distinguishing apathy from fraud and starts charging honest claimants whose
    case a jury simply ignored. **If you think two is the wrong number, say so** — it is a judgement
    call and the cost of moving it is one constant.

    *(b) The approved variant is not priced at all.* A case that a jury votes through and that then sits
    out its 30-day enforcement window terminates via `expireEnforcement` / `abandonEnforcement` with a
    **100% refund**, holding the asset's dispute slot for up to 37 days at zero nominal cost. We
    accepted that on purpose. Reaching it requires `MINIMUM_VOTES` AIRP jurors to affirmatively vote
    **for** a claim by someone who is not the holder, which is jury collusion or jury negligence — a
    different threat, addressed by who holds seats 70-73, not by bond economics. Charging the fee
    there would instead penalise the honest claimant whose claim the jury endorsed and whom the
    resolver quorum then failed to serve (KI-28), which is exactly the "machinery failure is never
    slashed" rule this design is built on. **If you think that trade is wrong, say so** — it is a
    judgement call, not an oversight, and the cost of reversing it is one condition.

13. **The appeal right could be griefed away (bounded appeal window).** `REJECTED` is deliberately
    absent from `initiateRecovery`'s active-case guard because it is non-terminal and appealable — but
    the `REJECTED` branch of `executeResolution` also called `_unlinkToken`, freeing the token's only
    dispute slot **in the same transaction that created the claimant's appeal right**. `appeal()` then
    reverts `ActiveCaseExists` if anything else holds that slot. `executeResolution` is permissionless
    while `appeal()` is claimant-only, so an EOA appellant **cannot** atomically expire a decoy and
    appeal in one transaction: a third party front-ran the freed slot indefinitely, for gas, and the
    claimant who had just paid a 50% slash to earn the appeal could never use it.

    A `REJECTED` case now **keeps** `_tokenToCase[tokenId]` for the length of a bounded appeal window
    (`_appealDeadline[caseId] = block.timestamp + appealWindow()`, default **7 days**, governor-settable
    within `[1 day, 30 days]` via `setAppealWindow`). `initiateRecovery`'s guard treats `REJECTED` as
    occupying the slot while `block.timestamp <= appealDeadlineEffective(existingCase)`, and once the
    window has lapsed it releases the stale link **lazily, inside `initiateRecovery`** — no cleanup
    function, no keeper, so a slot can never be left locked by an absent third party. `appeal()` works
    throughout the window and reverts the new `AppealWindowClosed(caseId, deadline)` after it. The
    guard and `appeal()` read the **same private helper**, so they are exact complements by
    construction rather than by two conditions somebody has to keep in step by hand. The deadline is
    **recorded at rejection**, so shortening the window by governance cannot retract a right already
    granted, and it counts **unpaused seconds only** — see item 15. `isQuarantined()` correspondingly
    stays **true** across the window: the case really does still own the slot and the asset really is
    still `FLAGGED`. Pinned by
    `test_regression_thirdPartyCannotGriefAwayTheAppealRight`,
    `test_regression_lapsedAppealWindowFreesTheSlotLazily`,
    `test_regression_appealWindowBoundaryIsInclusive` and
    `test_regression_guardAndAppealStayExactComplementsUnderPauseCredit`.

    **The trade this window makes, quantified.** A rejected griefer now holds the token's only dispute
    slot for `votingDuration + appealWindow` — **14 days** at defaults — where before the window
    existed it was `votingDuration` alone, **7 days**, at the identical cost of 50% of the bond. That
    is the price of stopping a third party from front-running an appeal right the claimant had already
    paid that slash to earn, and it is a **token** slot, not custody: the asset never moves and stays
    exactly as `FLAGGED` as AIRP found it. It is bounded on both sides — `APPEAL_WINDOW_MAX` caps the
    extension at 30 days, and carrying the squat past the window means actually filing the appeal,
    which costs a bond that doubles every round (`APPEAL_MULTIPLIER`: 1x, 2x, 4x, ...) and re-enters a
    vote that can slash it.

    `appealWindow()` follows the item-11 pattern exactly, and for the same reason: it returns the
    **effective** value via a private zero-fallback, `configuredAppealWindow()` exposes the raw slot,
    and a proxy upgraded from an implementation that predates slot 23 therefore applies 7 days instead
    of giving every newly rejected case a deadline of exactly `block.timestamp` — an appeal right that
    expires in the transaction that creates it. Pinned by
    `test_regression_appealWindowZeroFallbackIsReportedAndApplied` (which asserts the fallback is
    APPLIED, not merely reported) and `test_storageUpgradeSafety_v1LayoutToV2`.

    One deliberate carve-out: `appeal()` treats `_appealDeadline[caseId] == 0` on a `REJECTED` case as
    "no window was ever recorded" and allows the appeal. That is reachable only for a case rejected by
    an implementation that predates this window — which also released its token link immediately, so it
    never occupied anyone's slot — and closing its appeal right retroactively at upgrade time would be
    a silent taking. Every case rejected from here on receives a non-zero deadline, so the carve-out
    can never widen the window for a new case, and `appeal()`'s "never steal another live case's link"
    guard still applies to it. Pinned by
    `test_regression_appealCannotClobberAnotherLiveCasesTokenLink`.

**A FOURTH adversarial review then proved three more — all of them in the economics items 12 and 13
themselves introduced.** Two were **spec** defects rather than implementation defects: the code did
exactly what the previous spec said, and the spec was wrong. Each was demonstrated with a passing PoC
before it was fixed.

14. **One vote dodged the anti-squat fee (`FEE_EXEMPT_MIN_VOTES = 2`).** Item 12 keyed the fee on
    `voteCount == 0`, and `vote()` excludes only the claimant and the current holder. So **one** address
    holding a single AIRP juror seat (ids 70-73) that a griefer controls, rents or bribes could cast one
    vote per decoy, tip the case into the `0 < voteCount < MINIMUM_VOTES` apathy carve-out, and make
    squatting free and infinitely repeatable — the exact state the fee exists to prevent. Proven: three
    consecutive cycles left the griefer's balance **exactly unchanged** and the treasury at **exactly
    zero**. Awkwardly, the same carve-out also fired when a single diligent juror voted on a decoy and
    nobody else turned up, i.e. when the jury was doing its job.

    The fee is now charged whenever `voteCount < FEE_EXEMPT_MIN_VOTES`, a named constant equal to
    **2**, and the full refund is granted only from **two** votes up. One vote is purchasable from one
    seat; two requires collusion between two independently-granted seats. `MINIMUM_VOTES` is 3, so the
    threshold still sits **strictly below quorum** and the apathy principle — *voter apathy is not
    claimant fraud* — survives for every case that drew real, plural engagement. What this does and
    does not buy is priced in item 12's residuals. Pinned by
    `test_regression_oneColludingVoteNoLongerExemptsADecoy` and
    `test_regression_twoVotesExemptADecoyButOneDoesNot`.

15. **A pause spanning the appeal window destroyed the appeal right (pause-aware deadline).**
    `appeal()` carries `whenNotPaused` and item 13's `_appealDeadline` was an absolute wall-clock
    instant that nothing ever extended. Before the window existed the appeal right was unbounded, so a
    pause merely **delayed** it; with the window a pause that outlasts it **consumes** it outright —
    and the claimant had already paid a 50% slash to earn that right. Reachable two ways: owner
    `pause()`, and the `CircuitBreaker` auto-trip inside `initiateRecovery` / `appeal`, which calls
    `_pause()` **directly**. The breaker's 4-hour cooldown does **not** clear `Pausable` — only
    `unpause()` (owner-only) does — so ordinary volume could pause the contract and the owner would
    have had to notice and unpause within 7 days or the right was gone. That contradicted the rule
    item 6 states: a tripped breaker can never trap a bond.

    The window now counts **unpaused seconds only**, in O(1) with no iteration over cases. Three
    appended slots do it: `_pausedAt` (25) records when the current pause began, `_pauseCredit` (26)
    accumulates the seconds spent paused all time, and `_pauseCreditAtRejection` (27) records the
    credit reading at each rejection. The effective deadline is the recorded deadline plus whatever
    credit accrued since, including a pause still in progress, exposed through **one private helper**
    that `appeal()` and `initiateRecovery`'s guard both consult — and mirrored on chain as the public
    `appealDeadlineEffective(caseId)`, exactly as `appealWindow()` exposes the effective window. Credit
    can never exceed the wall time elapsed since the rejection, so this can extend a window but never
    resurrect one that already lapsed in fully unpaused time. **Both `_pause()` and `_unpause()` are
    overridden**, not the external `pause()`, precisely because the breaker's direct `_pause()` is the
    path that made this urgent; that path is pinned by its own test.

    That "can never exceed the wall time elapsed since the rejection" property was **false in the
    first cut of this mechanism**, and two independent reviewers proved it with PoCs before it
    shipped. The stamp recorded raw `_pauseCredit`, which deliberately excludes a pause still in
    progress (only `_unpause()` banks it), while the reader added that in-progress pause in full. A
    case rejected *during* an existing pause was therefore credited every second the contract had
    already been paused before its window existed — 100 days of phantom credit in the PoC — and the
    eventual unpause banked the over-credit permanently, extending the dispute-slot lock past
    `APPEAL_WINDOW_MAX`. It needed no privileged actor: `executeResolution` is deliberately not
    `whenNotPaused`, so the REJECTED branch is reachable mid-pause. The fix routes **both** the stamp
    and the reading through one `_creditNow()` helper, so the baseline and the reading are measured
    the same way and an in-progress pause sits inside the baseline rather than being added to it.
    Pinned by `test_regression_pauseStartingBeforeRejectionDoesNotOverCredit`, which fails by exactly
    the 100-day over-credit if the stamp is reverted to raw `_pauseCredit`.

    `_pauseCreditAtRejection` is stored **offset by one**, so a stored `0` means unambiguously "never
    recorded" rather than "recorded when the credit happened to be 0". A case rejected **before** this
    upgrade therefore receives **zero** credit and keeps exactly the wall-clock deadline it was given;
    reading its unwritten 0 as a genuine baseline would have handed it the entire pause credit accrued
    since the upgrade, an unbounded grant nobody voted for. The residual is that such a case can still
    lose its window to a long pause, exactly as it could before this change — bounded by the fact that
    the live deployment has opened **zero** cases (`nextCaseId()` reads 1), so the affected set is
    empty. Pinned by `test_regression_pauseSpanningTheWindowDoesNotDestroyTheAppealRight`,
    `test_regression_pauseCreditExpiresAndTheSlotIsReleased` (a pause does not extend it
    *indefinitely* either), `test_regression_guardAndAppealStayExactComplementsUnderPauseCredit`,
    `test_regression_preUpgradeRejectionGetsNoHistoricalPauseCredit` and
    `test_regression_circuitBreakerAutoTripAccruesPauseCredit`.

16. **`setMinimumStake` had no floor, so the fee could silently round to zero
    (`MINIMUM_STAKE_FLOOR`).** `setEnforcementWindow` and `setAppealWindow` are both bounded, but the
    one parameter the anti-squat economics actually rest on was not. Any `minimumStake` below
    `BASIS_POINTS / SQUAT_FEE_RATE` (**10 wei**) makes `(bond * SQUAT_FEE_RATE) / BASIS_POINTS`
    truncate to **0**: the fee stops existing with no revert, no event and no other signal, while every
    document still claims squatting costs 10%. Proven: governor sets `minimumStake` to 9, a griefer
    squats, and both balances are exactly unchanged. `setMinimumStake` now reverts
    `MinimumStakeBelowFloor(requested, MINIMUM_STAKE_FLOOR)` below that floor, which is derived from
    the fee rate rather than written as a literal, so the two can never drift apart. Pinned by
    `test_regression_setMinimumStakeFloorBoundsAndAuthority`.

**Measured cost to TAGITCore.** Exactly one member was added — the `preFlagState(uint256)` view.
Measured on this branch, `FOUNDRY_PROFILE=deploy forge build --sizes`:

| Contract | Before | After | Delta | EIP-170 margin after |
|---|---|---|---|---|
| `TAGITCore` | 22,601 | **22,664** | **+63** | **1,912** |
| `TAGITRecovery` | 12,709 | **17,709** | +5,000 | **6,867** |

`forge inspect TAGITCore storage-layout` is **byte-identical** before and after. `TAGITRecovery`'s
layout is strictly append-only: slots 0–19 are unchanged, `_enforcementWindow`, `_enforcementEndsAt`
and `_caseRound` occupy slots 20–22, `_appealWindow` and `_appealDeadline` occupy slots 23–24 (item
13), `_pausedAt`, `_pauseCredit` and `_pauseCreditAtRejection` occupy slots 25–27 (item 15), and
`__gap` shrinks `[37] -> [29]` in lockstep so the contract still ends at slot 56 — a 57-slot
footprint, unchanged. Because a v1 proxy has never written `_enforcementWindow`, the
contract reads it through a zero-fallback (`_window()`) rather than a `reinitializer(2)` — a missed
reinitializer call would make every `ENFORCING` case instantly expirable, and a fallback cannot be
missed. The public getter `enforcementWindow()` returns that **effective** value; the raw slot is
exposed separately as `configuredEnforcementWindow()`.

**Exposure.** `nextCaseId()` read **1** on the live deployment — zero recovery cases were ever opened,
so there is no migration burden and no live case to preserve. Everything is testnet-only.

**ABI/indexer impact — READ THIS BEFORE UPDATING `tagit-sdk` / `tagit-indexer`.**

*Events.* `CaseResolved` and `AssetQuarantined` keep their `topic0` (the `winner` parameter was renamed
to `awardedTo`, which is not part of an event signature). `QuarantineReleased` was **deleted** —
TAGITRecovery cannot release a TAGITCore freeze, so emitting it was itself a lie; `resolve()` already
emits `StateChanged`. New topics: `ResolutionPending`, `ResolutionDelivered`, `CaseVoided`,
`CaseExpired`, `EnforcementWindowUpdated`, `AppealRoundOpened`, `AntiSquatFeeCharged`,
`AppealWindowOpened`, `AppealWindowUpdated`.

> **`CaseExpired.bondReturned` is the NET amount the claimant actually received**, not the recorded
> bond. They differ on exactly one path: a case that expired having drawn **fewer than two** votes
> (`FEE_EXEMPT_MIN_VOTES`), where `SQUAT_FEE_RATE` went to the treasury and an `AntiSquatFeeCharged`
> was emitted immediately before the `CaseExpired`. **That threshold moved from zero to two** (item
> 14), so an indexer written against the earlier rule now under-reports the fee on one-vote expiries.
> An indexer that reconstructs claimant P&L from `CaseExpired` alone is correct; one that assumed
> `bondReturned == stakeBond` is not.

> **`AntiSquatFeeCharged` is NOT `StakeSlashed`.** They are separate topics because they mean
> different things: `StakeSlashed` is a 50% penalty following an adverse jury vote, and
> `AntiSquatFeeCharged` is a 10% fee for occupying an asset's dispute slot without drawing **two**
> votes. A UI that renders the fee as a fraud finding is defaming the claimant.

> **`AppealWindowOpened(caseId, tokenId, deadline)` marks the interval in which the token's dispute
> slot is NOT free.** Until `deadline`, `initiateRecovery` reverts `ActiveCaseExists` for everyone
> else and only this case's claimant may `appeal()`. After it, the slot is claimable and the stale
> link is cleared by the next `initiateRecovery` — there is no cleanup transaction and therefore no
> event marking the release; read `getActiveCaseForToken` if you need the live answer.
>
> **The `deadline` in this event is the WALL-CLOCK deadline recorded at rejection, and the contract
> may enforce a LATER one.** Since item 15 the window counts unpaused seconds, so every second the
> contract spends paused after the rejection pushes the enforced instant out. No event is emitted when
> that happens. An indexer that treats the emitted `deadline` as final will call an appeal window
> closed while the contract still accepts an `appeal()`. Read `appealDeadlineEffective(caseId)` on
> chain for the number the contract actually enforces; `appealDeadline(caseId)` returns the raw
> recorded value this event carries.

> **`CaseResolved` is not a terminal marker.** `REJECTED` is not terminal — `appeal()` reopens the case
> — so one `caseId` can emit `CaseResolved` more than once. Consumers must treat the **latest** one as
> authoritative. The doc comment previously claimed the event fired only on a terminal status; it
> never did.

> **`VoteCast` must be partitioned by round.** Vote records are now keyed by `(caseId, round)`.
> `AppealRoundOpened(caseId, round, bond)` marks the boundary; every `VoteCast` after it belongs to
> that round. An indexer that tallies `VoteCast` per case without partitioning will mix a closed round
> into a live one. `caseRound(uint256)` reads the live round on chain.

*Errors — a breaking ABI change, deliberate.* Eight declared-but-unreachable errors were removed
from `IRecovery`: `CannotTransferQuarantined` (removed earlier in this change) plus `QuorumNotReached`,
`InsufficientStake`, `VotingNotOpen`, `AssetAlreadyQuarantined`, `InsufficientAppealBond`,
`CircuitBreakerTripped` and `RateLimitExceeded`. **None of them was ever reverted by any code path**, so
no live revert can stop decoding — but a codegen'd SDK that references the symbols will fail to
compile and must drop them. The last two were shadows: the real reverts come from
`CircuitBreaker.CircuitBreakerTripped(uint256)` and `RateLimiter.RateLimitExceeded(address,uint256)`,
which have **different signatures**, so the `IRecovery` copies could never have decoded a real revert.
The policy is now stated in the `CUSTOM ERRORS` block of `IRecovery.sol`: an error that no path can
revert is deleted, not kept for shape. The `CircuitTripped` / `CircuitReset` / `RateLimitHit` **events**
are retained on purpose — the libraries emit them with identical signatures from this contract's
context, so their `topic0` really does appear in TAGITRecovery logs.

*Errors added.* `VotingPeriodEnded(uint256,uint256)` — `vote()` after `votingEndsAt` used to revert
`VotingStillActive`, a name that stated the exact opposite of the condition it fired on.
`VotingStillActive` keeps its correct meaning in `executeResolution()`. `EscrowUnderfunded(uint256,uint256)`
— asserted after `appeal()` collects its bond. `AppealWindowClosed(uint256,uint256)` — `appeal()` after
the bounded window lapsed (item 13). `InvalidAppealWindow(uint256)` — `setAppealWindow()` outside
`[APPEAL_WINDOW_MIN, APPEAL_WINDOW_MAX]`. `MinimumStakeBelowFloor(uint256,uint256)` —
`setMinimumStake()` below `MINIMUM_STAKE_FLOOR`, where the anti-squat fee would truncate to zero
(item 16). **Thirteen** errors are added in total against the eight deleted; recount with
`grep -c '^\s*error ' src/interfaces/IRecovery.sol` (25 now, 20 before).

*Views added.* `caseRound(uint256)`, `hasVotedInRound(uint256,uint256,address)`,
`getVoteInRound(uint256,uint256,address)`, `enforcementDeadline(uint256)`,
`configuredEnforcementWindow()`, `appealDeadline(uint256)`, `appealDeadlineEffective(uint256)`,
`appealWindow()`, `configuredAppealWindow()`. `hasVoted(caseId, voter)` and `getVote(caseId, voter)`
now answer for the **current** round; use the `InRound` variants to read a closed one.
`appealDeadline` is the **raw recorded** deadline and `appealDeadlineEffective` is the one the
contract enforces — they differ by accrued pause credit (item 15), and off-chain consumers want the
latter. `configuredEnforcementWindow` is declared on the contract but **not** on `IRecovery`; the
other eight are on both — `enforcementDeadline` IS declared, at `IRecovery.sol:495`.

*Setter added.* `setAppealWindow(uint256)` — governor-only, bounded to `[1 day, 30 days]`, governed
exactly as `setEnforcementWindow` is.

*Setter bounded.* `setMinimumStake(uint256)` keeps its selector and its governor-only authority but now
reverts `MinimumStakeBelowFloor` below `MINIMUM_STAKE_FLOOR` (10 wei) — item 16. A governance script
that previously set a sub-floor value silently succeeded and silently disabled the anti-squat fee; it
now reverts.

*Constants added.* `SQUAT_FEE_RATE` (1000 bp), `FEE_EXEMPT_MIN_VOTES` (2 — item 14),
`MINIMUM_STAKE_FLOOR` (`BASIS_POINTS / SQUAT_FEE_RATE` = 10 wei — item 16),
`APPEAL_WINDOW_DEFAULT` (7 days), `APPEAL_WINDOW_MIN` (1 day), `APPEAL_WINDOW_MAX` (30 days).

*Behaviour changed, no signature change.* `isQuarantined(tokenId)` now stays **true** while a
`REJECTED` case holds the token through its appeal window; it used to go false the instant the case
was rejected, which was the release that made item 13 exploitable. `getActiveCaseForToken(tokenId)`
correspondingly keeps returning the rejected case's id through that window, and may return a **stale**
id after the window lapses until the next `initiateRecovery` sweeps it — compare against
`appealDeadlineEffective()` if you need to distinguish "held" from "stale". Comparing against
`appealDeadline()` is now **wrong** for that purpose: since item 15 the raw recorded deadline can pass
while the contract still treats the slot as held, because the window counts unpaused seconds.

*Views changed.* `enforcementWindow()` keeps its selector but now returns the **effective** window
(falling back to `ENFORCEMENT_WINDOW_DEFAULT` when the slot was never written) instead of the raw slot.
On the upgraded proxy the old getter returned `0`, which off-chain consumers reported as "no
enforcement window configured" while the contract was in fact enforcing 30 days. Read the raw slot via
`configuredEnforcementWindow()`.

*Constants renamed.* `BADGE_VERIFIER` / `BADGE_CERTIFIED_VERIFIER` / `BADGE_MANUFACTURER` /
`BADGE_GOVERNANCE` (values 1/2/10/20) are **gone**, replaced by `BADGE_AIRP_JUROR` (70),
`BADGE_AIRP_SENIOR_JUROR` (71), `BADGE_AIRP_ARBITER` (72), `BADGE_AIRP_TRIBUNAL` (73). The old names
pointed at other contracts' registry entries; the new ones name the seat they actually are.

*Enum.* `CaseStatus` gained members 6/7/8 (`ENFORCING`, `EXPIRED`, `VOIDED`) — appended, never
reordered — and any UI switching on the enum must handle them.

**Verification.** `forge test`: **2,082 passed, 0 failed** across 77 suites (1,972 before this
change). `test/recovery/TAGITRecoveryVerdict.t.sol` holds **37** tests and
`test/recovery/TAGITRecoveryRegression.t.sol` **36** of its own (**73** when
run — it inherits the verdict fixture). `forge inspect TAGITRecovery storage-layout` confirms slots
0-24 are byte-for-byte where they were, that `_pausedAt` / `_pauseCredit` /
`_pauseCreditAtRejection` are strictly appended at 25-27, and that the contract still ends at slot 56
for an unchanged 57-slot footprint. The end-to-end
proof that the original defect is fixed is `test_endToEndDelivery_claimantActuallyReceivesTheAsset`;
the proof that the second-, third- and fourth-round defects (items 4-16) are fixed is the whole of
`TAGITRecoveryRegression` — every test there began as a PoC that passed by demonstrating a bug and is
now inverted to pass by demonstrating its absence.

**What we did NOT do, deliberately.** We did not grant TAGITRecovery `RESOLVER_CAPABILITY`. Doing so
would have let the AIRP contract satisfy Core's 2-of-3 human multisig single-handedly and would have
put a custodial badge on a contract whose proxy owner is a hot EOA (KI-27). We accepted one extra
human transaction instead. Please attack that trade-off.

---

# OPEN — ADJACENT TO KI-25, DELIBERATELY OUT OF SCOPE FOR THAT FIX

These four were found while remediating KI-25. They are **not fixed**. They are listed separately
because each is a distinct defect that the KI-25 change chose not to absorb, and we would rather you
have our reasoning than guess at it.

## KI-26 — `TAGITCore.approveResolve` first-approver-binds-recipient deadlock

**Severity:** Medium. **Status:** Open, pre-existing, not introduced by KI-25.

`approveResolve` (`src/core/TAGITCore.sol:1077-1125`) lets the **first** approver set
`_resolveRecipient[tokenId]`; every later approver must match it or revert `RecipientMismatch`. There
is no `resetResolveRound` and the nonce only advances inside a successful `resolve()`. A single
resolver — mistaken or malicious — can therefore bind a token's resolve round to a wrong recipient and
there is no way to clear it short of a Core upgrade.

**Why KI-25 did not fix it.** It is a Core access-control defect, not a recovery-flow defect, and
fixing it means adding a state-changing function to a contract with 1,912 bytes of EIP-170 headroom.
It also degrades safely under the new design: `finalizeResolution` detects the mismatch
(`ResolverRecipientMismatch`), the case can be exited via `expireEnforcement` or
`abandonEnforcement`, and the claimant is refunded **100% with no slash**. Pinned by
`test_finalizeResolution_revert_resolverRecipientMismatch`.

**Related and already disclosed:** `requiresCapability` fails **open** when `accessController ==
address(0)` (`src/core/TAGITCore.sol:550-558`) — see AUDIT-SCOPE §3.2. The KI-25 change adds no new
`requiresCapability` gate and every new precondition reverts rather than proceeding, so it does not
widen that exposure.

---

## KI-27 — The `TAGITRecovery` proxy owner is the deployer EOA, not the TimelockController

**Severity:** Medium. **Status:** Open — an operational precondition of shipping KI-25.

`TAGITCore`'s owner is already the TimelockController. `TAGITRecovery`'s is not: the proxy
(`0x6BC3C69367E586810A3B317fA9F0406504e95866`) is owned by the deployer EOA, so its implementation can
be swapped with **zero delay**. Under the KI-25 design this is not exploitable *through TAGITCore* —
Recovery holds no capability there — but it does let one hot key rewrite the escrow and slashing logic
sitting over other people's bonds.

**Required before this leaves testnet:** transfer the Recovery proxy owner to the TimelockController.
This is the same governance gap as KI-01, applied to a second contract.

---

## KI-28 — `RESOLVER_CAPABILITY` and `FLAGGER_CAPABILITY` rosters are unpopulated; the recovery path is inert

**Severity:** Medium. **Status:** Open — an operational precondition, not a code defect.

`RESOLVER_CAPABILITY` (`keccak256("RESOLVER")`) is held by **nobody** on the live deployment — not the
Recovery proxy, not the deployer EOA, not the timelock — so `TAGITCore.resolve()` is uncallable and the
Core-side recovery path is dead independently of KI-25. Under the new design this fails **safely**
rather than silently: an approved case sits in `ENFORCING`, nobody can execute it, and it terminates as
`EXPIRED` with a 100% refund. Safe, but useless.

**Required to make AIRP functional:**

- `RESOLVER_CAPABILITY` to **three** distinct, independently-custodied human addresses. **None** to the
  Recovery proxy, the Core proxy, or the deployer EOA — that is the KI-25 trust boundary.
- `FLAGGER_CAPABILITY` to **at least two** independent operators. Under the new design nothing enters
  AIRP without a flag, so a single FLAGGER key is a censorship chokepoint on a victim's access to the
  dispute process. This is the one genuine loss of permissionlessness KI-25 introduced, and it is a
  deliberate trade for closing a free, unreleasable asset-freeze griefing vector.
- `IdentityBadge` ids **70 / 71 / 72 / 73** (AIRP jury seats: JUROR 1x, SENIOR_JUROR 2x, ARBITER 3x,
  TRIBUNAL 4x) to at least **three distinct** voters via `IdentityBadge.grantIdentity`, and
  confirmation that `TAGITAccess.setIdentityBadge` points at the live `IdentityBadge`. `hasIdentity` is
  zero-trust and returns `false` when unset, which makes every vote revert `NotBadgeHolder` —
  fail-closed, and pinned by `test_unwiredIdentityBadge_failsClosed`.
- Monitoring on `CaseVoided` and on `CaseExpired` from an `ENFORCING` case: both mean the resolver
  quorum diverged from or ignored a verdict. A keeper is needed for `finalizeResolution` /
  `expireEnforcement` — nothing settles a bond on its own.

---

## KI-29 — `TAGITGovernor._countVote` was an empty-bodied override of an abstract OZ hook

**Severity:** Low. **Status:** Hardened in the same change as KI-25.

`src/governance/TAGITGovernor.sol` overrode OpenZeppelin's abstract `_countVote` hook with an empty
body. It is unreachable today — `TAGITGovernor` overrides `_castVote` and tallies through
`_recordHouseVote` — and it cannot simply be deleted, because the base declares it abstract and the
contract would not compile. But an empty body means any future refactor that routes voting back
through the OZ counting path would **silently record no votes at all**.

The body now reverts with a declared custom error, `CountVoteUnsupported(proposalId, account)`, and
carries a comment explaining why it is unreachable. Fail-loud instead of fail-silent. The full
governance suite (29 tests) passes unchanged.

---

## Sources and how to reproduce

| Source | Location | Trust |
|---|---|---|
| Live chain reads | `https://sepolia.base.org`, commands shown inline | Authoritative, reproducible |
| Deployment manifest | `deployment-addresses.json` | Authoritative — corrected and re-verified against chain on 2026-07-26 |
| EVMbench detect/exploit reports | `tagit-security/evmbench/results/` | LLM-generated (`claude-sonnet-4-20250514`), unverified line numbers, several incorrect premises — each use is annotated above |
| EVMbench score card | `tagit-security/evmbench/results/evmbench-final-score.md` | **Withdrawn** — self-graded, do not rely on |
| Halmos | `tagit-security/reports/halmos-results-summary.md`, `halmos-results.txt` | Tool output, 2026-02-20, stale |
| Mythril | `tagit-security/reports/mythril-*-report.md` | Tool output, 2026-02-24, 2 of 56 files, stale |
| Slither baseline | `tagit-security/reports/slither-baseline.json` (+ summary) | Tool output, 2026-02-20, Slither 0.11.3, stale; counts re-derived from the JSON |
| CI history | `gh run list --workflow=<name>` | Authoritative, reproducible |
| Source and tests | this repo at `audit-prep/p0-manifest-and-false-evidence` | Authoritative |

**If you find something in our documentation that contradicts this file, this file is the later
statement — and please tell us, so we can fix or delete the other one.**

**Not in this document:** anything we have not measured. There is no list of "issues we are
confident do not exist", because we do not have the evidence to make that claim.
