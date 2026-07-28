File written to `/Users/artem/Developer/tagit/tagit-contracts/KNOWN-ISSUES.md`. Complete content:

---

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
| `testFuzz_*` functions, tracked | 84 |
| `invariant_*` functions | 12 |
| `check_*` (Halmos) functions | 22 |
| Test files, tracked | 80 |

Fuzz configuration is `runs = 100000` (`foundry.toml:34`); invariant configuration is
`runs = 256, depth = 500, fail_on_revert = true` (`foundry.toml:38-41`). The last recorded CI
result is 0 failing tests; we did not re-run the suite for this document.

Note that our older documents describe "20 fuzz tests × 10,000 runs". Both halves of that are now
stale — there are 84 `testFuzz_` functions and the configured run count is 100,000.

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

**Location:** working tree of `/Users/artem/Developer/tagit/tagit-contracts`

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
skipped. Regression tests: `test/security/EVMbenchFixes.t.sol:393-476` (seven `test_PATCH10_*`
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
