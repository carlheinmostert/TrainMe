-- Milestone K — upsert_client_with_id RPC.
--
-- Offline-first parallel to Milestone G's `upsert_client(p_practice_id,
-- p_name)`. The original RPC lets the server mint the uuid; that's a
-- problem for the mobile app's pending-sync queue, which needs to
-- write a local `cached_clients` row (with an id) BEFORE contacting the
-- server so the practitioner sees the client immediately while offline.
-- The row must survive the eventual sync without the UI having to
-- re-address anything.
--
-- This RPC accepts the caller's pre-generated uuid. Three return
-- shapes, matching the mobile SyncService's rewire logic:
--
--   1. Fresh row — id is not yet in the table and no name conflict:
--      INSERT with p_id + p_name. Returns p_id.
--
--   2. Idempotent re-apply — row with p_id already exists in the
--      practice (sync raced and this is a replay): returns p_id
--      unchanged. The caller treats that as "already synced, drop
--      the pending op".
--
--   3. Name conflict — a DIFFERENT row in this practice already uses
--      p_name (two devices offline, both picked the same name): returns
--      the EXISTING row's id, not p_id. The mobile sync loop detects
--      "returned id != sent id" and rewires its local cached_clients +
--      sessions.client_id references from p_id to the server's id
--      (last-write-wins silently per the SyncService conflict policy).
--
-- Practice-membership gate mirrors rename_client / upsert_client.

CREATE OR REPLACE FUNCTION public.upsert_client_with_id(
  p_id          uuid,
  p_practice_id uuid,
  p_name        text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trimmed     text := btrim(coalesce(p_name, ''));
  v_existing_id uuid;
BEGIN
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  -- Practice-membership gate. user_practice_ids() is the SECURITY
  -- DEFINER helper from Milestone C (see schema_milestone_c_recursion_fix).
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  -- Conflict shape 1: idempotent retry — same id already exists. Return
  -- unchanged.
  IF EXISTS (SELECT 1 FROM clients WHERE id = p_id) THEN
    RETURN p_id;
  END IF;

  -- Conflict shape 2: another row in this practice already uses the
  -- target name. Return that row's id so the mobile loop can rewire.
  SELECT id INTO v_existing_id
  FROM clients
  WHERE practice_id = p_practice_id AND name = v_trimmed;
  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  -- No conflict — insert with the caller's id.
  INSERT INTO clients (id, practice_id, name)
  VALUES (p_id, p_practice_id, v_trimmed);
  RETURN p_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_client_with_id(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_client_with_id(uuid, uuid, text) TO authenticated;

-- Smoke tests (run as admin or via supabase db query):
--
--   -- Fresh insert:
--   -- SELECT public.upsert_client_with_id(
--   --   '00000000-0000-0000-0000-00000000abcd'::uuid,
--   --   '<valid_practice_id>'::uuid,
--   --   'Test Client'
--   -- );  -- expect: 00000000-...-00000000abcd
--
--   -- Idempotent replay:
--   -- SELECT public.upsert_client_with_id(
--   --   '00000000-0000-0000-0000-00000000abcd'::uuid,
--   --   '<valid_practice_id>'::uuid,
--   --   'Test Client'
--   -- );  -- expect: same id back
--
--   -- Name conflict (new id, colliding name):
--   -- SELECT public.upsert_client_with_id(
--   --   gen_random_uuid(),
--   --   '<valid_practice_id>'::uuid,
--   --   'Test Client'
--   -- );  -- expect: 00000000-...-00000000abcd (the EXISTING row's id)
