-- get_plan_full — add `referral_code` to the returned plan object.
-- =====================================================================
--
-- The Printable Workout Guide (/h/{planId}) footer renders a real QR
-- pointing at the practitioner's referral landing page
-- (https://manage.homefit.studio/r/{referral_code}). The web player's
-- only anon surface is `get_plan_full`, so the code has to ride on the
-- existing payload — same pattern as the brand-skin fields
-- (brand_color / public_logo_url / practice_name) added in
-- 20260526184005_brand_skin_subscription.sql.
--
-- SENSITIVE RPC: get_plan_full is SECURITY DEFINER and anon-callable. The
-- live definition was sourced via pg_get_functiondef on the STAGING
-- project (vadjvkmldtoeyspyoqbx) and is carried forward UNCHANGED below;
-- the ONLY delta is the `referral_code` key appended to the plan object
-- in the final jsonb_build_object. Every existing key/column is preserved
-- (per feedback_schema_migration_column_preservation.md). `preferred_treatment`
-- on each exercise + `circuit_names` / `version` on the plan continue to
-- flow through unchanged via to_jsonb(e) / to_jsonb(plan_row).
--
-- The referral code is the practice's single non-revoked slug from
-- `referral_codes`. NULL when the practice has none — the handout hides
-- the QR gracefully in that case. The lookup mirrors the existing brand
-- fields' practice-scoped projection (LIMIT 1, no extra round-trip).

CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  plan_row             plans;
  v_consent            jsonb;
  v_gray_ok            boolean;
  v_orig_ok            boolean;
  v_base_url           text;
  exes                 jsonb;
  v_brand_color        text;
  v_public_logo_url    text;
  v_practice_name      text;
  v_artifacts          jsonb;
  v_brand_skin_active  boolean := false;
  v_referral_code      text;
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

  SELECT decrypted_secret INTO v_base_url
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_url'
   LIMIT 1;

  IF plan_row.practice_id IS NOT NULL THEN
    SELECT pr.brand_color, pr.public_logo_url, pr.name
      INTO v_brand_color, v_public_logo_url, v_practice_name
      FROM practices pr
     WHERE pr.id = plan_row.practice_id
     LIMIT 1;
    v_brand_skin_active := public.practice_has_active_brand_skin(plan_row.practice_id);

    -- Printable Workout Guide footer QR: the practice's single
    -- non-revoked referral slug. NULL when the practice has none.
    SELECT rc.code INTO v_referral_code
      FROM referral_codes rc
     WHERE rc.practice_id = plan_row.practice_id
       AND rc.revoked_at IS NULL
     LIMIT 1;
  END IF;

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
                      END,
                    'thumbnail_url_bw',
                      CASE
                        WHEN e.media_type = 'photo'
                          AND v_base_url IS NOT NULL
                          AND length(v_base_url) > 0
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'media'
                               AND o.name = plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_bw.jpg'
                          )
                        THEN rtrim(v_base_url, '/') ||
                             '/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_bw.jpg'
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

  -- R1-M4 + Wave 1 artifact-system extension: whitelisted projection.
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'kind',             a.kind,
               'status',           a.status,
               'generated_at',     a.generated_at,
               'published_at',     a.published_at,
               'first_opened_at',  a.first_opened_at
             )
             ORDER BY a.generated_at DESC
           ),
           '[]'::jsonb
         )
    INTO v_artifacts
    FROM public.plan_artifacts a
   WHERE a.plan_id = p_plan_id;

  RETURN jsonb_build_object(
    'plan',
      to_jsonb(plan_row)
        || jsonb_build_object(
             'brand_color',        v_brand_color,
             'public_logo_url',    v_public_logo_url,
             'practice_name',      v_practice_name,
             'brand_skin_active',  v_brand_skin_active,
             'referral_code',      v_referral_code
           ),
    'exercises', exes,
    'artifacts', v_artifacts
  );
END;
$function$;
