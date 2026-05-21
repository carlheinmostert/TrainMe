-- ============================================================================
-- Safe Mode — practice premises + public profile + geofenced bystander blur
-- ============================================================================
-- Adds:
--   - PostGIS extension (geometry / ST_Contains for geofence queries)
--   - public profile columns on `practices` (slug + logo + blurb + listed)
--   - `practice_premises` table (many premises per practice, soft-delete)
--   - `premises_reports` table (abuse reports — Carl reviews manually)
--   - audit columns on `exercises` (captured_in_premises_id + safe_mode_active)
--   - RPCs: upsert_premises, delete_premises, restore_premises,
--           list_practice_premises, set_practice_public_profile,
--           find_premises_at (anon), get_practice_profile (anon),
--           report_premises (anon)
--   - RLS policies scoped by practice membership
--   - Helper: practice_premises_default_slug() for slug auto-generation
--
-- See CLAUDE.md ("Safe Mode" section) for the design spec.
-- ============================================================================

BEGIN;

-- ============================================================================
-- Section 1: PostGIS extension
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "postgis" WITH SCHEMA "extensions";

-- ============================================================================
-- Section 2: practices — public profile columns
-- ============================================================================
ALTER TABLE "public"."practices"
  ADD COLUMN IF NOT EXISTS "public_slug" text,
  ADD COLUMN IF NOT EXISTS "public_logo_url" text,
  ADD COLUMN IF NOT EXISTS "public_blurb" text,
  ADD COLUMN IF NOT EXISTS "public_profile_listed" boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS "public_profile_updated_at" timestamp with time zone;

-- Slug uniqueness + format check. NULL allowed; once set, must be lowercase
-- alphanumeric + hyphens, 3-40 chars, no leading/trailing hyphen.
ALTER TABLE "public"."practices"
  ADD CONSTRAINT "practices_public_slug_format"
  CHECK (
    public_slug IS NULL
    OR (
      public_slug ~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])?$'
      AND length(public_slug) BETWEEN 3 AND 40
    )
  );

ALTER TABLE "public"."practices"
  ADD CONSTRAINT "practices_public_blurb_length"
  CHECK (public_blurb IS NULL OR length(public_blurb) <= 280);

CREATE UNIQUE INDEX IF NOT EXISTS "practices_public_slug_unique"
  ON "public"."practices" (public_slug)
  WHERE public_slug IS NOT NULL;

-- ============================================================================
-- Section 3: practice_premises — many per practice, soft-deletable
-- ============================================================================
CREATE TABLE IF NOT EXISTS "public"."practice_premises" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "practice_id" uuid NOT NULL,
    "name" text NOT NULL,
    "address" text,
    "polygon" extensions.geometry(Polygon, 4326) NOT NULL,
    "safe_mode_enforced" boolean NOT NULL DEFAULT false,
    "signal_type" text NOT NULL DEFAULT 'gps',
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
    "deleted_at" timestamp with time zone,
    "created_by_user_id" uuid,
    "deleted_by_user_id" uuid,
    CONSTRAINT "practice_premises_pkey" PRIMARY KEY (id),
    CONSTRAINT "practice_premises_practice_fk"
      FOREIGN KEY (practice_id) REFERENCES "public"."practices"(id) ON DELETE CASCADE,
    CONSTRAINT "practice_premises_name_nonempty"
      CHECK (length(btrim(name)) > 0 AND length(name) <= 80),
    CONSTRAINT "practice_premises_signal_type_valid"
      CHECK (signal_type = ANY (ARRAY['gps'::text, 'gps+wifi'::text, 'gps+beacon'::text])),
    CONSTRAINT "practice_premises_polygon_simple"
      CHECK (extensions.ST_IsValid(polygon) AND extensions.ST_NPoints(polygon) <= 14),
    CONSTRAINT "practice_premises_polygon_area"
      CHECK (extensions.ST_Area(polygon::extensions.geography) <= 1000000)
);

