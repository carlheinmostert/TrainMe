-- ============================================================================
-- Self-trainer wave PR #5 (2026-05-25): self-verification publish plumbing
-- ============================================================================
-- Extends `public.replace_plan_exercises` to round-trip the new
-- `exercises.self_verified boolean` column (added by PR #1 in
-- 20260525074056_self_trainer_wave.sql) through the publish payload, and
-- adds `public.get_my_self_face_embedding()` SECURITY DEFINER RPC so the
-- mobile capture pipeline can read its own
-- `practitioners.face_embedding` (a 512-d pgvector) without exposing
-- the column to a direct table SELECT.
--
-- Per `feedback_schema_migration_column_preservation`: this migration
-- recreates `replace_plan_exercises` with the existing column list
-- preserved verbatim from 20260521174000_validate_captured_in_premises_id.sql
-- and adds `self_verified` to the SELECT + INSERT list. CREATE OR REPLACE
-- is fine — return type is unchanged.
--
-- Self-verified semantics (per docs/SELF_TRAINER_WAVE.md § "Publish
-- flow changes"):
--   * NULL  = not yet checked (legacy / pre-wave rows).
--   * true  = MobileFaceNet at conversion time matched
--             practitioners.face_embedding above the cosine-similarity
--             threshold.
--   * false = mismatch OR no face detected OR no reference embedding
--             (conservative — downstream publish-cost preview treats
--             NULL as false).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Extend replace_plan_exercises to round-trip exercises.self_verified
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.replace_plan_exercises(p_plan_id uuid, p_rows jsonb)
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
      rest_seconds,
      focus_frame_offset_ms,
      hero_crop_offset,
      safe_mode_active,
      captured_in_premises_id,
      self_verified
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
      NULLIF(r->>'focus_frame_offset_ms', '')::integer,
      NULLIF(r->>'hero_crop_offset', '')::numeric,
      COALESCE(NULLIF(r->>'safe_mode_active', '')::boolean, false),
      -- S-H3 fix: client supplied this, so confirm it points at one of
      -- the calling practice's own premises. If the row's id isn't owned
      -- (NULL, malformed, or another practice's id) we NULL it out
      -- rather than erroring — Safe Mode metadata is non-load-bearing
      -- for playback, and a single bad row shouldn't kill an entire
      -- publish.
      (
        SELECT pp.id
          FROM public.practice_premises pp
         WHERE pp.id = NULLIF(r->>'captured_in_premises_id', '')::uuid
           AND pp.practice_id = v_practice_id
         LIMIT 1
      ),
      -- Self-trainer PR #5: NULLABLE bool. Pre-wave callers (and any
      -- exercise captured before the user opted into face verification)
      -- omit this key entirely → falls through to NULL. NULL is the
      -- canonical "not yet checked" marker; downstream publish-cost
      -- aggregation treats NULL as false (conservative).
      NULLIF(r->>'self_verified', '')::boolean
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

-- ---------------------------------------------------------------------------
-- 2. get_my_self_face_embedding() — read RPC for the conversion pipeline
-- ---------------------------------------------------------------------------
-- The capture-time self-verification step in app/lib/services/conversion_service.dart
-- needs the caller's own face_embedding to compare against the freshly
-- converted capture. Reading via a SECURITY DEFINER RPC keeps the
-- practitioners table out of the client's enumerated table-SELECT path
-- (per `feedback_no_direct_db_access`) and returns the embedding as a
-- real[] which PostgREST serialises as a JSON array of floats — the
-- shape the Dart layer hands to the native channel.
--
-- Returns NULL when the caller has not yet registered a self-face
-- embedding (i.e. has not run the consent flow). Conversion service
-- treats NULL as "skip self-verification — leave exercises.self_verified
-- at NULL".

CREATE OR REPLACE FUNCTION public.get_my_self_face_embedding()
 RETURNS real[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller    uuid := auth.uid();
  v_embedding vector(512);
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_my_self_face_embedding requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  SELECT face_embedding INTO v_embedding
    FROM public.practitioners
   WHERE user_id = v_caller
   LIMIT 1;

  IF v_embedding IS NULL THEN
    RETURN NULL;
  END IF;

  -- vector → real[] coercion. pgvector ships an explicit cast
  -- (`vector::real[]`) that yields a same-length array preserving the
  -- L2-normalised floats. PostgREST then encodes the real[] as a JSON
  -- numeric array → Dart `List<double>`.
  RETURN v_embedding::real[];
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_my_self_face_embedding()
  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_my_self_face_embedding()
  TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_my_self_face_embedding()
  TO service_role;

COMMENT ON FUNCTION public.get_my_self_face_embedding() IS
  'Self-trainer PR #5 — returns the caller''s own '
  'practitioners.face_embedding as a real[] (512 floats) for the '
  'capture-time self-verification flow. Returns NULL when the caller '
  'has not registered a self-face. SECURITY DEFINER so the embedding '
  'column stays out of the enumerated table-SELECT surface.';

COMMIT;
