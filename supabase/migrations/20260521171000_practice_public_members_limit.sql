-- ============================================================================
-- Q-H1 fix (synthesis 2026-05-21): cap get_practice_public_members at 50 rows
-- ============================================================================
-- The original function (20260521151000_practice_public_members.sql) had no
-- LIMIT in the RETURN QUERY. A pathological practice with hundreds of members
-- would return the full set to anon, taking time + bandwidth + render budget
-- on /v/{slug}. The public profile UI only ever shows the top N team cards
-- and there's no pagination on this surface — a server-side cap is the right
-- gate.
--
-- 50 matches the design spec: the public-profile team grid never paginates;
-- 50 is the documented soft maximum.
--
-- Column list + privacy semantics are preserved verbatim from the previous
-- definition per feedback_schema_migration_column_preservation. Sourced from
-- the prior migration file (the live DB definition is identical).
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_practice_public_members(p_practice_id uuid)
 RETURNS TABLE(
   display_name text,
   role text
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_listed boolean;
BEGIN
  IF p_practice_id IS NULL THEN
    RETURN;
  END IF;

  SELECT public_profile_listed INTO v_listed
  FROM public.practices
  WHERE id = p_practice_id
  LIMIT 1;

  -- Mirror the privacy contract of get_practice_profile: unlisted
  -- practices return nothing so we don't confirm membership rosters
  -- for slugs that aren't in the directory.
  IF NOT coalesce(v_listed, false) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    -- Never expose a full email. Fall back to the local-part only if
    -- display_name is missing so anon callers never see "@" addresses.
    coalesce(
      nullif(btrim(u.raw_user_meta_data->>'display_name'), ''),
      split_part(u.email, '@', 1),
      'Practitioner'
    )::text AS display_name,
    pm.role::text AS role
  FROM public.practice_members pm
  JOIN auth.users u ON u.id = pm.trainer_id
  WHERE pm.practice_id = p_practice_id
  ORDER BY
    -- Owners first, then practitioners; within each tier sort
    -- alphabetically by display_name for a stable render.
    CASE WHEN pm.role = 'owner' THEN 0 ELSE 1 END,
    coalesce(
      nullif(btrim(u.raw_user_meta_data->>'display_name'), ''),
      split_part(u.email, '@', 1)
    ) ASC
  -- Q-H1: hard cap. Public profile team grid never paginates.
  LIMIT 50;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_practice_public_members(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_practice_public_members(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_practice_public_members(uuid) TO authenticated;

COMMIT;