-- GIST index for ST_Contains (the find_premises_at hot path).
CREATE INDEX IF NOT EXISTS "practice_premises_polygon_gist"
  ON "public"."practice_premises" USING GIST (polygon)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS "practice_premises_practice_id_idx"
  ON "public"."practice_premises" (practice_id)
  WHERE deleted_at IS NULL;

-- ============================================================================
-- Section 4: premises_reports — abuse reports, Carl reviews manually
-- ============================================================================
CREATE TABLE IF NOT EXISTS "public"."premises_reports" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "premises_id" uuid NOT NULL,
    "reporter_user_id" uuid,
    "reason" text NOT NULL,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolution_note" text,
    CONSTRAINT "premises_reports_pkey" PRIMARY KEY (id),
    CONSTRAINT "premises_reports_premises_fk"
      FOREIGN KEY (premises_id) REFERENCES "public"."practice_premises"(id) ON DELETE CASCADE,
    CONSTRAINT "premises_reports_reason_length"
      CHECK (length(btrim(reason)) BETWEEN 1 AND 500)
);

CREATE INDEX IF NOT EXISTS "premises_reports_unresolved_idx"
  ON "public"."premises_reports" (created_at DESC)
  WHERE resolved_at IS NULL;

-- ============================================================================
-- Section 5: exercises — Safe Mode audit columns
-- ============================================================================
ALTER TABLE "public"."exercises"
  ADD COLUMN IF NOT EXISTS "captured_in_premises_id" uuid,
  ADD COLUMN IF NOT EXISTS "safe_mode_active" boolean NOT NULL DEFAULT false;

ALTER TABLE "public"."exercises"
  ADD CONSTRAINT "exercises_captured_in_premises_fk"
  FOREIGN KEY (captured_in_premises_id)
  REFERENCES "public"."practice_premises"(id)
  ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS "exercises_safe_mode_idx"
  ON "public"."exercises" (captured_in_premises_id)
  WHERE safe_mode_active = true;

-- ============================================================================
-- Section 6: RLS enable
-- ============================================================================
ALTER TABLE "public"."practice_premises" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."premises_reports" ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- Section 7: RLS policies
-- ============================================================================

-- practice_premises: members SELECT their practice's rows.
-- Anonymous read is via the find_premises_at / get_practice_profile RPCs
-- (SECURITY DEFINER), not via direct SELECT.
CREATE POLICY "practice_premises_select_member" ON "public"."practice_premises"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING (
      practice_id IN (SELECT user_practice_ids())
      OR user_is_practice_owner(practice_id)
    );

CREATE POLICY "practice_premises_insert_member" ON "public"."practice_premises"
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK (
      practice_id IN (SELECT user_practice_ids())
      OR user_is_practice_owner(practice_id)
    );

CREATE POLICY "practice_premises_update_member" ON "public"."practice_premises"
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING (
      practice_id IN (SELECT user_practice_ids())
      OR user_is_practice_owner(practice_id)
    )
    WITH CHECK (
      practice_id IN (SELECT user_practice_ids())
      OR user_is_practice_owner(practice_id)
    );

CREATE POLICY "practice_premises_delete_member" ON "public"."practice_premises"
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (
      practice_id IN (SELECT user_practice_ids())
      OR user_is_practice_owner(practice_id)
    );

-- premises_reports: write-only for clients via the RPC (no direct INSERT).
-- SELECT visible to owners of the practice that owns the premises (so they
-- see reports against their own venue) and to service_role.
CREATE POLICY "premises_reports_select_owner" ON "public"."premises_reports"
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING (
      EXISTS (
        SELECT 1 FROM practice_premises pp
        WHERE pp.id = premises_reports.premises_id
          AND user_is_practice_owner(pp.practice_id)
      )
    );

