-- ============================================================================
-- Wave 30 — Client avatar (body-focus blur, single still, raw-archive storage)
-- ============================================================================
--
-- Three coupled changes:
--
--   1. clients.avatar_path text — relative storage path under raw-archive,
--      shape `{practice_id}/{client_id}/avatar.png`. NULL = no avatar yet
--      (UI falls back to the initials monogram). Cloud-side write happens
--      via the new `set_client_avatar` RPC; the practitioner-side capture
--      flow uploads the PNG to the private `raw-archive` bucket and then
--      stamps this column.
--
--   2. clients.video_consent gains a fourth boolean key `avatar`. Existing
--      rows get `avatar=false` merged in (additive, idempotent). New rows
--      default to false too. The column default is updated so future
--      INSERTs without an explicit consent jsonb still get all four keys.
--
--   3. set_client_avatar(p_client_id, p_avatar_path) — SECURITY DEFINER
--      RPC, practice-membership gated, returns the updated row. Only path
--      that mobile uses to persist the cloud-side avatar pointer.
--
-- The existing raw-archive bucket policy (`can_write_to_raw_archive(path)`)
-- already accepts any path whose first segment is a practice_id the caller
-- belongs to — `{practice_id}/{client_id}/avatar.png` slots in cleanly.
-- No new storage policies needed.
--
-- The existing `set_client_video_consent` RPC already merges the three
-- legacy keys into the jsonb on every call. To honour the fourth, we
-- replace it with a four-arg variant that accepts the avatar flag too,
-- and keep the three-arg shape as a forwarding shim so older mobile
-- builds don't break mid-rollout.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. clients.avatar_path
-- ============================================================================

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS avatar_path text;

COMMENT ON COLUMN public.clients.avatar_path IS
  'Wave 30. Relative path inside the raw-archive bucket of the body-focus '
  'blurred avatar PNG. Shape `{practice_id}/{client_id}/avatar.png`. '
  'NULL = no avatar yet; UI falls back to the initials monogram. Written '
  'via set_client_avatar after a best-effort cloud upload.';

-- ============================================================================
-- 2. video_consent: add `avatar` key (idempotent)
-- ============================================================================
--
-- Backfill any consent jsonb that's missing the key. Uses `||` to merge so
-- existing keys are untouched; only the missing `avatar` slot is added with
-- the default `false`.

UPDATE public.clients
   SET video_consent = video_consent || jsonb_build_object('avatar', false)
 WHERE NOT (video_consent ? 'avatar');

-- Refresh the column default so brand-new rows that omit video_consent get
-- all four keys at INSERT time. Idempotent: re-running just rewrites the
-- same default expression.
ALTER TABLE public.clients
  ALTER COLUMN video_consent SET DEFAULT
    '{"line_drawing": true, "grayscale": false, "original": false, "avatar": false}'::jsonb;

-- ============================================================================
-- 3. set_client_video_consent — accept the avatar flag
-- ============================================================================
--
-- Postgres rejects argument-count changes via CREATE OR REPLACE. Drop both
-- shapes first (the historical 3-arg AND any prior 4-arg attempt) before
-- recreating. The 3-arg variant survives as a forwarding shim so older
-- clients keep working until they pick up the new build.

DROP FUNCTION IF EXISTS public.set_client_video_consent(uuid, boolean, boolean, boolean);
DROP FUNCTION IF EXISTS public.set_client_video_consent(uuid, boolean, boolean, boolean, boolean);

CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id     uuid,
  p_line_drawing  boolean,
  p_grayscale     boolean,
  p_original      boolean,
  p_avatar        boolean
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
           'original',     COALESCE(p_original, false),
           'avatar',       COALESCE(p_avatar, false)
         ),
         consent_confirmed_at = now()
   WHERE id = p_client_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean, boolean) FROM anon, public;

-- Forwarding shim: pre-Wave-30 mobile builds call the 3-arg shape. Preserve
-- their semantics by reading the existing avatar flag and re-stamping it
-- unchanged so a stale client can't accidentally clobber the new key.
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
  v_existing_avatar boolean;
