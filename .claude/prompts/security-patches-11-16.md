# SECURITY PATCH SPRINT: PATCH-11 through PATCH-16
# Claude CLI Autonomous Execution Prompt
# Source: Official paradigmxyz/evmbench + OpenAI gpt-5.2 — 2026-02-24
# Usage: claude --file .claude/prompts/security-patches-11-16.md --mode execute
# Run from: C:\tagcode\tagit-contracts
# ============================================================================

## YOUR MISSION

You are SUDO AI implementing 6 HIGH severity security patches for TAG IT Network
smart contracts. These findings came from the official paradigmxyz/evmbench tool
running OpenAI gpt-5.2 Codex on 2026-02-24.

Work through each patch in priority order. Do not skip. Do not rush.
After all 6 patches: run the full test suite. Zero regressions = done.

Security stance: default deny, explicit auth, validate all inputs,
custom errors over require strings, emit events for all state changes.

## ENVIRONMENT

- Working dir:  C:\tagcode\tagit-contracts
- Contracts:    src/
- Tests:        test/
- Security dir: C:\tagcode\tagit-security\
- Run tests:    forge test
- Lint:         forge fmt && forge build

Confirm environment before starting:

```bash
cd C:/tagcode/tagit-contracts
forge build 2>&1 | tail -5
echo "Build status: $?"
```

If build fails — fix compilation errors before touching any patch files.

## PATCH EXECUTION ORDER (highest blast radius first)

PATCH-16 → PATCH-15 → PATCH-14 → PATCH-11 → PATCH-12 → PATCH-13

After EACH patch:

```bash
forge build                                                    # must compile clean
forge test --match-path test/security/PatchXX*.t.sol -vv       # patch tests pass
forge test -vv                                                 # zero regressions across full suite
git add -p && git commit -m "security: PATCH-XX description"
```

Only move to next patch after current one is green.

---

## PATCH-16: Session Key Spend Limits Not Enforced

**File:** `src/account/TAGITAccount.sol`

### What's wrong

Session keys have `spendLimit` in their permission struct but it is NEVER
checked during execution. A dApp session key can drain the entire account
balance regardless of its configured limit.

### Step 1 — Read the current file

```bash
cat src/account/TAGITAccount.sol
```

Find:
- The `SessionKeyPermission` struct definition
- The `_validateSessionKey()` function (or equivalent validation logic)
- Where `execute()` calls validation
- Where session keys are granted and renewed

### Step 2 — Apply the patch

Add to contract state variables:

```solidity
// PATCH-16: session key spend tracking
mapping(address => uint256) public sessionKeySpent;
mapping(address => mapping(address => uint256)) public sessionKeyTokenSpent;
```

Add custom error (with other errors at top of contract):

```solidity
error SpendLimitExceeded(address key, uint256 attempted, uint256 remaining);
```

Modify `_validateSessionKey()` — add spend enforcement block:

```solidity
// PATCH-16: enforce spend limit
uint256 newTotal = sessionKeySpent[key] + value;
if (newTotal > sessionKeys[key].spendLimit) {
    revert SpendLimitExceeded(
        key,
        value,
        sessionKeys[key].spendLimit - sessionKeySpent[key]
    );
}
sessionKeySpent[key] = newTotal;
emit SessionKeySpend(key, value, sessionKeys[key].spendLimit - newTotal);
```

Add to key renewal/expiry function (reset spent counter):

```solidity
// PATCH-16: reset spend counter on key renewal
sessionKeySpent[key] = 0;
```

Add event declaration:

```solidity
event SessionKeySpend(address indexed key, uint256 spent, uint256 remaining);
```

### Step 3 — Write test file

