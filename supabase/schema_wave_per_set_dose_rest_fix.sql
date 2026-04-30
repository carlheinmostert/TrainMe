-- homefit.studio — Wave per-set DOSE: rest-period round-trip fix (forward only)
-- =============================================================================
-- Run via:  supabase db query --linked --file supabase/schema_wave_per_set_dose_rest_fix.sql
-- Carl reviews before apply. Single forward-only file. No down migration.
--
-- WHY
--   The wave-1 migration `schema_wave_per_set_dose.sql` (already applied)
--   dropped `exercises.hold_seconds`. For video/photo rows that data lives
--   in the new `exercise_sets` child table — fine. But for rest rows
--   (`media_type = 'rest'`) the column was the rest *duration*, and that
--   semantic was dropped without a destination column. The cloud now has
--   no place to round-trip rest duration; mobile (SQLite v33 +
--   `ExerciseCapture.restHoldSeconds`) preserved the value locally, so
--   only the cloud half is severed.
--
--   Existing values in production are unrecoverable (the column is gone)
--   and that's accepted. This migration makes future publishes write rest
--   duration back to cloud — and surfaces it on `get_plan_full` so the
--   web player + any future cloud → mobile pull will see it.
--
-- WHAT THIS MIGRATION DOES (single transaction)
--   1. ADD COLUMN exercises.rest_seconds integer (NULL allowed; only
--      meaningful when media_type = 'rest').
--   2. CREATE OR REPLACE replace_plan_exercises so each input exercise
--      object's `rest_seconds` is read + INSERTed onto the new column.
--      Body sourced from live DB via `pg_get_functiondef` (per the
--      column-preservation memory) — byte-for-byte faithful to the live
--      Wave-1 body, plus the one new column. The new return shape
--      `{plan_version, fallback_set_exercise_ids}` and the synthetic
--      single-set fallback behaviour are unchanged.
--   3. CREATE OR REPLACE get_plan_full to emit `rest_seconds` per
--      exercise. Body sourced from live DB. Every existing per-exercise
--      key preserved — line_drawing_url, grayscale_url, original_url,
--      grayscale_segmented_url, original_segmented_url, mask_url,
--      sets[], plus the `to_jsonb(e)` blob (which now naturally carries
--      the new rest_seconds column too — but we add it explicitly inside
--      the build object as well so the contract is documented at the
--      call site, matching the existing per-exercise key pattern).
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT modify or recover the dropped data — production rest rows
--     keep their NULL until the next publish overwrites them.
--   * Does NOT touch exercise_sets or the per-set DOSE shape. Rest rows
--     intentionally have no exercise_sets child rows; rest duration lives
--     on the parent exercise via the new column.
--   * Does NOT change SQLite-side schema. Mobile already has the field.
--   * Does NOT touch consume_credit / unlock_plan_for_edit /
--     validate_plan_treatment_consent / list_practice_sessions /
--     list_sessions_for_client — verified via prosrc grep that none
--     reference the dropped `hold_seconds` for rest semantics; the only
--     prosrc hits for `hold_seconds` are replace_plan_exercises +
--     get_plan_full (both rewritten here), and the only references to
--     'rest' in other RPCs are media_type filters that are correct as-is.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. Add the new column
-- ============================================================================
ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS rest_seconds integer;

COMMENT ON COLUMN public.exercises.rest_seconds IS
  'Rest-period duration in seconds. Only meaningful when media_type=''rest''; '
  'for video/photo rows this stays NULL (set timing lives on exercise_sets). '
  'Replaces the old hold_seconds-for-rest semantic that was dropped in '
  'schema_wave_per_set_dose.sql.';

-- ============================================================================
-- 2. replace_plan_exercises — read rest_seconds from each input row
-- ============================================================================
-- Live-sourced body. Single delta from the Wave-1 version: rest_seconds
-- added to the INSERT column list + SELECT projection. Everything else
-- (membership guard, child-row writer, synthetic-fallback, return shape)
-- byte-for-byte unchanged.
DROP FUNCTION IF EXISTS public.replace_plan_exercises(uuid, jsonb);

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

  -- Wipe + rewrite. Cascade FK on exercise_sets → exercises drops child rows.
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
      rest_seconds
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
      NULLIF(r->>'rest_seconds', '')::integer
    FROM jsonb_array_elements(p_rows) AS r;

    -- Child set rows. For each exercise in p_rows, expand its `sets` array.
    -- If `sets` is missing/empty for a video/photo exercise, synthesise a
    -- single-set default so the exercise remains playable. Rest exercises
    -- get nothing (their sets array is ignored).
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

    -- Synthetic single-set fallback for video/photo rows that arrived
    -- without a `sets` array. Keeps publishes from old clients (or buggy
    -- callers) playable instead of silently empty.
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

