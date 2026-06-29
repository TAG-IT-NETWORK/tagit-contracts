# On-Chain Key-Rotation Ceremony — Mainnet Cutover Runbook

> **Status:** DEFERRED to mainnet (founder decision 2026-06-29). On Base Sepolia testnet the
> single reused key (`0x458B…Cb3D` = deployer + `trustedOracle` + services relayer signer) is an
> **accepted risk** (faucet value only).
>
> **This runbook is live-verified against the CURRENT Base Sepolia deployment** (chainId 84532) — it
> is executable as-is on testnet if ever needed. **For mainnet:** the contract *addresses* and the
> *old key address* change, so re-derive them from the mainnet deploy. The **function calls,
> Timelock-gating, ordering, and gotchas below are identical** on any deployment.

---

## Authority map — everywhere the OLD key holds power

The reused key is far more privileged than "the oracle." Every row below was confirmed live via
read-only `cast call`.

| # | Authority | Contract | Gated by | Revoke via |
|---|---|---|---|---|
| 1 | `trustedOracle` | TAGITCore | **Timelock** | `setTrustedOracle(KEY_B)` (schedule/execute) |
| 2 | 7 capabilities (MINTER…RECYCLER) | CapabilityBadge | **Ownable (OLD key directly)** | `batchRevokeCapabilities(OLD, …)` |
| 3 | ADMIN identity badge (id 1) | IdentityBadge | **Ownable (OLD)** | `revokeIdentity(OLD, 1)` |
| 4–6 | **Owner** of CapabilityBadge, IdentityBadge, TAGITAccess | each | itself | `transferOwnership(KEY_A/Safe)` |
| 7–9 | Timelock `PROPOSER` / `EXECUTOR` / `CANCELLER` roles | TimelockController | **Timelock** (DEFAULT_ADMIN = Timelock itself) | `revokeRole` via schedule/execute |
| 10 | Owner/admin of **~20 other contracts** (Token, Staking, Governor, Treasury, Recovery, Programs, Paymaster, Emissions, Burner, Vesting, wTAG, AccountFactory, CCIPAdapter, RoboticAuthorizer, Agent*) | various | per-contract Ownable/AccessControl | **separate ceremony** — move to Timelock/Safe |

**Key correction vs. first assumption:** capability/badge/facade grants are **plain `Ownable` calls by the
OLD key**, NOT Timelock proposals. Only the Core (`setTrustedOracle`, `setAccessController`, UUPS
upgrade) and Timelock role changes go through the 60s Timelock.

