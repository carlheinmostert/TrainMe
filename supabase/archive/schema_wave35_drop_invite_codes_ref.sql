-- ============================================================================
-- Wave 35 — Drop dead practice_invite_codes reference from remove_practice_member
-- ============================================================================
-- Wave 14 (milestone U) retired the invite-code flow and dropped the
-- `practice_invite_codes` table outright. The accompanying RPC drop list
-- captured `mint_practice_invite_code` + `claim_practice_invite_code`,
-- but missed the dead UPDATE inside `remove_practice_member` that still
-- pointed at the now-defunct table:
--
--   UPDATE public.practice_invite_codes
--      SET revoked_at = now()
--    WHERE practice_id = p_practice_id
--      AND created_by  = p_trainer_id
--      AND claimed_at IS NULL
--      AND revoked_at IS NULL;
--
-- That branch was a "revoke any unclaimed invite codes this user minted"
-- book-keeping step from Wave 5. With the table gone, it raises
--   ERROR: relation "public.practice_invite_codes" does not exist
-- the moment an owner clicks Remove on a member row, so the entire
-- remove flow is broken in production.
--
-- Fix: drop the dead UPDATE. Behaviour stays identical to Wave 14's
-- intent — without the table, there's nothing to revoke. Owner-only
-- guard, last-owner guard, self-remove rejection, and the actual
-- DELETE are unchanged.
--
-- Apply with:
--   supabase db query --linked --file supabase/schema_wave35_drop_invite_codes_ref.sql
--
-- Verify post-apply (no rows expected):
--   SELECT proname FROM pg_proc WHERE prosrc LIKE '%practice_invite_codes%';

CREATE OR REPLACE FUNCTION public.remove_practice_member(
  p_practice_id uuid,
  p_trainer_id  uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_role       text;
  v_owner_count int;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  IF p_trainer_id = v_caller THEN
    RAISE EXCEPTION 'use leave_practice to remove yourself'
      USING ERRCODE = '22023';
  END IF;

  -- Lock the target row. P0002 if they're not a member.
  SELECT pm.role
    INTO v_role
    FROM public.practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.trainer_id  = p_trainer_id
   FOR UPDATE;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'member not found' USING ERRCODE = 'P0002';
  END IF;

  -- Last-owner guard.
  IF v_role = 'owner' THEN
    SELECT COUNT(*)
      INTO v_owner_count
      FROM public.practice_members
     WHERE practice_id = p_practice_id
       AND role = 'owner'
       AND trainer_id <> p_trainer_id;

    IF v_owner_count = 0 THEN
      RAISE EXCEPTION 'cannot remove the last owner'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Wave 14 retired practice_invite_codes; the legacy "revoke unclaimed
  -- codes" UPDATE has been removed. Nothing else to clean up before the
  -- DELETE — auth.users + credit_ledger + plan_issuances are FK-attached
  -- to auth.users, not to this pivot, so they survive the removal.

  DELETE FROM public.practice_members
   WHERE practice_id = p_practice_id
     AND trainer_id  = p_trainer_id;
END;
$$;

-- Grants survive across CREATE OR REPLACE; no need to re-grant.