-- ============================================================================
-- 3. get_plan_full — emit per-exercise `rest_seconds`
-- ============================================================================
-- Live-sourced body. Single delta: an explicit `'rest_seconds', e.rest_seconds`
-- key inside the per-exercise jsonb_build_object. The to_jsonb(e) merge above
-- already carries the column, but adding it explicitly keeps the contract
-- self-documenting at the call site (matches the existing pattern of
-- declaring line_drawing_url, sets[], etc. inline even though some of them
-- duplicate to_jsonb fields). Every other key preserved byte-for-byte:
--   line_drawing_url, grayscale_url, original_url,
--   grayscale_segmented_url, original_segmented_url, mask_url, sets.
CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  plan_row    plans;
  v_consent   jsonb;
  v_gray_ok   boolean;
  v_orig_ok   boolean;
  exes        jsonb;
BEGIN
  UPDATE plans
     SET first_opened_at = now()
   WHERE id = p_plan_id
     AND first_opened_at IS NULL
  RETURNING * INTO plan_row;

  IF plan_row IS NULL THEN
    SELECT * INTO plan_row FROM plans WHERE id = p_plan_id LIMIT 1;
  END IF;

  IF plan_row IS NULL THEN
    RETURN NULL;
  END IF;

  IF plan_row.client_id IS NOT NULL THEN
    SELECT video_consent INTO v_consent
      FROM clients WHERE id = plan_row.client_id LIMIT 1;
  END IF;

  IF v_consent IS NULL THEN
    v_consent := '{"line_drawing": true, "grayscale": false, "original": false}'::jsonb;
  END IF;

  v_gray_ok := COALESCE((v_consent ->> 'grayscale')::boolean, false);
  v_orig_ok := COALESCE((v_consent ->> 'original')::boolean, false);

  SELECT COALESCE(
           jsonb_agg(
             to_jsonb(e)
               || jsonb_build_object(
                    'line_drawing_url', e.media_url,
                    'grayscale_url',
                      CASE
                        WHEN v_gray_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mp4',
                               1800)
                        WHEN v_gray_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'original_url',
                      CASE
                        WHEN v_orig_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mp4',
                               1800)
                        WHEN v_orig_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'grayscale_segmented_url',
                      CASE
                        WHEN v_gray_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.mp4',
                               1800)
                        WHEN v_gray_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'original_segmented_url',
                      CASE
                        WHEN v_orig_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.mp4',
                               1800)
                        WHEN v_orig_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'mask_url',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok) AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mask.mp4',
                               1800)
                        ELSE NULL
                      END,
                    'sets',
                      COALESCE(
                        (
                          SELECT jsonb_agg(
                                   jsonb_build_object(
                                     'position',                 s.position,
                                     'reps',                     s.reps,
                                     'hold_seconds',             s.hold_seconds,
                                     'weight_kg',                s.weight_kg,
                                     'breather_seconds_after',   s.breather_seconds_after
                                   )
                                   ORDER BY s.position
                                 )
                            FROM public.exercise_sets s
                           WHERE s.exercise_id = e.id
                        ),
                        '[]'::jsonb
                      ),
                    -- NEW: rest-period duration. NULL for video/photo;
                    -- positive integer for media_type='rest'. Lets the
                    -- web player + future cloud→mobile sync round-trip
                    -- the value that schema_wave_per_set_dose.sql
                    -- accidentally severed when it dropped hold_seconds.
                    'rest_seconds', e.rest_seconds
                  )
               ORDER BY e.position
           ),
           '[]'::jsonb
         )
    INTO exes
    FROM exercises e
   WHERE e.plan_id = p_plan_id;

  RETURN jsonb_build_object(
    'plan',      to_jsonb(plan_row),
    'exercises', exes
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;

COMMIT;

-- ============================================================================
-- Verification queries — run via `supabase db query --linked` after apply
-- ============================================================================
--
-- 1. Column exists and is the right type:
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='exercises'
--      AND column_name='rest_seconds';
--   -- Expected: 1 row, integer, YES.
--
-- 2. RPCs reference the new column (prosrc grep):
--   SELECT proname
--     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public'
--      AND p.prosrc ILIKE '%rest_seconds%';
--   -- Expected rows: replace_plan_exercises, get_plan_full.
--
-- 3. Function signatures unchanged:
--   SELECT proname,
--          pg_get_function_identity_arguments(p.oid) AS args,
--          pg_get_function_result(p.oid)             AS returns
--     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public'
--      AND proname IN ('replace_plan_exercises','get_plan_full');
--   -- Expected:
--   --   replace_plan_exercises(p_plan_id uuid, p_rows jsonb) -> jsonb
--   --   get_plan_full(p_plan_id uuid)                       -> jsonb
--
-- 4. End-to-end smoke test (replace <plan-uuid>):
--   SELECT public.replace_plan_exercises(
--     '<plan-uuid>'::uuid,
--     '[{"id":"<rest-uuid>","position":1,"name":"Rest","media_type":"rest","rest_seconds":90}]'::jsonb
--   );
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid));
--   -- Expected: per-exercise object includes "rest_seconds": 90.
--
-- 5. Audit: no other RPC references the dropped hold_seconds-for-rest
--    semantic (sanity re-check post-apply):
--   SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public' AND p.prosrc ILIKE '%hold_seconds%';
--   -- Expected: replace_plan_exercises, get_plan_full only.
