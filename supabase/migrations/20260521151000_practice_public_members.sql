-- ============================================================================
-- Public Profile v2 — practitioner cards on /v/{slug}
-- ============================================================================
-- Adds get_practice_public_members(p_practice_id), an anon-readable
-- SECURITY DEFINER RPC that returns the display_name + role for every
-- practice_member row when the practice has opted into the directory
-- (public_profile_listed=true).
--
-- Privacy: no email and no trainer_id ever leaves the DB. The web
-- player at /v/{slug} renders initials avatars from display_name; if a
-- user has no display_name we fall back to the email local-part on the
-- DB side so the public surface never sees a full email.
--
-- Spec: docs/specs/2026-05-21-public-profile-v2-design.md (Task 14)
-- Plan: docs/plans/2026-05-21-public-profile-v2-plan.md (Task 14)
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
    ) ASC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_practice_public_members(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_practice_public_members(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_practice_public_members(uuid) TO authenticated;

COMMIT;
