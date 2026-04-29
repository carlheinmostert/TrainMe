-- Hotfix: replace_plan_exercises INSERT was missing 7 columns added
-- post-Wave 20. The SEC-2 security hardening re-created the RPC with
-- an explicit column list that forgot the newer fields. Same pattern
-- as the Wave 40.5 client_exercise_defaults drop.
--
-- Missing columns restored:
--   inter_set_rest_seconds  (Wave 28)
--   video_reps_per_loop     (Wave 24)
--   video_duration_ms       (Wave 24)
--   start_offset_ms         (Wave 20 soft-trim)
--   end_offset_ms           (Wave 20 soft-trim)
--   aspect_ratio            (Wave 28)
--   rotation_quarters       (Wave 28)

CREATE OR REPLACE FUNCTION public.replace_plan_exercises(
  p_plan_id UUID,
  p_rows    JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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

  -- SEC-2 (C-1): reject any input row whose plan_id disagrees.
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

  -- FULL column list — every column on `exercises` that the mobile
  -- publish path can set. When adding a new column to `exercises`,
  -- ADD IT HERE or it silently drops on every publish.
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
      -- Columns below were missing from the SEC-2 rewrite:
      inter_set_rest_seconds,
      video_reps_per_loop,
      video_duration_ms,
      start_offset_ms,
      end_offset_ms,
      aspect_ratio,
      rotation_quarters
    )
    SELECT
      (r->>'id')::uuid,
      p_plan_id,
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
      -- Restored columns:
      NULLIF(r->>'inter_set_rest_seconds', '')::integer,
      NULLIF(r->>'video_reps_per_loop', '')::integer,
      NULLIF(r->>'video_duration_ms', '')::integer,
      NULLIF(r->>'start_offset_ms', '')::integer,
      NULLIF(r->>'end_offset_ms', '')::integer,
      NULLIF(r->>'aspect_ratio', '')::double precision,
      NULLIF(r->>'rotation_quarters', '')::integer
    FROM jsonb_array_elements(p_rows) AS r;
  END IF;
END;
$fn$;
