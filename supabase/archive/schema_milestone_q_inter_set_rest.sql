-- Milestone Q — per-exercise inter-set rest ("Post Rep Breather").
--
-- The mobile Studio card + web player both grow a new per-exercise
-- control: a breather between sets, configured by the practitioner and
-- played back to the client. Carl's mental model: "Post Rep Breather"
-- sits alongside the existing reps / sets / hold editors; the web
-- player pauses the video + shows a sage countdown chip over the last
-- visible frame at each set boundary, then resumes from that same
-- frame into the next set (continuous playback, no reset).
--
-- Semantics:
--
--   * inter_set_rest_seconds IS NULL → no breather (legacy rows + any
--     pre-migration captures). The player treats this as 0 for duration
--     math but still hides the segmented progress bar when sets <= 1.
--   * inter_set_rest_seconds = 0 → practitioner explicitly disabled the
--     breather (distinct from NULL only in intent — behaviour is the
--     same). We store the 0 to record the deliberate choice.
--   * inter_set_rest_seconds > 0 → breather seconds. Mobile seeds fresh
--     captures at 15 via ExerciseCapture.withPersistenceDefaults() —
--     NOT backfilled on existing rows, which stay NULL.
--
-- Scope:
--
-- This column mirrors the mobile SQLite `exercises.inter_set_rest_seconds`
-- (schema v24, see app/lib/services/local_storage_service.dart). The
-- two columns share a simple integer value so publish + sync round-trip
-- without translation. The web player reads it via `get_plan_full` —
-- no change to the RPC needed because `to_jsonb(e)` already emits every
-- column on the exercises row (same pattern as schema_milestone_p_prep_seconds.sql).
--
-- Duration math (mobile + web):
--
--   exercise_total = sets × per_set
--                  + max(0, sets - 1) × COALESCE(inter_set_rest_seconds, 0)
--
-- Feeds the progress-matrix pill width AND the wall-clock ETA on the
-- workout-timeline-bar. Legacy rows (NULL) compute without any inter-
-- set rest — a deliberate behaviour change on re-publish; acceptable
-- per the brief.
--
-- Consent gating is NOT relevant here — the breather is silent pacing;
-- no media-dependency.

-- ---------------------------------------------------------------------------
-- 1. Column add — nullable INTEGER with a CHECK constraint so negative
--    values can't land via a malformed publish. Zero IS allowed (it's
--    the explicit-disable value).
-- ---------------------------------------------------------------------------

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS inter_set_rest_seconds INTEGER
    CHECK (inter_set_rest_seconds IS NULL OR inter_set_rest_seconds >= 0);

COMMENT ON COLUMN public.exercises.inter_set_rest_seconds IS
  'Practitioner-configured inter-set rest ("Post Rep Breather") for this '
  'exercise, in seconds. '
  'NULL = no breather (legacy rows, pre-migration). '
  '0 = practitioner explicitly disabled. '
  'Positive integer = breather seconds, played between sets on the web '
  'player. Fresh mobile captures seed to 15 via '
  'ExerciseCapture.withPersistenceDefaults(); no server-side default. '
  'Mirrors the mobile SQLite exercises.inter_set_rest_seconds column. '
  'Web player reads it via get_plan_full (emitted by to_jsonb(e)).';

-- ---------------------------------------------------------------------------
-- 2. RLS — no new policy needed. The existing exercises-table RLS scopes
--    reads + writes by practice membership via the plan's practice_id.
--    inter_set_rest_seconds inherits those policies transparently.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. get_plan_full — no change. The function uses `to_jsonb(e)` which
--    emits every column on the exercises row, so inter_set_rest_seconds
--    surfaces automatically on the anonymous player payload.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 4. Smoke test (run manually after apply):
--
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'exercises'
--      AND column_name = 'inter_set_rest_seconds';
--
--   -- Expect 1 row: inter_set_rest_seconds | integer | YES
--
--   -- Check constraint is in place:
--   SELECT conname, pg_get_constraintdef(oid) AS def
--     FROM pg_constraint
--    WHERE conrelid = 'public.exercises'::regclass
--      AND conname LIKE '%inter_set_rest%';
--
--   -- Confirm get_plan_full surfaces the new field on a recent plan:
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid)
--            -> 'exercises' -> 0 -> 'inter_set_rest_seconds');
-- ---------------------------------------------------------------------------
