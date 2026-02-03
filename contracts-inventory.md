# TAGIT Contracts Inventory

> Generated: 2026-02-02 | Phase 2.1: Safe Read Operation

## Summary

| Category | Count |
|----------|-------|
| **Total Contracts** | 37 |
| Core Modules | 9 |
| Interfaces | 15 |
| Libraries | 5 |
| Token | 5 |
| Other | 3 |

## Directory Structure

```
src/
├── access/
│   ├── CapabilityBadge.sol      # ERC-1155 capability badges
│   ├── IdentityBadge.sol        # Soulbound identity badges (ERC-5192)
│   └── TAGITAccess.sol          # BIDGES badge system coordinator
│
├── account/
│   ├── TAGITAccount.sol         # Smart account implementation
│   ├── TAGITAccountFactory.sol  # Account factory (ERC-4337)
│   └── TAGITPaymaster.sol       # Gas sponsorship
│
├── bridge/
│   └── CCIPAdapter.sol          # Chainlink CCIP cross-chain adapter
│
├── core/
│   └── TAGITCore.sol            # ERC-721 digital twins, 7-state lifecycle
│
├── governance/
│   └── TAGITGovernor.sol        # DAO voting & proposal execution
│
├── interfaces/
│   ├── ICapabilityBadge.sol
│   ├── ICCIPAdapter.sol
│   ├── IIdentityBadge.sol
│   ├── IRecovery.sol
│   ├── ITAGITAccess.sol
│   ├── ITAGITAccount.sol
│   ├── ITAGITAccountFactory.sol
│   ├── ITAGITBurner.sol
│   ├── ITAGITEmissions.sol
│   ├── ITAGITGovernor.sol
│   ├── ITAGITPaymaster.sol
│   ├── ITAGITPrograms.sol
│   ├── ITAGITStaking.sol
│   ├── ITAGITTreasury.sol
│   └── ITAGITVesting.sol
│
├── libraries/
│   ├── CircuitBreaker.sol       # Emergency pause mechanism
│   ├── Constants.sol            # System-wide constants
│   ├── DrainDetector.sol        # Anomaly detection for withdrawals
│   ├── RateLimiter.sol          # Rate limiting logic
│   └── ReplayProtection.sol     # Replay attack prevention
│
├── programs/
│   └── TAGITPrograms.sol        # Loyalty, rewards, staking programs
│
├── recovery/
│   └── TAGITRecovery.sol        # AIRP lost/stolen recovery protocol
│
├── token/
│   ├── TAGITBurner.sol          # Token burn mechanism
│   ├── TAGITEmissions.sol       # Token emission schedule
│   ├── TAGITStaking.sol         # Staking rewards
│   ├── TAGITToken.sol           # ERC-20 TAGIT token
│   └── TAGITVesting.sol         # Token vesting schedules
│
└── treasury/
    └── TAGITTreasury.sol        # Fee collection & distribution
```

## File List (Alphabetical)

| File | Path |
|------|------|
| CapabilityBadge.sol | src/access/ |
| CCIPAdapter.sol | src/bridge/ |
| CircuitBreaker.sol | src/libraries/ |
| Constants.sol | src/libraries/ |
| DrainDetector.sol | src/libraries/ |
| ICapabilityBadge.sol | src/interfaces/ |
| ICCIPAdapter.sol | src/interfaces/ |
| IdentityBadge.sol | src/access/ |
| IIdentityBadge.sol | src/interfaces/ |
| IRecovery.sol | src/interfaces/ |
| ITAGITAccess.sol | src/interfaces/ |
| ITAGITAccount.sol | src/interfaces/ |
| ITAGITAccountFactory.sol | src/interfaces/ |
| ITAGITBurner.sol | src/interfaces/ |
| ITAGITEmissions.sol | src/interfaces/ |
| ITAGITGovernor.sol | src/interfaces/ |
| ITAGITPaymaster.sol | src/interfaces/ |
| ITAGITPrograms.sol | src/interfaces/ |
| ITAGITStaking.sol | src/interfaces/ |
| ITAGITTreasury.sol | src/interfaces/ |
| ITAGITVesting.sol | src/interfaces/ |
| RateLimiter.sol | src/libraries/ |
| ReplayProtection.sol | src/libraries/ |
| TAGITAccess.sol | src/access/ |
| TAGITAccount.sol | src/account/ |
| TAGITAccountFactory.sol | src/account/ |
| TAGITBurner.sol | src/token/ |
| TAGITCore.sol | src/core/ |
| TAGITEmissions.sol | src/token/ |
| TAGITGovernor.sol | src/governance/ |
| TAGITPaymaster.sol | src/account/ |
| TAGITPrograms.sol | src/programs/ |
| TAGITRecovery.sol | src/recovery/ |
| TAGITStaking.sol | src/token/ |
| TAGITToken.sol | src/token/ |
| TAGITTreasury.sol | src/treasury/ |
| TAGITVesting.sol | src/token/ |