Create `test/security/Patch16SessionKeySpend.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/account/TAGITAccount.sol";

contract Patch16SessionKeySpendTest is Test {
    TAGITAccount account;
    address owner = makeAddr("owner");
    address sessionKey = makeAddr("sessionKey");
    address attacker = makeAddr("attacker");
    uint256 SPEND_LIMIT = 0.01 ether;

    function setUp() public {
        vm.startPrank(owner);
        account = new TAGITAccount(owner);
        account.grantSessionKey(sessionKey, SPEND_LIMIT, block.timestamp + 1 days);
        vm.deal(address(account), 100 ether); // fund account
        vm.stopPrank();
    }

    function test_sessionKey_enforces_spend_limit() public {
        vm.prank(sessionKey);
        account.execute(address(0x1), SPEND_LIMIT, "");
        assertEq(account.sessionKeySpent(sessionKey), SPEND_LIMIT);
    }

    function test_sessionKey_reverts_over_limit() public {
        vm.prank(sessionKey);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITAccount.SpendLimitExceeded.selector,
            sessionKey,
            SPEND_LIMIT + 1,
            SPEND_LIMIT
        ));
        account.execute(address(0x1), SPEND_LIMIT + 1, "");
    }

    function test_sessionKey_cumulative_tracking() public {
        uint256 half = SPEND_LIMIT / 2;
        vm.startPrank(sessionKey);
        account.execute(address(0x1), half, "");
        account.execute(address(0x1), half, "");
        // Next spend should revert
        vm.expectRevert();
        account.execute(address(0x1), 1, "");
        vm.stopPrank();
    }

    function test_sessionKey_reset_on_renewal() public {
        vm.prank(sessionKey);
        account.execute(address(0x1), SPEND_LIMIT, "");

        // Renew key
        vm.prank(owner);
        account.renewSessionKey(sessionKey, SPEND_LIMIT, block.timestamp + 2 days);

        // Should be able to spend again
        vm.prank(sessionKey);
        account.execute(address(0x1), SPEND_LIMIT, "");
        assertEq(account.sessionKeySpent(sessionKey), SPEND_LIMIT);
    }

    function testFuzz_sessionKey_spend(uint256 amount) public {
        amount = bound(amount, SPEND_LIMIT + 1, 100 ether);
        vm.prank(sessionKey);
        vm.expectRevert();
        account.execute(address(0x1), amount, "");
    }

    function test_attacker_cannot_use_session_key() public {
        vm.prank(attacker);
        vm.expectRevert();
        account.execute(address(0x1), 1 ether, "");
    }
}
```

### Step 4 — Verify

```bash
forge build
forge test --match-path test/security/Patch16*.t.sol -vv
forge test -vv 2>&1 | tail -20
git add src/account/TAGITAccount.sol test/security/Patch16SessionKeySpend.t.sol
git commit -m "security: PATCH-16 enforce session key spend limits

- Add sessionKeySpent mapping for cumulative ETH tracking
- Add sessionKeyTokenSpent for ERC-20 spend tracking
- _validateSessionKey() now reverts SpendLimitExceeded when over limit
- Spend counter resets on key renewal
- SpendLimitExceeded(key, attempted, remaining) custom error
- SessionKeySpend event emitted on each spend
- 6 tests: unit + fuzz coverage

Fixes: EVMbench HIGH finding — session key spend limits not enforced"
```

---

## PATCH-15: emailHash Identity Hijacking in AccountFactory

**File:** `src/account/TAGITAccountFactory.sol`

### What's wrong

`deployAccount(emailHash)` is public with no verification that the caller
owns that email. Attacker front-runs victim onboarding and claims their
smart account address.

### Step 1 — Read current file

```bash
cat src/account/TAGITAccountFactory.sol
```

Find: `deployAccount()` function and any existing access control patterns.

### Step 2 — Apply the patch

Add to state variables:

```solidity
// PATCH-15: email verification gate
mapping(bytes32 => bool) public verifiedEmails;
bytes32 public constant EMAIL_VERIFIER_ROLE = keccak256("EMAIL_VERIFIER_ROLE");
```

Add custom errors:

```solidity
error EmailNotVerified(bytes32 emailHash);
error AlreadyVerified(bytes32 emailHash);
```

Add verifier function:

```solidity
/// @notice Pre-verify an email hash before account deployment
/// @dev Only EMAIL_VERIFIER_ROLE can call. Off-chain service verifies
///      email ownership then calls this to whitelist the hash.
function verifyEmail(bytes32 emailHash)
    external
    onlyRole(EMAIL_VERIFIER_ROLE)
{
    if (verifiedEmails[emailHash]) revert AlreadyVerified(emailHash);
    verifiedEmails[emailHash] = true;
    emit EmailVerified(emailHash, msg.sender);
}
```

Modify `deployAccount()` — add verification check at top:

