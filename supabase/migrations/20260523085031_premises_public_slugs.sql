-- ============================================================================
-- Per-premises public slugs for Safe Mode transparency URLs
-- ============================================================================
-- Spec: docs/specs/2026-05-22-safe-mode-transparency.md (v2 — per-premises URL)
-- Stack: docs/test-scripts/2026-05-23-stack.md items 5 + 6
--
-- The bystander-facing live transparency URL was per-practice in Phase B
-- (`/v/{practice-slug}/now`). Carl's "Studio Floor vs Outdoor Court 10 km
-- away" feedback established that bystanders only care about who's
-- recording AT THIS VENUE — a single practice-wide rollup leaks unrelated
-- sessions and is wrong for the poster QR.
--
-- The new URL shape is `/v/{practice-slug}/{premises-slug}/now`. Each
-- premises needs its own slug (3-40 chars, lowercase, hyphenated), unique
-- within the parent practice. The practice-wide rollup is RETIRED — the
-- web player will return a friendly 404 on the old shape.
--
-- This migration:
--   1. Adds `public_slug text` + `first_poster_downloaded_at timestamptz`
--      to `practice_premises`.
--   2. Backfills slugs from premises names (auto-numbered on collision).
--   3. Sets `public_slug` NOT NULL after backfill.
--   4. Adds the shape CHECK + the (practice_id, public_slug) UNIQUE
--      partial index (deleted_at IS NULL — tombstoned rows free their
--      slug for reuse).
--   5. Replaces `get_live_sessions(p_slug text)` with the two-arg form
--      `(p_practice_slug text, p_premises_slug text)`. The old single-arg
--      function is DROPPED — only `live.js` calls it and that's updated
--      in the same PR.
--   6. Adds `mark_poster_downloaded(p_premises_id uuid)` — stamps
--      `first_poster_downloaded_at` if NULL (no-op otherwise). Used by
--      the portal poster page to lock the slug post-download.
--   7. Extends `update_premises_metadata` with a `p_public_slug text`
--      argument. The 5-arg call site (the portal) and the legacy 4-arg
--      call sites (none in tree, but defensive) both keep working —
--      Postgres dispatches on signature.
--   8. Extends `get_premises` + `list_practice_premises` RETURNS TABLE
--      with the two new columns, preserving every existing column per
--      the column-preservation rule.
--   9. Re-grants EXECUTE on the replaced functions to authenticated /
--      anon as appropriate.
--
-- Slug shape matches the practice slug constraint exactly:
--   `^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$` — 3-40 chars total, starts
--   + ends with alphanumeric, hyphens allowed in the middle.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Schema: new columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.practice_premises
  ADD COLUMN IF NOT EXISTS public_slug                 text,
  ADD COLUMN IF NOT EXISTS first_poster_downloaded_at  timestamptz;

-- ---------------------------------------------------------------------------
-- 2. Backfill slugs from names with collision-suffixing.
--    Iterate over every existing row (live + tombstoned alike — the
--    UNIQUE partial index only constrains live rows but a slug on a
--    soft-deleted row is fine and easier than nullifying tombstones).
--    Generate a base slug via the same regex shape practice slugs use;
--    if the base collides with an already-assigned slug in the same
--    practice, append `-2`, `-3`, … until unique.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_row        record;
  v_base       text;
  v_candidate  text;
  v_n          integer;
BEGIN
  FOR v_row IN
    SELECT id, practice_id, name
      FROM public.practice_premises
     WHERE public_slug IS NULL
     ORDER BY created_at NULLS FIRST, id
  LOOP
    -- Base slug: lowercase, hyphens-for-non-alphanumeric, strip leading
    -- + trailing hyphens, clamp 3-40 chars.
    v_base := btrim(
                regexp_replace(
                  regexp_replace(lower(coalesce(v_row.name, '')), '[^a-z0-9]+', '-', 'g'),
                  '(^-+|-+$)', '', 'g'
                )
              );
    IF v_base = '' OR v_base IS NULL THEN
      v_base := 'site';
    END IF;
    IF length(v_base) < 3 THEN
      v_base := v_base || '-site';
    END IF;
    IF length(v_base) > 40 THEN
      v_base := substring(v_base, 1, 40);
      -- Strip any trailing hyphen we may have introduced via mid-hyphen
      -- truncation; rule (2) of the brief says "truncate mid-hyphen is
      -- fine, just strip trailing hyphens".
      v_base := regexp_replace(v_base, '-+$', '', 'g');
      IF length(v_base) < 3 THEN
        v_base := v_base || 'aa';
      END IF;
    END IF;

    -- Auto-suffix on collision within the same practice. Look only at
    -- the rows we've already stamped — preserves deterministic order
    -- by created_at.
    v_candidate := v_base;
    v_n         := 2;
    WHILE EXISTS (
      SELECT 1 FROM public.practice_premises pp
       WHERE pp.practice_id = v_row.practice_id
         AND pp.public_slug = v_candidate
         AND pp.id <> v_row.id
    ) LOOP
      v_candidate := v_base || '-' || v_n::text;
      -- Pathological 40-char base + suffix overflow — re-trim base.
      IF length(v_candidate) > 40 THEN
        v_candidate := substring(v_base, 1, 40 - length('-' || v_n::text)) || '-' || v_n::text;
      END IF;
      v_n := v_n + 1;
      IF v_n > 999 THEN
        RAISE EXCEPTION 'premises_public_slugs backfill: too many collisions on % in practice %',
          v_base, v_row.practice_id;
      END IF;
    END LOOP;

    UPDATE public.practice_premises
       SET public_slug = v_candidate
     WHERE id = v_row.id;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. NOT NULL + CHECK + UNIQUE.
