-- ============================================================================
-- Wave 43 — Three-mode hold position on per-set PLAN rows
-- ============================================================================
-- BRIEF
--   Adds `hold_position` to `public.exercise_sets`. The column controls how
--   `hold_seconds` contributes to the per-set duration on both surfaces:
--     * 'per_rep'         → reps × hold        (legacy contract)
--     * 'end_of_set'      → 1 × hold           (new default)
--     * 'end_of_exercise' → only on the LAST set of the exercise; 0 elsewhere
--
--   Default for new rows: 'end_of_set'. Existing rows whose `hold_seconds > 0`
--   are backfilled to 'per_rep' so already-displayed plan durations stay
--   byte-stable. Rows with `hold_seconds = 0` keep the new default — math is
--   identical in all three modes when hold is 0.
--
-- SCOPE
--   1. ALTER TABLE public.exercise_sets ADD COLUMN hold_position …
--   2. Backfill existing rows.
--   3. Add CHECK constraint (validates the three legal wire values).
--   4. CREATE OR REPLACE replace_plan_exercises — accept hold_position in
--      the nested `sets` array; preserves every existing column.
--   5. CREATE OR REPLACE get_plan_full — emit hold_position inside each
--      per-exercise `sets` jsonb element; preserves every existing column.
--
--   Mobile mirror: SQLite v36 in app/lib/services/local_storage_service.dart
--   (column added to exercise_sets + same backfill logic).
--
-- NOTES
--   * Both function bodies are LIVE-SOURCED column-for-column from
--     supabase/schema_wave_per_set_dose_rest_fix.sql (the most recent
--     migration to touch them). Per the
--     `feedback_schema_migration_column_preservation.md` memory rule,
--     every prior column is carried forward; only the per-set jsonb shape
--     is extended.
--   * RETURN TYPE unchanged on both functions (jsonb).
--   * `hold_position` is wire-string only (no enum type) — keeps the JSON
--     payload simple and matches the SQLite `TEXT` column.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. ALTER + backfill + CHECK constraint
-- ============================================================================
ALTER TABLE public.exercise_sets
  ADD COLUMN IF NOT EXISTS hold_position text NOT NULL DEFAULT 'end_of_set';

-- Preserve existing displayed durations on already-published plans. The
-- web-player's pre-Wave-43 contract was `reps × hold` (per_rep). Stamping
-- 'per_rep' on rows with non-zero hold keeps byte-stable durations after
-- the function rewrites below. Rows with hold_seconds = 0 stay on the
-- 'end_of_set' default — math is identical in all three modes when hold
-- is 0, so no displayed duration shifts.
UPDATE public.exercise_sets
   SET hold_position = 'per_rep'
 WHERE hold_seconds > 0
   AND hold_position = 'end_of_set';

-- CHECK constraint (idempotent: drop-then-add).
ALTER TABLE public.exercise_sets
  DROP CONSTRAINT IF EXISTS exercise_sets_hold_position_valid;
ALTER TABLE public.exercise_sets
  ADD CONSTRAINT exercise_sets_hold_position_valid
  CHECK (hold_position IN ('per_rep', 'end_of_set', 'end_of_exercise'));

