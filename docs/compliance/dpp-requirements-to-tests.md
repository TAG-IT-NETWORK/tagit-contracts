# DPP Requirements → Conformance Tests

> **Status:** Draft · **Version:** 0.1.0 · **Date:** 2026-10-15 · **Owner:** TAG IT Network
> **Scope:** maps EU Digital Product Passport (DPP) requirements to concrete, testable TAG IT
> controls and the tests that verify them. Companion to [`dpp-metadata-gap-analysis.md`](./dpp-metadata-gap-analysis.md)
> and the carrier/data standard [`tagit-hardware/specs/digital-product-passport/README.md`](../../../tagit-hardware/specs/digital-product-passport/README.md) (DPP-001).

---

## 0. Read this first — what this document is and is not

- **Conformance ≠ legal compliance.** These tests prove that specific, *machine-checkable* DPP
  requirements hold in our code. They do **not** make TAG IT legally compliant with the ESPR or any
  delegated act, and nothing here is legal advice. The binding obligations, the product categories
  in scope, and the dates all need review by counsel against the primary texts.
- **Label accordingly.** When citing this work to a partner/auditor, say "conforms to the DPP data
  model / GS1 Digital Link structure", never "DPP-compliant".
- **Dates and standard numbers move.** The ESPR framework (Reg (EU) 2024/1781) is in force, but the
  per-product **delegated acts**, the harmonised EN standards (e.g. the identifier/data-carrier EN
  numbers), and the Registry implementing regulation are still being finalised. Every date / number
  below marked *(verify)* must be checked against EUR-Lex and the Commission's ESPR pages before it is
  relied on. Batteries are the first concrete regime (~18 Feb 2027, Reg (EU) 2023/1542) *(verify)*;
  iron/steel, textiles, furniture etc. follow via delegated acts with ≥18-month transitions *(verify)*.
