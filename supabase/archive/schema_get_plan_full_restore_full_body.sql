-- Wave Restore-Full-Body (2026-05-05)
--
-- ROOT CAUSE: PR #263 (`schema_lobby_three_treatment_thumbs.sql`) and
-- PR #266 (`schema_lobby_three_treatment_thumbs_existence_check.sql`)
-- were both authored as fresh `CREATE OR REPLACE FUNCTION public.get_plan_full(...)`
-- bodies WITHOUT sourcing the previous live function definition first.
-- That dropped EVERY field added by prior migrations:
--
--   * `sets` (per-set jsonb array from `exercise_sets` — Wave per-set-dose).
--     Direct cause of "weight grammar not showing" on the lobby — the web
--     player reads `slide.sets[]` and my migration removed it.
--   * `grayscale_segmented_url`, `original_segmented_url`, `mask_url`
--     (Wave 36 photo segmented + body-focus dual-video).
--   * Photo branches in `grayscale_url` / `original_url` (Wave 22 photo
--     three-treatment parity).
--   * `rest_seconds` field on each exercise.
--
-- This migration restores the full Wave 43 body and ADDS the existence-
-- checked `thumbnail_url_line` / `thumbnail_url_color` (Wave Three-
-- Treatment-Thumbs from PR #263, hardened in PR #266).
--
-- Locked-in lesson (already in feedback memory): always source the prior
-- function body via `pg_get_functiondef('public.get_plan_full(uuid)'::regprocedure)`
-- BEFORE writing a new CREATE OR REPLACE.

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
                    'rest_seconds', e.rest_seconds,
                    -- Three-treatment thumbnails (Wave 2026-05-05).
                    -- Existence-checked against storage.objects so older
                    -- plans (pre-PR #263) get NULL → legacy fallback in the
                    -- web player, not 404 → broken-image glyph.
                    'thumbnail_url_line',
                      CASE
                        WHEN e.media_type = 'video'
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'media'
                               AND o.name = plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_line.jpg'
                          )
                        THEN 'https://yrwcofhovrcydootivjx.supabase.co/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_line.jpg'
                        ELSE NULL
                      END,
                    'thumbnail_url_color',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok)
                          AND e.media_type = 'video'
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

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;
