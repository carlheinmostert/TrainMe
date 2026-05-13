-- Bundle 2b (Audit PR 6) — Photo three-treatment thumbnail variant pipeline.
--
-- Extends `get_plan_full` so `thumbnail_url_line` and `thumbnail_url_color`
-- are emitted for PHOTO exercises too, mirroring the video-only behaviour
-- shipped in 2026-05-12 (env-aware thumb_line migration). The conversion
-- service photo branch now produces a symmetric trio of thumbnail files:
--
--   * `{id}_thumb.jpg`       — B&W (canonical practitioner thumb).
--   * `{id}_thumb_color.jpg` — raw colour (uploaded to raw-archive).
--   * `{id}_thumb_line.jpg`  — line-drawing (uploaded to media bucket).
--
-- Upload paths match the video pipeline exactly so the URL synthesis
-- below works without media-type branching beyond the existence checks
-- (which already differ across the public `media` bucket vs the private
-- `raw-archive`).
--
-- POLICY: this migration re-creates `get_plan_full` via CREATE OR REPLACE
-- FUNCTION. Per `feedback_schema_migration_column_preservation.md`, the
-- body below was sourced from the latest migration file
-- (`20260512150219_get_plan_full_env_aware_thumb_line.sql`) which is the
-- most recent CREATE OR REPLACE of this function. The only changes vs
-- that body are:
--
--   1. `thumbnail_url_line` CASE arm — drop the `e.media_type = 'video'`
--      filter so the existence check (storage.objects in bucket `media`)
--      runs for both `'video'` and `'photo'` rows.
--   2. `thumbnail_url_color` CASE arm — same: drop the `'video'` filter.
--
-- All other jsonb_build_object keys, all other CASE arms, and the entire
-- function shape (parameters, return type, SECURITY DEFINER, search_path)
-- are PRESERVED VERBATIM.

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
  v_base_url  text;
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

  -- C5 fix — pull the project base URL from vault so per-branch DBs
  -- return per-branch thumbnail URLs. Use a safe SELECT so a missing
  -- row yields NULL (the CASE arm below treats NULL like "thumbnail
  -- not available" and the web player falls back to the poster frame).
  SELECT decrypted_secret INTO v_base_url
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_url'
   LIMIT 1;

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
                    'rest_seconds', e.rest_seconds,
                    -- Three-treatment thumbnails (Wave 2026-05-05; photo
                    -- parity Bundle 2b 2026-05-13).
                    --
                    -- Existence-checked against storage.objects so older
                    -- plans (pre-PR #263 for videos, pre-Bundle-2b for
                    -- photos) get NULL → legacy fallback in the web
                    -- player, not 404 → broken-image glyph.
                    --
                    -- The media-type filter was dropped in Bundle 2b
                    -- because the photo conversion service now produces
                    -- `_thumb_line.jpg` / `_thumb_color.jpg` alongside
                    -- `_thumb.jpg` in the symmetric naming convention
                    -- videos already used. Same storage paths
                    -- (`{plan}/{exercise}_thumb_line.jpg` in `media`;
                    -- `{practice}/{plan}/{exercise}_thumb_color.jpg` in
                    -- `raw-archive`), same env-aware URL synthesis.
                    -- Existence check is the gate.
                    --
                    -- C5 fix — read the project base URL from
                    -- `v_base_url` (vault.secrets.supabase_url) instead
                    -- of hardcoding the prod project ref. Per-branch
                    -- vault-sync populates each branch's own URL.
                    'thumbnail_url_line',
                      CASE
                        WHEN e.media_type IN ('video', 'photo')
                          AND v_base_url IS NOT NULL
                          AND length(v_base_url) > 0
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'media'
                               AND o.name = plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_line.jpg'
                          )
                        THEN rtrim(v_base_url, '/') ||
                             '/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_line.jpg'
                        ELSE NULL
                      END,
                    'thumbnail_url_color',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok)
                          AND e.media_type IN ('video', 'photo')
                          AND plan_row.practice_id IS NOT NULL
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'raw-archive'
                               AND o.name = plan_row.practice_id::text || '/' ||
                                            plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_color.jpg'
                          )
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '_thumb_color.jpg',
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
