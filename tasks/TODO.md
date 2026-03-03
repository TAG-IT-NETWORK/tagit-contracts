# Current Task: HACK-T03 — Deploy TAGITPaymaster to Arbitrum Sepolia
Date: 2026-03-02
Status: COMPLETE

## Objective
Deploy TAGITPaymaster (ERC-4337 gasless paymaster) to Arbitrum Sepolia for the
Arbitrum Open House NYC Hackathon (March 6-8).

## Plan (Approved: Yes)
- [x] Step 1: Read codebase (CLAUDE.md, TAGITPaymaster.sol, DeployArbitrumSepolia.s.sol)
- [x] Step 2: Verify function selectors against actual TAGITCore contract
- [x] Step 3: Create deploy script `script/deploy/DeployPaymasterArbitrum.s.sol`
- [x] Step 4: Create fork test `test/deploy/DeployPaymasterArbitrum.t.sol`
- [x] Step 5: Update `exports/addresses.json` with arbitrum-sepolia stub
- [x] Step 6: `forge build` — compiles clean
- [x] Step 7: Fork test — 21/21 passing
- [x] Step 8: Dry-run — executes correctly
- [x] Step 9: Fund deployer with 0.5 ETH on Arbitrum Sepolia
- [x] Step 10: Broadcast `--broadcast --verify` — SUCCESS
- [x] Step 11: Update `exports/addresses.json` with actual addresses
- [x] Step 12: On-chain verification — all checks pass
- [x] Step 13: Git commit

## Deployed Addresses (Arbitrum Sepolia - Chain 421614)
| Contract | Address | Arbiscan |
|----------|---------|----------|
| TAGITPaymaster (impl) | `0x4c9aACfcb64169E3BC187c227c4C0e0a5CFDA1cF` | [Verified](https://sepolia.arbiscan.io/address/0x4c9aACfcb64169E3BC187c227c4C0e0a5CFDA1cF) |
| TAGITPaymaster (proxy) | `0xBbB9f7dB1C38Af7998b511d8026042755Eb4F4C4` | [Verified](https://sepolia.arbiscan.io/address/0xBbB9f7dB1C38Af7998b511d8026042755Eb4F4C4) |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Canonical |

## On-Chain Verification
- Governor: `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` (deployer)
- Owner: `0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` (deployer)
- EntryPoint: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (canonical v0.7)
- Paused: false
- Version: 1.0.0
- Protocol Deposit: 0.05 ETH
- EntryPoint Balance: 0.05 ETH
- Stake: 0.01 ETH (86400s unstake delay)
- bindTag (0xf1313d45): sponsored=true
- activate (0xb260c42a): sponsored=true
- claim (0xddd5e1b2): sponsored=true
- mint (0x2cfd3005): sponsored=true
- random (0xdeadbeef): sponsored=false

## Files Created/Modified
- [x] `script/deploy/DeployPaymasterArbitrum.s.sol` — NEW
- [x] `test/deploy/DeployPaymasterArbitrum.t.sol` — NEW (21 tests)
- [x] `exports/addresses.json` — MODIFIED (added arbitrum-sepolia)
- [x] `tasks/TODO.md` — MODIFIED

---

# Previous Task: SEC-AUD-001 — Full Audit Remediation
Date: 2026-02-27
Status: COMPLETE
