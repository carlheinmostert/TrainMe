-- Wave Lobby — practitioner-authored 1:1 Hero crop.
--
-- ===== Multi-PR plan ======================================================
-- This is PR 1/N for the new web-player lobby. The lobby replaces today's
-- "first card + Start button" entry on session.homefit.studio with a
-- vertical-scrolling menu of 1:1 hero frames showing what's coming. Hero
-- frames need to be cropped 1:1 from source video that's typically 16:9
-- landscape or 9:16 portrait. Automated centre-cropping was rejected
-- (heads/feet got sliced); the practitioner authors the crop directly via
-- a draggable 1:1 viewport in the editor sheet's Hero tab.
--
-- This PR ships ONLY the data plumbing — schema column + RPC wiring +
-- mobile mirror + sync mappers. No editor UI, no Studio-card consumers,
-- no web-player surface. Those are PR 2/3/4. NULL default keeps every
-- existing surface byte-stable: consumers treat NULL as 0.5 (centred).
-- ===========================================================================
--
-- ===== R-10 parity ========================================================
-- The same crop value is the foundation for the practitioner-facing
-- thumbnail surfaces too — Studio cards filmstrip, Home, ClientSessions,
-- Camera peek. They render the Hero JPG at `exercises.thumbnail_url`
-- (already populated by the publish flow); cropping happens at
-- consumption time via Flutter `Alignment` / CSS `object-position`, not
-- at storage time. So a single column drives both surfaces; subsequent
-- PRs just teach each consumer to read it.
-- ===========================================================================
--
-- ===== Column semantics ====================================================
-- `hero_crop_offset` is a normalized scalar in [0.0, 1.0] along the
-- source media's *free axis*:
--
--   * Landscape source (aspect_ratio > 1, e.g. 1.778 for 16:9)
--       free axis = X (horizontal). 0.0 = crop hugs the left edge,
--       0.5 = centred crop, 1.0 = crop hugs the right edge.
--       The Y axis is constrained (the 1:1 viewport already spans the
--       full height) and isn't stored.
--
--   * Portrait source (aspect_ratio < 1, e.g. 0.5625 for 9:16)
--       free axis = Y (vertical). 0.0 = crop hugs the top edge,
--       0.5 = centred crop, 1.0 = crop hugs the bottom edge.
--       The X axis is constrained.
--
--   * Square source (aspect_ratio == 1)
--       free axis is undefined; value is ignored. Practitioners can't
--       reach the picker for a 1:1 source — the editor disables it.
--
-- Orientation is determined via the Wave 28 `aspect_ratio` /
-- `rotation_quarters` columns (already populated on every new
-- conversion). NULL `aspect_ratio` means the consumer hasn't derived
-- the orientation yet — fall through to centred (0.5).
--
-- NULL `hero_crop_offset` = unset (legacy rows / new captures the
-- practitioner hasn't touched). Consumers treat NULL as 0.5.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Column add — nullable NUMERIC (no default; NULL = "consumer uses
--    0.5"). Idempotent so re-running on a DB that already has the
--    column is a no-op.
-- ---------------------------------------------------------------------------

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS hero_crop_offset numeric;

COMMENT ON COLUMN public.exercises.hero_crop_offset IS
  'Wave Lobby. Practitioner-authored 1:1 Hero crop offset, normalized '
  '0.0..1.0 along the source media''s FREE axis: X for landscape '
  '(aspect_ratio > 1), Y for portrait (aspect_ratio < 1). The '
  'constrained axis spans the full short edge of the source and is not '
  'stored. NULL = unset; consumers default to 0.5 (centred). Drives '
  'the web-player lobby 1:1 hero frames AND every practitioner-facing '
  'thumbnail surface (Studio cards filmstrip, Home, ClientSessions, '
  'Camera peek). Mirrors the mobile SQLite '
  'exercises.hero_crop_offset column (schema v38).';

-- ---------------------------------------------------------------------------
-- 2. replace_plan_exercises — add hero_crop_offset to INSERT list.
--
-- Per the CLAUDE.md gotcha (Wave 20 + Wave 24 + Wave Hero all bitten):
-- every new column on `exercises` MUST be added to this RPC's INSERT
-- column list, otherwise the value is silently dropped on every publish.
--
-- Function body sourced from the LIVE DB via:
--   select pg_get_functiondef('public.replace_plan_exercises(uuid,jsonb)'::regprocedure);
-- on 2026-05-04 — NOT from supabase/*.sql files (which lag the live DB
-- per the recurring trap; see feedback_schema_migration_column_preservation.md).
-- The live body already reflects the Wave 43 hold_position changes
-- (per-set hold_position INSERT + branch in the synthetic-set
-- fallback) which are NOT in any single .sql file by themselves.
--
-- Function signature (uuid, jsonb) -> jsonb is unchanged, so
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
      hero_crop_offset
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
      NULLIF(r->>'hero_crop_offset', '')::numeric
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

-- ---------------------------------------------------------------------------
-- 3. get_plan_full — no edit required.
--
-- The function emits per-exercise rows via `to_jsonb(e)`, which auto-
-- picks up every column on `exercises` once §1 above runs. The same
-- pattern was confirmed for Wave 28 (aspect_ratio, rotation_quarters)
-- and Wave Hero (focus_frame_offset_ms): both flow through to the wire
-- without an explicit jsonb_build_object override.
--
-- Live body sourced 2026-05-04 via:
--   select pg_get_functiondef('public.get_plan_full(uuid)'::regprocedure);
-- The per-exercise object starts with `to_jsonb(e) || jsonb_build_object(...)`
-- — the override only ADDS keys (line_drawing_url, grayscale_url,
-- original_url, the segmented variants, mask_url, sets, rest_seconds),
-- never strips them. So `hero_crop_offset` (a plain `exercises` column
-- after §1) flows through automatically.
--
-- Smoke test §4 below confirms it on the wire.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 4. Smoke tests — run manually after apply.
--
--   -- Column visible:
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema = 'public'
--      AND table_name = 'exercises'
--      AND column_name = 'hero_crop_offset';
--   -- Expect: hero_crop_offset | numeric | YES
--
--   -- INSERT list contains the new column:
--   SELECT position('hero_crop_offset' IN pg_get_functiondef(
--            'public.replace_plan_exercises(uuid,jsonb)'::regprocedure)) > 0;
--   -- Expect: t
--
--   -- Round-trip: pick any plan with at least one video exercise, set
--   -- hero_crop_offset, fetch via get_plan_full, confirm the value
--   -- surfaces on the wire:
--   UPDATE public.exercises
--      SET hero_crop_offset = 0.32
--    WHERE id = '<some-exercise-id>';
--   SELECT jsonb_path_query(
--            public.get_plan_full('<plan-id>'::uuid),
--            '$.exercises[*] ? (@.id == "<some-exercise-id>") . hero_crop_offset'
--          );
--   -- Expect: 0.32
--
--   -- Practitioner round-trip: republish the same plan via
--   -- replace_plan_exercises with hero_crop_offset = 0.32 in the rows
--   -- payload, then re-fetch via get_plan_full. Value must persist.
-- ---------------------------------------------------------------------------
