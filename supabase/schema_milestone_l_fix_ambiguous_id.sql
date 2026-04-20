-- Fix 42702 ambiguity in delete_client / restore_client.
-- Both functions have SETOF return columns that include `id`, which
-- shadowed the clients.id column in UPDATE ... WHERE id = p_client_id.
-- Qualify the column refs with the table alias.

CREATE OR REPLACE FUNCTION public.delete_client(p_client_id uuid)
RETURNS TABLE (
  id          uuid,
  practice_id uuid,
  name        text,
  deleted_at  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'delete_client: client % not found', p_client_id
      USING ERRCODE = 'P0002';
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
$fn$;


CREATE OR REPLACE FUNCTION public.restore_client(p_client_id uuid)
RETURNS TABLE (
  id          uuid,
  practice_id uuid,
  name        text,
  deleted_at  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_cascade_ts   timestamptz;
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
    INTO v_practice_id, v_cascade_ts
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'restore_client: client % not found', p_client_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'restore_client: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF v_cascade_ts IS NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  UPDATE plans AS p
     SET deleted_at = NULL
   WHERE p.client_id = p_client_id
     AND p.deleted_at = v_cascade_ts;

  UPDATE clients AS c
     SET deleted_at = NULL,
         updated_at = now()
   WHERE c.id = p_client_id;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$fn$;
