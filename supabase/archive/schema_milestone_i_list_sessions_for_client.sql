-- homefit.studio — Milestone I: list_sessions_for_client RPC
-- =============================================================================
-- Run via `supabase db query --linked --file supabase/schema_milestone_i_list_sessions_for_client.sql`.
-- Safe to re-run (CREATE OR REPLACE only; no DDL on tables).
--
-- PRE-REQS
--   * Milestone G applied (clients table, plans.client_id FK).
--   * Milestone H applied (list_practice_sessions established the row shape
--     this function mirrors).
--
-- WHAT THIS MIGRATION DOES
--   Creates `public.list_sessions_for_client(p_client_id uuid)`, a SECURITY
--   DEFINER RPC returning the same shape as `list_practice_sessions` but
--   scoped to a single client row. Used by the portal `/clients/[id]` page
--   to render per-client session history without pulling every session in
--   the practice.
--
--   Visibility mirrors `list_practice_sessions`:
--     - Practice owner   -> every session of this client.
--     - Practitioner     -> only sessions they most-recently published.
--     - Non-member       -> 42501 (defense-in-depth; the portal page gates
--                          on getCurrentUserRole first).
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   Does NOT alter `list_practice_sessions` — that function remains the
--   entry point for the /clients list aggregate and any future all-session
--   views.
-- =============================================================================

BEGIN;

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

  -- Resolve the client's practice. If the client row doesn't exist (or
  -- has been deleted), return an empty set rather than erroring — the
  -- portal page will render its own empty state.
  SELECT c.practice_id INTO v_practice_id
    FROM public.clients c
   WHERE c.id = p_client_id
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
-- Verification — run via `supabase db query --linked` after apply
-- ============================================================================
-- 1. Function registered:
--    SELECT p.proname, pg_catalog.pg_get_function_arguments(p.oid) AS args
--      FROM pg_catalog.pg_proc p
--      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
--     WHERE n.nspname = 'public' AND p.proname = 'list_sessions_for_client';
--
-- 2. Anon call rejected (expected 28000 from the CLI):
--    SELECT * FROM public.list_sessions_for_client(
--      '<any-uuid>'::uuid
--    );
--
-- 3. Unknown client returns empty (NOT 42501):
--    As an authenticated user:
--      SELECT * FROM public.list_sessions_for_client(
--        '00000000-0000-0000-0000-000000000000'::uuid
--      );
