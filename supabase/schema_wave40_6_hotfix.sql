-- ============================================================================
-- Wave 40.6 hotfix — restore client_exercise_defaults to client RPCs
-- ============================================================================
--
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_wave40_6_hotfix.sql
--
-- WHY
--   Wave 40.4 (schema_wave40_4_avatar_url.sql) re-created
--   `list_practice_clients` and `get_client_by_id` to add avatar_path +
--   avatar_url columns. In the process it accidentally dropped the
--   `client_exercise_defaults jsonb` column from the RETURNS TABLE that
--   Milestone R (schema_milestone_r_sticky_defaults.sql) had added.
--
--   Result: every cloud sync since Wave 40.4 returns NULL for
--   client_exercise_defaults. CachedClient.fromCloudJson handles NULL
--   gracefully (defaults to empty map), but sticky per-client exercise
--   defaults (reps, sets, hold, treatment pref, etc.) are silently wiped
--   on every SyncService pull.
--
-- WHAT THIS MIGRATION DOES
--   1. DROP + recreate list_practice_clients with all columns:
--      id, name, video_consent, consent_confirmed_at, avatar_path,
--      avatar_url, client_exercise_defaults, last_plan_at.
--
--   2. DROP + recreate get_client_by_id with all columns:
--      id, name, video_consent, consent_confirmed_at, avatar_path,
--      avatar_url, client_exercise_defaults.
--
-- Idempotent: safe to re-run.
-- ============================================================================

BEGIN;

-- 1. list_practice_clients — add client_exercise_defaults back

DROP FUNCTION IF EXISTS public.list_practice_clients(uuid);

CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
RETURNS TABLE (
  id                       uuid,
  name                     text,
  video_consent            jsonb,
  consent_confirmed_at     timestamptz,
  avatar_path              text,
  avatar_url               text,
  client_exercise_defaults jsonb,
  last_plan_at             timestamptz
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
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults,
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

-- 2. get_client_by_id — add client_exercise_defaults back

DROP FUNCTION IF EXISTS public.get_client_by_id(uuid);

CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
RETURNS TABLE (
  id                       uuid,
  name                     text,
  video_consent            jsonb,
  consent_confirmed_at     timestamptz,
  avatar_path              text,
  avatar_url               text,
  client_exercise_defaults jsonb
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
         END AS avatar_url,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults
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
--   -- Both should now include `client_exercise_defaults jsonb`.
--
-- B. Smoke test:
--   SELECT id, name, client_exercise_defaults
--     FROM public.list_practice_clients('<practice-uuid>'::uuid);
--   -- client_exercise_defaults should be a JSON object (possibly '{}').
