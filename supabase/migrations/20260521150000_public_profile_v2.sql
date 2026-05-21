-- ============================================================================
-- Public Profile v2 — branding columns + widened RPCs
-- ============================================================================
-- Adds practice-level branding (brand_color, tagline, specialties, contact
-- email/whatsapp/website) and widens get_plan_full / get_practice_profile /
-- set_practice_public_profile to read + write them. Adds an owner-side
-- get_practice_profile_owner RPC so the editor doesn't have to hit
-- practices directly (closes the pre-existing feedback_no_direct_db_access
-- violation in web-portal/src/lib/supabase/api.ts).
--
-- Every existing column in each RPC's return shape is preserved verbatim
-- per the schema-migration-column-preservation rule (CLAUDE.md gotchas).
-- Pre-flight signatures captured in docs/notes/public-profile-v2-preflight.md.
--
-- Spec: docs/specs/2026-05-21-public-profile-v2-design.md
-- Plan: docs/plans/2026-05-21-public-profile-v2-plan.md
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.practices
  ADD COLUMN IF NOT EXISTS brand_color text,
  ADD COLUMN IF NOT EXISTS tagline text,
  ADD COLUMN IF NOT EXISTS specialties text[],
  ADD COLUMN IF NOT EXISTS contact_email text,
  ADD COLUMN IF NOT EXISTS contact_whatsapp text,
  ADD COLUMN IF NOT EXISTS contact_website text;

-- ---------------------------------------------------------------------------
-- 2. Check constraints — keep data within UI limits at the DB layer too.
--    Idempotent via DO-blocks: re-running this migration in dev is safe.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practices_brand_color_hex') THEN
    ALTER TABLE public.practices
      ADD CONSTRAINT practices_brand_color_hex
        CHECK (brand_color IS NULL OR brand_color ~ '^#[0-9A-Fa-f]{6}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practices_tagline_length') THEN
    ALTER TABLE public.practices
      ADD CONSTRAINT practices_tagline_length
        CHECK (tagline IS NULL OR length(tagline) <= 60);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practices_specialties_max') THEN
    ALTER TABLE public.practices
      ADD CONSTRAINT practices_specialties_max
        CHECK (specialties IS NULL OR array_length(specialties, 1) <= 8);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practices_contact_email_length') THEN
    ALTER TABLE public.practices
      ADD CONSTRAINT practices_contact_email_length
        CHECK (contact_email IS NULL OR length(contact_email) <= 120);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practices_contact_whatsapp_length') THEN
    ALTER TABLE public.practices
      ADD CONSTRAINT practices_contact_whatsapp_length
        CHECK (contact_whatsapp IS NULL OR length(contact_whatsapp) <= 20);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practices_contact_website_length') THEN
    ALTER TABLE public.practices
      ADD CONSTRAINT practices_contact_website_length
        CHECK (contact_website IS NULL OR length(contact_website) <= 200);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. set_practice_public_profile — widened signature.
--
--    Existing positional params (p_practice_id, p_slug, p_logo_url,
--    p_blurb, p_listed) keep their position. New V2 params append at the
--    end with DEFAULT NULL so any old caller still works.
--
--    Body preserves all existing validations (slug shape, blurb length,
--    list-without-slug guard) and adds writes for the six new columns.
--    Empty-string normalisation to NULL keeps the new CHECK constraints
--    happy.
--
--    DROP the 5-arg signature first — Postgres treats add-DEFAULTs as
--    a separate overload, so leaving both behind creates an ambiguity
--    risk for any positional callers in the wild.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.set_practice_public_profile(uuid, text, text, text, boolean);

