-- ---------------------------------------------------------------------------
-- Premises Safe Mode quick-toggle RPC + audit event.
--
-- Item 23 of the 2026-05-23 portal premises pass. The premises list page
-- exposes the Safe Mode badge as an interactive toggle — operators can flip
-- the state in one click without entering Edit mode. To get a clean audit
-- trail we wrap the existing `update_premises_metadata(...)` field update
-- in a dedicated SECURITY DEFINER RPC that ALSO writes an
-- `audit_events` row, atomically.
--
-- Why a new RPC instead of teaching `update_premises_metadata` to log:
--   - `update_premises_metadata` is the multi-field autosave path on the
--     /premises/[id] editor. It writes ≥1 field at a time and is called
--     on every blur. Logging every blur would flood the audit feed.
--   - The Safe Mode toggle is a single, semantically meaningful action.
--     One click = one audit row. Wrapping it in a purpose-built RPC keeps
--     the meta payload clean (`{from, to}` diff, mirroring the
--     `client.consent.update` shape).
--   - Mid-flight updates to `update_premises_metadata` would risk re-firing
--     audit rows for unrelated field saves on the editor page.
--
-- Audit kind: `practice.premises.safe_mode_toggled`. Mirrors the existing
-- `practice.premises.created` / `.updated` / `.deleted` namespace (currently
-- unwritten — the portal hasn't been instrumenting them yet, but the
-- namespace is reserved).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.toggle_premises_safe_mode(
  p_premises_id uuid,
  p_to boolean
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_prev         boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'toggle_premises_safe_mode requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'toggle_premises_safe_mode: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_to IS NULL THEN
    RAISE EXCEPTION 'toggle_premises_safe_mode: p_to is required'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve practice + capture the previous value for the audit diff.
  SELECT pp.practice_id, pp.safe_mode_enforced
    INTO v_practice_id, v_prev
    FROM public.practice_premises AS pp
   WHERE pp.id = p_premises_id
     AND pp.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'toggle_premises_safe_mode: premises not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Membership check mirrors update_premises_metadata: any member of the
  -- practice (or owner) can flip Safe Mode. Same gate the row's Edit link
  -- uses, so toggle visibility on the list page (per the brief) tracks
  -- the same permission boundary.
  IF NOT EXISTS (
    SELECT 1
      FROM public.practice_members AS pm
     WHERE pm.practice_id = v_practice_id
       AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'toggle_premises_safe_mode: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- No-op + no audit row when the value is already what the caller asked
  -- for. Keeps the audit feed clean when the optimistic UI sends a
  -- redundant write (e.g. on rapid double-clicks).
  IF coalesce(v_prev, false) = p_to THEN
    RETURN;
  END IF;

  UPDATE public.practice_premises
     SET safe_mode_enforced = p_to,
         updated_at = now()
   WHERE id = p_premises_id;

  -- Audit row — same shape as `client.consent.update`: `{from, to}` diff
  -- so the audit page can render the transition compactly.
  INSERT INTO public.audit_events (
    practice_id,
    actor_id,
    kind,
    ref_id,
    meta
  ) VALUES (
    v_practice_id,
    v_caller,
    'practice.premises.safe_mode_toggled',
    p_premises_id,
    jsonb_build_object(
      'from',   coalesce(v_prev, false),
      'to',     p_to,
      'source', 'premises_list_quick_toggle'
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.toggle_premises_safe_mode(uuid, boolean) IS
  'Flip practice_premises.safe_mode_enforced for a single row and write an audit_events entry atomically. Owner OR member of the practice may call. No-op (no audit row) when the target value matches current. Powers the one-click Safe Mode badge toggle on the /premises list page (item 23 of the 2026-05-23 portal premises pass).';

REVOKE ALL ON FUNCTION public.toggle_premises_safe_mode(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_premises_safe_mode(uuid, boolean) TO authenticated;
