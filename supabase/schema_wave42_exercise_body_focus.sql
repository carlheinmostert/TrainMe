-- Wave 42 — per-exercise practitioner body-focus default.
--
-- Up to Wave 25, Body Focus (the segmented body-pop look on the colour
-- treatments) was a single per-device flag the practitioner toggled in
-- the mobile preview. The flag never reached publish — every published
-- plan rendered the web player's own per-device default, which in turn
-- was a global localStorage key. Wave 42 promotes Body Focus to a
-- per-exercise practitioner default that publishes through, mirroring
-- the `preferred_treatment` plumbing (Milestone O):
--
--   * `body_focus IS NULL` → no explicit choice, render with body-focus
--     ON (preserves the pre-feature default; every legacy row stays
--     unchanged on first open). The web player + mobile preview both
--     read NULL as "render default = true".
--   * `true`  → practitioner explicitly opted into body-focus on this
--               exercise.
--   * `false` → practitioner explicitly opted out (e.g. wide-frame demo
--               where dimming the background loses crucial context).
--
-- Per-exercise: moving to the next exercise in the deck doesn't carry
-- this forward — each exercise renders ITS OWN saved preference.
--
-- The web player lays a per-exercise CLIENT override on top of this
-- default in `homefit.overrides::{planId}` localStorage; that's a
-- client-side concept and lives entirely in the browser.

-- ---------------------------------------------------------------------------
-- 1. Column add — nullable BOOLEAN (no default; NULL = "render default
--    of true"). Idempotent so re-running on a DB that already has the
--    column is a no-op.
-- ---------------------------------------------------------------------------

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS body_focus BOOLEAN;

COMMENT ON COLUMN public.exercises.body_focus IS
  'Practitioner-sticky body-focus default for this specific exercise. '
  'NULL = render with body-focus ON (the pre-feature default). '
  'TRUE / FALSE = explicit practitioner choice. '
  'Mirrors the mobile SQLite exercises.body_focus column. '
  'Web player layers per-exercise client overrides on top via '
  'localStorage homefit.overrides::{planId}.';

-- ---------------------------------------------------------------------------
-- 2. RPC wiring — NOT duplicated in this file
--
--    `get_plan_full(uuid)` and `replace_plan_exercises(uuid, jsonb)`
--    evolve with the per-set DOSE stack (`schema_wave_per_set_dose.sql`,
--    `schema_wave_per_set_dose_rest_fix.sql`, …). Those migrations define
--    `replace_plan_exercises` as RETURNS jsonb (plan_version +
--    fallback_set_exercise_ids) with INSERT lists that already include
--    `body_focus` + `rest_seconds` + nested `sets`.
--
--    Do NOT paste a legacy RETURNS void body here — PostgreSQL rejects
--    CREATE OR REPLACE when it would change the return type (42P13).
--
--    `to_jsonb(e)` on each exercise row picks up `body_focus`
--    automatically once the column exists (§1 above).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. Smoke test (run manually after apply):
--
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND table_name = 'exercises'
--      AND column_name = 'body_focus';
--
--   SELECT position('body_focus' IN pg_get_functiondef(
--            'public.replace_plan_exercises(uuid,jsonb)'::regprocedure)) > 0;
--
--   -- Round-trip: pick any plan with at least one exercise, set
--   -- body_focus, fetch via get_plan_full, confirm:
--   UPDATE public.exercises
--      SET body_focus = false
--    WHERE id = '<some-exercise-id>';
--   SELECT jsonb_path_query(
--            public.get_plan_full('<plan-id>'::uuid),
--            '$.exercises[*] ? (@.id == "<some-exercise-id>") . body_focus'
--          );
-- ---------------------------------------------------------------------------
