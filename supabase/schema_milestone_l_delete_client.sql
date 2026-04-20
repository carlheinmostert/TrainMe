-- Milestone L — delete_client + restore_client (soft-delete with cascade).
--
-- Adds a `deleted_at` tombstone column to `public.clients` and a pair of
-- SECURITY DEFINER RPCs that soft-delete a client together with its plans
-- in a single transaction. "Restore" reverses the cascade using the same
-- timestamp so we only un-delete what was cascaded — plans that were
-- manually soft-deleted earlier stay deleted.
--
-- Why soft delete, not hard delete?
--   * R-01: destructive actions fire immediately with a 7-second undo
--     window in the UI (SnackBar on mobile, toast on portal). The undo
--     MUST work even after the optimistic local update has settled — a
--     true DELETE would strand the FK cascade side-effects (plans,
--     exercises) and force a sync round-trip to "restore" them.
--   * A follow-up cron / admin pass can hard-purge rows whose
--     `deleted_at < now() - interval '7 days'` when a recycle bin is
--     wired; out of scope here.
--
-- Cascade shape
--   * `delete_client(p_client_id)`:
--       1. Stamp clients.deleted_at = now() (idempotent if already set).
--       2. UPDATE plans SET deleted_at = clients.deleted_at WHERE
--          plans.client_id = p_client_id AND plans.deleted_at IS NULL.
--          We copy the EXACT client timestamp onto the cascaded plans
--          so restore can find them later by timestamp equality.
--   * `restore_client(p_client_id)`:
--       1. Capture the current deleted_at timestamp on the client row.
--       2. UPDATE plans SET deleted_at = NULL WHERE plans.client_id =
--          p_client_id AND plans.deleted_at = <captured-ts>. Plans
--          soft-deleted at any other timestamp stay deleted — only the
--          cascade from this client's delete is reversed.
--       3. Clear clients.deleted_at. Order is deliberate: if step 2
--          throws, step 3 still runs inside the same transaction and
--          the whole thing rolls back.
--
-- Tenancy
--   All three client-touching RPCs this migration ships (delete_client,
--   restore_client, plus the patched list_practice_clients +
--   get_client_by_id) gate on `user_practice_ids()` the same way milestone
--   G's upsert_client / set_client_video_consent do. SECURITY DEFINER
--   lookups through practice_members bypass RLS on the helper call itself
--   (no self-referential recursion); the explicit membership check in SQL
--   is the authoritative gate.
--
-- Idempotency + safety
--   * Safe to replay — `delete_client` on an already-soft-deleted client
--     is a no-op (WHERE deleted_at IS NULL filters it out). Returns the
--     existing tombstoned row.
--   * Safe to replay — `restore_client` on an already-live client is a
--     no-op. Returns the existing row.
--   * The patched list_practice_clients / get_client_by_id filter
--     deleted rows out so UI surfaces never surface a deleted client
--     (even if some page holds onto the UUID).
--   * upsert_client / set_client_video_consent / rename_client / list_sessions_for_client
--     reject deleted clients with a 22023 ("client has been deleted") —
--     stops a pending offline op from resurrecting a deleted row.
--
-- Does NOT touch
--   * `schema.sql` — Carl regenerates the canonical snapshot separately.
--   * Storage — media / raw-archive objects for deleted clients stay in
--     place. A future purge job handles cleanup in concert with the 7-day
--     hard-delete window.

BEGIN;

-- ============================================================================
-- 1. Tombstone columns
-- ============================================================================
-- clients.deleted_at — tombstones a client row.
ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- Partial index makes "active clients" lookups cheap while costing almost
-- nothing in the deleted case.
CREATE INDEX IF NOT EXISTS idx_clients_active
  ON public.clients (practice_id)
  WHERE deleted_at IS NULL;

