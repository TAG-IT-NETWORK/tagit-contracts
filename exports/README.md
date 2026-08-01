# TAG IT Contracts - Dashboard Integration

This folder contains ABIs and addresses for integrating with TAG IT smart contracts.

## Quick Start

### 1. Import Addresses

```typescript
import addresses from '../deployment-addresses.json';

const network = 'base-sepolia';  // the live chain (84532)
const contracts = addresses.networks[network].contracts;

// Entries come in two shapes: UUPS contracts are { proxy, implementation, type },
// everything else is { address, ... }. Read the field, not the entry.
// TAGITCore is behind a UUPS proxy — always use the proxy address.
console.log(contracts.TAGITCore.proxy);  // 0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D
```

### 2. Import ABIs

```typescript
import TAGITCoreABI from './abis/TAGITCore.json';
import TAGITAccessABI from './abis/TAGITAccess.json';
import CapabilityBadgeABI from './abis/CapabilityBadge.json';
```

### 3. Create Contract Instances (ethers.js)

```typescript
import { ethers } from 'ethers';
import TAGITCoreABI from './abis/TAGITCore.json';
import addresses from '../deployment-addresses.json';

const provider = new ethers.JsonRpcProvider('https://sepolia.base.org');
const signer = await provider.getSigner();

const tagitCore = new ethers.Contract(
  addresses.networks['base-sepolia'].contracts.TAGITCore.proxy,
  TAGITCoreABI,
  signer
);
```

---

## Proxy Architecture

TAGITCore uses the **UUPS proxy pattern** (EIP-1822) with a **TimelockController** for governance.

### How It Works

- **Proxy contract**: The address callers interact with. Holds all storage and delegates calls to the implementation.
- **Implementation contract**: The logic contract behind the proxy. Can be upgraded without changing the proxy address.
- **TimelockController**: Owns the proxy. All admin operations (upgrades, config changes) require a delay before execution. **On the deployed testnets that delay is currently 60s (Base Sepolia) / 300s (OP Sepolia)** — read it live with `getMinDelay()` rather than trusting a number in docs. 48 hours is the mainnet target, not the current value.

### Key Points for Integrators

- Always interact with the **proxy address** (`contracts.TAGITCore` / `contracts.TAGITCoreProxy`). The proxy address never changes.
- The implementation address can change after upgrades. Call `getImplementation()` on the proxy to read the current logic contract.
- ABI remains the same — the proxy transparently delegates to the implementation.
- Upgrades are governed: a proposal must be scheduled on the TimelockController and can only execute after `getMinDelay()` has elapsed.

### Upgrade Flow

```
1. Proposer schedules upgradeToAndCall on TimelockController (getMinDelay() starts)
2. UpgradeScheduled event emitted — off-chain monitors can alert
3. After the delay elapses, executor calls TimelockController.execute()
4. TimelockController calls proxy.upgradeToAndCall(newImpl, "")
5. Proxy storage slot updated to point to new implementation
```

Use `script/UpgradeTAGITCore.s.sol` for the full schedule + execute workflow.

---

## Contract Reference

### TAGITCore (ERC-721)

Digital Twin NFT with lifecycle state machine, deployed behind UUPS proxy.

#### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `mint` | `mint(address to, bytes32 metadata) returns (uint256)` | Create new Digital Twin NFT |
| `bindTag` | `bindTag(uint256 tokenId, bytes32 tagHash, bytes challengeResponse, bytes oracleSignature)` | Bind NFC tag with oracle verification |
| `activate` | `activate(uint256 tokenId)` | QA approval |
| `claim` | `claim(uint256 tokenId, address newOwner)` | Transfer ownership |
| `flag` | `flag(uint256 tokenId)` | Mark as lost/stolen |
| `resolve` | `resolve(uint256 tokenId, address newOwner)` | Recovery resolution |
| `recycle` | `recycle(uint256 tokenId)` | End-of-life |

#### View Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `name` | `name() returns (string)` | Token name: "TAG IT Digital Twin" |
| `symbol` | `symbol() returns (string)` | Token symbol: "TAGIT" |
| `totalSupply` | `totalSupply() returns (uint256)` | Total minted tokens |
| `ownerOf` | `ownerOf(uint256 tokenId) returns (address)` | Token owner |
| `getAsset` | `getAsset(uint256 tokenId) returns (address, uint64, State, uint8, uint16)` | Asset details |
| `getTagByToken` | `getTagByToken(uint256 tokenId) returns (bytes32)` | Get tag hash by token |
| `getTokenByTag` | `getTokenByTag(bytes32 tagHash) returns (uint256)` | Get token by tag hash |
| `getImplementation` | `getImplementation() returns (address)` | Current implementation address (proxy only) |

#### Admin Functions (TimelockController only)

| Function | Signature | Description |
|----------|-----------|-------------|
| `upgradeToAndCall` | `upgradeToAndCall(address newImplementation, bytes data)` | Upgrade to new implementation |
| `setAccessController` | `setAccessController(address accessController)` | Set BIDGES access controller |
| `setNFCOracle` | `setNFCOracle(address oracle)` | Set trusted NFC oracle for bindTag |

All admin functions are gated by the TimelockController's `getMinDelay()`. See the note above: this is 60s on Base Sepolia today, not 48 hours.

#### State Enum

```typescript
enum State {
  NONE = 0,      // Default/not created
  MINTED = 1,    // NFT exists, no tag
  BOUND = 2,     // Tag cryptographically linked
  ACTIVATED = 3, // QA passed, ready for distribution
  CLAIMED = 4,   // Owned by end consumer
  FLAGGED = 5,   // Lost/stolen/recall
  RECYCLED = 6   // End of life
}
```

