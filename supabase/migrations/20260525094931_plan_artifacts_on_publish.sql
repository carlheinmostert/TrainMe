-- ============================================================================
-- Self-trainer wave — PR #7: plan_artifacts write on publish
--                           + get_plan_full extension
-- 2026-05-25 — feat/plan-artifacts-write
--
-- Spec:  docs/SELF_TRAINER_WAVE.md § Publish flow changes
-- ADR:   docs/adr/0022-plan-artifacts-abstraction-before-reel.md
-- Brief: docs/sub-agent-briefs/07-plan-artifacts-write.md
-- Depends on: PR #1 (supabase/migrations/20260525074056_self_trainer_wave.sql)
--             which created the plan_artifacts table.
--
-- Two RPC extensions, both `CREATE OR REPLACE FUNCTION`:
--
--   1. public.consume_credit(uuid, uuid, integer)
--      - Carry forward every existing branch + return shape (prepaid unlock
--        fast path, treatment-consent backstop, insufficient-credits return,
--        normal debit). NO existing behaviour changes.
--      - Add: after a successful debit OR after a prepaid-unlock consumption,
--        upsert one plan_artifacts row (kind='plan_url', status='ready',
--        generated_at=now()). Inside the same transaction.
--      - The upsert handles republishes (same plan, same kind) — generated_at
--        and status are refreshed on conflict.
--
--   2. public.get_plan_full(uuid)
--      - Carry forward every existing field of the returned jsonb (plan {
--        ...to_jsonb(plans) + brand_color + public_logo_url + practice_name },
--        exercises [ per-exercise sets, treatment URLs, mask, thumbnails ]).
--      - Add: top-level `artifacts` array carrying the plan_artifacts rows
--        for the requested plan_id. For kind='plan_url' the output_url is
--        intentionally NULL (URL is computed client-side as
--        session.homefit.studio/p/{plan_id}); future kinds (reel, pdf) will
--        populate output_url with a signed URL.
--
-- Hard rules followed:
--   * Repo-relative paths only in commentary.
--   * Live signatures fetched via pg_get_functiondef before authoring
--     (feedback_schema_migration_column_preservation):
--       - consume_credit: kept all 5 inputs branches (auth check, practice
--         membership check, consent backstop, prepaid fast path,
--         insufficient-credits, normal debit) + both jsonb return shapes
--         (ok+new_balance+prepaid_unlock_at on fast path; ok+new_balance on
--         normal debit; ok=false+reason+balance on insufficient).
--       - get_plan_full: kept every key in the jsonb_build_object (plan {
--         to_jsonb(plan_row) merged with brand_color/public_logo_url/
--         practice_name }, exercises [per-exercise normalised with
--         line_drawing_url, grayscale_url, original_url, grayscale_segmented_url,
--         original_segmented_url, mask_url, sets, rest_seconds,
--         thumbnail_url_line, thumbnail_url_color, thumbnail_url_bw, plus
--         all to_jsonb(e) columns]). The plan_row UPDATE…first_opened_at side
--         effect is preserved.
--   * Anonymous read continues to be the single enumerated surface
--     (docs/DATA_ACCESS_LAYER.md): anon reads plan_artifacts ONLY through
--     get_plan_full; direct SELECT remains blocked by the RLS policy that
--     PR #1 installed.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. consume_credit — write plan_artifacts row inside the same transaction
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.consume_credit(
  p_practice_id uuid,
  p_plan_id     uuid,
  p_credits     integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_balance      integer;
  v_new_balance  integer;
  v_prepaid_at   timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'consume_credit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'consume_credit: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_credits IS NULL OR p_credits <= 0 THEN
    RAISE EXCEPTION 'consume_credit: p_credits must be positive (got %)', p_credits
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'consume_credit: caller % is not a member of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- SEC-2 (C-2 / restore Milestone V): publish-time consent backstop.
  -- Runs BEFORE both the prepaid-unlock fast path and the normal
  -- credit-burn branch so a malformed plan can never burn a credit
  -- (or consume a prepaid unlock) with treatments the client hasn't
  -- consented to. validate_plan_treatment_consent is SECURITY DEFINER
  -- and membership-checks internally, so this is safe to call without
  -- additional guarding here.
  IF p_plan_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.validate_plan_treatment_consent(p_plan_id)
  ) THEN
    RAISE EXCEPTION
      'consume_credit: plan % has exercises with unconsented treatments', p_plan_id
      USING ERRCODE = 'P0003';
  END IF;

  PERFORM 1 FROM practices WHERE id = p_practice_id FOR UPDATE;

  SELECT unlock_credit_prepaid_at
    INTO v_prepaid_at
    FROM plans
   WHERE id = p_plan_id
     AND practice_id = p_practice_id
   FOR UPDATE;

  IF v_prepaid_at IS NOT NULL THEN
    UPDATE plans
       SET unlock_credit_prepaid_at = NULL,
           first_opened_at          = NULL,
           last_opened_at           = NULL
     WHERE id = p_plan_id;

    SELECT COALESCE(SUM(delta), 0)::integer
      INTO v_balance
      FROM credit_ledger
     WHERE practice_id = p_practice_id;

    -- PR #7 — plan_artifacts write on publish. Same transaction.
    -- Upsert handles republishes (one row per (plan_id, kind), refresh
    -- generated_at and re-stamp status='ready'). The 'plan_url' kind has
    -- output_url=NULL on purpose; URL is computed client-side.
    IF p_plan_id IS NOT NULL THEN
      INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at)
      VALUES (p_plan_id, 'plan_url', 'ready', now())
      ON CONFLICT (plan_id, kind) DO UPDATE
        SET generated_at = now(),
            status       = 'ready';
    END IF;

    RETURN jsonb_build_object(
      'ok',                true,
      'new_balance',       v_balance,
      'prepaid_unlock_at', v_prepaid_at
    );
  END IF;

  SELECT COALESCE(SUM(delta), 0)::integer
    INTO v_balance
    FROM credit_ledger
   WHERE practice_id = p_practice_id;

  IF v_balance < p_credits THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'reason',  'insufficient_credits',
      'balance', v_balance
    );
  END IF;

  -- Wave 40.5: stamp trainer_id on the consumption ledger row.
  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes, trainer_id)
  VALUES (
    p_practice_id,
    -p_credits,
    'consumption',
    p_plan_id,
    'consume_credit(' || p_credits::text || ')',
    v_caller
  );

  v_new_balance := v_balance - p_credits;

  -- PR #7 — plan_artifacts write on publish. Same transaction.
  -- See comment on the prepaid-unlock branch above for rationale.
  IF p_plan_id IS NOT NULL THEN
    INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at)
    VALUES (p_plan_id, 'plan_url', 'ready', now())
    ON CONFLICT (plan_id, kind) DO UPDATE
      SET generated_at = now(),
          status       = 'ready';
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance
  );