- **Design target, not an obligation today.** Unless TAG IT targets the EU market in a
  delegated-act category, DPP is "design toward it", and this suite is the ratchet that keeps us
  aligned as the rules land. The market/category/timeline decision is a business call (Artem's),
  not an engineering one.

---

## 1. Why TAG IT already fits the DPP shape

TAG IT is, structurally, a DPP system already — this is not a greenfield. The pieces the ESPR asks
for exist today:

| DPP primitive | TAG IT realisation | Where |
|---|---|---|
| Unique persistent identifier | ERC-721 `tokenId` (sequential, never reused) + GTIN-14 + item serial | `TAGITCore`, DPP-001 §3 |
| Data carrier on the item | NTAG 424 DNA chip carrying a GS1 Digital Link URL `/01/{GTIN}/21/{serial}` | DPP-001 §2–3 |
| Resolvable passport pointer | `tokenURI = baseURI + tokenId`; `verify.tagit.network/api/dpp/...` W3C VC | `TAGITCore.tokenURI`, `apps/verify` |
| Integrity anchor | `metadataHash[tokenId]` = keccak256 of canonical passport JSON | `TAGITCore` |
| Lifecycle + provenance | 7-state machine + `CustodyTransfer` audit chain (`prevStateHash`) | `TAGITCore` |
| Tamper-evidence of the physical item | NTAG 424 DNA SUN (SDM) clone/replay resistance | DPP-001 §3–4 |
| Machine-readable passport | W3C VCDM 2.0 JSON-LD, typed `DigitalProductPassport` (UNTP shape) | `apps/verify/src/lib/dpp.ts` |

The gaps are known and already roadmapped in DPP-001 §7 (signed VC, role-scoped disclosure, durable
off-chain pinning, on-chain GTIN↔tokenId map). See the gap analysis for the field-level view.

---

## 2. Legend

**Status** — `Have` (implemented + tested here) · `Partial` (implemented, thinner than DPP asks) ·
`Gap` (not built) · `Phase-2` (explicitly roadmapped in DPP-001 §7).

**Layer** — where the control lives: `chain` (contracts, tested in `test/compliance/`) ·
`svc` (tagit-services) · `verify` (tagit-dashboard/apps/verify) · `nfc` (chip/bridge/mobile) ·
`idx` (tagit-indexer) · `ops` (process/legal).

**Test** — `DPP-C-nn` = an on-chain conformance test in this repo (see §4). `off-chain` = belongs to
another repo's suite (candidate tests noted in the gap analysis). `n/a` = process control, not a test.

---

## 3. Requirement → control → test

### A. Identification & data carrier  — ESPR Art. 8 (carrier/identifier), Annex III
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| A1 | Each item carries a **unique identifier**, unique per instance | `tokenId` sequential from 1, never reused; `totalSupply` tracks | chain | Have | **DPP-C-01** |
| A2 | Identifier bound 1:1 to the **physical data carrier** | `bindTag` maps NFC tag hash ↔ `tokenId` bijectively (`getTokenByTag`/`getTagByToken`); re-use reverts `TagAlreadyBound` | chain | Have | **DPP-C-02** |
| A3 | Carrier is a standards identifier (ISO/IEC 15459; GS1 Digital Link) | GS1 Digital Link `/01/{GTIN-14}/21/{serial}`, GTIN mod-10 | nfc/verify | Partial | off-chain (`apps/verify/src/lib/gs1.ts`) |
| A4 | Carrier type permitted (QR / NFC / RFID) | NTAG 424 DNA (NFC) + GS1 URL that QR-resolves | nfc | Have | off-chain |
| A5 | Real GS1 GTIN / company prefix (GS1 membership) | v1 accepts any well-formed GTIN | ops/svc | Gap (Phase-2) | off-chain |

### B. Passport data content — ESPR Arts. 9–10, Annex III; per-category delegated act *(verify)*
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| B1 | Passport carries required product data (identity, origin, compliance) | `tagit-meta/1` canonical schema (brand/model/sku/gtin/serial/category/countryOfOrigin/manufactureDate/media…) | svc | Partial | off-chain (`tagit-services/src/metadata/schema.ts`) |
| B2 | Passport resolves from the carrier/identifier | `tokenURI → baseURI + tokenId`; `/api/v1/meta/:tokenId`; `/api/dpp/...` | chain/svc/verify | Have | **DPP-C-03** + off-chain |
| B3 | Economic-operator details (manufacturer, EU responsible person) | not an explicit schema field | svc | Gap | off-chain |
| B4 | Substances of concern | not modelled | svc | Gap | off-chain |
| B5 | Repair / spare-parts / recycling info (circularity data) | not modelled | svc | Gap | off-chain |
| B6 | Conformity docs / declarations / certificates | media pipeline can carry PDFs; no typed cert fields | svc | Partial | off-chain |
| B7 | Machine-readable passport (interoperable format) | W3C VCDM 2.0 JSON-LD, UNTP `DigitalProductPassport` | verify | Have | off-chain (`apps/verify/src/lib/dpp.ts`) |

### C. Provenance, lifecycle & traceability — ESPR traceability; NIST AU-9 / CMMC chain-of-custody
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| C1 | Full lifecycle is **recorded and retrievable** | 7-state machine; `StateChanged` + `CustodyTransfer` per transition | chain | Have | **DPP-C-04** |
| C2 | Audit trail is **immutable & hash-linked** | `CustodyTransfer.prevStateHash = keccak256(id, fromState, fromOwner, block-1)` | chain | Have | **DPP-C-04** |
| C3 | End-of-life / retirement captured | `recycle → RECYCLED` (terminal) | chain | Have | **DPP-C-06** |
| C4 | Provenance queryable off-chain (EPCIS-style) | indexer `StateTransition` / `CustodyChange` entities | idx | Partial (Phase-2 API) | off-chain |

### D. Integrity & tamper-evidence — ESPR data integrity
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| D1 | Passport content is **tamper-evident** | `metadataHash[tokenId]` = keccak256(canonical JSON); any byte change breaks the anchor | chain | Have | **DPP-C-05** |
| D2 | Only authorised parties can change the anchor | `updateMetadataHash` = token owner **or** `MINTER_CAPABILITY`; else `Unauthorized` | chain | Have | **DPP-C-05** |
| D3 | Physical item is clone/replay-resistant | NTAG 424 DNA SUN (SDM), constant-time CMAC verify | nfc | Have | off-chain (`apps/verify/src/lib/sdm.ts`) |
| D4 | Passport is a **self-verifying signed credential** | VC is **unsigned** in v1 (`X-DPP-Proof: unsigned-anchor-only`) | verify | Gap (Phase-2) | off-chain |

### E. Access rights & differentiated disclosure — ESPR Art. 11; Arts. 13–14 (Registry/portal)
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| E1 | Public, unrestricted fields are openly accessible | `tokenURI` uniform/public; `/api/dpp/...` CORS-open | chain/verify | Have | **DPP-C-03** + off-chain |
| E2 | **Differentiated access** by role (consumer / repairer / recycler / authority) | binary public/restricted redaction only; SD-JWT role tiers → BIDGES unbuilt | svc/verify | Gap (Phase-2) | off-chain |
| E3 | Registry holds identifier + pointer (no central data store) | n/a (EU-operated); TAG IT would register identifiers | ops | Gap | n/a |

### F. Data persistence & continuity ("survive the issuer") — ESPR Art. 10(4)
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| F1 | Passport data **survives issuer insolvency** (backup to independent provider) | canonical JSON in a single Postgres; on-chain holds only hash + provenance | svc | Gap (Phase-2) | off-chain |
| F2 | Durable content pinning (IPFS/Arweave/US store) | `ipfsCid` columns exist but **pinning is not wired** into publish | svc | Gap (Phase-2) | off-chain |
| F3 | Data reconstructable / versioned | append-only `item_metadata_versions` (hash-linked `previousHash`); `backfill-metadata.ts` | svc | Partial | off-chain |

### G. Data protection — GDPR (Reg (EU) 2016/679)
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| G1 | **Data minimisation** — no personal data on-chain | `TAGITCore` stores only `{owner addr, timestamp, state, flags}` + a `bytes32` hash; no strings/PII | chain | Have | **DPP-C-08** |
| G2 | Identity anchored as a **hash**, never plaintext | `TAGITAccount._emailHash` is `bytes32` keccak256; schema `scanForbiddenKeys` blocks email/phone/address/ownerName | chain/svc | Have | **DPP-C-08** + off-chain |
| G3 | Erasure (Art. 17) compatible with immutability | personal data off-chain & erasable; chain holds only non-reversible hashes | chain/svc | Partial | DPP-C-08 (on-chain half) |
| G4 | Owner identity pseudonymous in public views | wallet address truncated in public DTOs | svc | Have | off-chain |

### H. Economic-operator accountability / write authorisation — ESPR operator duties
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| H1 | Only authorised operators can create/alter the passport | capability gates: MINTER/BINDER/ACTIVATOR/CLAIMER/FLAGGER/RESOLVER/RECYCLER (`MissingCapability` on failure) | chain | Have | **DPP-C-07** |
| H2 | Privileged config under governance | owner = TimelockController; `onlyOwner` on `setBaseURI`/upgrade | chain | Have | off-chain (governance suite) |

### I. Product-token classification (avoid "financial instrument") — MiCA/securities posture
| # | Requirement | TAG IT control | Layer | Status | Test |
|---|---|---|---|---|---|
| I1 | Token is **bound to the physical good**, not freely tradable | transfers soulbound: `transferFrom`/`safeTransferFrom` revert `TransferDisabled`; ownership moves only via `claim`/`transferAsset` | chain | Have | **DPP-C-09** |
| I2 | Legal classification review | — | ops | Gap | n/a (counsel) |

---

## 4. On-chain conformance tests (this repo)

Implemented in `test/compliance/`, run with `forge test --match-path "test/compliance/*" -vvv`
on the **default** profile (do **not** use `FOUNDRY_PROFILE=deploy` — its via-ir CSE-caches
`block.timestamp` across `vm.warp`). See [`test/compliance/README.md`](../../test/compliance/README.md).

| ID | Invariant | Maps to | Test file |
|---|---|---|---|
| **DPP-C-01** | Unique, non-reused product identifier (sequential `tokenId`, `totalSupply`) | A1 | `DPPIdentityCarrier.t.sol` |
| **DPP-C-02** | Carrier↔twin 1:1 binding; a tag can't bind two twins | A2 | `DPPIdentityCarrier.t.sol` |
| **DPP-C-03** | Passport pointer (`tokenURI`) resolves uniformly to every caller (#47 regression) | B2, E1 | `DPPIdentityCarrier.t.sol` |
| **DPP-C-04** | Every lifecycle transition emits an immutable, hash-linked custody record | C1, C2 | `DPPProvenanceIntegrity.t.sol` |
| **DPP-C-05** | Metadata hash anchor is tamper-evident & write-restricted | D1, D2 | `DPPProvenanceIntegrity.t.sol` |
| **DPP-C-06** | End-of-life `recycle` is terminal (no resurrection) | C3 | `DPPProvenanceIntegrity.t.sol` |
| **DPP-C-07** | Passport writes are gated to authorised capabilities | H1 | `DPPAccessDataProtection.t.sol` |
| **DPP-C-08** | No personal data on-chain; only a bare owner address + a `bytes32` hash | G1, G2, G3 | `DPPAccessDataProtection.t.sol` |
| **DPP-C-09** | Product token is soulbound to the good; only lifecycle paths move it | I1 | `DPPAccessDataProtection.t.sol` |

---

## 5. Out of scope for this suite (do not mistake green for done)

- **Legal determination** of which obligations/categories/dates apply (counsel).
- **Per-category delegated-act data fields** (B3–B6) — off-chain schema work; see gap analysis.
- **Signed VC** (D4) and **role-scoped disclosure** (E2) — DPP-001 Phase-2.
- **Durable persistence / IPFS pinning** (F1–F2) — DPP-001 Phase-2.
- **Off-chain conformance** (GS1 URL format, schema completeness, resolver access tiers) — belongs to
  `tagit-services` / `apps/verify` suites; candidate tests listed in the gap analysis.

---

## 6. References

- ESPR — Regulation (EU) 2024/1781 (Ecodesign for Sustainable Products). *(verify current consolidated text on EUR-Lex)*
- EU Battery Regulation — Regulation (EU) 2023/1542 (battery passport, ~18 Feb 2027). *(verify)*
- GDPR — Regulation (EU) 2016/679.
- GS1 Digital Link URI Syntax; ISO/IEC 15459 (unique identifiers). Harmonised EN identifier/data-carrier standards are being developed under CEN/CENELEC JTC 24. *(verify EN numbers)*
- W3C Verifiable Credentials Data Model 2.0; UN Transparency Protocol (UNECE Rec. 49).
- TAG IT: DPP-001 (`tagit-hardware/specs/digital-product-passport/README.md`); `KNOWN-ISSUES.md`.

*All regulatory citations are engineering working references, not legal advice; verify against primary sources.*