-- ---------------------------------------------------------------------------
ALTER TABLE public.practice_premises
  ALTER COLUMN public_slug SET NOT NULL;

ALTER TABLE public.practice_premises
  DROP CONSTRAINT IF EXISTS practice_premises_public_slug_format;

ALTER TABLE public.practice_premises
  ADD CONSTRAINT practice_premises_public_slug_format
  CHECK (public_slug ~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$');

-- Unique within practice, but only on live rows. Tombstones free their
-- slug so a future row with the same name doesn't get blocked.
CREATE UNIQUE INDEX IF NOT EXISTS practice_premises_public_slug_unique
  ON public.practice_premises (practice_id, public_slug)
  WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- 4. Helper: generate a slug from a name (no DB lookup; collision-resolution
--    is the caller's responsibility — used by RPCs that mint defaults).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.premises_default_slug(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT
    CASE
      WHEN slug = '' OR slug IS NULL THEN 'site'
      WHEN length(slug) < 3 THEN slug || '-site'
      WHEN length(slug) > 40 THEN regexp_replace(substring(slug, 1, 40), '-+$', '', 'g')
      ELSE slug
    END
  FROM (
    SELECT btrim(
             regexp_replace(
               regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g'),
               '(^-+|-+$)', '', 'g'
             )
           ) AS slug
  ) t;
$function$;

-- ---------------------------------------------------------------------------
-- 5. create_default_premises — stamp a slug on the new row.
--    Auto-numbered name "New premises N" + slug "new-premises-N" (the
--    name itself, slugified). Collisions auto-suffixed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_default_premises(p_practice_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller     uuid := auth.uid();
  v_id         uuid;
  v_name       text;
  v_n          integer;
  v_base_slug  text;
  v_slug       text;
  v_suffix     integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'create_default_premises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'create_default_premises: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.practice_members AS pm
     WHERE pm.practice_id = p_practice_id
       AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'create_default_premises: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_n
    FROM public.practice_premises AS pp
   WHERE pp.practice_id = p_practice_id
     AND pp.deleted_at IS NULL;

  v_name := 'New premises ' || (v_n + 1)::text;

  -- Slugify the auto-name. Collision-resolve in case the user has
  -- deleted + re-created premises in a sequence that lands on the same
  -- slugified label.
  v_base_slug := public.premises_default_slug(v_name);
  v_slug      := v_base_slug;
  v_suffix    := 2;
  WHILE EXISTS (
    SELECT 1 FROM public.practice_premises pp
     WHERE pp.practice_id = p_practice_id
       AND pp.public_slug = v_slug
       AND pp.deleted_at IS NULL
  ) LOOP
    v_slug   := v_base_slug || '-' || v_suffix::text;
    IF length(v_slug) > 40 THEN
      v_slug := substring(v_base_slug, 1, 40 - length('-' || v_suffix::text))
                || '-' || v_suffix::text;
    END IF;
    v_suffix := v_suffix + 1;
    IF v_suffix > 999 THEN
      RAISE EXCEPTION 'create_default_premises: too many slug collisions'
        USING ERRCODE = '23505';
    END IF;
  END LOOP;

  INSERT INTO public.practice_premises (
    id,
    practice_id,
    name,
    polygon,
    address,
    safe_mode_enforced,
    public_slug,
    created_by_user_id
  )
  VALUES (
    gen_random_uuid(),
    p_practice_id,
    v_name,
    NULL,
    NULL,
    false,
    v_slug,
    v_caller
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.create_default_premises(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. get_premises — extend RETURNS TABLE with public_slug +
--    first_poster_downloaded_at, preserving every existing column.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_premises(uuid);

CREATE OR REPLACE FUNCTION public.get_premises(p_premises_id uuid)
 RETURNS TABLE(
   id uuid,
   practice_id uuid,
   name text,
   address text,
   polygon_geojson text,
   centroid_lat double precision,
   centroid_lng double precision,
   area_m2 double precision,
   safe_mode_enforced boolean,
   signal_type text,
   public_slug text,
   first_poster_downloaded_at timestamp with time zone,
   created_at timestamp with time zone,
   updated_at timestamp with time zone
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_premises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'get_premises: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT pp.practice_id INTO v_practice_id
    FROM public.practice_premises AS pp
   WHERE pp.id = p_premises_id
     AND pp.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'get_premises: premises not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.practice_members AS pm
     WHERE pm.practice_id = v_practice_id
       AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'get_premises: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    pp.id,
    pp.practice_id,
    pp.name,
    pp.address,
    CASE WHEN pp.polygon IS NULL THEN NULL::text
         ELSE extensions.ST_AsGeoJSON(pp.polygon)::text END,
    CASE WHEN pp.polygon IS NULL THEN NULL::double precision
         ELSE extensions.ST_Y(extensions.ST_Centroid(pp.polygon))::double precision END,
    CASE WHEN pp.polygon IS NULL THEN NULL::double precision
         ELSE extensions.ST_X(extensions.ST_Centroid(pp.polygon))::double precision END,
    CASE WHEN pp.polygon IS NULL THEN 0::double precision
         ELSE extensions.ST_Area(pp.polygon::extensions.geography)::double precision END,
    pp.safe_mode_enforced,
    pp.signal_type,
    pp.public_slug,
    pp.first_poster_downloaded_at,
    pp.created_at,
    pp.updated_at
  FROM public.practice_premises AS pp
  WHERE pp.id = p_premises_id
    AND pp.deleted_at IS NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_premises(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. list_practice_premises — same extension as get_premises.
--    Preserves every column from the prior signature; adds public_slug
--    + first_poster_downloaded_at. The 42702-fix qualified style is
--    preserved.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_practice_premises(uuid);

CREATE OR REPLACE FUNCTION public.list_practice_premises(p_practice_id uuid)
 RETURNS TABLE(
   id uuid,
   practice_id uuid,
   name text,
   address text,
   polygon_geojson text,
   centroid_lat double precision,
   centroid_lng double precision,
   area_m2 double precision,
   safe_mode_enforced boolean,
   signal_type text,
   public_slug text,
   first_poster_downloaded_at timestamp with time zone,
   created_at timestamp with time zone,
   updated_at timestamp with time zone
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_premises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_premises: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.practice_members AS pm
     WHERE pm.practice_id = p_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_practice_premises: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    pp.id,
    pp.practice_id,
    pp.name,
    pp.address,
    CASE WHEN pp.polygon IS NULL THEN NULL::text
         ELSE extensions.ST_AsGeoJSON(pp.polygon)::text END,
    CASE WHEN pp.polygon IS NULL THEN NULL::double precision
         ELSE extensions.ST_Y(extensions.ST_Centroid(pp.polygon))::double precision END,
    CASE WHEN pp.polygon IS NULL THEN NULL::double precision
         ELSE extensions.ST_X(extensions.ST_Centroid(pp.polygon))::double precision END,
    CASE WHEN pp.polygon IS NULL THEN 0::double precision
         ELSE extensions.ST_Area(pp.polygon::extensions.geography)::double precision END,
    pp.safe_mode_enforced,
    pp.signal_type,
    pp.public_slug,
    pp.first_poster_downloaded_at,
    pp.created_at,
    pp.updated_at
  FROM public.practice_premises AS pp
  WHERE pp.practice_id = p_practice_id
    AND pp.deleted_at IS NULL
  ORDER BY pp.created_at ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.list_practice_premises(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. update_premises_metadata — extend signature with p_public_slug.
--    Drop the old 4-arg signature first; the portal is updated in the
--    same PR. NULL on p_public_slug = leave untouched. Validates against
--    the shape regex + (practice_id, slug) uniqueness within live rows.
--    Rejects slug changes once first_poster_downloaded_at is stamped.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.update_premises_metadata(uuid, text, text, boolean);

CREATE OR REPLACE FUNCTION public.update_premises_metadata(
  p_premises_id uuid,
  p_name text,
  p_address text,
  p_safe_mode_enforced boolean,
  p_public_slug text
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller        uuid := auth.uid();
  v_practice_id   uuid;
  v_current_slug  text;
  v_locked_at     timestamptz;
  v_trim_name     text;
  v_trim_addr     text;
  v_trim_slug     text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'update_premises_metadata requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'update_premises_metadata: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT pp.practice_id, pp.public_slug, pp.first_poster_downloaded_at
    INTO v_practice_id, v_current_slug, v_locked_at
    FROM public.practice_premises AS pp
   WHERE pp.id = p_premises_id
     AND pp.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'update_premises_metadata: premises not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.practice_members AS pm
     WHERE pm.practice_id = v_practice_id
       AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'update_premises_metadata: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF p_name IS NOT NULL THEN
    v_trim_name := btrim(p_name);
    IF v_trim_name = '' THEN
      RAISE EXCEPTION 'update_premises_metadata: name required'
        USING ERRCODE = '22023';
    END IF;
    IF length(v_trim_name) > 80 THEN
      RAISE EXCEPTION 'update_premises_metadata: name too long (max 80 chars)'
        USING ERRCODE = '22023';
    END IF;
    UPDATE public.practice_premises
       SET name = v_trim_name,
           updated_at = now()
     WHERE id = p_premises_id;
  END IF;

  IF p_address IS NOT NULL THEN
    v_trim_addr := nullif(btrim(p_address), '');
    UPDATE public.practice_premises
       SET address = v_trim_addr,
           updated_at = now()
     WHERE id = p_premises_id;
  END IF;

  IF p_safe_mode_enforced IS NOT NULL THEN
    UPDATE public.practice_premises
       SET safe_mode_enforced = p_safe_mode_enforced,
           updated_at = now()
     WHERE id = p_premises_id;
  END IF;

  IF p_public_slug IS NOT NULL THEN
    v_trim_slug := lower(btrim(p_public_slug));
    -- Treat empty string as "no-op" so a client passing the field with
    -- a blank value doesn't accidentally trip validation.
    IF v_trim_slug <> '' THEN
      IF v_trim_slug <> coalesce(v_current_slug, '') THEN
        -- Slug change requested. Hard-stop if locked.
        IF v_locked_at IS NOT NULL THEN
          RAISE EXCEPTION 'update_premises_metadata: slug is locked (poster already downloaded)'
            USING ERRCODE = '22023';
        END IF;

        IF v_trim_slug !~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$' THEN
          RAISE EXCEPTION 'update_premises_metadata: slug must be 3-40 chars, lowercase letters/digits/hyphens, start + end with alphanumeric'
            USING ERRCODE = '22023';
        END IF;

        IF EXISTS (
          SELECT 1 FROM public.practice_premises pp
           WHERE pp.practice_id = v_practice_id
             AND pp.public_slug = v_trim_slug
             AND pp.id <> p_premises_id
             AND pp.deleted_at IS NULL
        ) THEN
          RAISE EXCEPTION 'update_premises_metadata: slug already in use in this practice'
            USING ERRCODE = '23505';
        END IF;

        UPDATE public.practice_premises
           SET public_slug = v_trim_slug,
               updated_at = now()
         WHERE id = p_premises_id;
      END IF;
    END IF;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.update_premises_metadata(uuid, text, text, boolean, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 9. mark_poster_downloaded — stamp first_poster_downloaded_at on the
--    first view of /poster?print=1. Idempotent: subsequent calls are a
--    no-op (we never re-stamp). Owner-only by design — the slug-lock
--    contract is "owner downloaded the printed QR, now it can't change
--    underneath them".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_poster_downloaded(p_premises_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'mark_poster_downloaded requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'mark_poster_downloaded: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT pp.practice_id INTO v_practice_id
    FROM public.practice_premises AS pp
   WHERE pp.id = p_premises_id
     AND pp.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    -- Silent for the firehose case where the poster page renders for a
    -- soft-deleted premises (the page itself 404s; this is a no-op).
    RETURN;
  END IF;

  IF NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'mark_poster_downloaded: caller % is not the owner of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.practice_premises
     SET first_poster_downloaded_at = now()
   WHERE id = p_premises_id
     AND first_poster_downloaded_at IS NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.mark_poster_downloaded(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 10. get_live_sessions — two-arg form (practice slug + premises slug).
--     Filter sessions to the specific premises only. The premises-array
--     in the return shape becomes a single-element list (just THE
--     premises we're showing), so the live page can still draw its
--     polygon without a second RPC.
--
--     The old single-arg form is dropped; web-player/live.js calls the
--     new form in the same PR.
--
--     Both slugs are normalised lowercase + btrim. Missing match → empty
--     result (same as before — never leaks the existence of unlisted
--     slugs).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_live_sessions(text);
DROP FUNCTION IF EXISTS public.get_live_sessions(text, text);

CREATE FUNCTION public.get_live_sessions(
  p_practice_slug text,
  p_premises_slug text
)
 RETURNS TABLE (
   practice_id        uuid,
   practice_name      text,
   practice_slug      text,
   premises_id        uuid,
   premises_name      text,
   premises_slug      text,
   premises_polygon   jsonb,
   session_id         uuid,
   trainer_id         uuid,
   first_name         text,
   last_name          text,
   avatar_url         text,
   started_at         timestamptz,
   last_heartbeat_at  timestamptz,
   last_latitude      double precision,
   last_longitude     double precision,
   manual_mode        boolean,
   kind               text
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', extensions
AS $function$
DECLARE
  v_practice_slug text := nullif(btrim(lower(coalesce(p_practice_slug, ''))), '');
  v_premises_slug text := nullif(btrim(lower(coalesce(p_premises_slug, ''))), '');
  v_practice      public.practices%ROWTYPE;
  v_premises      public.practice_premises%ROWTYPE;
BEGIN
  IF v_practice_slug IS NULL OR v_premises_slug IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_practice
    FROM public.practices p
   WHERE p.public_slug = v_practice_slug
     AND coalesce(p.public_profile_listed, false) = true
   LIMIT 1;

  IF v_practice.id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_premises
    FROM public.practice_premises pp
   WHERE pp.practice_id = v_practice.id
     AND pp.public_slug = v_premises_slug
     AND pp.deleted_at IS NULL
   LIMIT 1;

  IF v_premises.id IS NULL THEN
    RETURN;
  END IF;

  -- One 'premises' row for the polygon — only emitted when Safe Mode is
  -- enforced (the live page is only meaningful for enforced venues; a
  -- non-enforced premises has no public live story).
  IF coalesce(v_premises.safe_mode_enforced, false) AND v_premises.polygon IS NOT NULL THEN
    RETURN QUERY
      SELECT
        v_practice.id           AS practice_id,
        v_practice.name         AS practice_name,
        v_practice.public_slug  AS practice_slug,
        v_premises.id           AS premises_id,
        v_premises.name         AS premises_name,
        v_premises.public_slug  AS premises_slug,
        to_jsonb(
          ARRAY(
            SELECT jsonb_build_array(extensions.ST_X(pt), extensions.ST_Y(pt))
              FROM extensions.ST_DumpPoints(v_premises.polygon) AS d(path, pt)
             ORDER BY (d.path)[2]
          )
        )                       AS premises_polygon,
        NULL::uuid              AS session_id,
        NULL::uuid              AS trainer_id,
        NULL::text              AS first_name,
        NULL::text              AS last_name,
        NULL::text              AS avatar_url,
        NULL::timestamptz       AS started_at,
        NULL::timestamptz       AS last_heartbeat_at,
        NULL::double precision  AS last_latitude,
        NULL::double precision  AS last_longitude,
        NULL::boolean           AS manual_mode,
        'premises'::text        AS kind;
  END IF;

  -- Active sessions at THIS premises (heartbeat < 60s ago).
  RETURN QUERY
    SELECT
      v_practice.id           AS practice_id,
      v_practice.name         AS practice_name,
      v_practice.public_slug  AS practice_slug,
      v_premises.id           AS premises_id,
      v_premises.name         AS premises_name,
      v_premises.public_slug  AS premises_slug,
      NULL::jsonb             AS premises_polygon,
      acs.id                  AS session_id,
      acs.trainer_id          AS trainer_id,
      prac.first_name         AS first_name,
      prac.last_name          AS last_name,
      prac.avatar_url         AS avatar_url,
      acs.started_at          AS started_at,
      acs.last_heartbeat_at   AS last_heartbeat_at,
      acs.last_latitude       AS last_latitude,
      acs.last_longitude      AS last_longitude,
      acs.manual_mode         AS manual_mode,
      'session'::text         AS kind
    FROM public.active_capture_sessions acs
    LEFT JOIN public.practitioners prac
      ON prac.user_id = acs.trainer_id
   WHERE acs.practice_id = v_practice.id
     AND acs.premises_id = v_premises.id
     AND acs.ended_at IS NULL
     AND acs.last_heartbeat_at >= now() - interval '60 seconds';
END;
$function$;

REVOKE ALL ON FUNCTION public.get_live_sessions(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text, text) TO service_role;

COMMIT;