END;
$function$;

COMMENT ON FUNCTION public.consume_credit(uuid, uuid, integer) IS
  'Atomic credit consumption + plan_artifacts row write (PR #7). '
  'Membership-checked, treatment-consent backstopped, prepaid-unlock-aware. '
  'Every successful debit (or prepaid-unlock consumption) upserts one '
  'plan_artifacts(plan_id, kind=''plan_url'', status=''ready'') row in the '
  'same transaction. See docs/SELF_TRAINER_WAVE.md § Publish flow changes '
  'and docs/adr/0022-plan-artifacts-abstraction-before-reel.md.';

-- ---------------------------------------------------------------------------
-- 2. get_plan_full — top-level `artifacts` array added
-- ---------------------------------------------------------------------------
-- Everything below the artifacts addition is byte-for-byte identical to the
-- live RPC body fetched via pg_get_functiondef on 2026-05-25 from staging
-- (vadjvkmldtoeyspyoqbx). The single addition is the v_artifacts subquery
-- and its inclusion as a top-level key in the returned jsonb_build_object.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  plan_row          plans;
  v_consent         jsonb;
  v_gray_ok         boolean;
  v_orig_ok         boolean;
  v_base_url        text;
  exes              jsonb;
  -- V2 additions:
  v_brand_color     text;
  v_public_logo_url text;
  v_practice_name   text;
  -- PR #7 addition: plan_artifacts rows for this plan.
  v_artifacts       jsonb;
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
  -- return per-branch thumbnail URLs.
  SELECT decrypted_secret INTO v_base_url
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_url'
   LIMIT 1;

  -- V2 — practice branding lookup. Anon-readable: brand_color and
  -- public_logo_url are already public via /v/{slug}; surfacing them
  -- here just saves a round-trip. Always populated regardless of
  -- public_profile_listed because the player only renders branding for
  -- the practice that owns the plan, not for directory discovery.
  IF plan_row.practice_id IS NOT NULL THEN
    SELECT pr.brand_color, pr.public_logo_url, pr.name
      INTO v_brand_color, v_public_logo_url, v_practice_name
      FROM practices pr
     WHERE pr.id = plan_row.practice_id
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

  -- PR #7 — plan_artifacts surface. NULL-safe: a plan with zero rows in
  -- plan_artifacts (which should never happen post-backfill, but defensive)
  -- returns an empty array, not NULL. RLS is bypassed because get_plan_full
  -- is SECURITY DEFINER; anon callers reach this code path only via the RPC.
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'kind',         a.kind,
               'status',       a.status,
               'output_url',   a.output_url,
               'generated_at', a.generated_at,
               'metadata',     a.metadata
             )
             ORDER BY a.generated_at DESC
           ),
           '[]'::jsonb
         )
    INTO v_artifacts
    FROM public.plan_artifacts a
   WHERE a.plan_id = p_plan_id;

  -- V2 — merge practice branding into the top-level `plan` object so
  -- the web player + lobby JS can read them via plan.brand_color etc.
  -- All three values may be NULL; the player has been updated to
  -- handle each independently.
  -- PR #7 — `artifacts` is a NEW top-level sibling of `plan` and
  -- `exercises`. Always present; empty array when the backfill missed
  -- a row or for a brand-new plan that has not yet been published.
  RETURN jsonb_build_object(
    'plan',
      to_jsonb(plan_row)
        || jsonb_build_object(
             'brand_color',     v_brand_color,
             'public_logo_url', v_public_logo_url,
             'practice_name',   v_practice_name
           ),
    'exercises', exes,
    'artifacts', v_artifacts
  );
END;
$function$;

COMMENT ON FUNCTION public.get_plan_full(uuid) IS
  'Anonymous plan read RPC. Returns jsonb { plan, exercises, artifacts }. '
  'Plan: to_jsonb(plans) + brand_color + public_logo_url + practice_name. '
  'Exercises: per-row treatment URLs, mask, segmented variants, sets, '
  'thumbnails. Artifacts (PR #7): plan_artifacts rows for this plan, '
  'ordered by generated_at DESC. SECURITY DEFINER — single anon surface '
  'per docs/DATA_ACCESS_LAYER.md.';

COMMIT;
