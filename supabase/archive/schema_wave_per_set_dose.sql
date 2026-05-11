-- homefit.studio — Wave: per-set PLAN relational model (clean cutover)
-- =============================================================================
-- Run via:  supabase db query --linked --file supabase/schema_wave_per_set_dose.sql
-- Carl reviews before apply. Single forward-only file. No down migration.
--
-- WHY
--   Until now, every exercise carried uniform `(reps, sets, hold_seconds,
--   inter_set_rest_seconds)` columns — every set played identical to every
--   other. The new PLAN table mockup
--   (`docs/design/mockups/exercise-card-plan-table.html`) supports per-set
--   variation: pyramids (10/8/6 reps), per-set weight escalation, weighted
--   exercises (`weight_kg`), and per-set breather. The model has to change.
--
-- DESIGN
--   `exercise_sets` is a child table (1:N from exercises). Each row is one
--   playable set with reps, hold, weight, and the breather AFTER that set.
--   Plays in order by `position`. Cycle/round reconciliation (when circuit
--   cycle count diverges from set count) is a UI-side rule — no DB enforcement.
--
-- WHAT THIS MIGRATION DOES (single transaction)
--   1. Creates `public.exercise_sets` (id PK, exercise_id FK, position, reps,
--      hold_seconds, weight_kg numeric(5,1) NULLABLE, breather_seconds_after,
--      timestamps; UNIQUE (exercise_id, position); CHECKs).
--   2. Backfills from legacy: each exercise where media_type IN ('video','photo')
--      → COALESCE(sets,1) rows in exercise_sets, cloning reps/hold/inter_set_rest.
--      `weight_kg` left NULL (bodyweight by default). Rest exercises skipped.
--   3. RLS lockdown (same pattern as `credit_ledger`):
--        - SELECT scoped via parent exercise → plan → practice membership
--          using `user_practice_ids()` (SECURITY DEFINER helper, bypasses RLS).
--        - Anon SELECT blocked (no policy = denied).
--        - REVOKE INSERT/UPDATE/DELETE from authenticated/anon — RPC-write-only
--          (`replace_plan_exercises` is the sole writer).
--   4. Drops legacy columns from `exercises`:
--        reps, sets, hold_seconds, inter_set_rest_seconds, custom_duration_seconds.
--      Also drops the dead-since-inception columns:
--        rep_duration_seconds, set_rest_seconds.
--   5. Scrubs the `clients.client_exercise_defaults` JSONB so the legacy keys
--      `reps`, `sets`, `hold_seconds`, `inter_set_rest_seconds` no longer
--      poison sticky-default reads. Per-set values are not sticky at the
--      client level (they live on the exercise's set rows). KEEPS:
--        video_reps_per_loop, preferred_treatment, include_audio, prep_seconds,
--        custom_duration_per_rep (legacy fragment, harmless), and any future
--        keys not in the drop list.
--      NB: there is NO public.client_exercise_defaults TABLE. The brief was
--      inaccurate about that. The column on `clients` is the only home.
--   6. Re-creates `replace_plan_exercises` to:
--        - accept new input shape with nested `sets` array per exercise,
--        - delete + re-insert the parent exercise row (same as before),
--        - delete + re-insert child exercise_sets rows (cascade handles delete),
--        - preserve EVERY column the live body currently writes (sourced from
--          live DB via `pg_get_functiondef`, NOT from supabase/*.sql files —
--          per the column-preservation gotcha memory).
--      Live source dropped: reps, sets, hold_seconds, inter_set_rest_seconds,
--      custom_duration_seconds (5 columns gone). Otherwise byte-for-byte
--      faithful to the live body.
--   7. Re-creates `get_plan_full` to add per-exercise `sets` jsonb array
--      `[{position, reps, hold_seconds, weight_kg, breather_seconds_after}, ...]`.
--      Preserves ALL existing per-exercise keys (line_drawing_url,
--      grayscale_url, original_url, grayscale_segmented_url,
--      original_segmented_url, mask_url, plus every column on `exercises`
--      via to_jsonb(e)). Sourced from live DB, not from supabase/*.sql.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT change the trainer/web-player code. Carl ships the surface
--     changes in the same wave; this file is the DB half only.
--   * Does NOT touch consume_credit, unlock_plan_for_edit, or
--     validate_plan_treatment_consent — verified via prosrc grep that none
--     reference the dropped columns.
--   * Does NOT touch get_client_by_id / list_practice_clients — they return
--     the whole `client_exercise_defaults` JSONB blob; once the legacy keys
--     are scrubbed (step 5), the returned data is correct without any RPC
--     signature change.
--   * Does NOT add a separate `exercise_sets` audit-log table. Set edits
--     ride on existing plan-version + audit-event paths.
--
-- AUDIT — RPCs that referenced legacy columns (via prosrc grep, live DB)
--   inter_set_rest_seconds   → only `replace_plan_exercises` (rewritten here)
--   custom_duration_seconds  → only `replace_plan_exercises` (rewritten here)
--   hold_seconds             → only `replace_plan_exercises` (rewritten here)
--   reps / sets              → only `replace_plan_exercises` (rewritten here)
--   client_exercise_defaults → get_client_by_id, list_practice_clients,
--                              set_client_exercise_default — all return/write
--                              the JSONB blob opaquely; no signature change
--                              needed once data is scrubbed.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. exercise_sets table
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.exercise_sets (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  exercise_id              uuid NOT NULL REFERENCES public.exercises(id) ON DELETE CASCADE,
  position                 integer NOT NULL,
  reps                     integer NOT NULL,
  hold_seconds             integer NOT NULL DEFAULT 0,
  weight_kg                numeric(5,1),
  breather_seconds_after   integer NOT NULL DEFAULT 60,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exercise_sets_position_positive       CHECK (position > 0),
  CONSTRAINT exercise_sets_reps_positive           CHECK (reps > 0),
  CONSTRAINT exercise_sets_hold_nonneg             CHECK (hold_seconds >= 0),
  CONSTRAINT exercise_sets_breather_nonneg         CHECK (breather_seconds_after >= 0),
  CONSTRAINT exercise_sets_weight_kg_range         CHECK (weight_kg IS NULL OR weight_kg > 0),
  CONSTRAINT exercise_sets_unique_position         UNIQUE (exercise_id, position)
);

CREATE INDEX IF NOT EXISTS idx_exercise_sets_exercise_position
  ON public.exercise_sets (exercise_id, position);

-- updated_at touch trigger (mirrors clients trigger pattern).
CREATE OR REPLACE FUNCTION public._exercise_sets_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_exercise_sets_touch_updated_at ON public.exercise_sets;
CREATE TRIGGER trg_exercise_sets_touch_updated_at
  BEFORE UPDATE ON public.exercise_sets
  FOR EACH ROW
  EXECUTE FUNCTION public._exercise_sets_touch_updated_at();

-- ============================================================================
-- 2. Backfill from legacy exercises columns
-- ============================================================================
-- One row per (exercise, set ordinal). Idempotent: re-running is a no-op once
-- exercise_sets is populated, because the WHERE NOT EXISTS clause skips any
-- exercise that already has at least one child row.
DO $$
DECLARE
  v_inserted integer := 0;
BEGIN
  WITH src AS (
    SELECT
      e.id                                      AS exercise_id,
      generate_series(1, GREATEST(COALESCE(e.sets, 1), 1)) AS position,
      COALESCE(NULLIF(e.reps, 0), 1)            AS reps,
      COALESCE(e.hold_seconds, 0)               AS hold_seconds,
      COALESCE(e.inter_set_rest_seconds, 60)    AS breather_seconds_after
      FROM public.exercises e
     WHERE e.media_type IN ('video', 'photo')
       AND NOT EXISTS (
         SELECT 1 FROM public.exercise_sets s WHERE s.exercise_id = e.id
       )
  ),
  ins AS (
    INSERT INTO public.exercise_sets (
      exercise_id, position, reps, hold_seconds, weight_kg, breather_seconds_after
    )
    SELECT exercise_id, position, reps, hold_seconds, NULL, breather_seconds_after
      FROM src
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_inserted FROM ins;
  RAISE NOTICE 'exercise_sets backfill: inserted % rows.', v_inserted;
END
$$;

-- ============================================================================
-- 3. RLS lockdown — RPC-write-only, practice-scoped read
-- ============================================================================
ALTER TABLE public.exercise_sets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS exercise_sets_select_member ON public.exercise_sets;

-- SELECT: practice membership via parent exercise → plan → practice.
-- Uses user_practice_ids() (SECURITY DEFINER, bypasses RLS). Anon has no
-- policy = denied (the web player goes through get_plan_full SECURITY
-- DEFINER, so anon never SELECTs this table directly).
CREATE POLICY exercise_sets_select_member ON public.exercise_sets
  FOR SELECT USING (
    EXISTS (
      SELECT 1
        FROM public.exercises e
        JOIN public.plans p ON p.id = e.plan_id
       WHERE e.id = exercise_sets.exercise_id
         AND (
           p.practice_id IN (SELECT public.user_practice_ids())
           OR public.user_is_practice_owner(p.practice_id)
         )
    )
  );

-- No INSERT/UPDATE/DELETE policies = denied for non-superusers. Belt-and-
-- braces: also REVOKE from authenticated + anon so even if a future policy
-- accidentally opens a write path, the GRANT layer keeps it closed.
-- Pattern matches schema_milestone_e_revoke_credit_ledger_writes.sql.
REVOKE INSERT, UPDATE, DELETE ON public.exercise_sets FROM authenticated, anon;
GRANT SELECT ON public.exercise_sets TO authenticated;
-- (No GRANT to anon — RLS denies SELECT for them anyway, but keep GRANT
-- consistent with credit_ledger.)

-- ============================================================================
-- 4. Drop legacy columns from `exercises`
-- ============================================================================
-- Order matters: drop in dependency order. None of these have FKs, defaults
-- referenced elsewhere, or generated-column dependents. Verified via prosrc
-- grep that only `replace_plan_exercises` referenced them, and that RPC is
-- recreated below.
ALTER TABLE public.exercises DROP COLUMN IF EXISTS reps;
ALTER TABLE public.exercises DROP COLUMN IF EXISTS sets;
ALTER TABLE public.exercises DROP COLUMN IF EXISTS hold_seconds;
ALTER TABLE public.exercises DROP COLUMN IF EXISTS inter_set_rest_seconds;
ALTER TABLE public.exercises DROP COLUMN IF EXISTS custom_duration_seconds;

-- Dead-since-inception columns (zero non-null rows in production). Cleared
-- out as part of the per-set wave so the table doesn't carry corpses.
ALTER TABLE public.exercises DROP COLUMN IF EXISTS rep_duration_seconds;
ALTER TABLE public.exercises DROP COLUMN IF EXISTS set_rest_seconds;

-- ============================================================================
-- 5. Scrub legacy keys from `clients.client_exercise_defaults` JSONB
-- ============================================================================
-- The brief said "drop column inter_set_rest_seconds from
-- client_exercise_defaults", but that's a JSONB column on `clients`, not a
-- table. The right move is to strip the legacy keys so future
-- get_client_by_id / list_practice_clients / set_client_exercise_default
-- reads/writes don't carry stale values into the new per-set world.
--
-- KEEPS: video_reps_per_loop, preferred_treatment, include_audio,
-- prep_seconds, custom_duration_per_rep, and any future keys.
UPDATE public.clients
   SET client_exercise_defaults = (
       client_exercise_defaults
         - 'reps'
         - 'sets'
         - 'hold_seconds'
         - 'inter_set_rest_seconds'
         - 'custom_duration_seconds'
       )
 WHERE client_exercise_defaults ?| ARRAY['reps','sets','hold_seconds','inter_set_rest_seconds','custom_duration_seconds'];

-- ============================================================================
-- 6. replace_plan_exercises — accept nested `sets` array, write child rows
-- ============================================================================
-- LIVE-SOURCED bodies preserved column-for-column. Drops legacy columns from
-- the INSERT list. Adds a child-rows INSERT for exercise_sets. Wrapped in
-- the same membership + plan_id-match guard as the live body.
--
-- Input shape (per element of p_rows):
--   {
--     id, position, name, media_url, thumbnail_url, media_type,
--     notes, circuit_id, include_audio, preferred_treatment, prep_seconds,
--     video_reps_per_loop, start_offset_ms, end_offset_ms,
--     aspect_ratio, rotation_quarters, body_focus,
--     sets: [
--       { position, reps, hold_seconds, weight_kg, breather_seconds_after },
--       ...
--     ]
--   }
--
-- For media_type='rest', `sets` may be null/empty/absent — no child rows
-- are written. For media_type IN ('video','photo'), if `sets` is missing or
-- empty the function inserts a single default row (reps=1, hold=0, weight
-- NULL, breather=60) so the exercise is still playable. (This matches the
-- backfill default and prevents a silently broken plan after an upsert that
-- forgot to populate `sets`.)
--
-- RETURN TYPE CHANGE: live function returns void; this wave returns jsonb.
-- Postgres `CREATE OR REPLACE FUNCTION` cannot change return type, so we
-- DROP first. No callers depend on the void return today (verified via
-- prosrc grep: no other RPC invokes replace_plan_exercises). Mobile
-- ApiClient will be updated in Phase 2 to read the new return.
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
      NULLIF(r->>'body_focus', '')::boolean
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
    -- callers) playable instead of silently empty. The exercise IDs that
    -- triggered this path are captured into v_fallback_ids and surfaced in
    -- the return jsonb so the caller can warn the user (defence-in-depth —
    -- the new client always sends `sets`; this only fires from stale
    -- TestFlight builds or buggy callers).
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

  -- Read current plan version for the return payload. Live function does
  -- not bump version here (that happens elsewhere in the publish flow);
  -- we surface whatever the plan currently carries so the caller has a
  -- useful number to log / display.
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

-- Permissions match the existing grant pattern (replace_plan_exercises is
-- called from the publish flow; only authenticated callers).
REVOKE EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) TO authenticated;

-- ============================================================================
-- 7. get_plan_full — emit per-exercise `sets` array
-- ============================================================================
-- LIVE-SOURCED body. Adds a `sets` jsonb array on each exercise dict.
-- Preserves every existing per-exercise key:
--   line_drawing_url, grayscale_url, original_url,
--   grayscale_segmented_url, original_segmented_url, mask_url,
--   plus every column on `exercises` via to_jsonb(e).
-- Plan-level keys unchanged (`plan` carries to_jsonb(plan_row)).
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
                    -- NEW: per-set PLAN rows. Empty array for rest exercises
                    -- and for any video/photo exercise that has no child rows
                    -- (shouldn't happen post-backfill, but degrade safely).
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
                      )
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
-- 1. exercise_sets row count and shape:
--   SELECT COUNT(*) AS total_sets,
--          COUNT(DISTINCT exercise_id) AS exercises_with_sets
--     FROM public.exercise_sets;
--
-- 2. Per-exercise integrity — every video/photo should have ≥ 1 set:
--   SELECT e.id, e.media_type, COUNT(s.id) AS set_count
--     FROM public.exercises e
--     LEFT JOIN public.exercise_sets s ON s.exercise_id = e.id
--    WHERE e.media_type IN ('video','photo')
--    GROUP BY e.id, e.media_type
--   HAVING COUNT(s.id) = 0;
--   -- Should return zero rows.
--
-- 3. Legacy columns gone:
--   SELECT column_name FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='exercises'
--      AND column_name IN ('reps','sets','hold_seconds','inter_set_rest_seconds',
--                          'custom_duration_seconds','rep_duration_seconds',
--                          'set_rest_seconds');
--   -- Should return zero rows.
--
-- 4. JSONB scrub on clients.client_exercise_defaults:
--   SELECT COUNT(*) AS clients_with_legacy_keys
--     FROM public.clients
--    WHERE client_exercise_defaults ?| ARRAY[
--      'reps','sets','hold_seconds','inter_set_rest_seconds','custom_duration_seconds'
--    ];
--   -- Should return 0.
--
-- 5. RLS posture:
--   SELECT polname FROM pg_policies
--    WHERE schemaname='public' AND tablename='exercise_sets';
--   -- exercise_sets_select_member only.
--   SELECT has_table_privilege('authenticated', 'public.exercise_sets', 'INSERT'),
--          has_table_privilege('authenticated', 'public.exercise_sets', 'UPDATE'),
--          has_table_privilege('authenticated', 'public.exercise_sets', 'DELETE');
--   -- All three: false.
--
-- 6. RPC functional smoke test (replace <plan-uuid>):
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid));
--   -- Should include 'sets' array per exercise.
--
-- 7. Function signatures — replace_plan_exercises return-type CHANGED.
--   SELECT proname,
--          pg_get_function_identity_arguments(p.oid) AS args,
--          pg_get_function_result(p.oid)             AS returns
--     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public'
--      AND proname IN ('replace_plan_exercises','get_plan_full');
--   -- Expected:
--   --   replace_plan_exercises(p_plan_id uuid, p_rows jsonb) -> jsonb
--   --     (was void; now returns {plan_version, fallback_set_exercise_ids[]})
--   --   get_plan_full(p_plan_id uuid)                       -> jsonb
--
-- 8. Synthetic-fallback smoke test — publish a video/photo exercise without
--    a `sets` array, confirm fallback_set_exercise_ids surfaces it:
--   SELECT public.replace_plan_exercises(
--     '<plan-uuid>'::uuid,
--     '[{"id":"<exercise-uuid>","position":1,"name":"x","media_type":"video"}]'::jsonb
--   );
--   -- Expected: {"plan_version": N, "fallback_set_exercise_ids": ["<exercise-uuid>"]}
