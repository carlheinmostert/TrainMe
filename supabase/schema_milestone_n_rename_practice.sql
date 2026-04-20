-- Milestone N — rename_practice RPC.
--
-- Lets a practice OWNER rename their practice. The default practice name
-- on first sign-in is `{email} Practice` (e.g. "carlhein@me.com Practice"),
-- which is ugly and impersonal — this RPC powers the inline rename on
-- the portal dashboard + Account Settings, and (future) the mobile
-- practice-chip sheet.
--
-- Contract:
--   Args: p_practice_id (uuid), p_new_name (text)
--   Returns: the updated practices row
--   Permissions: caller must be the OWNER of the practice — practitioners
--   get 42501 insufficient_privilege.
--
-- SQLSTATE mapping (mirrors rename_client from milestone J so the portal
-- error mapper stays consistent):
--   22023 invalid_parameter_value — empty or too-long name
--   P0002 no_data_found           — practice doesn't exist
--   42501 insufficient_privilege  — caller isn't the practice owner
--
-- Why SECURITY DEFINER? `practices` carries RLS policies that allow any
-- member to SELECT their practice but UPDATE is reserved. Rather than
-- adding a UPDATE policy that would have to re-check ownership (and
-- surface as a silent 0-rows-affected on non-owners), we gate explicitly
-- via `user_is_practice_owner(pid)` and let the DEFINER bypass RLS. The
-- 60-char cap and whitespace trim are ALSO enforced here — the RPC is
-- the only supported write path, clients cannot UPDATE the table
-- directly.

-- Practices.name limit: 60 chars feels generous for a practitioner
-- practice name while keeping dashboard copy scannable. Matches the
-- brief. If a longer name is ever needed, bump here + the JS maxLength
-- at the callsite in one go.

CREATE OR REPLACE FUNCTION public.rename_practice(
  p_practice_id uuid,
  p_new_name    text
)
RETURNS SETOF public.practices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trimmed text := btrim(coalesce(p_new_name, ''));
BEGIN
  -- Empty-after-trim → named error.
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  -- Length cap. 60 chars is the UX contract for dashboard rendering.
  IF char_length(v_trimmed) > 60 THEN
    RAISE EXCEPTION 'name too long (max 60 chars)' USING ERRCODE = '22023';
  END IF;

  -- Existence check BEFORE the ownership check so the error surface is
  -- "practice not found" (P0002) rather than "not a member" (42501) for
  -- a bad uuid. Same precedence rename_client uses.
  IF NOT EXISTS (SELECT 1 FROM practices WHERE id = p_practice_id) THEN
    RAISE EXCEPTION 'practice not found' USING ERRCODE = 'P0002';
  END IF;

  -- Owner-only. `user_is_practice_owner` is the Milestone C SECURITY
  -- DEFINER helper — bypasses RLS on practice_members so we don't
  -- self-recurse. Practitioners (non-owner members) hit this branch.
  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'only the practice owner can rename it'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  UPDATE practices
     SET name = v_trimmed
   WHERE id = p_practice_id
  RETURNING *;
END;
$$;

REVOKE ALL ON FUNCTION public.rename_practice(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rename_practice(uuid, text) TO authenticated;

-- Smoke test: call on a fake id, confirm the "practice not found"
-- branch fires. Run only as admin / via `supabase db query`.
-- SELECT * FROM public.rename_practice('00000000-0000-0000-0000-000000000000', 'test');