```solidity
// PATCH-15: require pre-verified email hash
if (!verifiedEmails[emailHash]) revert EmailNotVerified(emailHash);
verifiedEmails[emailHash] = false; // one-time use — consume on deploy
```

Add events:

```solidity
event EmailVerified(bytes32 indexed emailHash, address indexed verifier);
event AccountDeployed(bytes32 indexed emailHash, address account, address owner);
```

Grant `EMAIL_VERIFIER_ROLE` in constructor or initializer:

```solidity
// Grant to trusted off-chain email verifier service address
// _grantRole(EMAIL_VERIFIER_ROLE, emailVerifierServiceAddress);
// NOTE: leave commented for deploy script to configure
```

### Step 3 — Write test file

Create `test/security/Patch15EmailHash.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/account/TAGITAccountFactory.sol";

contract Patch15EmailHashTest is Test {
    TAGITAccountFactory factory;
    address admin = makeAddr("admin");
    address verifier = makeAddr("verifier");
    address user = makeAddr("user");
    address attacker = makeAddr("attacker");
    bytes32 emailHash = keccak256("user@company.com");

    function setUp() public {
        vm.startPrank(admin);
        factory = new TAGITAccountFactory(admin);
        factory.grantRole(factory.EMAIL_VERIFIER_ROLE(), verifier);
        vm.stopPrank();
    }

    function test_deployAccount_reverts_without_verification() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITAccountFactory.EmailNotVerified.selector, emailHash
        ));
        factory.deployAccount(emailHash, user);
    }

    function test_deployAccount_succeeds_after_verification() public {
        vm.prank(verifier);
        factory.verifyEmail(emailHash);

        vm.prank(user);
        address account = factory.deployAccount(emailHash, user);
        assertTrue(account != address(0));
        assertEq(factory.deployedAccounts(emailHash), account);
    }

    function test_verifyEmail_requires_role() public {
        vm.prank(attacker);
        vm.expectRevert(); // AccessControl revert
        factory.verifyEmail(emailHash);
    }

    function test_emailHash_single_use() public {
        vm.prank(verifier);
        factory.verifyEmail(emailHash);

        vm.prank(user);
        factory.deployAccount(emailHash, user);

        // Attempt second deploy with same hash — hash consumed
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITAccountFactory.EmailNotVerified.selector, emailHash
        ));
        factory.deployAccount(emailHash, user);
    }

    function test_frontrun_blocked() public {
        // Attacker tries to deploy before verifier approves — blocked
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITAccountFactory.EmailNotVerified.selector, emailHash
        ));
        factory.deployAccount(emailHash, attacker);

        // Verifier approves for legitimate user
        vm.prank(verifier);
        factory.verifyEmail(emailHash);

        // Legitimate user deploys
        vm.prank(user);
        address account = factory.deployAccount(emailHash, user);
        assertTrue(account != address(0));
    }

    function test_double_verify_reverts() public {
        vm.startPrank(verifier);
        factory.verifyEmail(emailHash);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITAccountFactory.AlreadyVerified.selector, emailHash
        ));
        factory.verifyEmail(emailHash);
        vm.stopPrank();
    }
}
```

### Step 4 — Verify

```bash
forge build
forge test --match-path test/security/Patch15*.t.sol -vv
forge test -vv 2>&1 | tail -20
git add src/account/TAGITAccountFactory.sol test/security/Patch15EmailHash.t.sol
git commit -m "security: PATCH-15 gate emailHash deployment behind EMAIL_VERIFIER_ROLE

- verifiedEmails[emailHash] mapping — must be true before deployAccount()
- verifyEmail() requires EMAIL_VERIFIER_ROLE — off-chain service gates access
- EmailNotVerified(emailHash) custom error on unverified deployment attempt
- One-time use: hash consumed on deploy to prevent replay
- AlreadyVerified(emailHash) error prevents double-verification
- 6 tests: front-run blocked, role required, single-use enforcement

Fixes: EVMbench HIGH finding — identity hijacking via permissionless emailHash"
```

---

## PATCH-14: Unverified actionProof in TAGITPrograms

**File:** `src/programs/TAGITPrograms.sol`

### What's wrong

`claimReward(programId, actionProof)` never verifies the proof.
Anyone submits random bytes and drains the reward treasury.

### Step 1 — Read current file

