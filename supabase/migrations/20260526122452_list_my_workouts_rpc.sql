-- ============================================================================
-- M29 portal entry-point — list_my_workouts() RPC
-- 2026-05-26 — feat/portal-my-workouts
--
-- Returns the signed-in user's self-capture sessions (the rows whose
-- plans.client_id points at a Self-client where clients.user_id =
-- auth.uid()). Used by the new portal /my-workouts surface; the mobile
-- twin reads from the SQLite cache, so this RPC is portal-only at the
-- call site today but is shaped the same so a future "shared by another
-- practitioner" plan can land in the same list without re-shaping the
-- contract.
--
-- Why a dedicated RPC rather than list_practice_sessions + client-side
-- filter:
--   1. A practitioner may belong to multiple practices, so the natural
--      query is per-USER, not per-practice. The existing per-practice
--      RPC would need a loop + dedup at the caller — better to push that
--      to Postgres.
--   2. Visibility rules differ. list_practice_sessions surfaces every
--      session in a practice (owner view) or every session the caller
--      most-recently published (practitioner view). My Workouts only
--      cares about sessions where the caller IS the subject; the row's
--      publisher is incidental.
--   3. Future "shared with you" expansion: when the inbound-shared-plan
--      ingestion ships, this RPC grows a UNION branch that pulls plans
--      whose `plan_invitations.accepted_by_user_id = auth.uid()` — the
--      portal page already passes the union through to a single list,
--      no extra round-trip.
--
-- Schema reference (verified live against staging 2026-05-26):
--   * clients.user_id        uuid (nullable; PR #486)
--   * clients.deleted_at     timestamptz (nullable)
--   * plans.client_id        uuid (FK clients.id, nullable for legacy rows)
--   * plans.practice_id      uuid (FK practices.id)
--   * plan_issuances         (latest publisher per plan)
--
-- Source-tag column ('source_tag') is included in the SELECT shape from
-- day one so the portal UI can render the chip without a second fetch.
-- Today every row is 'self'; future shared-plan branches will return
-- 'shared_by_practitioner' with `shared_by_email` populated.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.list_my_workouts()
  RETURNS TABLE(
    id                  uuid,
    practice_id         uuid,
    title               text,
    client_id           uuid,
    client_name         text,
    trainer_id          uuid,
    trainer_email       text,
    version             integer,
    last_published_at   timestamp with time zone,
    first_opened_at     timestamp with time zone,
    issuance_count      integer,
    exercise_count      integer,
    is_own_session      boolean,
    source_tag          text,
    shared_by_email     text
  )
  LANGUAGE plpgsql
  STABLE SECURITY DEFINER
  SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'list_my_workouts requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  RETURN QUERY
  WITH self_clients AS (
    -- All Self-client rows for this user (one per practice the user
    -- belongs to, in the limit). Soft-deleted rows excluded — the row
    -- still has children plans but we want them invisible until the
    -- practitioner restores the Self-client (which goes through
    -- ensure_self_client RPC).
    SELECT c.id, c.practice_id
      FROM clients c
     WHERE c.user_id = v_uid
       AND c.deleted_at IS NULL
  ),
  latest_issuance AS (
    -- Most recent publish per plan, restricted to plans owned by Self-
    -- clients (the WHERE on plan_id keeps the scan narrow).
    SELECT DISTINCT ON (pi.plan_id)
           pi.plan_id,
           pi.trainer_id  AS last_trainer_id,
           pi.issued_at   AS last_issued_at
      FROM plan_issuances pi
     WHERE pi.plan_id IN (
             SELECT p.id FROM plans p
              WHERE p.client_id IN (SELECT id FROM self_clients)
                AND p.deleted_at IS NULL
           )
     ORDER BY pi.plan_id, pi.issued_at DESC
  ),
  issuance_counts AS (
    SELECT pi.plan_id, COUNT(*)::integer AS issuance_count
      FROM plan_issuances pi
     WHERE pi.plan_id IN (
             SELECT p.id FROM plans p
              WHERE p.client_id IN (SELECT id FROM self_clients)
                AND p.deleted_at IS NULL
           )
     GROUP BY pi.plan_id
  ),
  exercise_counts AS (
    SELECT e.plan_id, COUNT(*)::integer AS exercise_count
      FROM exercises e
     WHERE e.plan_id IN (
             SELECT p.id FROM plans p
              WHERE p.client_id IN (SELECT id FROM self_clients)
                AND p.deleted_at IS NULL
           )
       AND e.media_type IS DISTINCT FROM 'rest'
     GROUP BY e.plan_id
  )
  SELECT
    p.id,
    p.practice_id,
    p.title,
    p.client_id,
    COALESCE(c.name, p.client_name)             AS client_name,
    li.last_trainer_id                          AS trainer_id,
    u.email::text                               AS trainer_email,
    p.version,
    li.last_issued_at                           AS last_published_at,
    p.first_opened_at,
    COALESCE(ic.issuance_count, 0)              AS issuance_count,
    COALESCE(ec.exercise_count, 0)              AS exercise_count,
    (li.last_trainer_id = v_uid)                AS is_own_session,
    -- Source tag: today every row is 'self'. When the inbound-shared
    -- branch lands, this expression becomes a CASE that distinguishes
    -- caller-as-subject from caller-as-recipient-of-someone-elses-plan.
    'self'::text                                AS source_tag,
    NULL::text                                  AS shared_by_email
    FROM plans p
    JOIN self_clients sc ON p.client_id = sc.id
    LEFT JOIN clients          c  ON p.client_id        = c.id
    LEFT JOIN latest_issuance  li ON p.id               = li.plan_id
    LEFT JOIN auth.users       u  ON li.last_trainer_id = u.id
    LEFT JOIN issuance_counts  ic ON p.id               = ic.plan_id
    LEFT JOIN exercise_counts  ec ON p.id               = ec.plan_id
   WHERE p.deleted_at IS NULL
   ORDER BY li.last_issued_at DESC NULLS LAST, p.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_workouts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_workouts() TO authenticated;

COMMENT ON FUNCTION public.list_my_workouts() IS
  'M29 (2026-05-26): returns the signed-in user''s self-capture sessions. '
  'Filtered to plans whose client_id references a Self-client owned by '
  'auth.uid(). Source-tag column reserved for future shared-plan ingestion.';

COMMIT;
