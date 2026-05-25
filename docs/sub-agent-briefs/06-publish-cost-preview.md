# Brief — PR #6: Publish flow cost preview + consume_credit conditional logic

**Target branch:** `feat/publish-cost-preview`
**Target merge:** `staging`
**Depends on:** PR #1 (schema — `clients.user_id`, `exercises.self_verified`), PR #5 (verification stamping)
**Sensitive zone:** `consume_credit` RPC (per `feedback_sensitive_code_review_before_merge`)

## Context

`docs/SELF_TRAINER_WAVE.md` § "Publish flow changes". `consume_credit` gains conditional cost computation: if session's client is the publishing user AND every exercise is `self_verified`, cost = 0. Otherwise existing duration-based pricing (1 or 2 credits).

## Acceptance criteria

1. **`preview_publish_cost` RPC** (new SECURITY DEFINER) — input: `p_session_id uuid`. Output: integer cost (0, 1, or 2). Pseudocode in design doc. Migration: `YYYYMMDDHHMMSS_preview_publish_cost_rpc.sql`. Idempotent + side-effect-free (no debits, no audit).

2. **`consume_credit` extension** — same conditional logic. If `cost = 0`: still write the `plan_issuances` row but skip the credit ledger debit (or write `kind='publish_free'` with `amount=0` for audit symmetry — recommend the latter). If `cost > 0`: existing behaviour.

3. **CRITICAL — preserve existing RETURNS TABLE shape** per `feedback_schema_migration_column_preservation`. Run `\df+ public.consume_credit` against the live DB before writing the migration; carry forward EVERY existing column. Bug-prone.

4. **API client extension** — `app/lib/services/api_client.dart` gains `previewPublishCost(String sessionId) -> int`. Routes to the new RPC.

5. **Studio workflow pill** — in `app/lib/screens/studio_mode_screen.dart` (or wherever the workflow pill lives — `studio_toolbar.dart` probably), call `previewPublishCost` when entering the Publish step. Render label based on result:
   - `cost == 0`: `"Publish · Free"` (coral chip subdued, no warning glyph)
   - `cost == 1`: `"Publish · 1 credit"` (standard)
   - `cost == 2`: `"Publish · 2 credits"` (standard)
   Refresh the preview on Studio focus + after any exercise add/delete (cost depends on count).

6. **No confirmation modal** (per R-01). Tap fires `consume_credit` directly. Refund via SnackBar Undo if user changes mind (existing pattern in `upload_service.dart`).

7. **Post-publish toast** unchanged — `"Published ✓"` dismissible toast.

8. **Test script** — `docs/test-scripts/2026-05-25-publish-cost-preview.md`. Items: (a) self-trainer publish (all verified): preview shows "Free", ledger gets `publish_free` row with `amount=0`; (b) self-trainer publish with one unverified exercise: preview shows "1 credit", debits 1; (c) practitioner publishing for client: preview shows "1 credit" (or "2" if long); (d) long self-session (>75 min, all verified): preview shows "Free" (the duration cost is bypassed when self-verified); (e) preview refreshes after deleting an exercise that changes the cost; (f) tap publish, undo via SnackBar: refund row appears in ledger.

## Hard rules

- **Repo-relative paths only**.
- **Sensitive zone — `consume_credit` RPC change requires Carl review per `feedback_sensitive_code_review_before_merge`.**
- **CREATE OR REPLACE FUNCTION must preserve every existing column** (`feedback_schema_migration_column_preservation`).
- **No direct DB access from Dart**.
- **R-10 N/A** for the cost preview (mobile-only UX); however the underlying `consume_credit` RPC is called by both web-portal (manage.homefit.studio) and mobile — verify no caller breaks.
- **No mobile deployment.**
- **No exception-driven control flow** (`feedback_no_exception_control_flow`) — RPC returns success/failure cleanly; mobile code branches on result.
- **No emojis.**
- **Branch**: `feat/publish-cost-preview`.
