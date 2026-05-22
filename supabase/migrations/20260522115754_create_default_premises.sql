-- ============================================================================
-- Premises: inline-page create flow — create_default_premises RPC + relax
-- polygon NOT NULL so a "draft" premises can exist before the user has
-- drawn the boundary.
-- ============================================================================
-- Why: the portal /premises page used a modal dialog to compose a new
-- premises (name + address + Safe Mode + polygon in one shot). That
-- broke R-01 (no modal confirmations) and the broader no-popups-ever
-- rule (mint with a default placeholder + navigate to detail + inline
-- rename). The replacement flow:
--
--   1. "Add premises" calls create_default_premises(p_practice_id) →
--      a row is INSERTed immediately with a placeholder name and a
--      NULL polygon.
--   2. The portal routes to /premises/{newId}, a full-page detail
--      surface where the user inline-edits name / address / Safe Mode
--      and uses the polygon editor as a first-class page section.
--   3. Polygon saves still go through upsert_premises which keeps its
--      existing geometry validation.
--
-- Schema change: polygon column becomes NULLable so the draft row can
-- exist before the user draws. All downstream readers (list /
-- find_premises_at / get_practice_profile_premises) tolerate NULL via
-- PostGIS function NULL-pass-through; the GIST index already uses
-- WHERE deleted_at IS NULL so the index simply won't include polygon-
-- less rows (ST_Contains can't match NULL anyway, so find_premises_at
-- gracefully skips drafts).
--
-- The polygon CHECK constraints must be rewritten to permit NULL —
-- doing this by DROP+ADD keeps Postgres happy on idempotent re-runs.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Allow NULL polygons for drafts.
-- ---------------------------------------------------------------------------
ALTER TABLE public.practice_premises
  ALTER COLUMN polygon DROP NOT NULL;

ALTER TABLE public.practice_premises
  DROP CONSTRAINT IF EXISTS practice_premises_polygon_simple;

ALTER TABLE public.practice_premises
  ADD CONSTRAINT practice_premises_polygon_simple
  CHECK (
    polygon IS NULL
    OR (extensions.ST_IsValid(polygon) AND extensions.ST_NPoints(polygon) <= 14)
  );

ALTER TABLE public.practice_premises
  DROP CONSTRAINT IF EXISTS practice_premises_polygon_area;

ALTER TABLE public.practice_premises
  ADD CONSTRAINT practice_premises_polygon_area
  CHECK (
    polygon IS NULL
    OR extensions.ST_Area(polygon::extensions.geography) <= 1000000
  );

-- ---------------------------------------------------------------------------
-- 2. create_default_premises — mint a draft row, return the new id so
-- the portal can route straight to /premises/{id}.
--
-- SECURITY DEFINER + practice-membership check mirrors the existing
-- upsert_premises shape. Name auto-numbers off the count of live
-- premises so successive clicks produce "New premises 1", "New
-- premises 2", … — meaningful enough to recognise in the list while
-- the user gets around to renaming.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_default_premises(p_practice_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_id     uuid;
  v_name   text;
  v_n      integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'create_default_premises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'create_default_premises: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- Practice-membership check (matches upsert_premises). Uses the
  -- aliased table reference style to dodge the 42702 SETOF/OUT-col
  -- shadowing trap (see feedback_schema_migration_column_preservation.md
  -- and the recurring delete_client / list_practice_premises incidents).
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

  -- Auto-numbered default name: count live premises for this practice
  -- and append (count + 1). Doesn't reuse numbers freed by deletion —
  -- that's fine, it's a placeholder the user is expected to replace.
  SELECT count(*) INTO v_n
    FROM public.practice_premises AS pp
   WHERE pp.practice_id = p_practice_id
     AND pp.deleted_at IS NULL;

  v_name := 'New premises ' || (v_n + 1)::text;

  INSERT INTO public.practice_premises (
    id,
    practice_id,
    name,
    polygon,
    address,
    safe_mode_enforced,
    created_by_user_id
  )
  VALUES (
    gen_random_uuid(),
    p_practice_id,
    v_name,
    NULL,
    NULL,
    false,
    v_caller
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.create_default_premises(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. get_premises — fetch a single premises by id with the same shape
-- as a list_practice_premises row. SECURITY DEFINER + practice-
-- membership check; mirrors the existing list RPC so the inline-detail
-- page can hydrate from the same field set the list panel uses.
-- ---------------------------------------------------------------------------
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
    pp.created_at,
    pp.updated_at
  FROM public.practice_premises AS pp
  WHERE pp.id = p_premises_id
    AND pp.deleted_at IS NULL;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_premises(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. update_premises_metadata — patch name / address / Safe Mode
-- without touching polygon. The inline-detail page autosaves each
-- field on blur; polygon edits remain a deliberate explicit save
-- through upsert_premises.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_premises_metadata(
  p_premises_id uuid,
  p_name text,
  p_address text,
  p_safe_mode_enforced boolean
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
  v_trim_name   text;
  v_trim_addr   text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'update_premises_metadata requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'update_premises_metadata: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT pp.practice_id INTO v_practice_id
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

  -- Partial-update semantics: NULL means "leave alone". Empty string
  -- on address is treated as "clear" (typical inline-clear gesture).
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
END;
$function$;

GRANT EXECUTE ON FUNCTION public.update_premises_metadata(uuid, text, text, boolean) TO authenticated;
