# script/ops — live-chain operational scripts (Base Sepolia 84532)

| Script | Purpose |
| --- | --- |
| `check-capabilities.sh` | READ-ONLY capability audit of an address against TAGITAccess |
| `timelock-set-uris.sh` | schedule+execute setBaseURI / setRedactedURI via the Timelock |
| `key-ceremony-1-generate.sh` | T01 step 1 — generate KEY_A/KEY_B into the macOS Keychain |
| `key-ceremony-2-grant.sh` | T01 step 2 — grant capabilities to KEY_B; opt-in oracle flip |
| `key-ceremony-3-strip-old.sh` | T01 step 3 — revoke the old shared hot key's capabilities |

## Key ceremony runbook (T01 / SECRETS.md step 0)

Goal: split the single shared hot key
`0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D` (simultaneously contracts
deployer, services `SIGNER_PRIVATE_KEY`, `TAGITCore.trustedOracle`,
MINTER/BINDER/RECYCLER/CLAIMER/ACTIVATOR/FLAGGER/RESOLVER capability holder,
Timelock PROPOSER/EXECUTOR/CANCELLER, CapabilityBadge + TAGITAccess owner,
and `SALE_TREASURY`) into:

- **KEY_A** — contracts deployer (Keychain `tagit-ceremony-key-a` / `deployer`)
- **KEY_B** — services oracle/signer (Keychain `tagit-ceremony-key-b` / `services-signer`)

`A != B`, and neither ever appears in stdout, logs, or files — key material
lives only in the macOS Keychain and (transiently) environment variables.

### Ordered procedure

1. **Generate** — `./key-ceremony-1-generate.sh`
   Prints only the two addresses. Refuses to overwrite existing Keychain
   items unless `FORCE=1`. Fund BOTH addresses with Base Sepolia ETH.

2. **Grant capabilities to KEY_B (harmless — changes no live behavior)**
   ```sh
   export CEREMONY_SENDER_KEYCHAIN_SERVICE=<item holding the OLD key>   # or CEREMONY_SENDER_PK
   ./key-ceremony-2-grant.sh <KEY_B> <KEY_A>
   ```
   Sender must be the CapabilityBadge owner (today: the old key). Grants
   MINTER/BINDER/RECYCLER (+CLAIMER, which the old key holds). Idempotent.
   The oracle is NOT flipped in this step — binding keeps working on the old
   services key.

3. **Rotate the services secrets to KEY_B — BEFORE any oracle flip**
   The moment `trustedOracle` flips, bind signatures from the old
   `SIGNER_PRIVATE_KEY` stop verifying. So rotate first:
   - **Vercel / services env**: set `SIGNER_PRIVATE_KEY` = KEY_B's private
     key (read it from the Keychain only at paste time:
     `security find-generic-password -s tagit-ceremony-key-b -a services-signer -w`).
     Mark it Sensitive. Redeploy.
   - **API_KEY rotation (audit item 0.1)**:
     - generate: `openssl rand -hex 32`
     - update the accepted-keys config and **remove the leaked
       `tagit-hack-2026-key`** from the accepted set
     - probe until the old key is dead:
       `curl -s -o /dev/null -w '%{http_code}' -H 'x-api-key: tagit-hack-2026-key' https://api.tagit.network/...`
       must return **401** (repeat after each deploy until it does).
   - **AWS Secrets Manager `tagit/services/prod` — merge, do NOT replace**:
     `put-secret-value` REPLACES the entire JSON blob. Read-modify-write:
     ```sh
     aws secretsmanager get-secret-value --secret-id tagit/services/prod \
         --query SecretString --output text > /tmp/sm.json   # contains secrets — shred after
     # edit /tmp/sm.json: update SIGNER_PRIVATE_KEY, API_KEY, SALE_TREASURY — keep every other key
     aws secretsmanager put-secret-value --secret-id tagit/services/prod \
         --secret-string file:///tmp/sm.json
     rm -P /tmp/sm.json
     ```
     (Or use `tagit-services/scripts/secrets/sm-push.sh` per SECRETS.md §1,
     which pushes a complete env file.)
   - Verify `/api/bind/status` still reports `isBindReady` (old oracle still
     active, new signer not yet trusted — bind stays up through step 4's flip
     only if this rotation happened; that is the point of the ordering).

4. **Flip the oracle (Timelock schedule → 65 s wait → execute)**
   ```sh
   ./key-ceremony-2-grant.sh <KEY_B> --flip-oracle
   ```
   `setTrustedOracle(address)` is `onlyOwner` and TAGITCore's owner is the
   TimelockController (minDelay 60 s), so the script schedules and executes
   through the Timelock. Sender needs PROPOSER+EXECUTOR (the old key holds
   both). Re-verify `/api/bind/status` → `isBindReady`, and do a real bind.

5. **Strip the old key**
   ```sh
   ./key-ceremony-3-strip-old.sh 0x458B4d0c3a55006965Fd13D6af7B8509De51Cb3D <KEY_B> --confirm-strip
   ```
   Pre-flight refuses unless KEY_B holds MINTER/BINDER/RECYCLER,
   `trustedOracle() == KEY_B`, and `--confirm-strip` is passed. Revokes every
   capability the old key holds **that KEY_B also holds**; uncovered ones
   (ACTIVATOR/FLAGGER/RESOLVER unless granted elsewhere) are skipped loudly
   (`STRIP_UNCOVERED=1` overrides).

6. **Manual tail (printed by step 5, not automated)**
   - Timelock PROPOSER/EXECUTOR/CANCELLER → KEY_A. The Timelock is its own
     DEFAULT_ADMIN, so each `grantRole`/`revokeRole` must be scheduled
     through the Timelock's own queue (self-call, 60 s delay). Grant + verify
     KEY_A **before** revoking the old key or the Timelock — and with it
     TAGITCore's owner functions — is bricked forever.
   - `CapabilityBadge.transferOwnership` and `TAGITAccess.transferOwnership`
     away from the old key (both live-verified as old-key-owned).
   - `SALE_TREASURY` env (tagit-services `src/sale/sale-relayer.ts`) → new
     treasury address, in Vercel and Secrets Manager (step 3's merge rule).
   - Drain the old key's ETH; delete it from every secret store.

### Verified on-chain facts these scripts rely on (2026-08-14)

| Fact | Value |
| --- | --- |
| `CapabilityBadge` (live) | `0xb05d22706B08A3F6409601de520cf7A6dbCB573d` |
| `CapabilityBadge.owner()` | the old key `0x458B…Cb3D` |
| grant / revoke | `grantCapability(address,uint256)` / `revokeCapability(address,uint256)`, both `onlyOwner` (src/access/CapabilityBadge.sol:69,100) |
| Capability ids | `uint256(keccak256("MINTER"))` etc. (src/core/TAGITCore.sol:71-79) |
| Oracle setter | `setTrustedOracle(address)` `onlyOwner` (src/core/TAGITCore.sol:1544) |
| `TAGITCore.owner()` | Timelock `0xfdA2478dB73064eF770f4e5E5b97BC83801126e1`, minDelay 60 s |
| Old key Timelock roles | PROPOSER + EXECUTOR + CANCELLER (not admin; Timelock self-admins) |
| Old key capabilities | MINTER BINDER RECYCLER CLAIMER ACTIVATOR FLAGGER RESOLVER (not VIEWER/AUDITOR) |
