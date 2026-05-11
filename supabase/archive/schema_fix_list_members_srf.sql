-- Hotfix: `list_practice_members_with_profile` used `= ANY (public.user_practice_ids())`
-- but `user_practice_ids()` is a set-returning function (not a scalar array).
-- Postgres throws `42809: op ANY/ALL (array) requires array on right side`
-- → PostgREST surfaces as a 500, the portal error-handler falls to an empty
-- list, and the practitioner sees "no members" on /members.
--
-- Fix: use `IN (SELECT public.user_practice_ids())` — same pattern every
-- other SECURITY DEFINER RPC in the codebase uses against `user_practice_ids()`.
-- Signature unchanged; CREATE OR REPLACE is safe.

CREATE OR REPLACE FUNCTION public.list_practice_members_with_profile(p_practice_id uuid)
 RETURNS TABLE(trainer_id uuid, email text, full_name text, role text, joined_at timestamp with time zone, is_current_user boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  -- Any practice member can see fellow members. Use the helper fn rather
  -- than a direct subquery on practice_members (avoids RLS recursion).
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      pm.trainer_id,
      u.email::text,
      COALESCE(
        (u.raw_user_meta_data->>'full_name'),
        (u.raw_user_meta_data->>'name'),
        ''
      )::text AS full_name,
      pm.role,
      pm.joined_at,
      (pm.trainer_id = auth.uid()) AS is_current_user
    FROM public.practice_members pm
    JOIN auth.users u ON u.id = pm.trainer_id
    WHERE pm.practice_id = p_practice_id
    ORDER BY pm.joined_at;
END;
$function$;