CREATE OR REPLACE FUNCTION public.set_practice_public_profile(
  p_practice_id uuid,
  p_slug text,
  p_logo_url text,
  p_blurb text,
  p_listed boolean,
  -- V2 additions (positional-compatible — appended at end):
  p_brand_color text DEFAULT NULL,
  p_tagline text DEFAULT NULL,
  p_specialties text[] DEFAULT NULL,
  p_contact_email text DEFAULT NULL,
  p_contact_whatsapp text DEFAULT NULL,
  p_contact_website text DEFAULT NULL
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller    uuid := auth.uid();
  v_slug      text := nullif(btrim(lower(coalesce(p_slug, ''))), '');
  v_blurb     text := nullif(btrim(coalesce(p_blurb, '')), '');
  v_logo      text := nullif(btrim(coalesce(p_logo_url, '')), '');
  v_brand     text := nullif(btrim(coalesce(p_brand_color, '')), '');
  v_tagline   text := nullif(btrim(coalesce(p_tagline, '')), '');
  v_email     text := nullif(btrim(coalesce(p_contact_email, '')), '');
  v_whatsapp  text := nullif(btrim(coalesce(p_contact_whatsapp, '')), '');
  v_website   text := nullif(btrim(coalesce(p_contact_website, '')), '');
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_practice_public_profile requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_practice_public_profile: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'only the practice owner can edit the public profile'
      USING ERRCODE = '42501';
  END IF;

  -- Slug shape (defence in depth — CHECK also enforces).
  IF v_slug IS NOT NULL AND v_slug !~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$' THEN
    RAISE EXCEPTION 'set_practice_public_profile: slug must be 3-40 lowercase alphanumeric + hyphen chars'
      USING ERRCODE = '22023';
  END IF;

  IF v_blurb IS NOT NULL AND length(v_blurb) > 280 THEN
    RAISE EXCEPTION 'set_practice_public_profile: blurb max 280 chars'
      USING ERRCODE = '22023';
  END IF;

  -- Can't list publicly without a slug.
  IF coalesce(p_listed, false) AND v_slug IS NULL THEN
    RAISE EXCEPTION 'set_practice_public_profile: cannot list practice publicly without a slug'
      USING ERRCODE = '22023';
  END IF;

  -- Website must be https:// if set.
  IF v_website IS NOT NULL AND v_website !~* '^https?://' THEN
    RAISE EXCEPTION 'set_practice_public_profile: website must start with https://'
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.practices
     SET public_slug              = v_slug,
         public_logo_url          = v_logo,
         public_blurb             = v_blurb,
         public_profile_listed    = coalesce(p_listed, false),
         public_profile_updated_at = now(),
         brand_color              = v_brand,
         tagline                  = v_tagline,
         specialties              = p_specialties,
         contact_email            = v_email,
         contact_whatsapp         = v_whatsapp,
         contact_website          = v_website
   WHERE id = p_practice_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. get_practice_profile — widened RETURNS TABLE with V2 fields.
--
--    Existing columns (practice_id, practice_name, slug, logo_url, blurb,
--    premises) PRESERVED VERBATIM IN ORDER. New V2 fields appended at
--    the end.
--
--    Anon-readable; listed-filter unchanged.
--
--    DROP + CREATE because RETURNS TABLE column lists cannot be widened
--    by CREATE OR REPLACE in Postgres.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_practice_profile(text);

CREATE OR REPLACE FUNCTION public.get_practice_profile(p_slug text)
 RETURNS TABLE(
   -- Existing (DO NOT REORDER — clients bind by name but also by position):
   practice_id uuid,
   practice_name text,
   slug text,
   logo_url text,
   blurb text,
   premises jsonb,
   -- V2 additions:
   brand_color text,
   tagline text,
   specialties text[],
   contact_email text,
   contact_whatsapp text,
   contact_website text
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_slug text := btrim(lower(coalesce(p_slug, '')));
BEGIN
  IF v_slug = '' THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.name,
    p.public_slug,
    p.public_logo_url,
    p.public_blurb,
    coalesce(
      (SELECT jsonb_agg(
                jsonb_build_object(
                  'id', pp.id,
                  'name', pp.name,
                  'address', pp.address,
                  'centroid_lat', extensions.ST_Y(extensions.ST_Centroid(pp.polygon))::double precision,
                  'centroid_lng', extensions.ST_X(extensions.ST_Centroid(pp.polygon))::double precision,
                  'safe_mode_enforced', pp.safe_mode_enforced
                )
                ORDER BY pp.created_at ASC
              )
         FROM practice_premises pp
        WHERE pp.practice_id = p.id
          AND pp.deleted_at IS NULL),
      '[]'::jsonb
    ),
    -- V2:
    p.brand_color,
    p.tagline,
    p.specialties,
    p.contact_email,
    p.contact_whatsapp,
    p.contact_website
  FROM practices p
  WHERE p.public_slug = v_slug
    AND p.public_profile_listed = true
  LIMIT 1;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. get_practice_profile_owner — NEW RPC for the editor.
--
--    Returns the same shape as get_practice_profile but keyed by
--    practice_id and gated by practice-membership (not by public_profile_listed).
--    Owners + practitioners can both read; the portal UI gates EDIT
--    capability separately via getCurrentUserRole(). This closes the
--    pre-existing `.from('practices').select(...)` violation in api.ts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_practice_profile_owner(p_practice_id uuid)
 RETURNS TABLE(
   practice_id uuid,
   practice_name text,
   slug text,
   logo_url text,
   blurb text,
   premises jsonb,
   brand_color text,
   tagline text,
   specialties text[],
   contact_email text,
   contact_whatsapp text,
   contact_website text,
   listed boolean
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_practice_profile_owner requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Membership check: caller must belong to the practice. Uses the
  -- SECURITY DEFINER helper that bypasses the practice_members RLS
  -- self-recursion trap (see CLAUDE.md infra notes).
  IF NOT (p_practice_id = ANY (public.user_practice_ids())) THEN
    RAISE EXCEPTION 'get_practice_profile_owner: caller is not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.name,
    p.public_slug,
    p.public_logo_url,
    p.public_blurb,
    coalesce(
      (SELECT jsonb_agg(
                jsonb_build_object(
                  'id', pp.id,
                  'name', pp.name,
                  'address', pp.address,
                  'centroid_lat', extensions.ST_Y(extensions.ST_Centroid(pp.polygon))::double precision,
                  'centroid_lng', extensions.ST_X(extensions.ST_Centroid(pp.polygon))::double precision,
                  'safe_mode_enforced', pp.safe_mode_enforced
                )
                ORDER BY pp.created_at ASC
              )
         FROM practice_premises pp
        WHERE pp.practice_id = p.id
          AND pp.deleted_at IS NULL),
      '[]'::jsonb
    ),
    p.brand_color,
    p.tagline,
    p.specialties,
    p.contact_email,
    p.contact_whatsapp,
    p.contact_website,
    p.public_profile_listed
  FROM practices p
  WHERE p.id = p_practice_id
  LIMIT 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_practice_profile_owner(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_practice_profile_owner(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. get_plan_full — widened jsonb return.
--
--    NOTE: this RPC returns jsonb (NOT a TABLE) — the pre-flight capture
--    showed the existing body builds `jsonb_build_object('plan', ..., 'exercises', ...)`.
--    Widening here means merging brand_color + public_logo_url + practice_name
--    into the `plan` object via the `||` jsonb concat operator, sourced
--    from a LEFT JOIN to practices.
--
--    Every existing branch (consent gates, treatment URL synthesis,
--    thumbnail existence checks, sets aggregation, vault base-URL
--    lookup) is preserved verbatim. The ONLY changes vs the pre-flight
--    capture are:
--      - new `v_brand_color`, `v_public_logo_url`, `v_practice_name` DECLAREs.
--      - new `SELECT ... INTO ... FROM practices WHERE id = plan_row.practice_id`.
--      - merge into the top-level `plan` jsonb via `||` at return time.
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

  -- V2 — merge practice branding into the top-level `plan` object so
  -- the web player + lobby JS can read them via plan.brand_color etc.
  -- All three values may be NULL; the player has been updated to
  -- handle each independently.
  RETURN jsonb_build_object(
    'plan',
      to_jsonb(plan_row)
        || jsonb_build_object(
             'brand_color',     v_brand_color,
             'public_logo_url', v_public_logo_url,
             'practice_name',   v_practice_name
           ),
    'exercises', exes
  );
END;
$function$;

COMMIT;
