-- Fix `get_practice_profile_owner` — wrap `user_practice_ids()` in a
-- subquery so `= ANY (...)` gets an array shape, not a SRF.
--
-- Background
-- ----------
-- `user_practice_ids()` is a SETOF uuid (set-returning function). When
-- called as the right-hand side of `= ANY (...)`, Postgres needs an
-- array OR a subquery — it cannot consume a SRF directly. The line:
--
--   IF NOT (p_practice_id = ANY (public.user_practice_ids())) THEN
--
-- throws `42809: op ANY/ALL (array) requires array on right side` on
-- every invocation. PostgREST surfaces that as 400 Bad Request to the
-- web portal, so the public-profile editor's hydration call fails
-- every time, making it look like saves don't persist (saves DO
-- persist — the 204 lands cleanly — but the read-back to populate the
-- form fails, so the UI shows stale empty state).
--
-- Same gotcha is documented in `gotchas_publish_path.md` / general
-- `infrastructure_gotchas.md` ("`= ANY (SRF)` invalid"). Every other
-- caller of `user_practice_ids()` in the codebase uses
-- `= ANY (SELECT public.user_practice_ids())` — only this one RPC
-- missed the wrap.
--
-- Fix: add the `SELECT ... ` subquery wrapper. Function signature and
-- behaviour are otherwise byte-identical.
--
-- Symptom observed on staging 2026-05-23: every save to the
-- /public-profile portal page returned 204 (success) but the page
-- never re-rendered the saved values because the subsequent fetch via
-- `get_practice_profile_owner` returned 400.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_practice_profile_owner(p_practice_id uuid)
 RETURNS TABLE(
   practice_id        uuid,
   practice_name      text,
   slug               text,
   logo_url           text,
   blurb              text,
   premises           jsonb,
   brand_color        text,
   tagline            text,
   specialties        text[],
   contact_email      text,
   contact_whatsapp   text,
   contact_website    text,
   listed             boolean
 )
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_practice_profile_owner requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Membership check: caller must belong to the practice. Wrap the SRF
  -- in a SELECT so `= ANY (...)` consumes an array, not a SETOF.
  IF NOT (p_practice_id = ANY (SELECT public.user_practice_ids())) THEN
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
GRANT EXECUTE ON FUNCTION public.get_practice_profile_owner(uuid) TO service_role;

COMMIT;