```bash
cat src/programs/TAGITPrograms.sol
```

Find: `claimReward()`, any existing EIP-712 usage, imports.

### Step 2 — Apply the patch

Add imports at top:

```solidity
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
```

If not already inheriting EIP712, add to contract declaration:

```solidity
contract TAGITPrograms is EIP712, AccessControl, ReentrancyGuard {
```

And add to constructor:

```solidity
) EIP712("TAGITPrograms", "1") {
```

Add state variables:

```solidity
// PATCH-14: EIP-712 action proof verification
mapping(address => uint256) public claimNonces;
bytes32 public constant PROGRAM_VERIFIER_ROLE = keccak256("PROGRAM_VERIFIER_ROLE");
bytes32 private constant ACTION_TYPEHASH = keccak256(
    "ActionProof(uint256 programId,address claimant,uint256 nonce,uint256 deadline)"
);
```

Add custom errors:

```solidity
error InvalidActionProof();
error ProofExpired();
```

Replace or modify `claimReward()`:

```solidity
/// @notice Claim reward for a completed program action
/// @param programId The program to claim from
/// @param deadline Proof expiry timestamp (max 1 hour from signing)
/// @param actionProof EIP-712 signature from PROGRAM_VERIFIER_ROLE address
function claimReward(
    uint256 programId,
    uint256 deadline,
    bytes calldata actionProof
) external nonReentrant {
    // PATCH-14: check deadline
    if (block.timestamp > deadline) revert ProofExpired();

    // PATCH-14: consume nonce (prevents replay)
    uint256 nonce = claimNonces[msg.sender]++;

    // PATCH-14: build EIP-712 digest
    bytes32 structHash = keccak256(abi.encode(
        ACTION_TYPEHASH,
        programId,
        msg.sender,
        nonce,
        deadline
    ));
    bytes32 digest = _hashTypedDataV4(structHash);

    // PATCH-14: recover and verify signer
    address signer = ECDSA.recover(digest, actionProof);
    if (!hasRole(PROGRAM_VERIFIER_ROLE, signer)) revert InvalidActionProof();

    _payReward(programId, msg.sender);
    emit RewardClaimed(programId, msg.sender, nonce);
}
```

### Step 3 — Write test file

Create `test/security/Patch14ActionProof.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../../src/programs/TAGITPrograms.sol";

contract Patch14ActionProofTest is Test {
    using ECDSA for bytes32;

    TAGITPrograms programs;
    address admin = makeAddr("admin");
    address claimant = makeAddr("claimant");
    address attacker = makeAddr("attacker");
    uint256 verifierKey = 0xA11CE;
    address verifier;
    uint256 constant PROGRAM_ID = 1;

    function setUp() public {
        verifier = vm.addr(verifierKey);
        vm.startPrank(admin);
        programs = new TAGITPrograms(admin);
        programs.grantRole(programs.PROGRAM_VERIFIER_ROLE(), verifier);
        programs.createProgram(PROGRAM_ID, 1 ether); // setup test program
        vm.deal(address(programs), 100 ether);
        vm.stopPrank();
    }

    function _signProof(
        uint256 programId,
        address claimantAddr,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            programs.ACTION_TYPEHASH(),
            programId,
            claimantAddr,
            nonce,
            deadline
        ));
        bytes32 digest = programs.hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifierKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_claimReward_valid_proof() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = programs.claimNonces(claimant);
        bytes memory proof = _signProof(PROGRAM_ID, claimant, nonce, deadline);

        uint256 balanceBefore = claimant.balance;
        vm.prank(claimant);
        programs.claimReward(PROGRAM_ID, deadline, proof);
        assertGt(claimant.balance, balanceBefore);
    }

    function test_claimReward_invalid_proof_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(TAGITPrograms.InvalidActionProof.selector);
        programs.claimReward(PROGRAM_ID, block.timestamp + 1 hours, bytes("garbage"));
    }

    function test_claimReward_expired_deadline_reverts() public {
        bytes memory proof = _signProof(PROGRAM_ID, claimant, 0, block.timestamp - 1);
        vm.prank(claimant);
        vm.expectRevert(TAGITPrograms.ProofExpired.selector);
        programs.claimReward(PROGRAM_ID, block.timestamp - 1, proof);
    }

    function test_claimReward_replay_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = programs.claimNonces(claimant);
        bytes memory proof = _signProof(PROGRAM_ID, claimant, nonce, deadline);

        vm.startPrank(claimant);
        programs.claimReward(PROGRAM_ID, deadline, proof);
        // Replay same proof — nonce incremented, sig now invalid
        vm.expectRevert(TAGITPrograms.InvalidActionProof.selector);
        programs.claimReward(PROGRAM_ID, deadline, proof);
        vm.stopPrank();
    }

    function test_claimReward_wrong_signer_reverts() public {
        uint256 wrongKey = 0xBAD;
        bytes32 digest = keccak256("anything");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory proof = abi.encodePacked(r, s, v);

        vm.prank(claimant);
        vm.expectRevert(TAGITPrograms.InvalidActionProof.selector);
        programs.claimReward(PROGRAM_ID, block.timestamp + 1 hours, proof);
    }

    function testFuzz_claimReward_random_bytes(bytes calldata proof) public {
        vm.prank(attacker);
        vm.expectRevert();
        programs.claimReward(PROGRAM_ID, block.timestamp + 1 hours, proof);
    }
}
```

