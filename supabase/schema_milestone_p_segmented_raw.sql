-- homefit.studio — Milestone P: segmented-color raw variant
-- =============================================================================
-- Run in Supabase SQL Editor or via `supabase db query --linked --file ...`.
-- Safe to re-run (the function is CREATE OR REPLACE).
--
-- PRE-REQS
--   * Milestone G (three-treatment video) applied. This migration extends the
--     existing `public.get_plan_full(p_plan_id uuid)` function with two
--     additional per-exercise keys — schema, bucket, consent model, signed-
--     URL helper, and storage RLS are unchanged and already in place.
--
-- WHAT THIS MIGRATION DOES
--   Extends `get_plan_full` so each exercise dict additionally carries:
--     - grayscale_segmented_url  text|null — signed raw-archive URL to the
--                                             dual-output segmented-color mp4
--                                             (`*.segmented.mp4`), consent-
--                                             gated on `grayscale`.
--     - original_segmented_url   text|null — same file, consent-gated on
--                                             `original`.
--
--   Both keys point at the SAME physical object in raw-archive at:
--       {practice_id}/{plan_id}/{exercise_id}.segmented.mp4
--
--   The file is written alongside the classic raw-archive original during the
--   native dual-output conversion pass on iOS: Vision person-segmentation
--   computes the body mask ONCE for the line-drawing treatment, and that same
--   mask is reused to composite a segmented-color mp4 where the body is
--   passed through pristine while the background is dimmed via the v7
--   backgroundDim LUT (matches the line-drawing's dimmed backdrop).
--
--   The web player's Color + B&W treatments prefer these URLs over the
--   untouched original so the body-pop effect is consistent across all three
--   treatments. When `grayscale_segmented_url` / `original_segmented_url` is
--   NULL (legacy plans, exercises captured before the dual-output pass, or
--   consent withheld), the client falls through to the pre-existing
--   `grayscale_url` / `original_url` for the untouched original.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT change the consent shape in `clients.video_consent` — same
--     `line_drawing` / `grayscale` / `original` flags gate both the
--     untouched + segmented signed URLs.
--   * Does NOT require the segmented file to exist on raw-archive — the
--     signed URL is a handle only. A 404 on playback degrades to the next
--     fallback (untouched original → line drawing).
--   * Does NOT backfill existing plans. Previously-published plans keep
--     their NULL `*_segmented_url` on re-read until the practitioner
--     re-captures / re-publishes.
-- =============================================================================

BEGIN;

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

  -- Assemble exercises. Four signed URLs per eligible video row:
  --   grayscale_url            → {practice_id}/{plan_id}/{exercise_id}.mp4
  --   original_url             → same object as grayscale_url
  --   grayscale_segmented_url  → {practice_id}/{plan_id}/{exercise_id}.segmented.mp4
  --   original_segmented_url   → same object as grayscale_segmented_url
  --
  -- The segmented signed URLs are emitted opportunistically — the signing
  -- helper doesn't check for object existence, so callers must tolerate a
  -- 404 on playback and fall through to the non-segmented URL. This keeps
  -- the RPC a single pass and avoids an O(N) head-object probe per plan.
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

COMMIT;

-- ============================================================================
-- Verification — run via `supabase db query --linked`
-- ============================================================================
-- 1. Check the function body now includes the new keys:
--   SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = 'get_plan_full'
--      AND 'grayscale_segmented_url' = ANY(string_to_array(prosrc, ''''));
--
-- 2. Sample call on a real plan:
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid));
--
-- 3. Inspect a single exercise's treatment URLs:
--   WITH r AS (SELECT public.get_plan_full('<plan-uuid>'::uuid) AS p)
--   SELECT jsonb_pretty(r.p -> 'exercises' -> 0) FROM r;
