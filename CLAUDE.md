# CLAUDE.md — Master Prompt for Claude Code

[**CLAUDE.md**](http://CLAUDE.md) | TAG IT Network | **Version 3.0** | December 2025 | *Federated Multi-Repo Edition*

---

# 📋 HOW TO USE THIS FILE

---

# 🌐 MULTI-REPO CONTEXT (FEDERATED MODEL)

<aside>
🔗

**MASTER PROMPT**: This file is the central source of truth hosted in `tagit-docs`. Each of the 12 repos inherits these rules. Repo-specific behavior is loaded from agent modules in `tagit-docs/agents/`.

</aside>

## Repo Detection

**First action in any session:** Identify which repo you're in from the file tree.

| If you're in... | Your focus is... | Agent Module |
| --- | --- | --- |
| tagit-contracts | Smart contracts, Foundry, Solidity | [`contracts-agent.md`](http://contracts-agent.md) |
| tagit-l2 | OP Stack infra, Docker, devops | [`l2-agent.md`](http://l2-agent.md) |
| tagit-bridge | CCIP adapters, cross-chain | [`bridge-agent.md`](http://bridge-agent.md) |
| tagit-services | Backend APIs, TypeScript, auth | [`services-agent.md`](http://services-agent.md) |
| tagit-indexer | Event indexing, Graph/Goldsky | [`indexer-agent.md`](http://indexer-agent.md) |
| tagit-security | Audits, slither, threat models | [`security-agent.md`](http://security-agent.md) |
| tagit-dashboard | Admin console, React, governance UI | [`dashboard-agent.md`](http://dashboard-agent.md) |
| tagit-mobile | ORACULAR scanner, Kotlin/Swift | [`mobile-agent.md`](http://mobile-agent.md) |
| tagit-sdk | JS/Kotlin/Swift SDKs, CLI tools | [`sdk-agent.md`](http://sdk-agent.md) |
| tagit-hardware | NFC/PQC specs, hardware protocols | [`hardware-agent.md`](http://hardware-agent.md) |
| tagit-docs | Markdown, diagrams, Wiki exports | [`docs-agent.md`](http://docs-agent.md) |
| tagit-governance | SOPs, RFCs, policies | [`governance-agent.md`](http://governance-agent.md) |

## Agent Inheritance

```
tagit-docs/[CLAUDE.md](http://CLAUDE.md) (this file — MASTER)
    ↓ inherits
tagit-docs/agents/{repo}-[agent.md](http://agent.md) (specialized rules)
    ↓ referenced by
{repo}/[CLAUDE.md](http://CLAUDE.md) (thin local pointer)
```

**Rule:** Agent modules **extend** this master prompt — they never override security requirements.

---

# 🔗 CROSS-REPO COMMUNICATION

<aside>
⚠️

**COORDINATION PROTOCOL**: When your task touches multiple repos, follow this protocol to prevent drift and blocked work.

</aside>

## When Working Across Repos

1. **Document the dependency** in your local `tasks/[TODO.md](http://TODO.md)`
2. **Create GitHub issue** in target repo with label `cross-repo`
3. **Reference format**: `Blocked by: tagit-{repo}#{issue}`
4. **Never assume** another repo's state — verify via GitHub

## TODO Hierarchy

```
1. Check tasks/[TODO.md](http://TODO.md) in THIS repo first
2. Cross-reference: tagit-docs/todos/[MASTER-TODO.md](http://MASTER-TODO.md)
3. If blocked, check upstream dependencies in GitHub issues
```

## Central TODO Aggregation

The master TODO lives in `tagit-docs/todos/[MASTER-TODO.md](http://MASTER-TODO.md)` and is auto-synced weekly from all repos via GitHub Action.

---

# 🧠 AGENT WORKFLOW (FOLLOW THIS ORDER)

<aside>
⚠️

**CRITICAL**: Claude Code performs best when you **plan before coding**. Never jump straight to implementation. Follow this workflow for every task.

</aside>

## Phase 1: UNDERSTAND (Read First, Code Never)

```
1. Read relevant files (use tab-completion for paths)
2. Ask clarifying questions if requirements are ambiguous
3. Use subagents to investigate specific questions
4. DO NOT write any code yet
```

## Phase 2: PLAN (Think Hard)

```
1. Create a written plan in a scratchpad file (tasks/[TODO.md](http://TODO.md))
2. Use "think hard" or "ultrathink" for complex problems
3. Identify attack vectors and edge cases BEFORE coding
4. Get human approval on the plan
5. STILL no code — just the plan
```

## Phase 3: IMPLEMENT (One File at a Time)

```
1. Implement solution following the approved plan
2. Write tests FIRST (TDD) when possible
3. Run tests after each file change
4. Commit frequently with descriptive messages
5. Use subagents to verify implementations
```

## Phase 4: VERIFY (Never Trust First Output)

```
1. Run full test suite
2. Run slither for security analysis
3. Check gas targets
4. Have a subagent review for STRIDE threats
5. Update [TODO.md](http://TODO.md) with completion status
```

---

# 📁 PROJECT STRUCTURE

<aside>
📂

**REPO-SPECIFIC**: The structure below varies by repo. Detect which repo you're in and reference the appropriate layout from `tagit-docs/wiki/[02-repository-organization.md](http://02-repository-organization.md)`.

</aside>

## Common Layout Pattern

```
tagit-{repo}/
├── [CLAUDE.md](http://CLAUDE.md)              ← Thin pointer to master (tagit-docs)
├── tasks/
│   └── [TODO.md](http://TODO.md)            ← Local scratchpad
├── src/                   ← Source code
├── test/                  ← Tests
├── script/                ← Deployment scripts (if applicable)
├── docs/                  ← Local docs
└── 
```

---

# 🎯 MISSION CONTEXT

## What TAG IT Does

- Creates **Digital Twins** (NFTs) representing physical assets
- Binds NFC/hardware tags to on-chain identity via cryptographic hashes
- Tracks asset lifecycle: manufacture → distribution → ownership → end-of-life
- Enables multi-signal verification (5+ signals required per check)
- Serves defense, enterprise, and consumer supply chain use cases

## The ORACULS Stack

```
Applications    → ORACULAR mobile app, Admin Console, Partner APIs
Gateway         → tagit-services (Auth, API routing, AI orchestration)
Ledger (L2)     → TAGIT L2 (OP Stack + EigenDA) ← YOU ARE HERE
Settlement      → Ethereum L1 (escrow, timelocks)
Interop         → Chainlink CCIP (cross-chain messaging)
Private Ledger  → Hyperledger Besu (gov/mil data)
```

## Key Terminology (MEMORIZE)

| Term | Definition |
| --- | --- |
| **Digital Twin** | NFT representing a physical asset's on-chain identity |
| **ORACULAR** | Mobile/web verification scanner app |
| **BIDGES** | Badge system for identity + capability management |
| **AIRP** | AI Recovery Protocol for lost/stolen asset handling |
| **PQC** | Post-Quantum Cryptography (future hooks, not MVP) |

---

# ✅ [TODO.md](http://TODO.md) TEMPLATE (CREATE THIS FILE)

<aside>
📝

**IMPORTANT**: Create `tasks/[TODO.md](http://TODO.md)` at session start. Use it as your working scratchpad. Check items off as you complete them. This improves Claude's focus on complex tasks.

</aside>

```markdown
# Current Task: [TASK NAME]
Date: YYYY-MM-DD
Status: Planning | In Progress | Review | Complete

## Objective
[One sentence describing what we're building]

## Plan (Approved: Yes/No)
- [ ] Step 1: [Description]
- [ ] Step 2: [Description]
- [ ] Step 3: [Description]

## Files to Modify
- [ ] `src/core/TAGITCore.sol` — [what changes]
- [ ] `test/unit/TAGITCore.t.sol` — [what tests]

## Security Checklist
- [ ] STRIDE threat model complete
- [ ] ReentrancyGuard on all state-changing functions
- [ ] Checks-Effects-Interactions pattern followed
- [ ] Custom errors (no string reverts)
- [ ] Input validation on ALL parameters
- [ ] Events emit for ALL state changes

## Verification
- [ ] `forge build` — compiles without warnings
- [ ] `forge test` — all tests pass
- [ ] `forge coverage` — ≥85% coverage
- [ ] `slither .` — 0 high/critical findings
- [ ] Gas targets met

## Notes
[Working notes, decisions, blockers]
```

---

# 🔐 SECURITY REQUIREMENTS (NON-NEGOTIABLE)

<aside>
⛔

**BLOCKING**: Code that violates these rules MUST be rejected. No exceptions. Security review has blocking authority.

</aside>

## 1. Checks-Effects-Interactions (ALWAYS)

```solidity
function claim(uint256 tokenId, address newOwner) external nonReentrant {
    // ✅ CHECKS (all validation first)
    if (!_exists(tokenId)) revert TokenNotFound(tokenId);
    if (_assets[tokenId].state != State.ACTIVATED) revert InvalidState(tokenId, _assets[tokenId].state, State.ACTIVATED);
    if (newOwner == address(0)) revert ZeroAddress();
    
    // ✅ EFFECTS (state changes before external calls)
    _assets[tokenId].owner = newOwner;
    _assets[tokenId].state = State.CLAIMED;
    _assets[tokenId].claimedAt = uint64(block.timestamp);
    
    // ✅ INTERACTIONS (external calls LAST)
    emit StateChanged(tokenId, State.ACTIVATED, State.CLAIMED, msg.sender);
}
```

## 2. ReentrancyGuard on ALL State-Changing Functions

```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TAGITCore is ERC721, ReentrancyGuard {
    function mint(...) external nonReentrant { ... }
    function bindTag(...) external nonReentrant { ... }
    function transfer(...) external nonReentrant { ... }
}
```

## 3. BIDGES Capability Checks (Zero Trust)

```solidity
modifier onlyWithCapability(uint256 capId) {
    if (!ITAGITAccess(accessContract).hasCapability(msg.sender, capId)) {
        revert Unauthorized(msg.sender, capId);
    }
    _;
}

// Usage:
function mint(...) external onlyWithCapability(CAP_MINT) nonReentrant { ... }
```

## 4. Custom Errors ONLY (Gas Efficient)

```solidity
// ❌ NEVER DO THIS
require(condition, "Some long string error message");

// ✅ ALWAYS DO THIS
error InvalidState(uint256 tokenId, State current, State required);
error Unauthorized(address caller, uint256 requiredCapability);
error TagAlreadyBound(bytes32 tagHash);
error InvalidTransition(State from, State to);
```

## 5. Input Validation on EVERY Parameter

```solidity
function bindTag(uint256 tokenId, bytes32 tagHash) external {
    if (tokenId == 0) revert InvalidTokenId();
    if (tagHash == bytes32(0)) revert InvalidTagHash();
    if (_tagToToken[tagHash] != 0) revert TagAlreadyBound(tagHash);
    if (!_exists(tokenId)) revert TokenNotFound(tokenId);
    // ...
}
```

## 6. STRIDE Threat Model (Apply to ALL Code)

| Threat | Question | Mitigation |
| --- | --- | --- |
| **S**poofing | Can identity be faked? | BIDGES capability checks |
| **T**ampering | Can data be modified? | Immutable state + events |
| **R**epudiation | Can actions be denied? | On-chain event logging |
| **I**nformation Disclosure | Can data leak? | Private chain for sensitive data |
| **D**enial of Service | Can system be halted? | Gas limits, pausable |
| **E**levation of Privilege | Can roles be escalated? | Soulbound badges, timelocks |

---

# 📋 SMART CONTRACT SPECIFICATIONS

## Asset Lifecycle State Machine (LifecycleLib.sol)

```solidity
enum State {
    NONE,       // 0 - Default/not created
    MINTED,     // 1 - NFT exists, no tag
    BOUND,      // 2 - Tag cryptographically linked
    ACTIVATED,  // 3 - QA passed, ready for distribution
    CLAIMED,    // 4 - Owned by end consumer
    FLAGGED,    // 5 - Lost/stolen/recall
    RECYCLED    // 6 - End of life
}
```

### Valid Transitions ONLY (updated 2026-05-30 — recall/scrap/resale upgrade):

```
NONE → MINTED                          (mint)
MINTED → BOUND                         (bindTag)
BOUND → ACTIVATED                      (activate)
ACTIVATED → CLAIMED                    (claim)
CLAIMED → CLAIMED (new owner)          (transferAsset — secondary-market resale, owner-gated)
{BOUND|ACTIVATED|CLAIMED} → FLAGGED    (flag — recall, pre-sale theft, or lost/stolen)
FLAGGED → {its exact pre-flag state}   (resolve — recovery; restores BOUND/ACTIVATED/CLAIMED)
{MINTED|BOUND|ACTIVATED|CLAIMED|FLAGGED} → RECYCLED  (recycle — void / scrap / end-of-life)
```

**INVARIANT**: The only backward movement is recovery. `flag()` can be entered from any
state with a bound tag (BOUND/ACTIVATED/CLAIMED); `resolve()` restores the **exact** state
held immediately before the flag (stored in `_preFlagState`), so `flag()+resolve()` is
**state-neutral** and can never be used to skip a forward transition (e.g. it cannot bypass
`claim()`'s capability check). Manufacturing-phase recovery (BOUND/ACTIVATED) returns the asset
to its current owner; consumer (CLAIMED) recovery reassigns to the resolver-approved owner.

## BIDGES Badge System

### Identity Badges (Soulbound ERC-5192)

| Badge ID | Name | Description |
| --- | --- | --- |
| 1 | KYC_L1 | Basic identity verified |
| 2 | KYC_L2 | Enhanced verification |
| 3 | KYC_L3 | Institutional/accredited |
| 10 | MANUFACTURER | Verified brand/factory |
| 11 | RETAILER | Authorized seller |
| 20 | GOV_MIL | Government/military clearance |
| 21 | LAW_ENFORCEMENT | Police/customs authority |

### Capability Badges (ERC-1155)

| Cap ID | Name | Permission |
| --- | --- | --- |
| 100 | CAP_MINT | Create new asset NFTs |
| 101 | CAP_BIND | Bind NFC tags to assets |
| 102 | CAP_ACTIVATE | QA activation approval |
| 104 | CAP_FLAG | Flag assets as suspicious |
| 105 | CAP_RECOVERY_INIT | Start AIRP recovery |
| 106 | CAP_RECOVERY_APPROVE | Approve recovery resolution |
| 107 | CAP_FREEZE | Emergency pause authority |
| 108 | CAP_DAO_VOTE | Governance voting rights |

---

# ⚡ GAS OPTIMIZATION (MANDATORY)

## Storage Packing

```solidity
// ✅ CORRECT - Pack into single 32-byte slot
struct Asset {
    address owner;       // 20 bytes
    uint64 timestamp;    // 8 bytes
    State state;         // 1 byte
    uint8 flags;         // 1 byte
    uint16 reserved;     // 2 bytes
}   // Total: 32 bytes = 1 slot

// ❌ WRONG - Wastes storage slots
struct Asset {
    address owner;       // 20 bytes → slot 0
    uint256 timestamp;   // 32 bytes → slot 1 (wasteful!)
    State state;         // 1 byte → slot 2
}
```

## Gas Targets

| Operation | Max Gas |
| --- | --- |
| mint() | < 150,000 |
| bindTag() | < 80,000 |
| verify() | < 50,000 |
| transfer() | < 100,000 |

---

# 🧪 TESTING REQUIREMENTS

## Coverage Targets

- **Overall**: ≥ 85%
- **Critical Paths**: 100% (state transitions, access control)
- **Fuzz Tests**: 10,000 runs minimum

## Test Types (ALL REQUIRED)

### 1. Unit Tests

```solidity
function test_mint_success() public { ... }
function test_mint_revert_unauthorized() public { ... }
function test_mint_revert_zeroAddress() public { ... }
```

### 2. Fuzz Tests

```solidity
function testFuzz_mint(address to, bytes32 metadata) public {
    vm.assume(to != address(0));
    vm.assume(to.code.length == 0);
    // ...
}
```

### 3. Invariant Tests

```solidity
function invariant_tagBindingUnique() public {
    // No two tokens can have the same tag
}

function invariant_stateOnlyForward() public {
    // Forward-only except recovery: resolve() restores the EXACT pre-flag state,
    // so flag()+resolve() round-trips (state-neutral) and never skips a transition.
}
```

### 4. Integration Tests

```solidity
function test_fullLifecycle() public {
    // MINT → BIND → ACTIVATE → CLAIM → FLAG → RESOLVE
}
```

---

# 📝 CODE STYLE

## File Header (REQUIRED)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TAGITCore
 * @author TAG IT Network <[dev@tagit.network](mailto:dev@tagit.network)>
 * @notice Core asset management for digital twins
 * @dev Implements ERC-721 with lifecycle state machine
 */
```

## NatSpec (REQUIRED for all public/external)

```solidity
/**
 * @notice Binds a physical NFC tag to an asset NFT
 * @dev Tag hash must be unique across all assets. Emits TagBound event.
 * @param tokenId The asset NFT to bind
 * @param tagHash Keccak256 hash of the NFC tag UID
 * @custom:security Requires CAP_BIND capability. Tag binding is irreversible.
 * @custom:emits TagBound
 */
function bindTag(uint256 tokenId, bytes32 tagHash) external;
```

---

# 🔧 BASH COMMANDS

```bash
# Build
forge build

# Test
forge test -vvv
forge test --match-test test_mint -vvv

# Coverage
forge coverage --report lcov

# Gas Report
forge test --gas-report

# Security Scan
slither . --config-file slither.config.json

# Deploy Local
anvil &
forge script script/Deploy.s.sol --fork-url [http://localhost:8545](http://localhost:8545) --broadcast

# Deploy OP Sepolia
forge script script/Deploy.s.sol \
    --rpc-url $OP_SEPOLIA_RPC \
    --private-key $DEPLOYER_KEY \
    --broadcast \
    --verify
```

---

# 🚀 DEPLOYMENT TARGETS

| Environment | Chain | Purpose |
| --- | --- | --- |
| Local | Anvil | Unlimited test ETH, instant blocks |
| Dev | OP Sepolia | Faucet ETH, fast iteration |
| Stage | OP Sepolia | Prod-like config, canary tests |
| Prod | OP Mainnet | DAO approval, multi-sig deploy |

---

# 📚 WIKI REFERENCES

When you need more context, reference these Notion docs:

| Document | What It Contains |
| --- | --- |
| **01 — System Overview** | Full architecture, data flows, verification logic |
| **02 — Repository Organization** | 12 repo structure, monorepo layouts |
| **03 — Smart Contract Architecture** | 6 core modules, dependency graph |
| **04 — Data Flow Diagrams** | Mermaid diagrams for all flows |
| **05 — Developer Handoff** | Detailed implementation specs |
| **Security** | STRIDE models, threat analysis |

---

# ✅ SUCCESS CRITERIA CHECKLIST

Before any PR or commit, verify ALL of these:

- [ ]  `forge build` — compiles without warnings
- [ ]  `forge test` — all tests pass
- [ ]  `forge coverage` — ≥85% overall, 100% critical paths
- [ ]  `slither .` — 0 high/critical findings
- [ ]  Gas targets met for all operations
- [ ]  NatSpec complete on all public/external functions
- [ ]  Events emit for ALL state changes
- [ ]  Fuzz tests pass with 10,000 runs
- [ ]  Invariant tests pass
- [ ]  STRIDE threat model documented
- [ ]  [TODO.md](http://TODO.md) updated with completion status

---

# 🚫 WHAT NOT TO DO

<aside>
🛑

**BLOCKING VIOLATIONS** — These will cause immediate rejection:

</aside>

- ❌ Leave `// TODO` or `// implement later` comments
- ❌ Skip security modifiers (nonReentrant, capability checks)
- ❌ Use `require()` with string messages
- ❌ Assume external contract behavior without validation
- ❌ Generate partial implementations
- ❌ Skip input validation on ANY parameter
- ❌ Proceed past BLOCKED status without resolution
- ❌ Hand-wave security on custody/transfer logic
- ❌ Recommend non-U.S. hosting for core data

---

# 💾 AGENT MEMORY

<aside>
🧠

**RE-READ THIS FILE** at the start of every session. The security requirements are non-negotiable. When in doubt, add more validation, not less. Plan first, code second.

</aside>

## Session Start Checklist

1. Read this [CLAUDE.md](http://CLAUDE.md)
2. Check `tasks/[TODO.md](http://TODO.md)` for current state
3. Ask clarifying questions before coding
4. Create/update plan before implementation
5. Verify with tests before committing