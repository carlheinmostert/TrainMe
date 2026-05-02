-- Wave Hero — per-exercise practitioner-picked Hero frame.
--
-- The Hero frame is the representative still image extracted from a video
-- exercise. It drives every practitioner-facing thumbnail surface (Studio
-- card, Home, ClientSessions, Camera peek) AND the client-facing video
-- poster + prep-phase overlay on the web player. Up to this wave, the
-- frame was auto-picked at conversion time via the motion-peak heuristic
-- in `VideoConverterChannel.pickMotionPeakTime` (sample 33% / 50% / 67%
-- of duration, pick the candidate with the largest grayscale-fingerprint
-- diff vs. frame 0). Practitioners had no override.
--
-- This wave adds:
--
--   * `exercises.focus_frame_offset_ms` — milliseconds into the source
--     raw video where the Hero frame was sampled. Populated on every new
--     conversion (the motion-peak time is persisted), and overwritten by
--     the practitioner via the editor-sheet "Hero" tab.
--
--   * NULL means "no record yet" (legacy rows pre-migration; backfilled
--     to 0 on the first thumbnail regeneration). Both surfaces fall
--     through to the existing motion-peak heuristic when NULL.
--
-- The actual thumbnail file overwritten in storage stays at
-- `exercises.thumbnail_url` — this column tracks WHEN in the video the
-- frame was sampled, so the practitioner can re-open the Hero tab,
-- scrub from the existing offset, and pick a different one.

