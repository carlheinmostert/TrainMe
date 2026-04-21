-- Hotfix: `delete_client` + `restore_client` threw P0002 "not found" when
-- invoked against a client_id that doesn't exist on the server. The
-- offline-first SyncService flush retries that exception forever, so any
-- pending delete/restore for a client that was never synced (or was
-- already deleted on another device) sticks in `pending_ops` and grows
-- the "N pending" chip indefinitely.
--
-- Symptom Carl hit 2026-04-21: 19 pending deletes on mobile Home.
--
-- Fix: treat "client not found on server" as a no-op (empty RETURN QUERY)
-- — the intended state (gone / restored) is already satisfied. Existing
-- already-soft-deleted rows still return their tombstone per original
-- Milestone L semantics. The membership check still fires against a real
-- practice when the row exists; it's skipped on the missing-row path
-- because there's nothing to authorise.
--
-- Signatures unchanged; CREATE OR REPLACE is safe.

CREATE OR REPLACE FUNCTION public.delete_client(p_client_id uuid)
 RETURNS TABLE(id uuid, practice_id uuid, name text, deleted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_now          timestamptz := now();
  v_existing_ts  timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'delete_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'delete_client: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_existing_ts
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  -- Idempotent no-op: client doesn't exist on server. Intended state
  -- (absent / tombstoned) is satisfied. Return empty so the mobile
  -- SyncService flush treats it as drained.
  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'delete_client: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF v_existing_ts IS NOT NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  UPDATE clients AS c
     SET deleted_at = v_now,
         updated_at = v_now
   WHERE c.id = p_client_id;

  UPDATE plans AS p
     SET deleted_at = v_now
   WHERE p.client_id = p_client_id
     AND p.deleted_at IS NULL;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.restore_client(p_client_id uuid)
 RETURNS TABLE(id uuid, practice_id uuid, name text, deleted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
  v_deleted_ts  timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'restore_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'restore_client: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_deleted_ts
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  -- Idempotent no-op on missing row.
  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'restore_client: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- No-op if the client isn't tombstoned; return the live row.
  IF v_deleted_ts IS NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  UPDATE clients AS c
     SET deleted_at = NULL,
         updated_at = now()
   WHERE c.id = p_client_id;

  UPDATE plans AS p
     SET deleted_at = NULL
   WHERE p.client_id = p_client_id
     AND p.deleted_at = v_deleted_ts;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$function$;
