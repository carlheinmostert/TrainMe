-- Hotfix: `claim_practice_invite` failed with `42702: column reference
-- "practice_id" is ambiguous` on every claim. The `IF NOT EXISTS` membership-
-- idempotency subquery had unqualified `practice_id` / `trainer_id` refs
-- that collided with the RETURNS TABLE OUT column `practice_id uuid`.
--
-- This is the exact trap CLAUDE.md warns about under "Infrastructure
-- Gotchas — PL/pgSQL 42702 SETOF OUT-column shadowing (qualify UPDATE
-- WHERE refs)". Also the same class of bug Milestone L's delete_client
-- hit.
--
-- Fix: alias practice_members as `pm` and qualify both column refs.
-- Signature unchanged; CREATE OR REPLACE is safe.

CREATE OR REPLACE FUNCTION public.claim_practice_invite(p_code text)
 RETURNS TABLE(practice_id uuid, practice_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_practice_id   uuid;
  v_practice_name text;
  v_caller        uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF p_code IS NULL OR length(p_code) <> 7 THEN
    RAISE EXCEPTION 'invalid code' USING ERRCODE = '22023';
  END IF;

  -- Lock the row so two concurrent claims can't both succeed.
  SELECT pic.practice_id
    INTO v_practice_id
    FROM public.practice_invite_codes pic
   WHERE pic.code = upper(p_code)
     AND pic.claimed_at IS NULL
     AND pic.revoked_at IS NULL
   FOR UPDATE;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'invalid or already-used code' USING ERRCODE = 'P0002';
  END IF;

  -- Idempotency: if the caller is already a member, skip the insert but
  -- still stamp the code as claimed by this user. (Avoids the "already a
  -- member" UX dead-end — the common case is a practitioner re-clicking
  -- their invite link after the first successful claim.)
  IF NOT EXISTS (
    SELECT 1
      FROM public.practice_members pm
     WHERE pm.practice_id = v_practice_id
       AND pm.trainer_id  = v_caller
  ) THEN
    INSERT INTO public.practice_members (practice_id, trainer_id, role, joined_at)
    VALUES (v_practice_id, v_caller, 'practitioner', now());
  END IF;

  UPDATE public.practice_invite_codes
     SET claimed_by = v_caller,
         claimed_at = now()
   WHERE code = upper(p_code);

  SELECT p.name
    INTO v_practice_name
    FROM public.practices p
   WHERE p.id = v_practice_id;

  RETURN QUERY SELECT v_practice_id, v_practice_name;
END;
$function$;
