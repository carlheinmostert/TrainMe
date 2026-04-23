-- Milestone W — list_all_client_names RPC.
--
-- Problem:
--   The default client-name picker in the mobile app mints sequential
--   names ("New client 1", "New client 2", ...). It used to scan only
--   the local cache for collisions. But `list_practice_clients` filters
--   `deleted_at IS NOT NULL`, so soft-deleted rows never land in the
--   cache — the picker was blind to recycle-bin names.
--
--   Result: deleting "New client 1" (soft-delete, still on cloud) then
--   creating a new client mints "New client 1" again → publish calls
--   upsert_client → server unique index sees the soft-deleted row →
--   raises 23505 "a deleted client already uses that name — restore it
--   instead". User is stuck in a loop with no way to fix it.
--
-- Fix:
--   Expose a thin RPC that returns EVERY client name in the practice,
--   regardless of `deleted_at`. The mobile picker calls it, unions
--   with the local cache, and picks the lowest-N that appears in
--   neither. Offline callers fall back to the local-cache-only scan
--   (which is correct when the cache is authoritative for the local
--   device's lifetime).
--
-- Security model:
--   SECURITY DEFINER + practice-membership gate, same as every other
--   client RPC in milestone G / L. Names are low-sensitivity data —
--   a member already sees all active names via `list_practice_clients`;
--   this just adds the tombstoned ones for collision detection.

CREATE OR REPLACE FUNCTION public.list_all_client_names(p_practice_id uuid)
RETURNS TABLE (name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_all_client_names requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_all_client_names: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_all_client_names: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT c.name
      FROM clients c
     WHERE c.practice_id = p_practice_id;
END;
$$;

REVOKE ALL ON FUNCTION public.list_all_client_names(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_all_client_names(uuid) TO authenticated;
