-- Hotfix: Milestone R SECURITY DEFINER fns used `= ANY (public.user_practice_ids())`
-- but `user_practice_ids()` is a set-returning function, not a scalar array.
-- Postgres throws `42809: op ANY/ALL (array) requires array on right side`,
-- PostgREST surfaces it as a 400, and the mobile SyncService queues the op
-- forever — which is what Carl hit on 2026-04-22 (9 setExerciseDefault ops
-- stuck on client 2a1e925e-…).
--
-- Same root cause + same fix as schema_fix_list_members_srf.sql.
-- Use `IN (SELECT public.user_practice_ids())` — the canonical pattern every
-- other SECURITY DEFINER RPC in the codebase already uses.
--
-- Functions patched:
--   * set_client_exercise_default  — blocker for Wave 8 sticky defaults.
--   * get_client_by_id             — not currently called in a hot path but
--                                    carries the same latent bug.
-- Signatures unchanged; CREATE OR REPLACE is safe. No DROP needed.

CREATE OR REPLACE FUNCTION public.set_client_exercise_default(
  p_client_id UUID,
  p_field     TEXT,
  p_value     JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller   UUID := auth.uid();
  v_practice UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_field IS NULL OR length(trim(p_field)) = 0 THEN
    RAISE EXCEPTION 'set_client_exercise_default: p_field must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id INTO v_practice
    FROM public.clients
   WHERE id = p_client_id
   LIMIT 1;

  IF v_practice IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  -- Fix: IN (SELECT SRF()) instead of = ANY (SRF).
  IF NOT (v_practice IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'set_client_exercise_default: caller % is not a member of practice %',
      v_caller, v_practice
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.clients
     SET client_exercise_defaults = jsonb_set(
           COALESCE(client_exercise_defaults, '{}'::jsonb),
           ARRAY[p_field],
           COALESCE(p_value, 'null'::jsonb),
           true
         )
   WHERE id = p_client_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
RETURNS TABLE (
  id                        uuid,
  name                      text,
  video_consent             jsonb,
  client_exercise_defaults  jsonb
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

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'get_client_by_id: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM public.clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  -- Fix: IN (SELECT SRF()) instead of = ANY (SRF).
  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'get_client_by_id: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults
    FROM public.clients c
   WHERE c.id = p_client_id;
END;
$fn$;
