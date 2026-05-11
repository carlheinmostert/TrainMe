-- ============================================================================
-- Wave 38 — rename_session RPC.
-- ============================================================================
--
-- Companion to `rename_client` (Milestone J). Lets a practitioner rename a
-- session (cloud table: `plans`) directly from the SessionCard on the client
-- detail page — the title becomes inline-editable. Until now the only path
-- that wrote a `plans.title` was the publish flow inside `upload_service.dart`,
-- which meant a draft never had its title sync to cloud and a published plan
-- only synced after a republish. With offline-queued rename, the cloud row
-- updates the moment connectivity returns.
--
-- Practice-membership check mirrors `unlock_plan_for_edit`: SECURITY DEFINER,
-- caller must be a member of the plan's practice. No unique constraint on
-- (practice_id, title) in `plans` — duplicate titles are fine — so this is
-- a straight UPDATE without conflict handling.
--
-- Idempotent: if the title is already the new value, the UPDATE rewrites the
-- same value and returns void. Safe to replay from the offline queue.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rename_session(
  p_plan_id  uuid,
  p_new_title text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_trimmed      text := btrim(coalesce(p_new_title, ''));
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'rename_session requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'rename_session: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'rename_session: title required'
      USING ERRCODE = '22023';
  END IF;

  -- Look up the practice so we can gate membership. SECURITY DEFINER
  -- bypasses RLS — gate explicitly.
  SELECT practice_id INTO v_practice_id
    FROM plans
   WHERE id = p_plan_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'rename_session: plan % not found', p_plan_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'rename_session: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE plans
     SET title = v_trimmed
   WHERE id = p_plan_id;
END;
$$;

REVOKE ALL ON FUNCTION public.rename_session(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rename_session(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rename_session(uuid, text) FROM anon;

-- ============================================================================
-- Verification
-- ============================================================================
--
-- A. Function exists + has expected signature:
--   SELECT proname, pg_get_function_arguments(oid)
--     FROM pg_proc WHERE proname = 'rename_session';
--
-- B. Permission gates work:
--   -- as a non-member: should raise 42501
--   SET LOCAL ROLE authenticated;
--   SELECT public.rename_session('<plan-uuid>'::uuid, 'should fail');
--
--   -- as a member: should update silently
--   SELECT public.rename_session('<plan-uuid>'::uuid, 'New title');
--   SELECT title FROM plans WHERE id = '<plan-uuid>'::uuid;
--
-- C. Empty title rejected:
--   SELECT public.rename_session('<plan-uuid>'::uuid, '   ');  -- 22023
