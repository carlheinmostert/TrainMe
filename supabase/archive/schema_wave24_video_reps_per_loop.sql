-- ============================================================================
-- Wave 24 — exercises.video_reps_per_loop + replace_plan_exercises pass-through
-- ============================================================================
--
-- Why: practitioners record videos that contain N reps (default 3), not 1.
-- The web player and mobile preview now derive per-rep time from
--
--     per_rep = video_duration / video_reps_per_loop
--     per_set = target_reps × per_rep
--
-- Single source of truth — replaces the manual `custom_duration_seconds`
-- override in the UI. The legacy column stays for backwards-compatible
-- reads (older plans persisted a manual override) but no new captures
-- write to it.
--
-- Three-state semantics on the new column:
--   * NULL → legacy / pre-migration row. Player treats as 1 rep per loop
--            (preserves existing playback math for any plan published
--            before today).
--   * INT > 0 → practitioner-set or persistence-default count of reps
--            captured in the video. Fresh mobile captures seed to 3 via
--            ExerciseCapture.withPersistenceDefaults().
--
-- get_plan_full automatically surfaces the new column because it builds
-- the per-exercise payload via `to_jsonb(e)` — no separate signature
-- update needed in the RPC body. Verified live before this migration.
--
-- Rollback: DROP COLUMN public.exercises.video_reps_per_loop. Mobile
-- gracefully degrades (the field becomes NULL → web player treats as
-- legacy 1-rep loop). Then re-deploy a replace_plan_exercises that
-- omits the column.
-- ============================================================================

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS video_reps_per_loop INTEGER
    CHECK (video_reps_per_loop IS NULL OR video_reps_per_loop > 0);

COMMENT ON COLUMN public.exercises.video_reps_per_loop IS
  'Wave 24. Number of repetitions captured in the source video. NULL = '
  'legacy / pre-migration row (player treats as 1). Fresh mobile captures '
  'seed to 3 via ExerciseCapture.withPersistenceDefaults(). Per-rep time '
  'is derived as video_duration_ms/1000 / video_reps_per_loop; per-set '
  'time is derived as target_reps × per_rep. Replaces the manual '
  'custom_duration_seconds override in the UI (legacy column retained '
  'for backwards-compatible reads).';

-- ============================================================================
-- replace_plan_exercises — extend the explicit INSERT column list to
-- include the new field. Mirrors the live RPC body (queried directly
-- via supabase db query --linked) which already covers
-- inter_set_rest_seconds + start/end_offset_ms even though the local
-- schema_fix file is stale at prep_seconds.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.replace_plan_exercises(
  p_plan_id uuid,
  p_rows    jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_practice_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id INTO v_practice_id
    FROM public.plans
   WHERE id = p_plan_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises: plan % not found', p_plan_id
      USING ERRCODE = '22023';
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'replace_plan_exercises: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.exercises WHERE plan_id = p_plan_id;

  IF jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 0 THEN
    INSERT INTO public.exercises (
      id,
      plan_id,
      position,
      name,
      media_url,
      thumbnail_url,
      media_type,
      reps,
      sets,
      hold_seconds,
      notes,
      circuit_id,
      include_audio,
      custom_duration_seconds,
      preferred_treatment,
      prep_seconds,
      inter_set_rest_seconds,
      start_offset_ms,
      end_offset_ms,
      video_reps_per_loop
    )
    SELECT
      (r->>'id')::uuid,
      (r->>'plan_id')::uuid,
      (r->>'position')::integer,
      r->>'name',
      r->>'media_url',
      r->>'thumbnail_url',
      r->>'media_type',
      NULLIF(r->>'reps', '')::integer,
      NULLIF(r->>'sets', '')::integer,
      NULLIF(r->>'hold_seconds', '')::integer,
      r->>'notes',
      r->>'circuit_id',
      COALESCE((r->>'include_audio')::boolean, false),
      NULLIF(r->>'custom_duration_seconds', '')::integer,
      r->>'preferred_treatment',
      NULLIF(r->>'prep_seconds', '')::integer,
      NULLIF(r->>'inter_set_rest_seconds', '')::integer,
      NULLIF(r->>'start_offset_ms', '')::integer,
      NULLIF(r->>'end_offset_ms', '')::integer,
      NULLIF(r->>'video_reps_per_loop', '')::integer
    FROM jsonb_array_elements(p_rows) AS r;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) FROM anon, public;

-- ============================================================================
-- Smoke test (run manually after apply):
--
--   -- Verify the column exists with the CHECK constraint:
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'exercises'
--      AND column_name = 'video_reps_per_loop';
--   -- Expect 1 row: video_reps_per_loop | integer | YES
--
--   -- Verify get_plan_full surfaces the new key (auto via to_jsonb(e)):
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid)
--            -> 'exercises' -> 0 -> 'video_reps_per_loop');
--   -- Expect: NULL on pre-migration rows; integer on rows republished
--   -- from a Wave-24-or-later mobile build.
-- ============================================================================