-- ============================================================================
-- 2. replace_plan_exercises — accept hold_position in nested sets
-- ============================================================================
-- Live-sourced from schema_wave_per_set_dose_rest_fix.sql. Single delta:
--   * exercise_sets INSERT column list adds hold_position
--   * SELECT projection adds COALESCE on the wire string with
--     'end_of_set' default, then validates against the three-value set
--     (any unknown value falls back to the default rather than blowing
--     up the publish — defence-in-depth against stale TestFlight
--     builds).
-- Everything else (membership guard, exercise-row writer, synthetic
-- single-set fallback, return shape) byte-for-byte preserved.
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
    -- Wave 43: includes hold_position. Unknown values fall back to the new
    -- default 'end_of_set' — keeps stale TestFlight builds publishing.
    INSERT INTO public.exercise_sets (
      exercise_id,
      position,
      reps,
      hold_seconds,
      hold_position,
      weight_kg,
      breather_seconds_after
    )
    SELECT
      (r->>'id')::uuid                                        AS exercise_id,
      COALESCE((s.value->>'position')::integer, s.ordinality::integer) AS position,
      GREATEST(COALESCE(NULLIF(s.value->>'reps', '')::integer, 1), 1)   AS reps,
      GREATEST(COALESCE(NULLIF(s.value->>'hold_seconds', '')::integer, 0), 0) AS hold_seconds,
      CASE
        WHEN s.value->>'hold_position' IN ('per_rep', 'end_of_set', 'end_of_exercise')
          THEN s.value->>'hold_position'
        ELSE 'end_of_set'
      END                                                     AS hold_position,
      NULLIF(s.value->>'weight_kg', '')::numeric(5,1)         AS weight_kg,
      GREATEST(COALESCE(NULLIF(s.value->>'breather_seconds_after', '')::integer, 60), 0) AS breather_seconds_after
    FROM jsonb_array_elements(p_rows) AS r,
         LATERAL jsonb_array_elements(COALESCE(r->'sets', '[]'::jsonb))
           WITH ORDINALITY AS s(value, ordinality)
    WHERE r->>'media_type' IN ('video', 'photo')
      AND jsonb_array_length(COALESCE(r->'sets', '[]'::jsonb)) > 0;

    -- Synthetic single-set fallback for video/photo rows that arrived
    -- without a `sets` array. Keeps publishes from old clients (or buggy
    -- callers) playable instead of silently empty. Defaults
    -- hold_position = 'end_of_set' to match the per-row column default.
    WITH inserted AS (
      INSERT INTO public.exercise_sets (
        exercise_id, position, reps, hold_seconds, hold_position, weight_kg, breather_seconds_after
      )
      SELECT
        (r->>'id')::uuid, 1, 1, 0, 'end_of_set', NULL, 60
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
-- 3. get_plan_full — emit hold_position inside per-exercise sets
-- ============================================================================
-- Live-sourced from schema_wave_per_set_dose_rest_fix.sql. Single delta:
--   * jsonb_build_object inside the `sets` aggregate gains a
--     'hold_position' key (s.hold_position).
-- Every other key preserved byte-for-byte:
--   line_drawing_url, grayscale_url, original_url,
--   grayscale_segmented_url, original_segmented_url, mask_url, sets,
--   rest_seconds.
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
                                     'hold_position',            s.hold_position,
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

-- ============================================================================
-- 4. pull_practice_plans_with_media — emit hold_position in pulled sets
-- ============================================================================
-- Mobile pulls plans via this RPC for cloud→local hydration. Without the
-- new key, freshly-pulled plans would lose hold_position and revert to
-- the new 'end_of_set' default on the next save round-trip — which would
-- silently mutate any plan that had been backfilled to 'per_rep'.
--
-- Live-sourced from supabase/schema_pull_practice_plans_with_media.sql.
-- Single delta inside the `sets` jsonb_build_object call. Every other
-- column carried forward.
--
-- NB: the function is owned by the publisher of the original migration
-- and we don't have the full live body in this file — Carl will need to
-- regenerate this function from `pg_get_functiondef` if the live body
-- has drifted from supabase/schema_pull_practice_plans_with_media.sql.
-- For this wave we keep the change isolated to the two RPCs we know
-- have to round-trip the new column on the publish path
-- (replace_plan_exercises) and the anon read path (get_plan_full).
-- pull_practice_plans_with_media is documented here as a follow-up.
--
-- TODO(Wave 43 follow-up): regenerate pull_practice_plans_with_media to
-- include 'hold_position' inside the per-set jsonb_build_object().

COMMIT;

-- ============================================================================
-- Verification queries — run via `supabase db query --linked` after apply
-- ============================================================================
--
-- 1. Column exists, default + check constraint applied:
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='exercise_sets'
--      AND column_name='hold_position';
--   -- Expected: text / NO / 'end_of_set'::text
--
--   SELECT conname, pg_get_constraintdef(oid)
--     FROM pg_constraint
--    WHERE conrelid = 'public.exercise_sets'::regclass
--      AND conname  = 'exercise_sets_hold_position_valid';
--   -- Expected: CHECK (hold_position IN ('per_rep','end_of_set','end_of_exercise'))
--
-- 2. Backfill landed:
--   SELECT hold_position, count(*)
--     FROM public.exercise_sets
--    GROUP BY 1
--    ORDER BY 1;
--   -- Expected (mixed plans): per_rep / end_of_set with no end_of_exercise.
--
-- 3. Functions still callable + emit the new key:
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid));
--   -- Expected: each exercise's sets[] item now carries 'hold_position'.
