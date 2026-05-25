# Test script — publish cost preview + consume_credit conditional free path

**PR:** #6 of the self-trainer wave (`feat/publish-cost-preview` → `staging`)
**Spec:** `docs/SELF_TRAINER_WAVE.md` § Publish flow changes
**Brief:** `docs/sub-agent-briefs/06-publish-cost-preview.md`

## What this PR ships

1. Migration `supabase/migrations/20260525140921_publish_cost_preview.sql`
   - New `public.preview_publish_cost(p_session_id uuid) -> integer` RPC. SECURITY DEFINER + membership-checked. Returns 0 / 1 / 2. Side-effect free.
   - New `public.is_self_trainer_all_verified(p_plan_id, p_caller)` SECURITY DEFINER helper — true only when the plan's client.user_id = caller AND every non-rest cloud exercise has self_verified = true AND at least one exercise exists.
   - `consume_credit` extension: when the self-verified predicate fires, write a `delta=0, type='publish_free'` ledger row instead of debiting. SEC-2 consent backstop + Wave 29 prepaid-unlock + Wave 40.5 trainer_id stamp + PR #7 plan_artifacts upsert preserved verbatim. Defensive `p_credits IN (1, 2)` validation on the paid path.
2. `app/lib/services/api_client.dart`: new `Future<int> previewPublishCost(String sessionId)` method.
3. `app/lib/services/upload_service.dart`: publish flow calls `previewPublishCost` first and passes the returned int as `p_credits`. RPC failure falls back to the mobile-computed `creditCostForDuration`.
4. `app/lib/screens/studio_mode_screen.dart`: `_publishCostPreview` state + `_refreshPublishCost` ticker. Refreshes on initState, after every `_pushSession` (exercise count / verified flag changes), and after a successful publish.
5. `app/lib/widgets/studio_bottom_bar.dart`: PUBLISH cell renders a small `FREE / 1 CR / 2 CR` caption below the PUBLISH label when the preview is available. Sage when free, secondary on-dark otherwise.

## Test items

Run on staging (`https://staging.manage.homefit.studio`) with the agent QA test account (`qa@homefit.studio`).

- [ ] **1. Self-trainer publish, all exercises verified → workflow pill shows FREE; ledger gets `type='publish_free'` row with `delta=0`.** Sign in as the practitioner. Capture a fresh plan where the linked client IS the practitioner's Self-client (per PR #4). Run conversion + ensure every exercise stamps `self_verified = true` (per PR #5). Open Studio for the plan. The PUBLISH cell shows the "FREE" sage caption. Tap PUBLISH. After success: `SELECT type, delta, plan_id, trainer_id FROM credit_ledger WHERE plan_id = '<plan-id>' ORDER BY created_at DESC LIMIT 1;` returns one row with `type='publish_free'`, `delta=0`, the practitioner's trainer_id.

- [ ] **2. Self-trainer publish with one unverified exercise → cell shows "1 CR"; ledger gets `type='consumption'` row with `delta=-1`.** Same Self-client. Capture two exercises, but bypass face verification on one (manually set `exercises.self_verified = false` via SQL after first publish, OR record without a face in frame). Studio PUBLISH cell shows "1 CR" (not FREE). Tap PUBLISH; the practice's credit balance decrements by 1. Latest credit_ledger row: `type='consumption'`, `delta=-1`.

- [ ] **3. Practitioner publishing for a separate client → cell shows "1 CR" (or "2 CR" for a long plan).** Switch to a non-Self client (regular practice client). Capture a short plan. Studio PUBLISH cell shows "1 CR". After publish: ledger row is `type='consumption'`, `delta=-1`. (R-10 regression check — the legacy paid path still works untouched.)

- [ ] **4. Long self-session > 75 min with all verified → cell shows FREE (duration bypass when self-verified).** Self-client plan with enough reps/sets that estimated duration > 75 min (e.g. 5 exercises × 4 sets × 12 reps × longer hold). All `self_verified = true`. PUBLISH cell shows FREE (NOT "2 CR"). Publish succeeds with `delta=0, type='publish_free'`. Confirms the self-verified path short-circuits the duration tier check.

- [ ] **5. Cost label refreshes after deleting an exercise.** Open a Self-client plan where two exercises are verified and one isn't (cell reads "1 CR"). Swipe-delete the unverified one. The cell label flips to FREE within ~1s (the post-pushSession refresh). Re-add an exercise via Capture; once it lands with `self_verified=false`, the label flips back to "1 CR".

- [ ] **6. Tap Publish then Undo via SnackBar → refund row appears in ledger.** Publish a paid plan (any non-self-trainer case). When the publish-success SnackBar surfaces, the existing refund flow (if applicable for whatever undo affordance currently exists) writes a compensating row. `SELECT type, delta FROM credit_ledger WHERE plan_id='<plan-id>' ORDER BY created_at;` shows `consumption` followed by `refund` (the existing refund pattern is unchanged).

- [ ] **7. Mismatched p_credits passed to `consume_credit` (manually via SQL) → RAISE 22023.** In the Supabase SQL editor, simulate a misbehaving client:
  ```sql
  SELECT public.consume_credit(
    '<practice-id>'::uuid,
    '<paid-plan-id>'::uuid,
    3  -- invalid: only 1 or 2 allowed on paid path
  );
  ```
  Expect: error with code `22023` and the message `consume_credit: p_credits must be 1 or 2 (got 3) — duration tier mismatch`. Confirms the defensive validation fires on the paid path.

- [ ] **8. `preview_publish_cost` is side-effect-free.** In the SQL editor, call `SELECT public.preview_publish_cost('<plan-id>'::uuid);` ten times in a row. The credit_ledger has ZERO new rows for that plan after the calls. The plan_artifacts table is unchanged.

- [ ] **9. RLS: caller outside the practice → 42501.** As the qa@ user, call `SELECT public.preview_publish_cost('<plan-id-from-another-practice>'::uuid);`. Expect error code `42501` ("caller X is not a member of practice Y").

- [ ] **10. Unknown plan id → returns 1.** `SELECT public.preview_publish_cost(gen_random_uuid());` returns `1` (default for fresh client-generated plan ID, as documented in the migration).

## Pre-merge checks (Mac-side)

- [ ] `grep -rn '<<<<<<<\|>>>>>>>' supabase/migrations/ app/lib/` returns zero matches.
- [ ] `dart_analyze` clean on `app/lib/services/api_client.dart` + `app/lib/services/upload_service.dart` + `app/lib/screens/studio_mode_screen.dart` + `app/lib/widgets/studio_bottom_bar.dart`.
- [ ] CI Supabase Branching: per-PR DB preview applies the migration without error; both `preview_publish_cost` + `consume_credit` callable; existing `consume_credit` round-trip preserved (PR #5 self-verified plumbing tests still pass).
