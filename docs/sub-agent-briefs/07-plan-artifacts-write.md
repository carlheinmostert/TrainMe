# Brief — PR #7: plan_artifacts write on publish + get_plan_full extension

**Target branch:** `feat/plan-artifacts-write`
**Target merge:** `staging`
**Depends on:** PR #1 (schema — `plan_artifacts` table)
**Sensitive zone:** `get_plan_full` is the single anon-callable surface (per `docs/DATA_ACCESS_LAYER.md`)

## Context

`docs/SELF_TRAINER_WAVE.md` § "Publish flow changes" + § "Schema deltas" § 3. Every Publish writes one `plan_artifacts (plan_id, kind='plan_url', status='ready')` row in the same transaction as the existing `plan_issuances` audit row. `get_plan_full` returns an `artifacts` array so the web player + mobile player can list available artifacts (future-proofs Reel).

## Acceptance criteria

1. **Write into `consume_credit`** — inside the same transaction, after the audit row write:
   ```sql
   INSERT INTO plan_artifacts (plan_id, kind, status, generated_at)
   VALUES (p_plan_id, 'plan_url', 'ready', now())
   ON CONFLICT (plan_id, kind) DO UPDATE
     SET generated_at = now(), status = 'ready';
   ```
   The UPSERT handles republishes (same plan, same `plan_url` kind, just refresh `generated_at`).

2. **`get_plan_full` extension** — add `artifacts jsonb` to the returned shape. Build via:
   ```sql
   (SELECT jsonb_agg(jsonb_build_object(
       'kind', kind,
       'status', status,
       'output_url', output_url,
       'generated_at', generated_at,
       'metadata', metadata))
    FROM plan_artifacts WHERE plan_id = p.id) AS artifacts
   ```
   For `kind='plan_url'`, `output_url` is NULL (URL is computed). Callers (web player + mobile) compute the URL from `plan_id` when `kind='plan_url'` AND `output_url IS NULL`.

3. **CRITICAL — preserve existing RETURNS TABLE shape** per `feedback_schema_migration_column_preservation`. Run `\df+ public.get_plan_full` against live DB; carry forward every existing field. `get_plan_full` is the single anon surface so any regression in returned shape is sev1.

4. **Web player consumption** — `web-player/api.js` updates its `getPlanFull` parser to surface `artifacts` on the returned object. Mobile `app/lib/services/api_client.dart` `getPlanFull` likewise. Both surfaces add an optional `artifacts` field on the typed model. Today only `plan_url` is returned; future kinds will land here.

5. **R-10 PARITY required** — both `web-player/` and `app/lib/screens/plan_preview_screen.dart` (the mobile preview surface that shares the web player bundle) must handle the new `artifacts` field without breaking. v1: just parse + ignore; future PRs will use it.

6. **Test script** — `docs/test-scripts/2026-05-25-plan-artifacts-write.md`. Items: (a) publish a new plan → `plan_artifacts` row exists with `kind='plan_url'`, `status='ready'`; (b) republish same plan → row's `generated_at` updates, no duplicate row; (c) `get_plan_full(plan_id)` returns `artifacts` array with one entry; (d) web player loads plan with `artifacts` field present; (e) mobile preview loads plan without crashing; (f) RLS: anon can read `artifacts` only via `get_plan_full`, NOT via direct SELECT.

## Hard rules

- **Repo-relative paths only**.
- **Sensitive zone — `get_plan_full` is the anon surface; Carl reviews before merge.**
- **CREATE OR REPLACE FUNCTION preserves all columns** (per `feedback_schema_migration_column_preservation`).
- **R-10 parity required** — port to web AND mobile parsing.
- **No direct DB access** from any surface — anon goes through `get_plan_full`, authenticated through `ApiClient`.
- **No mobile deployment.**
- **No emojis.**
- **Branch**: `feat/plan-artifacts-write`.
