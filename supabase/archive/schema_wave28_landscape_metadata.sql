-- ============================================================================
-- Wave 28 — exercises.aspect_ratio + rotation_quarters + replace_plan_exercises
-- ============================================================================
--
-- Why: landscape orientation support. The web + native players need two
-- new pieces of metadata to size pills and render rotated playback
-- correctly without re-encoding the source media.
--
--   * aspect_ratio (numeric) — effective playback aspect after any
--     practitioner rotation. e.g. 1.778 for 16:9, 0.5625 for 9:16.
--     NULL → consumer derives at first paint (legacy / pre-migration).
--
--   * rotation_quarters (smallint, default 0) — practitioner's manual
--     playback rotation in 90° clockwise quarters: 0/1/2/3. NULL is
--     treated as 0 by both surfaces. Applied as a CSS / Transform.rotate
--     at render time — no source re-encoding. When practitioner rotates
--     by 90°, aspect_ratio is also updated to the rotated value (single
--     write covers both).
--
-- get_plan_full surfaces both columns automatically because it builds
-- the per-exercise payload via `to_jsonb(e)` (verified live before this
-- migration).
--
-- Rollback: DROP COLUMN public.exercises.aspect_ratio,
-- public.exercises.rotation_quarters. Mobile + web both gracefully
-- degrade (NULL → derive from natural dimensions; rotation 0). Then
-- re-deploy a replace_plan_exercises that omits the columns.
-- ============================================================================

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS aspect_ratio numeric;

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS rotation_quarters smallint DEFAULT 0
    CHECK (rotation_quarters IS NULL OR rotation_quarters BETWEEN 0 AND 3);

COMMENT ON COLUMN public.exercises.aspect_ratio IS
  'Wave 28. Effective playback aspect ratio (width/height) after any '
  'practitioner rotation. NULL = consumer derives from natural media '
  'dimensions at first paint (legacy / pre-migration row).';

COMMENT ON COLUMN public.exercises.rotation_quarters IS
  'Wave 28. Practitioner playback rotation in 90° clockwise quarters '
  '(0/1/2/3). NULL or 0 = no rotation. Applied as CSS / Transform.rotate '
  'at render time — no source re-encoding. When set, aspect_ratio is '
  'updated in the same write to reflect the rotated dimensions.';

-- ============================================================================
-- replace_plan_exercises — extend the explicit INSERT column list to
-- include the two new fields. Mirrors the Wave 24 RPC body; every new
-- column on `exercises` needs explicit add to that RPC's INSERT column
-- list (see CLAUDE.md + gotchas_publish_path.md — recurring trap).
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
      video_reps_per_loop,
      aspect_ratio,
      rotation_quarters
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
      NULLIF(r->>'video_reps_per_loop', '')::integer,
      NULLIF(r->>'aspect_ratio', '')::numeric,
      NULLIF(r->>'rotation_quarters', '')::smallint
    FROM jsonb_array_elements(p_rows) AS r;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) FROM anon, public;

-- ============================================================================
-- Smoke test (run manually after apply):
--
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'exercises'
--      AND column_name IN ('aspect_ratio', 'rotation_quarters');
--   -- Expect 2 rows: aspect_ratio | numeric | YES | NULL
--   --               rotation_quarters | smallint | YES | 0
--
--   -- Verify get_plan_full surfaces the new keys (auto via to_jsonb(e)):
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid)
--            -> 'exercises' -> 0);
-- ============================================================================
