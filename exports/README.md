# TAG IT Contracts - Dashboard Integration

This folder contains ABIs and addresses for integrating with TAG IT smart contracts.

## Quick Start

### 1. Import Addresses

```typescript
import addresses from './addresses.json';

const network = 'op-sepolia';
const contracts = addresses.networks[network].contracts;

console.log(contracts.TAGITCore);  // 0x8B02b62FD388b2d7e3dF5Ec666D68Ac7c7ca02Fe
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
import addresses from './addresses.json';

const provider = new ethers.JsonRpcProvider(addresses.networks['op-sepolia'].rpcUrl);
const signer = await provider.getSigner();

const tagitCore = new ethers.Contract(
  addresses.networks['op-sepolia'].contracts.TAGITCore,
  TAGITCoreABI,
  signer
);
```

---

## Contract Reference

### TAGITCore (ERC-721)

Digital Twin NFT with lifecycle state machine.

#### Key Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `mint` | `mint(address to, bytes32 metadata) returns (uint256)` | Create new Digital Twin NFT |
| `bindTag` | `bindTag(uint256 tokenId, bytes32 tagHash)` | Bind NFC tag to token |
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
const provider = new ethers.JsonRpcProvider('https://sepolia.optimism.io');
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

// 4. Bind tag
const tagHash = ethers.keccak256(ethers.toUtf8Bytes('NFC-TAG-UID-ABC123'));
await tagitCore.bindTag(tokenId, tagHash);

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

### OP Sepolia (Testnet)

| Contract | Address |
|----------|---------|
| TAGITCore | `0x8B02b62FD388b2d7e3dF5Ec666D68Ac7c7ca02Fe` |
| TAGITAccess | `0x0611FE60f6E37230bDaf04c5F2Ac2dc9012130a9` |
| IdentityBadge | `0x26F2EBb84664EF1eF8554e15777EBEc6611256A6` |
| CapabilityBadge | `0x5e190F6Ebde4BD1e11a5566a1e81a933cdDf3505` |

### OP Mainnet

*Not yet deployed*

---

## Test Transaction Reference

| Action | Transaction Hash |
|--------|------------------|
| Token #1 Mint | `0x2188ab4f...` |
| MINTER Grant | `0xdd238f93...` |

---

## Verified on Etherscan

All contracts are verified and source code is available:

- [TAGITCore](https://sepolia-optimism.etherscan.io/address/0x8B02b62FD388b2d7e3dF5Ec666D68Ac7c7ca02Fe#code)
- [TAGITAccess](https://sepolia-optimism.etherscan.io/address/0x0611FE60f6E37230bDaf04c5F2Ac2dc9012130a9#code)
- [CapabilityBadge](https://sepolia-optimism.etherscan.io/address/0x5e190F6Ebde4BD1e11a5566a1e81a933cdDf3505#code)
- [IdentityBadge](https://sepolia-optimism.etherscan.io/address/0x26F2EBb84664EF1eF8554e15777EBEc6611256A6#code)

---

## Support

For integration questions, contact the contracts team.