-- ---------------------------------------------------------------------------
-- 1. Column add — nullable INTEGER (no default; NULL = "use motion-peak
--    fallback"). Idempotent so re-running on a DB that already has the
--    column is a no-op.
-- ---------------------------------------------------------------------------

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS focus_frame_offset_ms INTEGER;

COMMENT ON COLUMN public.exercises.focus_frame_offset_ms IS
  'Practitioner-picked Hero frame offset (ms into the raw video). '
  'Populated on every new conversion with the motion-peak time; '
  'overwritten by the practitioner via the editor-sheet Hero tab. '
  'NULL = legacy / pre-migration row (consumers fall through to the '
  'motion-peak heuristic). Mirrors the mobile SQLite '
  'exercises.focus_frame_offset_ms column (schema v35).';

-- ---------------------------------------------------------------------------
-- 2. replace_plan_exercises — add focus_frame_offset_ms to INSERT list.
--
-- Per the CLAUDE.md gotcha note (Wave 20 + Wave 24 both got bitten):
-- every new column on `exercises` MUST be added to this RPC's INSERT
-- column list, otherwise the value is silently dropped on every publish.
--
-- The function signature stays the same (uuid, jsonb) -> jsonb, so
-- CREATE OR REPLACE is safe (no return-type change).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.replace_plan_exercises(
  p_plan_id uuid,
  p_rows    jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller        uuid := auth.uid();
  v_practice_id   uuid;
  v_fallback_ids  uuid[] := ARRAY[]::uuid[];
  v_plan_version  integer;
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

  IF EXISTS (
    SELECT 1
      FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) AS r
     WHERE r ? 'plan_id'
       AND NULLIF(r->>'plan_id', '') IS NOT NULL
       AND (r->>'plan_id')::uuid IS DISTINCT FROM p_plan_id
  ) THEN
    RAISE EXCEPTION
      'replace_plan_exercises: per-row plan_id must match p_plan_id (%)', p_plan_id
      USING ERRCODE = '22023';
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
      notes,
      circuit_id,
      include_audio,
      preferred_treatment,
      prep_seconds,
      video_reps_per_loop,
      start_offset_ms,
      end_offset_ms,
      aspect_ratio,
      rotation_quarters,
      body_focus,
      rest_seconds,
      focus_frame_offset_ms
    )
    SELECT
      (r->>'id')::uuid,
      p_plan_id,
      (r->>'position')::integer,
      r->>'name',
      r->>'media_url',
      r->>'thumbnail_url',
      r->>'media_type',
      r->>'notes',
      r->>'circuit_id',
      COALESCE((r->>'include_audio')::boolean, false),
      r->>'preferred_treatment',
      NULLIF(r->>'prep_seconds', '')::integer,
      NULLIF(r->>'video_reps_per_loop', '')::integer,
      NULLIF(r->>'start_offset_ms', '')::integer,
      NULLIF(r->>'end_offset_ms', '')::integer,
      NULLIF(r->>'aspect_ratio', '')::numeric,
      NULLIF(r->>'rotation_quarters', '')::smallint,
      NULLIF(r->>'body_focus', '')::boolean,
      NULLIF(r->>'rest_seconds', '')::integer,
      NULLIF(r->>'focus_frame_offset_ms', '')::integer
    FROM jsonb_array_elements(p_rows) AS r;

    INSERT INTO public.exercise_sets (
      exercise_id,
      position,
      reps,
      hold_seconds,
      weight_kg,
      breather_seconds_after
    )
    SELECT
      (r->>'id')::uuid                                        AS exercise_id,
      COALESCE((s.value->>'position')::integer, s.ordinality::integer) AS position,
      GREATEST(COALESCE(NULLIF(s.value->>'reps', '')::integer, 1), 1)   AS reps,
      GREATEST(COALESCE(NULLIF(s.value->>'hold_seconds', '')::integer, 0), 0) AS hold_seconds,
      NULLIF(s.value->>'weight_kg', '')::numeric(5,1)         AS weight_kg,
      GREATEST(COALESCE(NULLIF(s.value->>'breather_seconds_after', '')::integer, 60), 0) AS breather_seconds_after
    FROM jsonb_array_elements(p_rows) AS r,
         LATERAL jsonb_array_elements(COALESCE(r->'sets', '[]'::jsonb))
           WITH ORDINALITY AS s(value, ordinality)
    WHERE r->>'media_type' IN ('video', 'photo')
      AND jsonb_array_length(COALESCE(r->'sets', '[]'::jsonb)) > 0;

    WITH inserted AS (
      INSERT INTO public.exercise_sets (
        exercise_id, position, reps, hold_seconds, weight_kg, breather_seconds_after
      )
      SELECT
        (r->>'id')::uuid, 1, 1, 0, NULL, 60
        FROM jsonb_array_elements(p_rows) AS r
       WHERE r->>'media_type' IN ('video', 'photo')
         AND jsonb_array_length(COALESCE(r->'sets', '[]'::jsonb)) = 0
      RETURNING exercise_id
    )
    SELECT COALESCE(array_agg(exercise_id), ARRAY[]::uuid[])
      INTO v_fallback_ids
      FROM inserted;
  END IF;

  SELECT version INTO v_plan_version
    FROM public.plans
   WHERE id = p_plan_id
   LIMIT 1;

  RETURN jsonb_build_object(
    'plan_version',             v_plan_version,
    'fallback_set_exercise_ids', to_jsonb(v_fallback_ids)
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. get_plan_full — no edit required.
--
-- The function emits per-exercise rows via `to_jsonb(e)`, which auto-
-- picks up every column on `exercises` once §1 above runs. So
-- `focus_frame_offset_ms` flows through to the web player automatically.
-- The web player only needs `thumbnail_url` for the prep-overlay use
-- case (already populated by the publish flow); the offset is
-- informational on the wire.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 4. Smoke tests — run manually after apply.
--
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND table_name = 'exercises'
--      AND column_name = 'focus_frame_offset_ms';
--
--   SELECT position('focus_frame_offset_ms' IN pg_get_functiondef(
--            'public.replace_plan_exercises(uuid,jsonb)'::regprocedure)) > 0;
--
--   -- Round-trip: pick any plan with at least one video exercise, set
--   -- focus_frame_offset_ms, fetch via get_plan_full, confirm the value
--   -- surfaces on the wire:
--   UPDATE public.exercises
--      SET focus_frame_offset_ms = 2400
--    WHERE id = '<some-exercise-id>';
--   SELECT jsonb_path_query(
--            public.get_plan_full('<plan-id>'::uuid),
--            '$.exercises[*] ? (@.id == "<some-exercise-id>") . focus_frame_offset_ms'
--          );
-- ---------------------------------------------------------------------------