---

### CapabilityBadge (ERC-1155)

Transferable capability tokens for access control.

#### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `grantCapability` | `grantCapability(address account, uint256 capabilityId) returns (uint256)` | Grant capability |
| `revokeCapability` | `revokeCapability(address account, uint256 capabilityId)` | Revoke capability |
| `hasCapability` | `hasCapability(address account, uint256 capabilityId) returns (bool)` | Check capability |

#### Capability IDs

| ID | Name | Permission |
|----|------|------------|
| 100 | MINTER | Create new asset NFTs |
| 101 | BINDER | Bind NFC tags to assets |
| 102 | ACTIVATOR | QA activation approval |
| 103 | CLAIMER | Transfer ownership |
| 104 | FLAGGER | Flag assets as suspicious |
| 105 | RESOLVER | Approve recovery resolution |
| 106 | RECYCLER | End-of-life disposal |

---

### TAGITAccess (BIDGES Facade)

Access control controller combining identity + capability checks.

#### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `hasCapability` | `hasCapability(address account, uint256 capabilityId) returns (bool)` | Check capability |
| `requireCapability` | `requireCapability(address account, uint256 capabilityId)` | Revert if missing capability |
| `hasIdentity` | `hasIdentity(address account, uint256 badgeId) returns (bool)` | Check identity badge |

---

## Example: Full Lifecycle

```typescript
import { ethers } from 'ethers';

// 1. Setup
const provider = new ethers.JsonRpcProvider('https://sepolia.base.org');
const signer = new ethers.Wallet(PRIVATE_KEY, provider);

const tagitCore = new ethers.Contract(TAGIT_CORE_ADDRESS, TAGITCoreABI, signer);
const capabilityBadge = new ethers.Contract(CAPABILITY_BADGE_ADDRESS, CapabilityBadgeABI, signer);

// 2. Grant MINTER capability (owner only)
await capabilityBadge.grantCapability(signer.address, 100);

// 3. Mint Digital Twin
const metadata = ethers.keccak256(ethers.toUtf8Bytes('product-sku-12345'));
const tx = await tagitCore.mint(signer.address, metadata);
const receipt = await tx.wait();

// Get tokenId from event
const event = receipt.logs.find(log => log.topics[0] === tagitCore.interface.getEvent('AssetMinted').topicHash);
const tokenId = event.args[0];

console.log('Minted Token ID:', tokenId.toString());

// 4. Bind tag (requires oracle signature post-PATCH-06)
const tagHash = ethers.keccak256(ethers.toUtf8Bytes('NFC-TAG-UID-ABC123'));
const challengeResponse = '0x...'; // NFC challenge-response bytes
const oracleSignature = '0x...';   // Signed by trusted NFC oracle
await tagitCore.bindTag(tokenId, tagHash, challengeResponse, oracleSignature);

// 5. Activate
await tagitCore.activate(tokenId);

// 6. Claim (transfer to new owner)
await tagitCore.claim(tokenId, NEW_OWNER_ADDRESS);

// 7. Check state
const asset = await tagitCore.getAsset(tokenId);
console.log('State:', asset[2]); // 4 = CLAIMED
```

---

## Network Addresses

### Base Sepolia (84532) — the only live chain

| Contract | Address |
|----------|---------|
| TAGITCore (proxy) | `0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D` |
| TAGITCore (impl) | `0x2377B7f33aFf34c58DDF6DeA7eD4dCaD616CA14C` |
| TimelockController | `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1` |
| TAGITAccess | `0xb56A1D91995C212342FaA843468F03521340A1D6` |
| IdentityBadge | `0xebdAC9A0663c02a7297681b078aaD893EF345030` |
| CapabilityBadge | `0xb05d22706B08A3F6409601de520cf7A6dbCB573d` |

> **Governance:** All TAGITCore admin operations go through the TimelockController. Verified on-chain 2026-08-01: `getMinDelay()` returns **300s on OP Sepolia** and **60s on Base Sepolia**. Must be raised to 48 hours before mainnet.

### Base Mainnet

*Not yet deployed.*

### Archived

OP Sepolia (11155420) and Arbitrum Sepolia (421614) were deprecated 2026-06-27 and
carry `"status": "archived"` in `deployment-addresses.json`. Their addresses remain
in that file as deployment history. Do not integrate against them.

---

## Test Transaction Reference

| Action | Transaction Hash |
|--------|------------------|
| Token #1 Mint | `0x2188ab4f...` |
| MINTER Grant | `0xdd238f93...` |

---

## Verified on Etherscan

All contracts are verified and source code is available:

- [TAGITCore (proxy)](https://sepolia.basescan.org/address/0x3aDc7EFDb58Ae85483eFf5D4966D916185f31d1D#code)
- [TAGITCore (impl)](https://sepolia.basescan.org/address/0x2377B7f33aFf34c58DDF6DeA7eD4dCaD616CA14C#code)
- [TimelockController](https://sepolia.basescan.org/address/0xfdA2478dB73064eF770f4e5E5b97BC83801126e1#code)
- [TAGITAccess](https://sepolia.basescan.org/address/0xb56A1D91995C212342FaA843468F03521340A1D6#code)
- [IdentityBadge](https://sepolia.basescan.org/address/0xebdAC9A0663c02a7297681b078aaD893EF345030#code)
- [CapabilityBadge](https://sepolia.basescan.org/address/0xb05d22706B08A3F6409601de520cf7A6dbCB573d#code)

---

## Support

For integration questions, contact the contracts team.
