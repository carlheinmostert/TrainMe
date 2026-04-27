-- ============================================================================
-- Wave 36 — photo body-focus segmented variant URLs in get_plan_full
-- ============================================================================
--
-- Wave 22 wired three-treatment for photos (line / B&W / Original) but never
-- shipped a segmented variant — only the line drawing JPG and the raw colour
-- JPG. Wave 30 built the segmentation pipeline for client AVATARS in
-- `ClientAvatarProcessor` (Vision person-segmentation + vImage Gaussian
-- blur composite, output PNG). Wave 34 wired the Body Focus pill on the
-- exercise photo preview chrome — but toggling it did NOTHING visually
-- because no segmented JPG existed.
--
-- Wave 36's mobile change reuses `ClientAvatarProcessor` (encoded as JPEG)
-- to produce `<exercise_id>.segmented.jpg` during photo conversion. This
-- migration extends `get_plan_full` so the web player + mobile preview
-- can flip to that segmented JPG when the body-focus toggle is on.
--
-- The schema's `exercises.segmented_raw_file_path` column is reused — for
-- videos it stores `.segmented.mp4`, for photos it stores `.segmented.jpg`.
-- No new column needed; only the RPC's signed-URL path needs to learn one
-- new suffix.
--
-- This migration:
--   1. Re-defines `public.get_plan_full(uuid)` so the per-exercise CASE
--      branches for `grayscale_segmented_url` and `original_segmented_url`
--      now ALSO emit a signed URL for photos at:
--        `{practice_id}/{plan_id}/{exercise_id}.segmented.jpg`
--
--      Videos keep emitting `.segmented.mp4` (unchanged from Wave 22).
--      The `mask_url` field stays video-only — photos have no mask sidecar
--      (the segmentation runs on a single still, not a frame stream;
--      there's no playback-time consumer for a photo mask sidecar today).
--   2. Photos with no segmented JPG on the bucket fall through gracefully:
--      the web player's `resolveTreatmentUrl` already prefers
--      `*_segmented_url` but falls back to `*_url` when the segmented
--      variant is null OR fails to load. So legacy photos without a
--      segmented variant still render correctly via the untouched
--      original.
--
-- Rollback: re-apply `schema_wave22_photos_three_treatment.sql` to revert
-- the photo segmented signing branch. Mobile + web both handle null
-- gracefully — body-focus toggle becomes a no-op for photos again, which
-- is the pre-Wave-36 behaviour.
-- ============================================================================

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
  -- Stamp first_opened_at atomically on first fetch.
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

  -- Resolve consent. Default = line-drawing only.
  IF plan_row.client_id IS NOT NULL THEN
    SELECT video_consent INTO v_consent
      FROM clients WHERE id = plan_row.client_id LIMIT 1;
  END IF;

  IF v_consent IS NULL THEN
    v_consent := '{"line_drawing": true, "grayscale": false, "original": false}'::jsonb;
  END IF;

  v_gray_ok := COALESCE((v_consent ->> 'grayscale')::boolean, false);
  v_orig_ok := COALESCE((v_consent ->> 'original')::boolean, false);

  -- Assemble exercises. Per-exercise treatment URLs:
  --
  --   VIDEOS  (media_type = 'video')
  --     line_drawing_url         → media_url (public bucket, always)
  --     grayscale_url            → {practice_id}/{plan_id}/{exercise_id}.mp4
  --     original_url             → same object as grayscale_url
  --     grayscale_segmented_url  → {practice_id}/{plan_id}/{exercise_id}.segmented.mp4
  --     original_segmented_url   → same as grayscale_segmented_url
  --     mask_url                 → {practice_id}/{plan_id}/{exercise_id}.mask.mp4
  --                                (consent-gated on grayscale OR original)
  --
  --   PHOTOS  (media_type = 'photo')
  --     line_drawing_url         → media_url (line-drawing JPG, public bucket)
  --     grayscale_url            → {practice_id}/{plan_id}/{exercise_id}.jpg
  --                                (Wave 22 — raw colour JPG; web player
  --                                applies CSS grayscale filter at playback)
  --     original_url             → same object as grayscale_url
  --     grayscale_segmented_url  → {practice_id}/{plan_id}/{exercise_id}.segmented.jpg
  --                                (Wave 36 — Vision-segmented + Gaussian
  --                                blur composite JPG; same body-pop look
  --                                as videos)
  --     original_segmented_url   → same as grayscale_segmented_url
  --     mask_url                 → NULL (photo pipeline has no mask sidecar)
  --
  -- The signed URLs are emitted opportunistically — sign_storage_url
  -- doesn't probe for object existence, so callers must tolerate a 404
  -- on playback and fall through to the line drawing.
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

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;

-- ============================================================================
-- Smoke test (run manually after apply against a known plan id):
--
--   -- Pick a plan that has a photo exercise:
--   SELECT id, media_type FROM exercises
--    WHERE plan_id = '<plan-uuid>'::uuid ORDER BY position;
--
--   -- Verify the RPC now emits grayscale_segmented_url +
--   -- original_segmented_url for photos when the linked client has consented:
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid)
--            -> 'exercises');
--   -- Expect: each photo dict has line_drawing_url + (if consent)
--   -- non-null grayscale_url + original_url + grayscale_segmented_url +
--   -- original_segmented_url. mask_url stays NULL for photos.
-- ============================================================================
