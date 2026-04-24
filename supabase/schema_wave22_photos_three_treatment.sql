-- ============================================================================
-- Wave 22 — photo three-treatment parity with videos
-- ============================================================================
--
-- Carl's framing: "a photo is just a video with one frame". Today
-- `get_plan_full` only emits `grayscale_url` / `original_url` for
-- `media_type = 'video'`; photos always get NULL on those keys, which
-- makes the web player's "Show me" segmented control disable Colour +
-- B&W on every photo slide regardless of consent. The line-drawing JPG
-- (e.g. `{exercise_id}_line.jpg`) is shipping in the public `media`
-- bucket via `media_url`, so the only thing missing is the raw colour
-- JPG path + signed URL.
--
-- The mobile upload (sister change in this wave) also lands the raw
-- colour JPG into the existing PRIVATE `raw-archive` bucket at:
--   `{practice_id}/{plan_id}/{exercise_id}.jpg`
--
-- Same bucket and same RLS as the videos — only the file extension and
-- mime differ. The grayscale treatment shares the same storage object
-- as the original (the web player applies CSS `filter: grayscale(1)
-- contrast(1.05)` on the <img>, mirroring the existing `video.is-grayscale`
-- rule). No second file.
--
-- This migration:
--   1. Re-defines `public.get_plan_full(uuid)` so the per-exercise CASE
--      branches BOTH videos AND photos:
--        * videos keep the existing `.mp4` paths (incl. the segmented +
--          mask sidecars) — zero behaviour change for videos.
--        * photos add the same `grayscale_url` + `original_url` keys
--          pointing at the `.jpg` raw-archive object, gated by the
--          same `video_consent.{grayscale,original}` flags.
--      Photos do NOT emit `grayscale_segmented_url`, `original_segmented_url`,
--      or `mask_url` — those are video-specific (Vision person-segmentation
--      mask only runs on the video pipeline). They stay NULL for photos.
--   2. `line_drawing_url` for photos continues to come straight from
--      `media_url` (the public-bucket line-drawing JPG already shipped),
--      so legacy photo plans keep working — only the Colour / B&W
--      segments get unlocked on republish + consent.
--
-- Rollback: re-apply `schema_milestone_g_three_treatment.sql` (and any
-- subsequent get_plan_full overrides — most recently the segmented +
-- mask sidecar pass) to restore video-only behaviour. Photos go back
-- to NULL on grayscale/original which the web player handles
-- gracefully (Colour + B&W segments grey out).
--
-- Backwards compatibility:
--   * Legacy photos with no raw .jpg on the bucket: `sign_storage_url`
--     hands back a signed URL anyway (no head-object probe), and the
--     web player's <img onerror=…> fallback collapses Colour / B&W back
--     to the line drawing. Acceptable for v1; a future tightening could
--     skip signing if the object isn't there, but that's an O(N) cost
--     per get_plan_full call.
--   * Plans with no client_id (legacy pre-R-11 publishes): unchanged —
--     they fall through to the default consent shape and only see
--     `line_drawing_url`. Photos there stay line-only.
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
  --   PHOTOS  (media_type = 'photo')                         [Wave 22]
  --     line_drawing_url         → media_url (line-drawing JPG, public bucket)
  --     grayscale_url            → {practice_id}/{plan_id}/{exercise_id}.jpg
  --                                (raw colour JPG; web player applies CSS
  --                                grayscale filter at playback time)
  --     original_url             → same object as grayscale_url
  --     grayscale_segmented_url  → NULL (photo pipeline has no Vision mask)
  --     original_segmented_url   → NULL
  --     mask_url                 → NULL
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
--   -- Verify the RPC now emits grayscale_url + original_url for photos
--   -- when the linked client has consented:
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid)
--            -> 'exercises');
--   -- Expect: each photo dict has line_drawing_url + (if consent)
--   -- non-null grayscale_url + original_url; segmented + mask stay NULL.
--
--   -- Negative test: revoke original consent on the client, re-call:
--   --   SELECT public.set_client_video_consent('<client>'::uuid, true, true, false);
--   -- Expect: photo dicts have original_url=NULL, grayscale_url still
--   -- populated (grayscale flag still on).
-- ============================================================================
