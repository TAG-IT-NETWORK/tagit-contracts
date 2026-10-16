# DPP Metadata Gap Analysis — current model vs. the EU DPP data model

> **Status:** Draft · **Version:** 0.1.0 · **Date:** 2026-10-15 · **Owner:** TAG IT Network
> Companion to [`dpp-requirements-to-tests.md`](./dpp-requirements-to-tests.md) and
> [`DPP-001`](../../../tagit-hardware/specs/digital-product-passport/README.md).

## 0. Caveats (same as the mapping)

Not legal advice. The EU DPP data model is still being standardised (CEN/CENELEC JTC 24; JRC
methodology; per-category delegated acts). Field names/obligations below are an engineering reading of
ESPR Annex III + the CIRPASS cross-sectoral model and **must be verified** against the final texts and
the delegated act for whatever product category TAG IT targets. Absence of a field here is a
*modelling* gap, not necessarily a legal deficiency today.

## 1. Verdict

TAG IT already implements the DPP **structure** (identifier, carrier, resolver, integrity anchor,
provenance, machine-readable VC) at a maturity most projects never reach. The gaps are almost entirely
in **data-content breadth** (compliance/substances/circularity fields) and in four **cross-cutting
Phase-2 items** already named in DPP-001 §7. None of the gaps are in the smart contracts — they are in
`tagit-services` (schema) and `apps/verify` (the VC serializer).

## 2. The data shapes that exist today

| # | Shape | Where | Role |
|---|---|---|---|
| 1 | **`tagit-meta/1`** canonical doc (richest) | `tagit-services/src/metadata/schema.ts` | the hashed, anchored metadata (`tokenURI` target) |
| 2 | Public asset DTO | `tagit-services/src/api/assets.ts` | consumer/verify view (subset + live chain state) |
| 3 | **DPP Verifiable Credential** | `tagit-dashboard/apps/verify/src/lib/dpp.ts` | the "passport" (W3C VCDM 2.0, UNTP-shaped) |
| 4 | Catalog DB records | `tagit-services/src/catalog/schema.ts` | `product_templates`, `catalog_items`, append-only `item_metadata_versions` |

**Key current fields.** `tagit-meta/1.tagit`: `schemaVersion, chainId(84532), contract, tokenId,
tagHash, version, templateId, templateVersion, brand, model, sku, gtin, serial, category,
countryOfOrigin, manufactureDate, media[], ext?(cosmetics|apparel|watches|electronics), previousHash`.
DPP VC `credentialSubject`: `id, registeredId(GTIN), serialNumber, name, brand, description, image,
sku, countryOfOrigin, lifecycleState, owner, registeredAt, digitalTwin{…}, authenticity{…}` + `evidence[0]`
= on-chain anchor. **The VC is a thinner subset than `tagit-meta/1`** (no category/model/manufactureDate/
`ext`/media hashes) and is **unsigned** in v1.

## 3. Field-level gap table

Status: `Have` · `Partial` (present but thin/free-text) · `Gap` (not modelled). "DPP element" is the
canonical ESPR/CIRPASS data group.

### Identification & carrier
| DPP element | Current field | Status | Note / recommendation |
|---|---|---|---|
| Unique product identifier | `tokenId` + `gtin` + `serial` | Have | item-level serial = unique instance |
| Data carrier | GS1 Digital Link `/01/{GTIN}/21/{serial}` (`apps/verify/src/lib/gs1.ts`) | Have | — |
| Registered/authority identifier | `registeredId` (GTIN) | Partial | GTIN not validated against a real GS1 company prefix (DPP-001 §7) |
| Chain/twin pointer | `digitalTwin{chain,contract,tokenId,tagUid}` | Have | `chainId` hardcoded to Base Sepolia (testnet) — must be configurable before an EU launch |

### Product / commercial
| DPP element | Current field | Status | Note |
|---|---|---|---|
| Product name / model / category | `name, model, category` | Have | — |
| Brand | `brand` | Have | — |
| Description | `description` | Have | — |
| Images / media | `media[]{role,sha256,mime,url,ipfs}` | Have | hashed; but see persistence gap below |
| Technical attributes | category `ext` (apparel/watches/electronics/cosmetics) | Partial | small fixed set; not aligned to a delegated-act attribute list |

### Origin & manufacturing
| DPP element | Current field | Status | Note |
|---|---|---|---|
| Country of origin | `countryOfOrigin` | Have | — |
| Manufacture date / batch | `manufactureDate`, `batchId` (DB) | Have | — |
| Place of manufacture (facility) | — | Gap | add if a target category requires it |

### Economic operator (ESPR Annex III)
| DPP element | Current field | Status | Note |
|---|---|---|---|
| Manufacturer legal identity | `brand` (string only) | Gap | no operator legal name / ID |
| EU responsible person / importer | — | Gap | required for EU placement; add typed field |
| Operator address / EORI / registration | — | Gap | — |

### Compliance & conformity
| DPP element | Current field | Status | Note |
|---|---|---|---|
| Declaration of conformity / CE | — (PDF via media possible) | Gap | add typed `conformity[]` (doc hash + type + authority) |
| Certificates / test reports | media PDFs | Partial | no typed certificate schema |
| Applicable standards / regulations | — | Gap | — |

