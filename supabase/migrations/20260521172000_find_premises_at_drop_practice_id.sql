-- ============================================================================
-- S-H1 fix (synthesis 2026-05-21): drop practice_id from find_premises_at()
-- ============================================================================
-- `find_premises_at(lat, lng)` is anon-callable so any client can hit it. The
-- previous return shape included `practice_id`, which an attacker could pair
-- with a sweep over likely lat/lng coordinates to enumerate which practices
-- own enforced premises in a given area — a privacy leak (a practitioner's
-- studio address is sensitive).
--
-- Mobile only uses `premises_id`, `premises_name`, `safe_mode_enforced` (see
-- app/lib/services/safe_mode_service.dart — it never reads `practice_id`
-- from the result). Dropping it from the return shape is a no-op for the
-- mobile flow.
--
-- CREATE OR REPLACE cannot change return type — drop + recreate. Re-add
-- the grants the original migration declared.
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.find_premises_at(double precision, double precision);

CREATE FUNCTION public.find_premises_at(
  p_lat double precision,
  p_lng double precision
)
 RETURNS TABLE(
   premises_id uuid,
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

REVOKE ALL ON FUNCTION public.find_premises_at(double precision, double precision) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.find_premises_at(double precision, double precision) TO anon;
GRANT EXECUTE ON FUNCTION public.find_premises_at(double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_premises_at(double precision, double precision) TO service_role;

COMMIT;
