# Publish pipeline architecture (docs-canvas example)

> **Audience:** mobile/app engineers, backend engineers, QA, support  
> **Scope:** current Flutter publish path (`UploadService.uploadPlan`) and its Supabase interactions  
> **Last verified against code:** `app/lib/services/upload_service.dart` (branch `feature/t1-data-access-seams`)

---

## Overview

The publish pipeline is a staged, mostly-compensated workflow that turns a local session into a cloud plan URL:

- validates local/media/consent preconditions,
- charges credits atomically (`consume_credit`),
- writes the new plan version,
- uploads media,
- replaces exercise rows,
- best-effort uploads raw archive variants,
- records issuance audit.

It is **not a DB transaction across all steps**, so reliability comes from:

1. strict ordering,
2. compensating actions (`refund_credit`, orphan media cleanup),
3. explicit result taxonomy (`PublishResult.*`),
4. local persistence of failure/success state.

---

## Table of contents

1. [System boundaries](#system-boundaries)  
2. [End-to-end flow](#end-to-end-flow)  
3. [State transitions and outcomes](#state-transitions-and-outcomes)  
4. [Failure modes and recovery matrix](#failure-modes-and-recovery-matrix)  
5. [Data written at each stage](#data-written-at-each-stage)  
6. [Design notes and invariants](#design-notes-and-invariants)  
7. [Code and doc references](#code-and-doc-references)

---

## System boundaries

### Primary actor
- **Flutter app**: `UploadService.uploadPlan(Session)`

### Data access seam
- All Supabase I/O is routed through **`ApiClient`** (`docs/DATA_ACCESS_LAYER.md`).

### External dependencies
- Supabase RPCs: `practice_credit_balance`, `consume_credit`, `refund_credit`, `replace_plan_exercises`, consent validation, client upsert.
- Storage buckets:
  - `media` (public plan media),
  - `raw-archive` (private originals/segmented/masks/photos).

---

## End-to-end flow

```mermaid
flowchart TD
  A[Start publishPlan(session)] --> B[Resolve trainer + practice]
  B --> C{Client consent confirmed?}
  C -- No --> C1[PublishResult.needsConsentConfirmation]
  C -- Yes --> D[Validate treatment consent RPC]
  D -->|violations| D1[PublishResult.unconsentedTreatments]
  D -->|ok or transient RPC fail| E[Local file preflight]
  E -->|missing files| E1[PublishResult.preflightFailed]
  E --> F[Balance pre-check RPC]
  F -->|insufficient| F1[PublishResult.insufficientCredits]
  F --> G[Upsert/resolve client row]
  G -->|error| G1[PublishResult.networkFailed]
  G --> H[Ensure plan row exists at current version]
  H --> I[consume_credit RPC]
  I -->|ok:false| I1[PublishResult.insufficientCredits]
  I -->|P0003| I2[Map to unconsented + return]
  I -->|ok:true| J[Upsert plan with bumped version + sent_at]
  J --> K[Upload media bucket objects]
  K --> L[replace_plan_exercises RPC]
  L --> M[Best-effort raw-archive uploads]
  M --> N[Best-effort plan_issuances audit insert]
  N --> O[Persist local session success + return success]
  J --> X[Catch block]
  K --> X
  L --> X
  M --> X
  N --> X
  X --> X1[Best-effort orphan media cleanup]
  X1 --> X2{credit consumed?}
  X2 -- yes --> X3[Best-effort refund_credit]
  X2 -- no --> X4[Build PublishFailurePayload]
  X3 --> X4
  X4 --> X5[PublishResult.networkFailed]
```

---

## State transitions and outcomes

| Phase | Trigger | Result type | Credit effect | Remote mutation |
|---|---|---|---|---|
| Consent-confirmation gate | `client.consent_confirmed_at == null` | `needsConsentConfirmation` | none | none |
| Treatment gate | consent violations | `unconsentedTreatments` | none | none |
| File preflight | missing converted/raw local files | `preflightFailed` | none | none |
| Balance pre-check | balance < required | `insufficientCredits` | none | none |
| Atomic debit | `consume_credit` returns `ok:false` | `insufficientCredits` | none | may already have ensured minimal `plans` row |
| Main execution success | all required steps complete | `success` | debit (or prepaid unlock path) | plan version bump + media/exercises + optional artifacts |
| Post-debit failure | exception after debit | `networkFailed` | debit then refund attempted | partial possible; cleanup/refund best-effort |
| Pre-debit failure | exception before debit | `networkFailed` | none | minimal partial possible (e.g., client/plan ensure) |

---

## Failure modes and recovery matrix

| Step / surface | Typical failure | Practitioner-visible outcome | Automatic recovery behavior | Manual recovery guidance |
|---|---|---|---|---|
| Consent checks | RPC/network issues during validation | Publish may continue to next checks | Client preflight validation errors are swallowed; server `consume_credit` backstop still enforces via `P0003` | Retry publish; if blocked, update client consent and retry |
| Local preflight | Missing local file path/file deleted | Preflight failure with missing exercise names | No network mutations; safe retry | Re-capture/reconvert missing media |
| Client upsert | Name collision against soft-deleted client (`23505`) | `networkFailed` with user-facing guidance | No credit consumed yet | Restore from recycle bin or rename client |
| Credit consume | insufficient credits | `insufficientCredits` | No debit; publish aborts | Top up/switch practice then retry |
| Version bump or media upload | network/storage failure after debit | `networkFailed` | Best-effort media orphan cleanup + best-effort `refund_credit` | Retry; verify credit balance if uncertain |
| Exercise replace | RPC failure | `networkFailed` | Same catch path (cleanup/refund attempt) | Retry publish |
| Raw archive uploads | raw/segmented/photo/mask upload failure | **still success** | Per-exercise best-effort swallow/log; next publish can retry | No immediate action required |
| Issuance audit insert | insert failure | **still success** | Swallowed via `loudSwallow` | Investigate logs if audit mismatch reported |

---

## Data written at each stage

| Ordered step | Data written | Why ordering matters |
|---|---|---|
| Resolve client (`upsertClientWithId`/`upsertClient`) | `clients` row/ID linkage | Required so plan has `client_id` for treatment-consent and signed URL behavior |
| Ensure plan row (current version) | `plans` upsert (non-bumped version) | Satisfies FK for `credit_ledger.plan_id` before debit |
| Consume credit | `credit_ledger` via RPC | Atomic race-safe charge source-of-truth |
| Bump plan + sent timestamp | `plans.version`, `plans.sent_at` | Only after successful debit to avoid unearned version bump |
| Upload media | `media` bucket objects | Requires plan/practice context for storage policy checks |
| Replace exercises | `exercises` (and set payload server handling) | Atomic replace pattern for plan exercise payload |
| Raw archive pass | `raw-archive` objects | Non-blocking add-on for treatment/archive surfaces |
| Audit append | `plan_issuances` row | Billing/support history; explicitly best-effort |

---

## Design notes and invariants

- **Data-access seam rule:** no direct Supabase calls from upload service; use `ApiClient`.
- **Debit-before-bump invariant:** credit consumption occurs before definitive version bump to avoid false version progression on debit failure.
- **Compensation policy:** if failure happens after debit, attempt `refund_credit`; never let refund failure mask original publish error.
- **Best-effort layers:** raw-archive and issuance audit do not fail publish.
- **Result taxonomy is load-bearing:** caller UI behavior is keyed off `PublishResult` variant, not raw exception parsing.

---

## Code and doc references

### Core implementation
- `app/lib/services/upload_service.dart`
- `app/lib/services/api_client.dart`

### Supporting documentation
- `docs/T2_PUBLISH_RELIABILITY.md`
- `docs/DATA_ACCESS_LAYER.md`

### Related backend migration/documentation anchors
- `supabase/schema_milestone_v_publish_consent_validation.sql` (consent guard + `P0003` backstop)
- `supabase/` migration set defining credit and exercise replace RPC behavior

---

## Assumptions captured in this canvas

1. This document describes the **Flutter publish pipeline only** (not portal/player read flows).  
2. “Accurate to current code” is interpreted from current branch source, especially inline comments that define intended behavior.  
3. Raw-archive variants are intentionally non-blocking and may be partially present after a successful publish.

