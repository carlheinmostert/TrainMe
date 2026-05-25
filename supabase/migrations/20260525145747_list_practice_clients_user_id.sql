-- 2026-05-25 — Self-trainer wave PR #9: My Workouts body.
--
-- Surfaces `clients.user_id` through `list_practice_clients` and
-- `get_client_by_id` so the Flutter cache can identify the
-- Self-client locally (the row where `clients.user_id = auth.uid()`)
-- without a second round-trip.
--
-- Why: PR #9 wires the My Workouts list + "New Session" FAB on Home.
-- Both rely on knowing which cached row is the Self-client — the FAB
-- mints a session bound to `clients.id`, and the list filters
-- `cached_sessions` where `client_id` matches. Today the
-- `clients.user_id` column exists (added in
-- 20260525074056_self_trainer_wave.sql), but neither RPC returns it,
-- so the mobile cache has no way to surface the row.
--
-- Column-preservation gotcha (feedback_schema_migration_column_preservation):
-- every other column is carried forward verbatim from the live
-- function definition. Source pulled from the most recent redefinition:
-- - list_practice_clients → 20260523102954_safe_mode_v2.sql (lines 270–335)
-- - get_client_by_id      → 20260513065845_consent_explicitly_set_at.sql (lines 220–279)
--
-- Both are SECURITY DEFINER + practice-membership gated.
--
-- No schema change to the `clients` table itself — `user_id` already
-- exists with the partial unique index
-- `(practice_id, user_id) WHERE user_id IS NOT NULL AND deleted_at IS NULL`.

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. list_practice_clients — add user_id to the RETURNS TABLE.
--
--    user_id is non-null only for the practitioner's Self-client row
--    in their personal practice (one row per practice, enforced by the
--    partial unique index). Used by the Flutter cache to identify the
--    self-client for the My Workouts surface.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_practice_clients(uuid);
CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
 RETURNS TABLE(
   id                            uuid,
   name                          text,
   video_consent                 jsonb,
   consent_confirmed_at          timestamp with time zone,
   consent_explicitly_set_at     timestamp with time zone,
   avatar_path                   text,
   avatar_url                    text,
   client_exercise_defaults      jsonb,
   last_plan_at                  timestamp with time zone,
   face_embedding                bytea,
   face_embedding_model_version  smallint,
   user_id                       uuid
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
         c.consent_explicitly_set_at,
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
             AND p.deleted_at IS NULL) AS last_plan_at,
         c.face_embedding,
         c.face_embedding_model_version,
         c.user_id
    FROM clients c
   WHERE c.practice_id = p_practice_id
     AND c.deleted_at IS NULL
   ORDER BY last_plan_at DESC NULLS LAST, c.name ASC;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_practice_clients(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_practice_clients(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_practice_clients(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.list_practice_clients(uuid) TO postgres;

-- ----------------------------------------------------------------------------
-- 2. get_client_by_id — same column addition, same forward-port.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_client_by_id(uuid);
CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
 RETURNS TABLE(
   id                          uuid,
   name                        text,
   video_consent               jsonb,
   consent_confirmed_at        timestamp with time zone,
   consent_explicitly_set_at   timestamp with time zone,
   avatar_path                 text,
   avatar_url                  text,
   client_exercise_defaults    jsonb,
   user_id                     uuid
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
         c.consent_explicitly_set_at,
         c.avatar_path,
         CASE
           WHEN c.avatar_path IS NOT NULL AND length(c.avatar_path) > 0
           THEN public.sign_storage_url('raw-archive', c.avatar_path, 3600)
           ELSE NULL
         END AS avatar_url,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults,
         c.user_id
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_client_by_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_client_by_id(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_client_by_id(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_client_by_id(uuid) TO postgres;

COMMIT;
