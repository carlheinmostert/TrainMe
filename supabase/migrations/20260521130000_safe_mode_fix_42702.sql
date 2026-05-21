-- ============================================================================
-- Safe Mode hotfix — list_practice_premises: 42702 column shadowing
-- ============================================================================
-- The original definition in 20260521120000_safe_mode.sql declares
-- `practice_id uuid` as an OUT column in RETURNS TABLE(...), then the
-- function body does:
--
--   SELECT 1 FROM practice_members
--    WHERE practice_id = p_practice_id AND trainer_id = v_caller
--
-- Postgres can't tell whether the unqualified `practice_id` references
-- the OUT column or `practice_members.practice_id` and errors with
-- 42702 ("column reference is ambiguous"). The portal's RPC wrapper
-- silently swallowed the error and showed an empty premises list, so
-- newly-created rows appeared to vanish.
--
-- Fix: alias `practice_members AS pm` and qualify both columns. The
-- column list in RETURNS TABLE is preserved exactly per the
-- column-preservation rule (CLAUDE.md gotchas). Same SECURITY DEFINER,
-- same search_path, same grants (CREATE OR REPLACE keeps them on a
-- same-signature replacement).
--
-- Same family of bug as the recurring `delete_client` 42702 incident
-- (PR #37) — qualify EVERY ref inside a SECURITY DEFINER fn whose
-- RETURNS TABLE column names overlap with the tables it queries.
-- ============================================================================

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
    extensions.ST_AsGeoJSON(pp.polygon)::text,
    extensions.ST_Y(extensions.ST_Centroid(pp.polygon))::double precision,
    extensions.ST_X(extensions.ST_Centroid(pp.polygon))::double precision,
    extensions.ST_Area(pp.polygon::extensions.geography)::double precision,
    pp.safe_mode_enforced,
    pp.signal_type,
    pp.created_at,
    pp.updated_at
  FROM public.practice_premises AS pp
  WHERE pp.practice_id = p_practice_id
    AND pp.deleted_at IS NULL
  ORDER BY pp.created_at ASC;
END;
$function$;
