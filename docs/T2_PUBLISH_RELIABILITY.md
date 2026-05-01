# T2 — Publish reliability classification

**Purpose:** Map every [`PublishResult`](../app/lib/services/upload_service.dart) variant to gates in [`UploadService.uploadPlan`](../app/lib/services/upload_service.dart), ledger behaviour, remote mutations, and Studio UX so publish side effects are not ambiguous for practitioners or maintainers. Aligns with the sprint goal: remove silent ambiguity in publish side effects.

**Canonical ordering** in [`UploadService.uploadPlan`](../app/lib/services/upload_service.dart) comments: numbered pipeline **1–8** after early exits. **0 / 0a** below are pre-pipeline gates in the same method.

| Class / outcome | When it happens (gate / phase) | Credits / ledger | Remote side effects | Local / Studio UX | Practitioner recovery |
|-----------------|--------------------------------|------------------|---------------------|-------------------|----------------------|
| **`PublishResult.success`** | Steps **3–8** complete (ensure client row → ensure plan → `consume_credit` → bump plan → media → `replace_plan_exercises` → raw-archive **best-effort** → `plan_issuances` **best-effort**). | **`creditsCharged`** reflects the computed publish cost (normal debit **or** prepaid-unlock republish where `consume_credit` does not debit again — **still success**). **No refund**. | Plan row **version bump** + `sent_at`; **`media`** (and thumbs) uploaded or metadata-only URL reuse; **`replace_plan_exercises`** replaces exercise payloads server-side; raw-archive / segmented / photo / mask uploads **silent partial possible**; **`plan_issuances`** may skip without failing publish. | Published ✓ snackbar; if `fallbackSetExerciseIds` is non-empty, extra coral snackbar ([`studio_mode_screen.dart`](../app/lib/screens/studio_mode_screen.dart)); if optional raw-archive artifacts failed, a non-blocking follow-up warning snackbar appears; `_publishError` cleared on publish start; successful session persisted locally. | N/A. |
| **`PublishResult.preflightFailed`** | **Step 1** — local paths missing on disk for a non-rest exercise. | **Untouched**. | **None.** | `_publishError`; missing-media snackbar + scroll to first broken card. | Restore media; **retry safe**. |
| **`PublishResult.insufficientCredits`** | **Step 2** balance read shows shortfall **or** **step 3b** `consume_credit` returns `{ok: false}`. | **Untouched** (no debit). | **Step 3a** may have ensured a minimal plan row (no version bump) so FK holds — still prior client-visible version until a successful publish. | Error snackbar via `toErrorString`; Retry. | Top up / switch practice; **retry safe**. |
| **`PublishResult.unconsentedTreatments`** | **Step 0** — treatment consent RPC lists violations **before** debit; **or** catch maps **`consume_credit`** **`PostgrestException` `P0003`** (server backstop; debit line not reached). | **Untouched** — ledger not debited on these paths. | **None.** | Bottom sheet: grant consent & publish vs back to Studio ([`_handleUnconsentedTreatments`](../app/lib/screens/studio_mode_screen.dart)). | Grant consent / adjust treatments; **retry**. |
| **`PublishResult.needsConsentConfirmation`** | **Step 0a** — cached client `consent_confirmed_at == null`. | **Untouched**. | **None.** | [`showClientConsentSheet`](../app/lib/screens/studio_mode_screen.dart); on save republish. | Confirm consent; **retry**. |
| **`PublishResult.networkFailed`** | **Step 3a** client upsert throws (e.g. **23505** name collision → `PublishFailureMessage`); **or** any exception after entering the `try` for steps **3–8** (wrapped `StateError` with practice/trainer context); **or** unexpected throw before `uploadPlan` returns (wrapped as `networkFailed` from Studio). | **Before `creditConsumed`:** untouched. **After debit:** **`refund_credit` best-effort** (failure swallowed → possible temporary ledger drift per [`upload_service.dart`](../app/lib/services/upload_service.dart) comments). | **Partial OK:** **plan row may already show bumped `version`** (`step 4`) while exercises/media incomplete — catch does **not** revert plan/exercises. **`uploadedPaths`** cleaned via **`removeMedia`** best-effort. **`replace_plan_exercises`** not reached → prior exercise rows may still match **prior** version depending on failure timing. | `_publishError`; red snackbar `Publish failed: …`, tap-to-copy, **Retry**. | Often **retry safe**; name collision requires recycle-bin restore / rename; if charged-but-failed, verify refund in portal when unsure. |

### Success with non-empty `fallbackSetExerciseIds`

[`replace_plan_exercises`](../app/lib/services/upload_service.dart) applied a synthetic single-set default for exercises whose incoming `sets` was missing or empty. Outcome remains **`PublishResult.success`** with normal **`creditsCharged`**. Studio shows Published ✓ plus a **second** coral snackbar prompting the practitioner to set reps and weight ([`_publishFromToolbar`](../app/lib/screens/studio_mode_screen.dart)).

### Follow-up hardening (post-T2 closeout)

- **`networkFailed`** — after the `PublishFailurePayload` pass, the snackbar shows a **short practitioner line**; tap-to-copy carries **PostgREST code / socket / inner text** plus a **refund attempted** note when the publish path debited credits. Generic unknown errors still fall back to a generic retry/support line.
- **Failure after step 4, before durable exercise replace:** remote **`plans.version`** may advance while the app surfaces **`networkFailed`** and local SQLite still holds the old **`session.version`** until the next successful publish — **no remote downgrade** in catch.
- **`refund_credit` RPC failure:** swallowed; ledger may need manual reconciliation.
- **Step 0 consent RPC failure:** logged and skipped; server **`consume_credit`** guard (**P0003**) remains backstop.
- **Raw-archive, segmented, photo raw, mask, issuance:** failures do **not** flip `PublishResult`; practitioner sees success while optional cloud artefacts may be missing until a later republish. Studio now surfaces a low-noise warning when optional raw-archive artifact uploads failed.

These are intentionally tracked as follow-up reliability hardening items (see
`docs/BACKLOG.md`) rather than blockers for this T2 sprint closeout.

### Verification

- `cd app && flutter analyze`
- `cd app && flutter test`
- Manual flows:
  - **Preflight:** missing local converted/raw file → missing-media snackbar, no credit loss.
  - **Insufficient credits:** balance below required → error snackbar; retry after top-up.
  - **Success + fallback sets:** exercise with empty `sets` in payload → success + coral fallback snackbar.
  - **Network failure:** toggle connectivity mid-publish → error snackbar + Retry; when debit had occurred, confirm balance / ledger reflects refund after recovery.