-- ============================================================================
-- Section 8: Helper — slug suggestion (best-effort, collision retry in RPC)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.practice_premises_default_slug(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT
    CASE
      WHEN slug = '' THEN NULL
      WHEN length(slug) < 3 THEN slug || '-practice'
      WHEN length(slug) > 40 THEN substring(slug, 1, 40)
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

-- ============================================================================
-- Section 9: RPCs
-- ============================================================================

-- ---------------------------------------------------------------------------
-- upsert_premises — create or update a premises. INSERT if p_id is NULL OR
-- the row doesn't exist; UPDATE otherwise. Validates polygon vertex count
-- and area (also enforced by CHECK constraints, but we want a friendlier
-- error message).
--
-- Polygon comes in as GeoJSON text (the portal uses Leaflet which emits
-- GeoJSON); we parse + project to SRID 4326.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_premises(
  p_id uuid,
  p_practice_id uuid,
  p_name text,
  p_address text,
  p_polygon_geojson text,
  p_safe_mode_enforced boolean
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller  uuid := auth.uid();
  v_id      uuid := p_id;
  v_geom    extensions.geometry(Polygon, 4326);
  v_vertices integer;
  v_area_m2  double precision;
  v_trimmed_name text := btrim(coalesce(p_name, ''));
  v_trimmed_addr text := nullif(btrim(coalesce(p_address, '')), '');
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'upsert_premises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'upsert_premises: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF v_trimmed_name = '' THEN
    RAISE EXCEPTION 'upsert_premises: name required'
      USING ERRCODE = '22023';
  END IF;

  IF length(v_trimmed_name) > 80 THEN
    RAISE EXCEPTION 'upsert_premises: name too long (max 80 chars)'
      USING ERRCODE = '22023';
  END IF;

  -- Caller must be a member of the practice.
  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'upsert_premises: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Parse GeoJSON. ST_GeomFromGeoJSON throws on malformed input.
  BEGIN
    v_geom := extensions.ST_SetSRID(extensions.ST_GeomFromGeoJSON(p_polygon_geojson), 4326);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'upsert_premises: invalid polygon GeoJSON: %', SQLERRM
      USING ERRCODE = '22023';
  END;

  IF extensions.GeometryType(v_geom) <> 'POLYGON' THEN
    RAISE EXCEPTION 'upsert_premises: geometry must be a Polygon (got %)',
      extensions.GeometryType(v_geom)
      USING ERRCODE = '22023';
  END IF;

  v_vertices := extensions.ST_NPoints(v_geom);
  -- ST_NPoints counts the closing point — a 12-vertex polygon has 13 points.
  IF v_vertices > 13 THEN
    RAISE EXCEPTION 'upsert_premises: too many vertices (max 12, got %)',
      v_vertices - 1
      USING ERRCODE = '22023';
  END IF;

  IF v_vertices < 4 THEN
    RAISE EXCEPTION 'upsert_premises: polygon needs at least 3 vertices'
      USING ERRCODE = '22023';
  END IF;

  v_area_m2 := extensions.ST_Area(v_geom::extensions.geography);
  IF v_area_m2 > 1000000 THEN
    RAISE EXCEPTION 'upsert_premises: polygon too large (max 1 km², got % m²)',
      round(v_area_m2)
      USING ERRCODE = '22023';
  END IF;

  IF v_area_m2 < 25 THEN
    RAISE EXCEPTION 'upsert_premises: polygon too small (min 25 m², got % m²)',
      round(v_area_m2)
      USING ERRCODE = '22023';
  END IF;

  IF v_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM practice_premises WHERE id = v_id
  ) THEN
    UPDATE practice_premises
       SET name = v_trimmed_name,
           address = v_trimmed_addr,
           polygon = v_geom,
           safe_mode_enforced = coalesce(p_safe_mode_enforced, false),
           updated_at = now(),
           deleted_at = NULL,
           deleted_by_user_id = NULL
     WHERE id = v_id
       AND practice_id = p_practice_id;
    RETURN v_id;
  END IF;

  INSERT INTO practice_premises (
    id, practice_id, name, address, polygon,
    safe_mode_enforced, created_by_user_id
  )
  VALUES (
    coalesce(v_id, gen_random_uuid()),
    p_practice_id,
    v_trimmed_name,
    v_trimmed_addr,
    v_geom,
    coalesce(p_safe_mode_enforced, false),
    v_caller
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- delete_premises — soft-delete (sets deleted_at). Mirrors delete_client.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_premises(p_premises_id uuid)
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
    RAISE EXCEPTION 'delete_premises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'delete_premises: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT pp.practice_id INTO v_practice_id
    FROM practice_premises pp
   WHERE pp.id = p_premises_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'delete_premises: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE practice_premises
     SET deleted_at = now(),
         updated_at = now(),
         deleted_by_user_id = v_caller
   WHERE id = p_premises_id
     AND deleted_at IS NULL;
END;
$function$;

-- ---------------------------------------------------------------------------
-- restore_premises — undo soft-delete.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.restore_premises(p_premises_id uuid)
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
    RAISE EXCEPTION 'restore_premises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'restore_premises: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT pp.practice_id INTO v_practice_id
    FROM practice_premises pp
   WHERE pp.id = p_premises_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'restore_premises: premises not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'restore_premises: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE practice_premises
     SET deleted_at = NULL,
         deleted_by_user_id = NULL,
         updated_at = now()
   WHERE id = p_premises_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- list_practice_premises — returns all non-deleted premises for a practice,
-- with polygon serialised as GeoJSON for client-side rendering.
-- ---------------------------------------------------------------------------
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
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
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
    extensions.ST_AsGeoJSON(pp.polygon)::text,
    extensions.ST_Y(extensions.ST_Centroid(pp.polygon))::double precision,
    extensions.ST_X(extensions.ST_Centroid(pp.polygon))::double precision,
    extensions.ST_Area(pp.polygon::extensions.geography)::double precision,
    pp.safe_mode_enforced,
    pp.signal_type,
    pp.created_at,
    pp.updated_at
  FROM practice_premises pp
  WHERE pp.practice_id = p_practice_id
    AND pp.deleted_at IS NULL
  ORDER BY pp.created_at ASC;
END;
$function$;

-- ---------------------------------------------------------------------------
-- set_practice_public_profile — owner-only. Updates slug/logo/blurb/listed.
-- Slug is unique across practices; a clash returns 23505.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_practice_public_profile(
  p_practice_id uuid,
  p_slug text,
  p_logo_url text,
  p_blurb text,
  p_listed boolean
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller  uuid := auth.uid();
  v_slug    text := nullif(btrim(lower(coalesce(p_slug, ''))), '');
  v_blurb   text := nullif(btrim(coalesce(p_blurb, '')), '');
  v_logo    text := nullif(btrim(coalesce(p_logo_url, '')), '');
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

  UPDATE practices
     SET public_slug = v_slug,
         public_logo_url = v_logo,
         public_blurb = v_blurb,
         public_profile_listed = coalesce(p_listed, false),
         public_profile_updated_at = now()
   WHERE id = p_practice_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- find_premises_at — anonymous-readable RPC used by mobile at camera-open.
-- Returns the most-restrictive enforced premises containing the point
-- (smallest area among those with safe_mode_enforced=true). If none
-- enforced, returns NULL row.
--
-- Intentionally exposed to `anon` AND `authenticated` so the mobile client
-- can call it without leaking the full premises table via direct SELECT.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.find_premises_at(
  p_lat double precision,
  p_lng double precision
)
 RETURNS TABLE(
   premises_id uuid,
   practice_id uuid,
   premises_name text,
   safe_mode_enforced boolean
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_point extensions.geometry(Point, 4326);
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RETURN;
  END IF;

  IF p_lat < -90 OR p_lat > 90 OR p_lng < -180 OR p_lng > 180 THEN
    RAISE EXCEPTION 'find_premises_at: lat/lng out of range'
      USING ERRCODE = '22023';
  END IF;

  v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326);

  -- Return the smallest enforced polygon containing the point ("most
  -- restrictive wins" — a studio inside a gym overrides the gym outer ring).
  RETURN QUERY
  SELECT
    pp.id,
    pp.practice_id,
    pp.name,
    pp.safe_mode_enforced
  FROM practice_premises pp
  WHERE pp.deleted_at IS NULL
    AND pp.safe_mode_enforced = true
    AND extensions.ST_Contains(pp.polygon, v_point)
  ORDER BY extensions.ST_Area(pp.polygon::extensions.geography) ASC
  LIMIT 1;
END;
$function$;

-- ---------------------------------------------------------------------------
-- get_practice_profile — anon RPC for the public profile page (web player
-- `/v/{slug}`). Returns practice card + non-deleted premises.
--
-- Returns NULL row if the slug doesn't exist OR the practice has not opted
-- into the directory (public_profile_listed=false).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_practice_profile(p_slug text)
 RETURNS TABLE(
   practice_id uuid,
   practice_name text,
   slug text,
   logo_url text,
   blurb text,
   premises jsonb
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
    )
  FROM practices p
  WHERE p.public_slug = v_slug
    AND p.public_profile_listed = true
  LIMIT 1;
END;
$function$;

-- ---------------------------------------------------------------------------
-- report_premises — anyone (anon or authenticated) can submit a report.
-- Rate-limited only by HTTP layer for MVP.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_premises(
  p_premises_id uuid,
  p_reason text
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller  uuid := auth.uid();
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_id      uuid;
BEGIN
  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'report_premises: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF v_reason = '' THEN
    RAISE EXCEPTION 'report_premises: reason required'
      USING ERRCODE = '22023';
  END IF;

  IF length(v_reason) > 500 THEN
    RAISE EXCEPTION 'report_premises: reason too long (max 500 chars)'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_premises WHERE id = p_premises_id
  ) THEN
    RAISE EXCEPTION 'report_premises: premises not found'
      USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO premises_reports (premises_id, reporter_user_id, reason)
  VALUES (p_premises_id, v_caller, v_reason)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- ============================================================================
-- Section 10: Function ACLs
-- ============================================================================

-- Authenticated-only RPCs (premises CRUD, profile edit).
REVOKE ALL ON FUNCTION public.upsert_premises(uuid, uuid, text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_premises(uuid, uuid, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_premises(uuid, uuid, text, text, text, boolean) TO service_role;

REVOKE ALL ON FUNCTION public.delete_premises(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_premises(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_premises(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.restore_premises(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.restore_premises(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_premises(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.list_practice_premises(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_practice_premises(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_practice_premises(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.set_practice_public_profile(uuid, text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_practice_public_profile(uuid, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_practice_public_profile(uuid, text, text, text, boolean) TO service_role;

-- Anon-readable RPCs (geofence + public profile + report).
REVOKE ALL ON FUNCTION public.find_premises_at(double precision, double precision) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_premises_at(double precision, double precision) TO anon;
GRANT EXECUTE ON FUNCTION public.find_premises_at(double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_premises_at(double precision, double precision) TO service_role;

REVOKE ALL ON FUNCTION public.get_practice_profile(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_practice_profile(text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_practice_profile(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_practice_profile(text) TO service_role;

REVOKE ALL ON FUNCTION public.report_premises(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_premises(uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION public.report_premises(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_premises(uuid, text) TO service_role;

REVOKE ALL ON FUNCTION public.practice_premises_default_slug(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.practice_premises_default_slug(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.practice_premises_default_slug(text) TO service_role;

-- ============================================================================
-- Section 11: Table grants
-- ============================================================================
-- practice_premises: authenticated INSERT/UPDATE/DELETE go through RLS.
-- Anon has no direct access (only via the SECURITY DEFINER RPCs above).
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.practice_premises TO authenticated;
GRANT ALL ON TABLE public.practice_premises TO service_role;

-- premises_reports: write-only via RPC. SELECT goes through RLS (owners only).
GRANT SELECT ON TABLE public.premises_reports TO authenticated;
GRANT ALL ON TABLE public.premises_reports TO service_role;

COMMIT;
