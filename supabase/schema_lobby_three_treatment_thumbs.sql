-- Wave Three-Treatment-Thumbs (2026-05-05)
--
-- Extends `public.get_plan_full(p_plan_id uuid)` to return per-exercise:
--   * thumbnail_url_line  — public URL to the line-drawing JPG
--                            (`{plan_id}/{exercise_id}_thumb_line.jpg`
--                            in the `media` bucket).
--   * thumbnail_url_color — signed URL to the color JPG
--                            (`{practice_id}/{plan_id}/{exercise_id}_thumb_color.jpg`
--                            in the `raw-archive` bucket). Consent-gated:
--                            returned when `video_consent.grayscale` OR
--                            `video_consent.original` is true. CSS
--                            grayscale(1) filter renders the B&W variant
--                            from the same source on the client.
--
-- The existing `thumbnail_url` column (B&W from raw) stays unchanged for
-- backward compat — the web player falls back to it when the new fields
-- are NULL (older plans not yet republished).
--
-- This migration is ADDITIVE — no schema changes, just an RPC update.
-- Falls back gracefully on plans where the new files weren't uploaded
-- (web player gets URLs that 404; <img> rendering fails to skeleton).
--
-- Mirrors the photo three-treatment pattern (Wave 22) where a single
-- color source serves both Color and B&W via CSS filter.

CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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

  -- Assemble exercises. Three-treatment thumbs added to the per-exercise
  -- jsonb. URLs reconstructed from convention paths (no schema columns):
  --   line  → `media/{plan_id}/{exercise_id}_thumb_line.jpg` (public URL)
  --   color → `raw-archive/{practice_id}/{plan_id}/{exercise_id}_thumb_color.jpg`
  --           (signed URL via sign_storage_url, consent-gated).
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
                        ELSE NULL
                      END,
                    -- Three-treatment thumbnails (Wave 2026-05-05).
                    'thumbnail_url_line',
                      CASE
                        WHEN e.media_type = 'video'
                        THEN 'https://yrwcofhovrcydootivjx.supabase.co/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_line.jpg'
                        ELSE NULL
                      END,
                    'thumbnail_url_color',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok)
                          AND e.media_type = 'video'
                          AND plan_row.practice_id IS NOT NULL
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
$fn$;

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;