### Substances & materials
| DPP element | Current field | Status | Note |
|---|---|---|---|
| Substances of concern (REACH/SCIP) | — | Gap | add if category in scope |
| Materials composition | `apparel.material` (free text) | Partial | not structured |
| Hazardous-substance flags | — | Gap | — |

### Circularity (repair / spare parts / recycling)
| DPP element | Current field | Status | Note |
|---|---|---|---|
| Repairability / repair instructions | — | Gap | — |
| Spare-parts availability | — | Gap | — |
| Recycling / disassembly instructions | — | Gap | on-chain `recycle` state exists; no consumer-facing instructions |
| Environmental footprint (carbon, etc.) | — | Gap | — |
| Warranty | — | Gap | — |

### Lifecycle, provenance & integrity
| DPP element | Current field | Status | Note |
|---|---|---|---|
| Lifecycle state | `lifecycleState` (on-chain 7-state) | Have | tested: **DPP-C-04/06** |
| Provenance / chain of custody | indexer `StateTransition`/`CustodyChange` + on-chain `CustodyTransfer` | Have | EPCIS-style API is Phase-2 |
| Integrity anchor | `metadataHash` (keccak256) | Have | tested: **DPP-C-05** |
| Signed credential (issuer proof) | `did:web:id.tagit.network` declared; VC **unsigned** | Gap | DPP-001 §7 — Ed25519 / SD-JWT |

### Access & persistence
| DPP element | Current field | Status | Note |
|---|---|---|---|
| Public (unrestricted) fields | `tokenURI` / `/api/dpp` open | Have | tested: **DPP-C-03** |
| Differentiated access (consumer/repairer/recycler/authority) | binary public/restricted (`visibility.ts`) | Gap | SD-JWT → BIDGES tiers (Phase-2) |
| Survive-the-issuer persistence | single Postgres; `ipfsCid` columns unused | Gap | pinning not wired (DPP-001 §7) |
| Versioned/reconstructable data | append-only `item_metadata_versions` (`previousHash` chain) + `backfill-metadata.ts` | Partial | reconstruct limited; no independent backup provider |

### Data protection (GDPR)
| DPP element | Current field | Status | Note |
|---|---|---|---|
| No PII on-chain | hash + wallet addr only | Have | tested: **DPP-C-08** |
| PII blocked from the passport doc | `FORBIDDEN_PII_KEYS` + `scanForbiddenKeys` (`metadata/schema.ts`) | Have | candidate off-chain test below |
| Pseudonymised owner in public views | truncated wallet address | Have | — |

## 4. Cross-cutting gaps (the Phase-2 shortlist, from DPP-001 §7)

1. **Unsigned VC** → add issuer-DID signing (Ed25519) + SD-JWT. Highest credibility lever.
2. **No differentiated access** → role-scoped disclosure mapped to BIDGES tiers.
3. **No durable persistence** → wire the `metadataHash` compute→pin→anchor flow (IPFS/Arweave/US store) + an independent backup, to meet "survive the issuer".
4. **GTIN not GS1-validated** → real company prefix (GS1 membership) + check-digit/prefix validation.
5. **DPP VC thinner than `tagit-meta/1`** → serialise the full canonical fields into `credentialSubject`.
6. **Content-breadth gaps** → economic-operator, conformity, substances, and circularity fields (scope to the target category's delegated act).
7. **Testnet `chainId` hardcoded** → make `chainId`/contract configurable before any EU launch.

## 5. Recommendations (prioritised)

- **P0 (cheap, high-trust):** sign the VC (gap 1); serialise full `tagit-meta/1` into the VC (gap 5);
  add the off-chain conformance tests in §6. These are days, not weeks, and materially raise credibility.
- **P1 (category-dependent):** add the economic-operator + conformity typed fields (gaps 6) once the
  target category is chosen; add GS1 membership/validation (gap 4).
- **P2 (infra):** persistence/pinning + independent backup (gap 3); differentiated access (gap 2).
- **Governance:** keep `chainId`/addresses configurable (gap 7); get the obligations reviewed by counsel.

## 6. Candidate off-chain conformance tests (mirror the on-chain suite)

These belong in `tagit-services` / `apps/verify` test suites, tagged `compliance`:

- **GS1 Digital Link format** (`apps/verify/src/lib/gs1.ts`): `/01/{GTIN-14}/21/{serial}` parses;
  GTIN mod-10 check digit enforced; malformed carriers rejected.
- **Schema completeness** (`metadata/schema.ts`): a passport missing a required DPP field fails
  validation; `scanForbiddenKeys` rejects `email/phone/address/ownerName` anywhere in the tree.
- **Anchor parity**: `keccak256(JCS(canonicalDoc))` equals the on-chain `metadataHash` (off-chain ↔ on-chain integrity).
- **Resolver access**: public fields served openly; restricted items return the redacted body; (when
  built) role tiers disclose the correct field subset per BIDGES tier.
- **VC conformance** (`dpp.ts`): credential is typed `["VerifiableCredential","DigitalProductPassport"]`;
  (when built) signature verifies against the issuer DID; `credentialSubject` carries the full field set.
- **Persistence** (when built): a published passport is retrievable after the primary DB is unavailable
  (pin/backup path).

*Not legal advice; verify all regulatory references against primary sources.*
