-- homefit.studio — Milestone P2: person-segmentation mask sidecar
-- =============================================================================
-- Run in Supabase SQL Editor or via `supabase db query --linked --file ...`.
-- Safe to re-run (the function is CREATE OR REPLACE).
--
-- PRE-REQS
--   * Milestone P (segmented-color raw variant) applied. This migration
--     extends `public.get_plan_full(p_plan_id uuid)` with one additional
--     per-exercise key; the `raw-archive` bucket, signed-URL helper, consent
--     model, and storage RLS are all unchanged from Milestone G / P.
--
-- WHAT THIS MIGRATION DOES
--   Extends `get_plan_full` so each video exercise dict additionally carries:
--     - mask_url  text|null — signed raw-archive URL to the Vision person-
--                              segmentation mask mp4 (`*.mask.mp4`), consent-
--                              gated on (grayscale OR original). The mask is
--                              useless without at least one of the two body
--                              treatments consented, so both rails open the
--                              gate.
--
--   The URL points at:
--       {practice_id}/{plan_id}/{exercise_id}.mask.mp4
--
--   The file is a grayscale H.264 mp4 produced by a THIRD AVAssetWriter in
--   the native iOS dual-output pass. It's the same `VNPixelBufferObservation`
--   the line-drawing + segmented composites already consume — written out
--   once per frame, pixel-perfect aligned with the segmented-colour mp4 at
--   `{...}.segmented.mp4`. The mask has NO consumer today (insurance for
--   future playback-time compositing — we commit to storing it now so we
--   can build tunable backgroundDim / other effects later without needing
--   to re-capture existing plans).
--
--   The web player passes `mask_url` through to the front-end but does
--   nothing with it yet. app.js is deliberately untouched.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT change the consent shape in `clients.video_consent` — same
--     `line_drawing` / `grayscale` / `original` flags. The mask rides
--     alongside grayscale + original; granting either unlocks the mask URL.
--   * Does NOT require the mask file to exist on raw-archive — the signed
--     URL is a handle only. Callers must tolerate a 404 on playback.
--   * Does NOT backfill existing plans. Previously-published plans keep
--     their NULL `mask_url` on re-read until the practitioner re-captures
--     / re-publishes against a build with the v7.2 dual-output+mask pass.
--   * Does NOT add playback-side compositing. Today the key is emitted
--     and web-player/api.js normalises it to null-or-present. app.js is
--     not touched.
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

  -- Assemble exercises. Five signed URLs per eligible video row:
  --   grayscale_url            → {practice_id}/{plan_id}/{exercise_id}.mp4
  --   original_url             → same object as grayscale_url
  --   grayscale_segmented_url  → {practice_id}/{plan_id}/{exercise_id}.segmented.mp4
  --   original_segmented_url   → same object as grayscale_segmented_url
  --   mask_url                 → {practice_id}/{plan_id}/{exercise_id}.mask.mp4
  --                              (consent-gated on grayscale OR original; the
  --                              mask is insurance for future playback-time
  --                              compositing, so any body-treatment consent
  --                              unlocks it)
  --
  -- The signed URLs are emitted opportunistically — the signing helper
  -- doesn't check for object existence, so callers must tolerate a 404
  -- on playback and fall through to the non-segmented / non-masked URL.
  -- This keeps the RPC a single pass and avoids an O(N) head-object
  -- probe per plan.
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
$fn$;

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;

COMMIT;

-- ============================================================================
-- Verification — run via `supabase db query --linked`
-- ============================================================================
-- 1. Check the function body now includes the new key:
--   SELECT CASE WHEN prosrc ~ 'mask_url' THEN 'applied' ELSE 'missing' END AS status
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = 'get_plan_full';
--
-- 2. Sample call on a real plan:
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid));
--
-- 3. Inspect a single exercise's treatment URLs:
--   WITH r AS (SELECT public.get_plan_full('<plan-uuid>'::uuid) AS p)
--   SELECT jsonb_pretty(r.p -> 'exercises' -> 0) FROM r;