### Step 4 — Verify

```bash
forge build
forge test --match-path test/security/Patch14*.t.sol -vv
forge test -vv 2>&1 | tail -20
git add src/programs/TAGITPrograms.sol test/security/Patch14ActionProof.t.sol
git commit -m "security: PATCH-14 EIP-712 actionProof verification in TAGITPrograms

- ACTION_TYPEHASH for typed structured data signing
- PROGRAM_VERIFIER_ROLE signs proofs off-chain
- ECDSA.recover() validates signer on-chain before reward payment
- claimNonces[claimant]++ prevents replay attacks
- deadline parameter rejects proofs older than signing window
- InvalidActionProof() and ProofExpired() custom errors
- 6 tests: valid proof, invalid bytes, replay, expired, wrong signer, fuzz

Fixes: EVMbench HIGH finding — reward claiming with unverified actionProof"
```

---

## PATCH-11: Cross-Asset Drain in TAGITTreasury

**File:** `src/treasury/TAGITTreasury.sol`

### What's wrong

`createAllocation()` records an asset type but `executeWithdrawal()` never
checks it. TAGIT allocation can be redeemed for ETH or any other asset.

### Step 1 — Read current file

```bash
cat src/treasury/TAGITTreasury.sol
```

Find: `Allocation` struct, `createAllocation()`, `executeWithdrawal()`.

### Step 2 — Apply the patch

Add custom error:

```solidity
error AssetMismatch(address expected, address received);
```

Modify `executeWithdrawal()` — add asset validation:

```solidity
function executeWithdrawal(
    uint256 allocationId,
    address asset,
    uint256 amount
) external onlyRole(EXECUTOR_ROLE) nonReentrant {
    Allocation storage alloc = allocations[allocationId];
    require(!alloc.executed, "AlreadyExecuted");
    require(amount <= alloc.amount, "ExceedsAllocation");

    // PATCH-11: enforce asset type matches allocation
    if (asset != alloc.asset) revert AssetMismatch(alloc.asset, asset);

    alloc.executed = true;
    _transfer(asset, msg.sender, amount);
    emit WithdrawalExecuted(allocationId, asset, amount, msg.sender);
}
```

### Step 3 — Write test file

