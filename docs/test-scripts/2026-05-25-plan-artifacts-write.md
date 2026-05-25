# Test script — plan_artifacts write on publish + get_plan_full extension

**PR:** #7 of the self-trainer wave (`feat/plan-artifacts-write` → `staging`)
**Spec:** `docs/SELF_TRAINER_WAVE.md` § Publish flow changes
**ADR:** `docs/adr/0022-plan-artifacts-abstraction-before-reel.md`
**Brief:** `docs/sub-agent-briefs/07-plan-artifacts-write.md`

## What this PR ships

1. Migration `supabase/migrations/20260525094931_plan_artifacts_on_publish.sql`
   - `consume_credit` RPC: upserts one `plan_artifacts(plan_id, kind='plan_url', status='ready')` row inside the same transaction as the existing credit debit (and on the prepaid-unlock fast path). All existing branches + return shapes preserved.
   - `get_plan_full` RPC: adds top-level `artifacts` array to the returned `jsonb`. All existing fields preserved.
2. `web-player/api.js` (`getPlanFull` + `getPlanFullLocal`): surface `payload.artifacts` on the returned object, defaulting to `[]`.
3. `web-player/app.js` (`fetchPlan`): stamp `artifacts` onto the flattened plan object so future consumers can read `plan.artifacts`.
4. `app/lib/services/api_client.dart`: `getPlanFull` docstring documents the new field; `artifactsFromPlanResponse()` helper + `PlanArtifact` model class.
5. `app/lib/services/unified_preview_scheme_bridge.dart`: emit empty `artifacts: []` on the embedded preview payload so the web-player bundle sees shape parity with the cloud RPC.
6. `web-player/sw.js`: dated entry in the historical trail (per `feedback_always_bump_sw_on_player_change`).

## Test items

Run on staging (`https://staging.session.homefit.studio` + `https://staging.manage.homefit.studio`) with the agent QA test account (`qa@homefit.studio`) and a freshly captured plan.

- [ ] **a. Publish writes a `plan_artifacts` row.** Publish a brand-new plan. In the Supabase staging SQL editor: `SELECT plan_id, kind, status, generated_at FROM plan_artifacts WHERE plan_id = '<published-plan-id>';` returns exactly one row with `kind='plan_url'`, `status='ready'`, `generated_at` within the last minute.
- [ ] **b. Republish refreshes `generated_at`, no duplicate row.** Make a non-structural edit (e.g. change rep count) and publish again. Re-run the query from (a). Still exactly one row, but `generated_at` updated to the more recent timestamp. Verify with: `SELECT count(*) FROM plan_artifacts WHERE plan_id = '<plan-id>' AND kind = 'plan_url';` returns `1`.
- [ ] **c. `get_plan_full` returns the artifacts array.** In the SQL editor: `SELECT public.get_plan_full('<plan-id>') -> 'artifacts';` returns a JSON array with one entry whose `kind` is `'plan_url'` and `output_url` is `null` (URL is computed client-side for plan_url).
- [ ] **d. Web player handles the extended response without crashing.** Open the plan URL (`https://staging.session.homefit.studio/p/<plan-id>`) in a fresh browser tab. Lobby renders normally, treatment row works, all exercises load. No console errors mentioning `artifacts`. In DevTools console: `JSON.parse(JSON.stringify(plan)).artifacts` returns the array of one entry. (`plan` is the lobby's local; confirm via `Array.isArray((window.__lastPayload || {}).artifacts)` if `plan` isn't in scope — both true.)
- [ ] **e. Mobile preview handles the extended response without crashing.** In the iOS simulator (no install required, just the in-app preview), open a session and tap Preview. The embedded web-player loads, the deck renders, treatment switching works. The embedded bridge emits `artifacts: []` (no rows exist for a pre-publish session); the bundle's parser treats empty as "none known" without throwing.
- [ ] **f. RLS: anon cannot SELECT `plan_artifacts` directly.** From a browser console on the staging player (anon JWT), run `await fetch('https://vadjvkmldtoeyspyoqbx.supabase.co/rest/v1/plan_artifacts?select=*', { headers: { apikey: <anon-key>, Authorization: 'Bearer ' + <anon-key> } }).then(r => r.json())`. Expect either an empty array or an RLS denial — NOT the row from (a). Then call `get_plan_full` against the same plan id and confirm the `artifacts` entry IS returned (proving anon access works only through the RPC).

## Pre-merge checks (Mac-side)

- [ ] `grep -rn '<<<<<<<\|>>>>>>>' supabase/migrations/ web-player/ app/lib/` returns zero matches.
- [ ] `dart_analyze` clean on `app/lib/services/api_client.dart` + `app/lib/services/unified_preview_scheme_bridge.dart`.
- [ ] CI Supabase Branching: per-PR DB preview applies the migration without error; both extended RPCs callable.