BEGIN
  SELECT COALESCE((video_consent ->> 'avatar')::boolean, false)
    INTO v_existing_avatar
    FROM clients WHERE id = p_client_id;

  PERFORM public.set_client_video_consent(
    p_client_id,
    p_line_drawing,
    p_grayscale,
    p_original,
    COALESCE(v_existing_avatar, false)
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean) FROM anon, public;

-- ============================================================================
-- 4. set_client_avatar — write the avatar_path pointer
-- ============================================================================
--
-- Membership-gated. Caller is expected to have already uploaded the PNG to
-- raw-archive at the supplied path; this RPC just commits the pointer.
-- Returns the updated row so the caller can refresh its in-memory cache.

CREATE OR REPLACE FUNCTION public.set_client_avatar(
  p_client_id    uuid,
  p_avatar_path  text
)
RETURNS TABLE (
  id            uuid,
  practice_id   uuid,
  name          text,
  avatar_path   text,
  video_consent jsonb
)
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
    RAISE EXCEPTION 'set_client_avatar requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_avatar: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- p_avatar_path NULL is allowed: lets the practitioner clear the avatar
  -- (e.g. "remove avatar" affordance). Empty string normalised to NULL so
  -- the column never carries a sentinel.
  IF p_avatar_path = '' THEN
    p_avatar_path := NULL;
  END IF;

  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_deleted_at
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_avatar: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_avatar: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = v_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_avatar: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE clients c
     SET avatar_path = p_avatar_path
   WHERE c.id = p_client_id;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.avatar_path, c.video_consent
    FROM clients c
   WHERE c.id = p_client_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.set_client_avatar(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_client_avatar(uuid, text) FROM anon, public;

-- ============================================================================
-- 5. list_practice_clients / get_client_by_id — surface avatar_path
-- ============================================================================
--
-- Additive change to the RETURNS TABLE shape. Mobile sync seeds the local
-- cache mirror; portal can ignore the new column (PostgREST tolerates extra).
-- Postgres rejects RETURN TYPE mutation under CREATE OR REPLACE — drop both
-- first, then recreate.

DROP FUNCTION IF EXISTS public.list_practice_clients(uuid);
DROP FUNCTION IF EXISTS public.get_client_by_id(uuid);

CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
RETURNS TABLE (
  id                    uuid,
  name                  text,
  video_consent         jsonb,
  consent_confirmed_at  timestamptz,
  avatar_path           text,
  last_plan_at          timestamptz
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
         c.consent_confirmed_at,
         c.avatar_path,
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

CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
RETURNS TABLE (
  id                    uuid,
  name                  text,
  video_consent         jsonb,
  consent_confirmed_at  timestamptz,
  avatar_path           text
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
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = v_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT c.id, c.name, c.video_consent, c.consent_confirmed_at, c.avatar_path
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.get_client_by_id(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_client_by_id(uuid) FROM anon, public;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
--
-- A. Column exists:
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'clients' AND column_name = 'avatar_path';
--
-- B. video_consent default + backfill:
--   SELECT column_default FROM information_schema.columns
--    WHERE table_name = 'clients' AND column_name = 'video_consent';
--   SELECT count(*) FROM public.clients WHERE NOT (video_consent ? 'avatar');  -- 0
--
-- C. RPCs callable:
--   SELECT public.set_client_avatar('<client-uuid>'::uuid,
--                                   '<practice>/<client>/avatar.png');
--   SELECT public.set_client_video_consent('<client-uuid>'::uuid,
--                                          true, false, false, true);  -- 4-arg
--   SELECT public.set_client_video_consent('<client-uuid>'::uuid,
--                                          true, false, false);        -- 3-arg shim
--
-- D. raw-archive INSERT for the avatar path (must succeed for a member of
--    the matching practice):
--   INSERT INTO storage.objects (bucket_id, name, owner)
--   VALUES ('raw-archive', '<practice>/<client>/avatar.png', auth.uid());