Create `test/security/Patch11TreasuryAsset.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/treasury/TAGITTreasury.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract Patch11TreasuryAssetTest is Test {
    TAGITTreasury treasury;
    MockERC20 tagitToken;
    address admin = makeAddr("admin");
    address allocator = makeAddr("allocator");
    address executor = makeAddr("executor");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.startPrank(admin);
        tagitToken = new MockERC20("TAGIT", "TAG", 18);
        treasury = new TAGITTreasury(admin, address(tagitToken));
        treasury.grantRole(treasury.ALLOCATOR_ROLE(), allocator);
        treasury.grantRole(treasury.EXECUTOR_ROLE(), executor);
        // Fund treasury with both assets
        tagitToken.mint(address(treasury), 1000 ether);
        vm.deal(address(treasury), 100 ether);
        vm.stopPrank();
    }

    function test_withdrawal_correct_asset_succeeds() public {
        vm.prank(allocator);
        uint256 id = treasury.createAllocation(100 ether, address(tagitToken));

        vm.prank(executor);
        treasury.executeWithdrawal(id, address(tagitToken), 100 ether);
        assertEq(tagitToken.balanceOf(executor), 100 ether);
    }

    function test_withdrawal_wrong_asset_reverts() public {
        // Allocate TAGIT tokens
        vm.prank(allocator);
        uint256 id = treasury.createAllocation(100 ether, address(tagitToken));

        // Try to withdraw ETH using TAGIT allocation — must revert
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITTreasury.AssetMismatch.selector,
            address(tagitToken),
            address(0) // ETH represented as address(0)
        ));
        treasury.executeWithdrawal(id, address(0), 100 ether);
    }

    function test_allocation_executed_once() public {
        vm.prank(allocator);
        uint256 id = treasury.createAllocation(100 ether, address(tagitToken));

        vm.startPrank(executor);
        treasury.executeWithdrawal(id, address(tagitToken), 100 ether);
        vm.expectRevert("AlreadyExecuted");
        treasury.executeWithdrawal(id, address(tagitToken), 100 ether);
        vm.stopPrank();
    }

    function testFuzz_withdrawal_asset_mismatch(address wrongAsset) public {
        vm.assume(wrongAsset != address(tagitToken));
        vm.prank(allocator);
        uint256 id = treasury.createAllocation(100 ether, address(tagitToken));

        vm.prank(executor);
        vm.expectRevert();
        treasury.executeWithdrawal(id, wrongAsset, 100 ether);
    }
}
```

### Step 4 — Verify

```bash
forge build
forge test --match-path test/security/Patch11*.t.sol -vv
forge test -vv 2>&1 | tail -20
git add src/treasury/TAGITTreasury.sol test/security/Patch11TreasuryAsset.t.sol
git commit -m "security: PATCH-11 lock asset type on allocation in TAGITTreasury

- executeWithdrawal() now verifies asset == alloc.asset before transfer
- AssetMismatch(expected, received) custom error with both addresses
- Prevents cross-asset drain: TAGIT allocation cannot redeem ETH/USDC
- 4 tests: correct asset succeeds, wrong asset reverts, fuzz all assets

Fixes: EVMbench HIGH finding — treasury cross-asset drain via TAGIT allocations"
```

---

## PATCH-12 + PATCH-13: TAGITPaymaster Brand Ownership

**File:** `src/account/TAGITPaymaster.sol`

These two patches are implemented together — same file, related logic.

### What's wrong (combined)

- **PATCH-12:** No ownership check on brand deposit/withdrawal. Anyone drains any brand.
- **PATCH-13:** Brand registration is permissionless. Attacker squats any brand ID.

### Step 1 — Read current file

```bash
cat src/account/TAGITPaymaster.sol
```

### Step 2 — Apply both patches

Add to state:

```solidity
// PATCH-12 + PATCH-13: brand ownership
mapping(bytes32 => address) public brandOwner;
mapping(bytes32 => address) public pendingBrandOwner;
```

Add custom errors:

```solidity
error NotBrandOwner(bytes32 brandId, address caller);
error BrandAlreadyRegistered(bytes32 brandId);
error NoPendingTransfer(bytes32 brandId);
```

Add modifier:

```solidity
modifier onlyBrandOwner(bytes32 brandId) {
    if (brandOwner[brandId] != msg.sender)
        revert NotBrandOwner(brandId, msg.sender);
    _;
}
```

Replace `registerBrand()`:

```solidity
// PATCH-13: role-gated registration prevents squatting
function registerBrand(bytes32 brandId, address owner)
    external
    onlyRole(BRAND_REGISTRY_ROLE)
{
    if (brandOwner[brandId] != address(0)) revert BrandAlreadyRegistered(brandId);
    brandOwner[brandId] = owner;
    emit BrandRegistered(brandId, owner, msg.sender);
}
```

Add to `withdrawBrandDeposit()`:

```solidity
// PATCH-12: ownership check
function withdrawBrandDeposit(bytes32 brandId, uint256 amount)
    external
    onlyBrandOwner(brandId)   // PATCH-12
    nonReentrant
{
    require(brandDeposits[brandId] >= amount, "Insufficient");
    brandDeposits[brandId] -= amount;
    payable(msg.sender).transfer(amount);
    emit BrandWithdrawal(brandId, msg.sender, amount);
}
```

