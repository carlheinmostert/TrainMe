-- Wave 42 — per-exercise practitioner body-focus default.
--
-- Up to Wave 25, Body Focus (the segmented body-pop look on the colour
-- treatments) was a single per-device flag the practitioner toggled in
-- the mobile preview. The flag never reached publish — every published
-- plan rendered the web player's own per-device default, which in turn
-- was a global localStorage key. Wave 42 promotes Body Focus to a
-- per-exercise practitioner default that publishes through, mirroring
-- the `preferred_treatment` plumbing (Milestone O):
--
--   * `body_focus IS NULL` → no explicit choice, render with body-focus
--     ON (preserves the pre-feature default; every legacy row stays
--     unchanged on first open). The web player + mobile preview both
--     read NULL as "render default = true".
--   * `true`  → practitioner explicitly opted into body-focus on this
--               exercise.
--   * `false` → practitioner explicitly opted out (e.g. wide-frame demo
--               where dimming the background loses crucial context).
--
-- Per-exercise: moving to the next exercise in the deck doesn't carry
-- this forward — each exercise renders ITS OWN saved preference.
--
-- The web player lays a per-exercise CLIENT override on top of this
-- default in `homefit.overrides::{planId}` localStorage; that's a
-- client-side concept and lives entirely in the browser.

-- ---------------------------------------------------------------------------
-- 1. Column add — nullable BOOLEAN (no default; NULL = "render default
--    of true"). Idempotent so re-running on a DB that already has the
--    column from a previous attempt is a no-op.
-- ---------------------------------------------------------------------------

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS body_focus BOOLEAN;

COMMENT ON COLUMN public.exercises.body_focus IS
  'Practitioner-sticky body-focus default for this specific exercise. '
  'NULL = render with body-focus ON (the pre-feature default). '
  'TRUE / FALSE = explicit practitioner choice. '
  'Mirrors the mobile SQLite exercises.body_focus column. '
  'Web player layers per-exercise client overrides on top via '
  'localStorage homefit.overrides::{planId}.';

-- ---------------------------------------------------------------------------
-- 2. get_plan_full(uuid) — re-emit. The existing function spreads
--    to_jsonb(e) over each exercise row, so adding the column to the
--    `exercises` table is enough for `body_focus` to surface in the
--    payload automatically. We CREATE OR REPLACE here purely as a
--    docs / audit anchor — the function body is identical to the
--    pg_get_functiondef snapshot taken on 2026-04-30.
--
--    Pre-flight pulled via:
--      select pg_get_functiondef(
--        'public.get_plan_full(uuid)'::regprocedure
--      );
--    Body below mirrors that snapshot byte-for-byte.
-- ---------------------------------------------------------------------------

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

  -- to_jsonb(e) carries every column on `exercises`, including
  -- body_focus (Wave 42). No explicit jsonb_build_object key needed.
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
                      END
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

-- ---------------------------------------------------------------------------
-- 3. replace_plan_exercises(uuid, jsonb) — re-emit. Carl's hard rule
--    (feedback_schema_migration_column_preservation): every column the
--    mobile publish path writes MUST be in the INSERT column list and
--    the row constructor. body_focus joins the existing 23 columns.
--
--    Pre-flight pulled via:
--      select pg_get_functiondef(
--        'public.replace_plan_exercises(uuid,jsonb)'::regprocedure
--      );
--    Body below mirrors that snapshot, with `body_focus` already
--    present (a previous attempt left the RPC patched even though the
--    repo's migration file was lost; this file is the authoritative
--    audit record).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.replace_plan_exercises(p_plan_id uuid, p_rows jsonb)
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
      video_reps_per_loop,
      start_offset_ms,
      end_offset_ms,
      aspect_ratio,
      rotation_quarters,
      body_focus
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
      NULLIF(r->>'inter_set_rest_seconds', '')::integer,
      NULLIF(r->>'video_reps_per_loop', '')::integer,
      NULLIF(r->>'start_offset_ms', '')::integer,
      NULLIF(r->>'end_offset_ms', '')::integer,
      NULLIF(r->>'aspect_ratio', '')::double precision,
      NULLIF(r->>'rotation_quarters', '')::integer,
      NULLIF(r->>'body_focus', '')::boolean
    FROM jsonb_array_elements(p_rows) AS r;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Smoke test (run manually after apply):
--
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'exercises'
--      AND column_name = 'body_focus';
--
--   -- Round-trip: pick any plan with at least one exercise, set
--   -- body_focus, fetch via get_plan_full, confirm:
--   UPDATE public.exercises
--      SET body_focus = false
--    WHERE id = '<some-exercise-id>';
--   SELECT jsonb_path_query(
--            public.get_plan_full('<plan-id>'::uuid),
--            '$.exercises[*] ? (@.id == "<some-exercise-id>") . body_focus'
--          );
-- ---------------------------------------------------------------------------