-- plans.deleted_at — tombstones a plan row. Cascade from delete_client
-- stamps this with the SAME timestamp as the owning client so
-- restore_client can reverse precisely what we cascaded (plans
-- soft-deleted at any other timestamp stay deleted).
--
-- list_practice_clients / list_sessions_for_client both filter on
-- `plans.deleted_at IS NULL` so cascaded-deleted plans don't surface
-- to the trainer app or portal. get_plan_full deliberately stays
-- unfiltered — if a client has a live link to a plan whose owning
-- client got soft-deleted, we'd rather serve the plan than 404 (the
-- 7-day purge is the hard boundary).
ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- Partial index — every hot path ("alive plans for this client",
-- "alive plans for this practice") filters on `deleted_at IS NULL`,
-- so the partial form is the most compact.
CREATE INDEX IF NOT EXISTS plans_deleted_at_idx
  ON public.plans (deleted_at)
  WHERE deleted_at IS NULL;

-- ============================================================================
-- 2. delete_client RPC — soft-delete with cascade to plans
-- ============================================================================
CREATE OR REPLACE FUNCTION public.delete_client(
  p_client_id uuid
)
RETURNS TABLE (
  id             uuid,
  practice_id    uuid,
  name           text,
  deleted_at     timestamptz
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

  -- Look up the client (including already-deleted rows so replay is a
  -- clean no-op that still returns the tombstoned row).
  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_existing_ts
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'delete_client: client % not found', p_client_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Practice-membership gate. Mirrors rename_client / upsert_client.
  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'delete_client: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Already soft-deleted → return the tombstoned row unchanged.
  IF v_existing_ts IS NOT NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  -- Stamp the client tombstone.
  UPDATE clients
     SET deleted_at = v_now,
         updated_at = v_now
   WHERE id = p_client_id;

  -- Cascade to plans owned by this client. Use the SAME timestamp the
  -- client got so restore can match by equality.
  UPDATE plans
     SET deleted_at = v_now
   WHERE client_id = p_client_id
     AND deleted_at IS NULL;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.delete_client(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_client(uuid) TO authenticated;

-- ============================================================================
-- 3. restore_client RPC — reverse the cascade
-- ============================================================================
CREATE OR REPLACE FUNCTION public.restore_client(
  p_client_id uuid
)
RETURNS TABLE (
  id             uuid,
  practice_id    uuid,
  name           text,
  deleted_at     timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller        uuid := auth.uid();
  v_practice_id   uuid;
  v_cascade_ts    timestamptz;
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

  -- Not deleted → return current row unchanged (idempotent no-op).
  IF v_cascade_ts IS NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  -- Reverse the cascade first: restore plans whose deleted_at matches
  -- the client's deleted_at exactly. Anything manually soft-deleted at
  -- another timestamp stays deleted — the "undo what we cascaded"
  -- invariant holds.
  UPDATE plans
     SET deleted_at = NULL
   WHERE client_id = p_client_id
     AND deleted_at = v_cascade_ts;

  -- Then restore the client row itself.
  UPDATE clients
     SET deleted_at = NULL,
         updated_at = now()
   WHERE id = p_client_id;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.restore_client(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.restore_client(uuid) TO authenticated;

-- ============================================================================
-- 4. Patch list_practice_clients + get_client_by_id to filter deleted
-- ============================================================================
-- list_practice_clients — same shape as milestone G, plus deleted filter.
CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
RETURNS TABLE (
  id             uuid,
  name           text,
  video_consent  jsonb,
  last_plan_at   timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = p_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_practice_clients: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         (SELECT MAX(COALESCE(p.sent_at, p.created_at))
            FROM plans p
           WHERE p.client_id = c.id
             AND p.deleted_at IS NULL) AS last_plan_at
    FROM clients c
   WHERE c.practice_id = p_practice_id
     AND c.deleted_at IS NULL
   ORDER BY last_plan_at DESC NULLS LAST, c.name ASC;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.list_practice_clients(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.list_practice_clients(uuid) FROM anon, public;

-- get_client_by_id — same shape, skip deleted rows.
CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
RETURNS TABLE (
  id             uuid,
  name           text,
  video_consent  jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_by_id requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;  -- empty set; client doesn't exist OR is deleted
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = v_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RETURN;  -- empty set; caller isn't a member
  END IF;

  RETURN QUERY
  SELECT c.id, c.name, c.video_consent
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.get_client_by_id(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_client_by_id(uuid) FROM anon, public;

-- ============================================================================
-- 5. Harden mutation RPCs — reject operations on deleted clients
-- ============================================================================
-- upsert_client_with_id: if a deleted row with p_id exists, DON'T return
-- p_id (which would be an implicit resurrect). Raise instead so the
-- offline queue can surface a clear error.
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
  v_deleted_at  timestamptz;
BEGIN
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  -- Idempotent retry — same id. Reject if the existing row is deleted;
  -- otherwise return unchanged.
  SELECT deleted_at INTO v_deleted_at
    FROM clients WHERE id = p_id;
  IF FOUND THEN
    IF v_deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'client has been deleted'
        USING ERRCODE = '22023';
    END IF;
    RETURN p_id;
  END IF;

  -- Name conflict — another row (active or deleted) in this practice uses
  -- p_name. If the matching row is deleted, reject (don't silently
  -- resurrect under a different id); if active, return its id so the
  -- mobile SyncService can rewire.
  SELECT id, deleted_at INTO v_existing_id, v_deleted_at
    FROM clients
   WHERE practice_id = p_practice_id AND name = v_trimmed
   LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    IF v_deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'a deleted client already uses that name — restore it instead'
        USING ERRCODE = '23505';
    END IF;
    RETURN v_existing_id;
  END IF;

  INSERT INTO clients (id, practice_id, name)
  VALUES (p_id, p_practice_id, v_trimmed);
  RETURN p_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_client_with_id(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_client_with_id(uuid, uuid, text) TO authenticated;

-- upsert_client (server-minted id variant): same hardening.
CREATE OR REPLACE FUNCTION public.upsert_client(
  p_practice_id uuid,
  p_name        text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller uuid := auth.uid();
  v_id     uuid;
  v_deleted_at timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'upsert_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'upsert_client: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'upsert_client: p_name must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'upsert_client: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  SELECT id, deleted_at INTO v_id, v_deleted_at
    FROM clients
   WHERE practice_id = p_practice_id AND name = trim(p_name)
   LIMIT 1;

  IF v_id IS NOT NULL THEN
    IF v_deleted_at IS NOT NULL THEN
      RAISE EXCEPTION 'a deleted client already uses that name — restore it instead'
        USING ERRCODE = '23505';
    END IF;
    RETURN v_id;
  END IF;

  INSERT INTO clients (practice_id, name)
  VALUES (p_practice_id, trim(p_name))
  ON CONFLICT (practice_id, name) DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.upsert_client(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.upsert_client(uuid, text) FROM anon, public;

-- set_client_video_consent: reject deleted clients so stale offline ops don't
-- touch a tombstoned row.
CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id     uuid,
  p_line_drawing  boolean,
  p_grayscale     boolean,
  p_original      boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_deleted_at   timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_line_drawing IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'set_client_video_consent: line_drawing consent cannot be withdrawn (must be true)'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at INTO v_practice_id, v_deleted_at
    FROM clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_video_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE clients
     SET video_consent = jsonb_build_object(
           'line_drawing', true,
           'grayscale',    COALESCE(p_grayscale, false),
           'original',     COALESCE(p_original, false)
         )
   WHERE id = p_client_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean) FROM anon, public;

-- rename_client: reject deleted clients.
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
  v_deleted_at  timestamptz;
  v_trimmed text := btrim(coalesce(p_new_name, ''));
BEGIN
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at INTO v_practice_id, v_deleted_at
  FROM clients
  WHERE id = p_client_id;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'client not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'client has been deleted' USING ERRCODE = '22023';
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this client''s practice'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    UPDATE clients
    SET name = v_trimmed,
        updated_at = now()
    WHERE id = p_client_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'a client with that name already exists'
      USING ERRCODE = '23505';
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.rename_client(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rename_client(uuid, text) TO authenticated;

-- list_sessions_for_client: skip deleted clients (empty set, not 42501, so
-- the portal page falls through to its empty state cleanly).
CREATE OR REPLACE FUNCTION public.list_sessions_for_client(
  p_client_id uuid
)
RETURNS TABLE (
  id                 uuid,
  title              text,
  client_name        text,
  trainer_id         uuid,
  trainer_email      text,
  version            integer,
  last_published_at  timestamptz,
  first_opened_at    timestamptz,
  issuance_count     integer,
  exercise_count     integer,
  is_own_session     boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid          uuid    := auth.uid();
  v_practice_id  uuid;
  v_is_owner     boolean;
  v_is_member    boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'list_sessions_for_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'list_sessions_for_client: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM public.clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  v_is_owner  := public.user_is_practice_owner(v_practice_id);
  v_is_member := v_practice_id = ANY(ARRAY(SELECT public.user_practice_ids()));

  IF NOT v_is_member AND NOT v_is_owner THEN
    RAISE EXCEPTION 'list_sessions_for_client: caller % is not a member of practice %',
      v_uid, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH latest_issuance AS (
    SELECT DISTINCT ON (pi.plan_id)
           pi.plan_id,
           pi.trainer_id  AS last_trainer_id,
           pi.issued_at   AS last_issued_at
      FROM plan_issuances pi
     WHERE pi.practice_id = v_practice_id
     ORDER BY pi.plan_id, pi.issued_at DESC
  ),
  issuance_counts AS (
    SELECT pi.plan_id, COUNT(*)::integer AS issuance_count
      FROM plan_issuances pi
     WHERE pi.practice_id = v_practice_id
     GROUP BY pi.plan_id
  ),
  exercise_counts AS (
    SELECT e.plan_id, COUNT(*)::integer AS exercise_count
      FROM exercises e
     WHERE e.media_type IS DISTINCT FROM 'rest'
     GROUP BY e.plan_id
  )
  SELECT
    p.id,
    p.title,
    COALESCE(c.name, p.client_name)            AS client_name,
    li.last_trainer_id                          AS trainer_id,
    u.email::text                               AS trainer_email,
    p.version,
    li.last_issued_at                           AS last_published_at,
    p.first_opened_at,
    COALESCE(ic.issuance_count, 0)              AS issuance_count,
    COALESCE(ec.exercise_count, 0)              AS exercise_count,
    (li.last_trainer_id = v_uid)                AS is_own_session
  FROM plans p
  LEFT JOIN clients          c  ON p.client_id    = c.id
  LEFT JOIN latest_issuance  li ON p.id           = li.plan_id
  LEFT JOIN auth.users       u  ON li.last_trainer_id = u.id
  LEFT JOIN issuance_counts  ic ON p.id           = ic.plan_id
  LEFT JOIN exercise_counts  ec ON p.id           = ec.plan_id
  WHERE p.client_id = p_client_id
    AND p.deleted_at IS NULL
    AND (
      v_is_owner
      OR li.last_trainer_id = v_uid
    )
  ORDER BY li.last_issued_at DESC NULLS LAST, p.id;
END;
$$;

REVOKE ALL ON FUNCTION public.list_sessions_for_client(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_sessions_for_client(uuid) TO authenticated;

COMMIT;

-- ============================================================================
-- Verification queries — run via `supabase db query --linked` after apply
-- ============================================================================
--
-- 1. Column exists + index in place:
--    SELECT column_name, data_type, is_nullable FROM information_schema.columns
--     WHERE table_schema = 'public' AND table_name = 'clients'
--       AND column_name = 'deleted_at';
--    SELECT indexname FROM pg_indexes
--     WHERE tablename = 'clients' AND indexname = 'idx_clients_active';
--
-- 2. Functions registered:
--    SELECT proname FROM pg_proc
--     WHERE proname IN ('delete_client', 'restore_client')
--     ORDER BY proname;
--
-- 3. Cascade smoke test (replace the uuid with a real client + verify a
--    plan gets tombstoned, then restored):
--    SELECT * FROM public.delete_client('<client-uuid>'::uuid);
--    SELECT id, deleted_at FROM plans WHERE client_id = '<client-uuid>'::uuid;
--    SELECT * FROM public.restore_client('<client-uuid>'::uuid);
--    SELECT id, deleted_at FROM plans WHERE client_id = '<client-uuid>'::uuid;
--
-- 4. list_practice_clients filters deleted rows:
--    SELECT * FROM public.list_practice_clients('<practice-uuid>'::uuid);