Add two-step ownership transfer:

```solidity
// PATCH-12: safe brand ownership handoff
function transferBrandOwnership(bytes32 brandId, address newOwner)
    external
    onlyBrandOwner(brandId)
{
    pendingBrandOwner[brandId] = newOwner;
    emit BrandOwnershipTransferInitiated(brandId, msg.sender, newOwner);
}

function acceptBrandOwnership(bytes32 brandId) external {
    if (pendingBrandOwner[brandId] != msg.sender) revert NoPendingTransfer(brandId);
    brandOwner[brandId] = msg.sender;
    delete pendingBrandOwner[brandId];
    emit BrandOwnershipTransferred(brandId, msg.sender);
}
```

Add events:

```solidity
event BrandRegistered(bytes32 indexed brandId, address indexed owner, address indexed registrar);
event BrandWithdrawal(bytes32 indexed brandId, address indexed owner, uint256 amount);
event BrandOwnershipTransferInitiated(bytes32 indexed brandId, address from, address to);
event BrandOwnershipTransferred(bytes32 indexed brandId, address indexed newOwner);
```

### Step 3 — Write test file

Create `test/security/Patch12And13Paymaster.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/account/TAGITPaymaster.sol";

contract Patch12And13PaymasterTest is Test {
    TAGITPaymaster paymaster;
    address admin = makeAddr("admin");
    address registrar = makeAddr("registrar");
    address brandOwnerAddr = makeAddr("brandOwner");
    address attacker = makeAddr("attacker");
    bytes32 BRAND_ID = keccak256("NIKE");

    function setUp() public {
        vm.startPrank(admin);
        paymaster = new TAGITPaymaster(admin);
        paymaster.grantRole(paymaster.BRAND_REGISTRY_ROLE(), registrar);
        vm.stopPrank();

        // Register brand with role
        vm.prank(registrar);
        paymaster.registerBrand(BRAND_ID, brandOwnerAddr);

        // Fund brand deposit
        vm.deal(brandOwnerAddr, 10 ether);
        vm.prank(brandOwnerAddr);
        paymaster.depositForBrand{value: 5 ether}(BRAND_ID);
    }

    // PATCH-12 tests
    function test_withdraw_by_owner_succeeds() public {
        uint256 before = brandOwnerAddr.balance;
        vm.prank(brandOwnerAddr);
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);
        assertEq(brandOwnerAddr.balance, before + 1 ether);
    }

    function test_withdraw_by_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITPaymaster.NotBrandOwner.selector, BRAND_ID, attacker
        ));
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);
    }

    function test_brand_ownership_two_step_transfer() public {
        vm.prank(brandOwnerAddr);
        paymaster.transferBrandOwnership(BRAND_ID, attacker);

        // Before accept — original owner still in control
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);

        // After accept
        vm.prank(attacker);
        paymaster.acceptBrandOwnership(BRAND_ID);
        assertEq(paymaster.brandOwner(BRAND_ID), attacker);
    }

    // PATCH-13 tests
    function test_registerBrand_requires_role() public {
        vm.prank(attacker);
        vm.expectRevert(); // AccessControl
        paymaster.registerBrand(keccak256("ADIDAS"), attacker);
    }

    function test_squatting_blocked() public {
        // Attacker cannot register any brand without role
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.registerBrand(BRAND_ID, attacker);
    }

    function test_double_registration_reverts() public {
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(
            TAGITPaymaster.BrandAlreadyRegistered.selector, BRAND_ID
        ));
        paymaster.registerBrand(BRAND_ID, brandOwnerAddr);
    }

    function testFuzz_withdraw_random_caller(address caller) public {
        vm.assume(caller != brandOwnerAddr);
        vm.prank(caller);
        vm.expectRevert();
        paymaster.withdrawBrandDeposit(BRAND_ID, 1 ether);
    }
}
```

### Step 4 — Verify

