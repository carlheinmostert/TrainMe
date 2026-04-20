-- Milestone P — per-exercise prep-countdown override.
--
-- The plan-preview (Flutter) and client web player (web-player/) both show
-- a "prep" countdown before each non-rest exercise begins. The default
-- shrinks from 15s → 5s in Wave 3; practitioners can override per exercise
-- via the Studio card's "Prep seconds" inline field.
--
-- Semantics:
--
--   * prep_seconds IS NULL → use the global default (5s). Every legacy row
--     migrates to NULL, which means the previous 15s baseline quietly
--     becomes the new 5s baseline. Acceptable per the Wave 3 test plan
--     (item 10).
--   * prep_seconds > 0 → practitioner's explicit override for this exercise.
--   * prep_seconds <= 0 is rejected at the UI layer (clearing the field
--     writes NULL via copyWith(clearPrepSeconds: true)); the CHECK below
--     is a belt-and-braces guard.
--
-- Scope:
--
-- This column mirrors the mobile SQLite `exercises.prep_seconds` (schema
-- v19, see app/lib/services/local_storage_service.dart). The two columns
-- share a simple integer value so publish + sync round-trip without
-- translation. The web player reads it via `get_plan_full` — no change to
-- the RPC needed because `to_jsonb(e)` already emits every column on the
-- exercises row (see schema_milestone_g_three_treatment.sql §6).
--
-- Consent gating is NOT relevant here — prep is silent runway before the
-- video plays; no media-dependency.

-- ---------------------------------------------------------------------------
-- 1. Column add — nullable INTEGER with a CHECK constraint so junk values
--    can't land via a malformed publish.
-- ---------------------------------------------------------------------------

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS prep_seconds INTEGER
    CHECK (prep_seconds IS NULL OR prep_seconds > 0);

COMMENT ON COLUMN public.exercises.prep_seconds IS
  'Practitioner-sticky prep-countdown override for this exercise, in seconds. '
  'NULL = use the global default (5s). '
  'Positive integer = explicit override. '
  'Written by the Flutter Studio card (Prep seconds inline field); '
  'mirrors the mobile SQLite exercises.prep_seconds column. '
  'Web player reads it via get_plan_full (emitted by to_jsonb(e)).';

-- ---------------------------------------------------------------------------
-- 2. RLS — no new policy needed. The existing exercises-table RLS scopes
--    reads + writes by practice membership via the plan's practice_id.
--    prep_seconds inherits those policies transparently.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. get_plan_full — no change. The function uses `to_jsonb(e)` which
--    emits every column on the exercises row, so prep_seconds surfaces
--    automatically on the anonymous player payload.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 4. Smoke test (run manually after apply):
--
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'exercises'
--      AND column_name = 'prep_seconds';
--
--   -- Expect 1 row: prep_seconds | integer | YES
--
--   -- Check constraint is in place:
--   SELECT conname, pg_get_constraintdef(oid) AS def
--     FROM pg_constraint
--    WHERE conrelid = 'public.exercises'::regclass
--      AND conname LIKE '%prep_seconds%';
--
--   -- Confirm get_plan_full surfaces the new field on a recent plan:
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid)
--            -> 'exercises' -> 0 -> 'prep_seconds');
-- ---------------------------------------------------------------------------