`TAGITCore` itself is owned by the Timelock — so the OLD key's leverage over Core is *indirect*, via its
Timelock roles (#7–9). Revoking those removes its upgrade + oracle + access-controller power.

---

## Address book (Base Sepolia — re-derive for mainnet)

```bash
export RPC=https://sepolia.base.org
export OLD=0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D      # old shared key (to retire)
export CORE=0x3adC7eFdB58Ae85483Eff5D4966D916185f31d1d     # TAGITCore proxy
export TL=0xfdA2478dB73064eF770f4e5E5b97BC83801126e1       # TimelockController (owner of Core, 60s)
export CAPB=0xb05d22706B08A3F6409601de520cf7A6dbCB573d     # CapabilityBadge (grant/revoke HERE)
export IDB=0xebdAC9A0663c02a7297681b078aaD893EF345030      # IdentityBadge
export ACCESS=0xb56A1D91995C212342FaA843468F03521340A1D6   # TAGITAccess (read-only facade)
export Z=0x0000000000000000000000000000000000000000000000000000000000000000

# capability IDs = uint256(keccak256(NAME))
export C_MINTER=0xf0887ba65ee2024ea881d91b74c2450ef19e1557f03bed3ea9f16b037cbe2dc9
export C_BINDER=0xfb704bbb91710a3d3aa055227458d7964a0bf804c27b8e17cd0128dc8a05cfa4
export C_ACTIV=0xce1f15692823e8a9d77ca8c1b7a2cc145ffd008750ee9d3f8604f9c52eeea73c
export C_CLAIM=0xe5667d34d7ea8d6fdb3aa71a0a5b85e4cf7f68356dd003cd638556b0eea2bce5
export C_FLAG=0xa36818ac366968e07c7f93f4d790b0dddd8d47093b859e75c114eaceb14cd609
export C_RESOLV=0x17a55417373800620b4c2ceaa9f76c02df2e2dd329b9cb9a7cf849712c108f6f
export C_RECYC=0xed9a180fc7f150727f3614f70f00ff77e8e514eb7a73979e612e1539666ab910
# Timelock role IDs
export R_PROP=0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1
export R_EXEC=0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63
export R_CANC=0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783
```

---

## Ceremony (order matters: grant-new BEFORE revoke-old)

### A. Generate + fund the two keypairs
```bash
cast wallet new   # KEY_A = new deployer/admin  (store in Safe/HSM)
cast wallet new   # KEY_B = new oracle/signer = services relayer
cast send KEY_A_ADDR --value 0.05ether --private-key $KEY_OLD --rpc-url $RPC
cast send KEY_B_ADDR --value 0.05ether --private-key $KEY_OLD --rpc-url $RPC
```

### B. Grant KEY_B the relayer capabilities (direct Ownable call — OLD still owns CapabilityBadge)
```bash
cast send $CAPB "batchGrantCapabilities(address,uint256[])" KEY_B_ADDR \
  "[$C_MINTER,$C_BINDER,$C_ACTIV,$C_CLAIM,$C_FLAG,$C_RESOLV,$C_RECYC]" \
  --private-key $KEY_OLD --rpc-url $RPC
# minimal alternative: grantCapability KEY_B_ADDR $C_BINDER  and  $C_CLAIM
```

### C. setTrustedOracle(KEY_B) via Timelock (schedule → wait 60s → execute)
```bash
DATA=$(cast calldata "setTrustedOracle(address)" KEY_B_ADDR)
SALT=$(cast keccak "rotate-oracle-keyB")
cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $CORE 0 $DATA $Z $SALT 60 --private-key $KEY_OLD --rpc-url $RPC
sleep 65
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" \
  $CORE 0 $DATA $Z $SALT --private-key $KEY_OLD --rpc-url $RPC
cast call $CORE "trustedOracle()(address)" --rpc-url $RPC   # expect KEY_B_ADDR
```
**KEY_B is now operational as oracle + BINDER. Verify services (below) BEFORE touching the OLD key.**

### D. Move ADMIN authority to KEY_A (prefer a Gnosis Safe over a hot EOA)
```bash
# D1: Ownable handoff (single-step, immediate) — typos are irreversible, double-check KEY_A_ADDR
cast send $CAPB   "transferOwnership(address)" KEY_A_ADDR --private-key $KEY_OLD --rpc-url $RPC
cast send $IDB    "transferOwnership(address)" KEY_A_ADDR --private-key $KEY_OLD --rpc-url $RPC
cast send $ACCESS "transferOwnership(address)" KEY_A_ADDR --private-key $KEY_OLD --rpc-url $RPC

# D2: grant KEY_A the three Timelock roles — MUST go through the Timelock (no EOA holds DEFAULT_ADMIN)
GP=$(cast calldata "grantRole(bytes32,address)" $R_PROP KEY_A_ADDR)
GE=$(cast calldata "grantRole(bytes32,address)" $R_EXEC KEY_A_ADDR)
GC=$(cast calldata "grantRole(bytes32,address)" $R_CANC KEY_A_ADDR)
SALT_G=$(cast keccak "grant-keyA-roles")
cast send $TL "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)" \
  "[$TL,$TL,$TL]" "[0,0,0]" "[$GP,$GE,$GC]" $Z $SALT_G 60 --private-key $KEY_OLD --rpc-url $RPC
sleep 65
cast send $TL "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" \
  "[$TL,$TL,$TL]" "[0,0,0]" "[$GP,$GE,$GC]" $Z $SALT_G --private-key $KEY_OLD --rpc-url $RPC
# CONFIRM all three true before Step E:
cast call $TL "hasRole(bytes32,address)(bool)" $R_PROP KEY_A_ADDR --rpc-url $RPC
cast call $TL "hasRole(bytes32,address)(bool)" $R_EXEC KEY_A_ADDR --rpc-url $RPC
cast call $TL "hasRole(bytes32,address)(bool)" $R_CANC KEY_A_ADDR --rpc-url $RPC
```

### E. Revoke ALL old-key authority (only after new holders confirmed)
```bash
# E1: capabilities (KEY_A now owns CapabilityBadge)
cast send $CAPB "batchRevokeCapabilities(address,uint256[])" $OLD \
  "[$C_MINTER,$C_BINDER,$C_ACTIV,$C_CLAIM,$C_FLAG,$C_RESOLV,$C_RECYC]" \
  --private-key $KEY_A --rpc-url $RPC
# E2: ADMIN identity badge
cast send $IDB "revokeIdentity(address,uint256)" $OLD 1 --private-key $KEY_A --rpc-url $RPC
# E3: Timelock roles — via Timelock, now driven by KEY_A
RP=$(cast calldata "revokeRole(bytes32,address)" $R_PROP $OLD)
RE=$(cast calldata "revokeRole(bytes32,address)" $R_EXEC $OLD)
RC=$(cast calldata "revokeRole(bytes32,address)" $R_CANC $OLD)
SALT_R=$(cast keccak "revoke-old-roles")
cast send $TL "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)" \
  "[$TL,$TL,$TL]" "[0,0,0]" "[$RP,$RE,$RC]" $Z $SALT_R 60 --private-key $KEY_A --rpc-url $RPC
sleep 65
cast send $TL "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" \
  "[$TL,$TL,$TL]" "[0,0,0]" "[$RP,$RE,$RC]" $Z $SALT_R --private-key $KEY_A --rpc-url $RPC
```

### F. Verify (OLD = zero authority; KEY_B = oracle+BINDER; KEY_A = admin)
```bash
cast call $CORE   "trustedOracle()(address)" --rpc-url $RPC                              # KEY_B_ADDR
cast call $ACCESS "hasCapability(address,uint256)(bool)" $OLD $C_BINDER --rpc-url $RPC   # false
cast call $IDB    "hasIdentity(address,uint256)(bool)"   $OLD 1        --rpc-url $RPC     # false
cast call $TL "hasRole(bytes32,address)(bool)" $R_PROP $OLD --rpc-url $RPC               # false
cast call $TL "hasRole(bytes32,address)(bool)" $R_EXEC $OLD --rpc-url $RPC               # false
cast call $TL "hasRole(bytes32,address)(bool)" $R_CANC $OLD --rpc-url $RPC               # false
cast call $CAPB "owner()(address)" --rpc-url $RPC                                        # KEY_A_ADDR
cast call $ACCESS "hasCapability(address,uint256)(bool)" KEY_B_ADDR $C_BINDER --rpc-url $RPC  # true
```

---

## Gotchas (read before running)

1. **60s Timelock delay** on every scheduled op. `scheduleBatch` shares one 60s window for several calls.
2. **Capability/badge/facade authority is plain `Ownable` (OLD key), NOT Timelock-gated** — Step B is a direct `cast send`. Only Core + Timelock role changes use schedule/execute.
3. **Timelock `DEFAULT_ADMIN_ROLE` is the Timelock contract itself** (`admin=address(0)` at deploy). No EOA can `grantRole`/`revokeRole` directly — must go *through* the Timelock (Steps D2/E3).
4. **Grant-new-before-revoke-old; never strand the Timelock.** Confirm KEY_A holds proposer+executor (end of D2) before revoking OLD's roles (E3). Revoking the only `EXECUTOR_ROLE` holder bricks governance. Keep OLD funded with gas until Step D completes (it signs A–D).
5. **`transferOwnership` is single-step** (OZ `Ownable`, not `Ownable2Step`) — a typo is irrecoverable. Prefer a **Gnosis Safe** as the new owner/admin.
6. **The services key is both oracle AND sender.** `bindTag` requires the oracle signature to recover to `trustedOracle` AND `msg.sender` to hold `BINDER`. KEY_B must be both (Steps B+C). Splitting signer from sender later needs two keys/two grants.

## Services (`tagit-services`) cutover + readiness

- Set `ORACLE_PRIVATE_KEY=$KEY_B` and `SIGNER_PRIVATE_KEY=$KEY_B` (oracle falls back to signer).
- Check `GET /api/v1/bind/status` reports: `configured:true`, `hasBinderCapability:true`, `oracleMatchesTrusted:true`. If tap-to-buy is used, `GET /api/v1/sale/status` self-checks `CLAIMER` (covered by Step B).

## Out of scope — flag for a separate ceremony

The OLD key still owns/admins ~20 other contracts (Token, Staking, Governor, Treasury, Recovery,
Programs, Paymaster, Emissions, Burner, Vesting, wTAG, AccountFactory, CCIPAdapter, RoboticAuthorizer,
Agent*) — none transferred to the Timelock. Enumerate (`cast call <addr> "owner()(address)"`) and move
them to the Timelock or a Safe in a dedicated pass.

---
*Generated 2026-06-29 from a read-only, live-verified investigation of the deployed contracts.
Evidence: TAGITCore.sol:1267 (setTrustedOracle), CapabilityBadge.sol:69/100/133/177, IdentityBadge.sol:73/114,
DeployBaseSepoliaFull.s.sol:198-203/462-510, OZ TimelockController v5.0.0 ctor:115-132.*