```bash
forge build
forge test --match-path test/security/Patch12And13*.t.sol -vv
forge test -vv 2>&1 | tail -20
git add src/account/TAGITPaymaster.sol test/security/Patch12And13Paymaster.t.sol
git commit -m "security: PATCH-12 + PATCH-13 brand ownership and registration in TAGITPaymaster

PATCH-12:
- brandOwner[brandId] mapping — set at registration, checked on all fund ops
- onlyBrandOwner modifier on depositForBrand, withdrawBrandDeposit
- Two-step ownership transfer: transferBrandOwnership + acceptBrandOwnership
- NotBrandOwner(brandId, caller) custom error

PATCH-13:
- BRAND_REGISTRY_ROLE gates registerBrand() — permissionless registration removed
- BrandAlreadyRegistered(brandId) prevents duplicate registration

Tests: 7 tests covering both patches

Fixes: EVMbench HIGH findings:
  - Brand deposit drain via untrusted brandId
  - Brand ID squatting / ownership hijack"
```

---

## FINAL VALIDATION — Run after all 6 patches committed

```bash
cd C:/tagcode/tagit-contracts

echo "=== FINAL TEST RUN ==="
forge test -vv 2>&1 | tee /tmp/final-test-results.txt

echo ""
echo "=== SECURITY PATCH TESTS ONLY ==="
forge test --match-path "test/security/Patch*" -vv

echo ""
echo "=== FUZZ RUNS ==="
forge test --match-test "testFuzz" --fuzz-runs 10000 -vv 2>&1 | tail -30

echo ""
echo "=== SLITHER CHECK ==="
slither . --filter-paths "test,lib,node_modules" 2>&1 | grep -E "HIGH|CRITICAL" | head -20

echo ""
echo "=== BUILD CLEAN CHECK ==="
forge build 2>&1 | grep -E "error|warning" | head -20

echo "=== DONE ==="
```

Expected results:
- All forge tests pass (check current passing count — should not decrease)
- All 6 Patch*.t.sol files pass 100%
- Fuzz tests: 10,000 runs, 0 failures
- Slither: no new HIGH/CRITICAL findings introduced by patches
- Build: 0 errors, minimal warnings

## SAVE RESULTS

```bash
# Copy test output to security repo
cp /tmp/final-test-results.txt \
   C:/tagcode/tagit-security/reports/patch-11-16-verification.txt

echo "Patches: PATCH-11 through PATCH-16" >> C:/tagcode/tagit-security/reports/patch-11-16-verification.txt
echo "Date: $(date -u)" >> C:/tagcode/tagit-security/reports/patch-11-16-verification.txt
echo "Tool: forge test + slither" >> C:/tagcode/tagit-security/reports/patch-11-16-verification.txt

cd C:/tagcode/tagit-security
git add reports/patch-11-16-verification.txt
git commit -m "security: PATCH-11 through PATCH-16 verification results — all tests pass"
git push origin main
```

## COMPLETION REPORT

Output this summary when all patches are done:

```
=== PATCH SPRINT COMPLETE: PATCH-11 through PATCH-16 ===

Date: [timestamp]

PATCH-16: Session key spend limits         => Enforced — SpendLimitExceeded error
PATCH-15: AccountFactory emailHash gate    => EMAIL_VERIFIER_ROLE required
PATCH-14: Programs actionProof EIP-712     => ECDSA verify + nonce + TTL
PATCH-11: Treasury asset type lock         => AssetMismatch error on mismatch
PATCH-12: Paymaster brandOwner mapping     => onlyBrandOwner modifier
PATCH-13: Brand registration role gate     => BRAND_REGISTRY_ROLE required

Test results:
  Total tests: [N] passing
  Security patch tests: [N]/[N] passing
  Fuzz runs: 10,000 per test, 0 failures
  Regressions: ZERO

Verification saved: tagit-security/reports/patch-11-16-verification.txt

NEXT STEPS:
1. Re-run official EVMbench to confirm 0 HIGH findings remain
2. Update Notion tasks PATCH-11 through PATCH-16 to Done
3. Update pre-audit package with patch verification output
4. Run Mythril on patched contracts (T08 — now unblocked)
5. Target post-patch EVMbench score: 950+/1000
```

## ABORT CONDITIONS

Stop and report to Artemus if:
- `forge build` fails on any patch — do not proceed
- Any existing test breaks — investigate before continuing
- A patch requires architectural changes beyond what's described — flag it
- A contract file doesn't exist at the expected path — check repo structure first

When aborting: commit work in progress with `[WIP]` prefix, save error output,
report exact failure with file + line number.
