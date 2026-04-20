-- ============================================================================
-- Milestone H — list_practice_sessions
-- ============================================================================
-- SECURITY DEFINER RPC powering the portal's "My Sessions" page.
--
-- Visibility rules:
--   * Practice owner  → all sessions in the practice (any trainer_id).
--   * Practitioner    → only sessions they themselves published.
--
-- "Owner" and "Practitioner" are the only two roles recognised (see
-- practice_members.role). Non-members get a 42501 insufficient_privilege
-- exception — the portal page should gate on membership before calling.
--
-- Schema note (2026-04-19): the `plans` table does NOT carry a trainer_id
-- column — authorship is recorded per-publish in plan_issuances. We
-- therefore derive the authoring practitioner as the trainer of the most
-- recent issuance for the plan. For plans that have never been published
-- (they can exist as drafts but won't get here — no UUID URL), we fall
-- back to NULL.
--
-- Similarly, there is no soft-delete column on plans today. If one is
-- added later (e.g. deleted_at) the WHERE clause below should pick it up.
--
-- Idempotent — CREATE OR REPLACE only, no table writes.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.list_practice_sessions(
  p_practice_id uuid
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
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid       uuid    := auth.uid();
  v_is_owner  boolean := public.user_is_practice_owner(p_practice_id);
  v_is_member boolean := p_practice_id = ANY(ARRAY(SELECT public.user_practice_ids()));
BEGIN
  IF NOT v_is_member THEN
    RAISE EXCEPTION 'not a member of this practice' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH latest_issuance AS (
    -- Most recent publish per plan, in this practice. Carries trainer_id
    -- (who published last) and issued_at (our "last_published_at").
    SELECT DISTINCT ON (pi.plan_id)
           pi.plan_id,
           pi.trainer_id  AS last_trainer_id,
           pi.issued_at   AS last_issued_at
      FROM plan_issuances pi
     WHERE pi.practice_id = p_practice_id
     ORDER BY pi.plan_id, pi.issued_at DESC
  ),
  issuance_counts AS (
    SELECT pi.plan_id, COUNT(*)::integer AS issuance_count
      FROM plan_issuances pi
     WHERE pi.practice_id = p_practice_id
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
    COALESCE(c.name, p.client_name)           AS client_name,
    li.last_trainer_id                         AS trainer_id,
    u.email::text                              AS trainer_email,
    p.version,
    li.last_issued_at                          AS last_published_at,
    p.first_opened_at,
    COALESCE(ic.issuance_count, 0)             AS issuance_count,
    COALESCE(ec.exercise_count, 0)             AS exercise_count,
    (li.last_trainer_id = v_uid)               AS is_own_session
  FROM plans p
  LEFT JOIN clients          c  ON p.client_id    = c.id
  LEFT JOIN latest_issuance  li ON p.id           = li.plan_id
  LEFT JOIN auth.users       u  ON li.last_trainer_id = u.id
  LEFT JOIN issuance_counts  ic ON p.id           = ic.plan_id
  LEFT JOIN exercise_counts  ec ON p.id           = ec.plan_id
  WHERE p.practice_id = p_practice_id
    AND (
      v_is_owner
      OR li.last_trainer_id = v_uid
    )
  ORDER BY li.last_issued_at DESC NULLS LAST, p.id;
END;
$$;

REVOKE ALL ON FUNCTION public.list_practice_sessions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_practice_sessions(uuid) TO authenticated;
