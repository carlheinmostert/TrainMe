-- Milestone J — rename_client RPC.
--
-- Lets a practitioner rename a client. Needed because `upsert_client`
-- is lookup-or-create (the publish path uses it to resolve a clientName
-- free-text field to a client row) — it CANNOT change an existing row's
-- name. Quick-flow session creation in the mobile app uses a
-- date-timestamp as the clientName by default, so practitioners need
-- a way to fix these after the fact.
--
-- Practice-membership check mirrors `set_client_video_consent`:
-- SECURITY DEFINER, caller must be a member of the client's practice.
-- The UNIQUE(practice_id, name) constraint on `clients` throws
-- `unique_violation` (23505) on conflict — we catch that and raise a
-- named error so the portal can show a nice message.

CREATE OR REPLACE FUNCTION public.rename_client(
  p_client_id uuid,
  p_new_name  text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_practice_id uuid;
  v_trimmed text := btrim(coalesce(p_new_name, ''));
BEGIN
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  -- Look up the practice so we can gate membership. Using the caller's
  -- RLS view of clients would 404 silently on non-members; this RPC is
  -- SECURITY DEFINER so we look up directly and gate explicitly.
  SELECT practice_id INTO v_practice_id
  FROM clients
  WHERE id = p_client_id;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'client not found' USING ERRCODE = 'P0002';
  END IF;

  -- Practice-membership gate. `user_practice_ids()` is the SECURITY
  -- DEFINER helper from Milestone C — bypasses RLS on practice_members
  -- so we don't self-recurse.
  IF NOT (v_practice_id = ANY (user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this client''s practice'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    UPDATE clients
    SET name = v_trimmed,
        updated_at = now()
    WHERE id = p_client_id;
  EXCEPTION WHEN unique_violation THEN
    -- UNIQUE(practice_id, name) conflict — another client in this
    -- practice already uses the target name.
    RAISE EXCEPTION 'a client with that name already exists'
      USING ERRCODE = '23505';
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.rename_client(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rename_client(uuid, text) TO authenticated;

-- Smoke test: call on a fake id, confirm the "client not found" branch
-- fires cleanly. Run only as admin or via `supabase db query`.
-- SELECT public.rename_client('00000000-0000-0000-0000-000000000000', 'test');
