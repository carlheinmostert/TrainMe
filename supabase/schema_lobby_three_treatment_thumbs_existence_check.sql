-- Wave Three-Treatment-Thumbs — existence-check fix (2026-05-05)
--
-- The first cut of `get_plan_full` (schema_lobby_three_treatment_thumbs.sql)
-- constructed `_thumb_line.jpg` + `_thumb_color.jpg` URLs for EVERY video
-- exercise, regardless of whether the practitioner had actually uploaded
-- those JPGs. Plans published before PR #263 (the upload pass that writes
-- the new variants) have only the legacy `_thumb.jpg` in storage — so the
-- speculative URLs 404 and the lobby renders the broken-image glyph
-- (Carl's "question mark placeholder", 2026-05-05).
--
-- Fix: existence-check `storage.objects` before returning a URL. A row in
-- storage.objects only exists when the file was successfully uploaded;
-- absence → return NULL → web player falls back to the legacy
-- `thumbnail_url` (B&W from raw, always present on any published plan).
--
-- Trade-off: two more index-scoped lookups per video exercise. Negligible
-- vs. the 13 RLS / signed-URL ops `get_plan_full` already does.

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
$fn$;

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;
