-- ============================================================================
-- Wave 40.4 — Surface a signed avatar URL on the portal-facing client RPCs
-- ============================================================================
--
-- Carl's QA on Wave 40 (items 14 + 16): the portal /clients list and the
-- /clients/[id] session-icon should render the body-focus avatar JPG that
-- the mobile app captures and uploads (Wave 30) — not just initials.
--
-- The mobile app uploads the avatar to the PRIVATE `raw-archive` bucket at
-- `{practice_id}/{client_id}/avatar.png` and stores that path in
-- `clients.avatar_path`. Anonymous + authenticated SELECT is blocked on
-- raw-archive; the only legitimate read path is via a short-lived signed
-- URL minted by `public.sign_storage_url(bucket, path, expires_in)` (the
-- pgjwt-backed helper introduced in Milestone G three-treatment).
--
-- This migration extends `list_practice_clients` and `get_client_by_id` to
-- additionally return `avatar_url text` — the signed URL valid for 1 hour
-- (3600s) when `clients.avatar_path` is non-null, NULL otherwise. The
-- helper degrades gracefully (returns NULL) if the vault secrets are
-- absent, so callers always get a plain "no avatar" path back.
--
-- Postgres rejects RETURN TYPE mutation under CREATE OR REPLACE — drop both
-- first, then recreate. Mobile callers also use these RPCs (via
-- `api_client.dart`) and tolerate extra columns (PostgREST + Dart map
-- read), so the additive `avatar_url` is non-breaking.
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.list_practice_clients(uuid);
DROP FUNCTION IF EXISTS public.get_client_by_id(uuid);

CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
RETURNS TABLE (
  id                    uuid,
  name                  text,
  video_consent         jsonb,
  consent_confirmed_at  timestamptz,
  avatar_path           text,
  avatar_url            text,
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
         CASE
           WHEN c.avatar_path IS NOT NULL AND length(c.avatar_path) > 0
           THEN public.sign_storage_url('raw-archive', c.avatar_path, 3600)
           ELSE NULL
         END AS avatar_url,
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
  avatar_path           text,
  avatar_url            text
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
  SELECT c.id,
         c.name,
         c.video_consent,
         c.consent_confirmed_at,
         c.avatar_path,
         CASE
           WHEN c.avatar_path IS NOT NULL AND length(c.avatar_path) > 0
           THEN public.sign_storage_url('raw-archive', c.avatar_path, 3600)
           ELSE NULL
         END AS avatar_url
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
-- A. Shapes match expectations:
--   SELECT pg_get_function_result(oid) FROM pg_proc
--    WHERE proname IN ('list_practice_clients', 'get_client_by_id');
--   -- Both should now include `avatar_url text`.
--
-- B. Smoke test (replace the practice id with a real one the caller belongs to):
--   SELECT id, name, avatar_path, left(avatar_url, 80)
--     FROM public.list_practice_clients('<practice-uuid>'::uuid);
--   -- Rows with avatar_path get a non-null avatar_url; null rows stay null.
--
-- C. The URL works (paste into a browser tab — should stream the PNG bytes).
--    Expires 1 hour after the SELECT.
--
-- D. Mobile + portal `getClientById` round-trip still works (extra column is
--    tolerated by PostgREST, Dart map-read, and the typed portal mapper).
