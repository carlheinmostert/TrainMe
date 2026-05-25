-- ============================================================================
-- Safe Mode — accepted-empty telemetry RPC
-- 2026-05-25 — fix/safe-mode-accept-zero-detection
-- ============================================================================
--
-- Companion to the Flutter conversion-service change that accepts
-- zero-detection captures (Vision found no humans in any frame: empty
-- room, equipment, outdoor landscape) instead of rejecting them. The
-- mobile app fire-and-forgets a row through this RPC on every accepted-
-- empty capture so practice owners can verify in production that the
-- relaxation isn't silently letting real PII through. Scene fingerprint
-- in `metadata` is numerics-only (channel means, entropy scalars,
-- complexity score) — never image bytes.
--
-- Storage table: existing `capture_audit_events` (migration
-- 20260523145446). The pre-existing CHECK constraint pinned `kind` to
-- ('photo', 'video'); this migration RELAXES that to also permit
-- 'safe_mode_accepted_empty'. The relax is the minimal table-schema
-- change that satisfies the functional requirement — without it the new
-- RPC's INSERT trips the constraint.
--
-- New RPC introduced:
--   * record_safe_mode_capture_event(p_premises_id, p_metadata)
--     SECURITY DEFINER, scoped to `user_practice_ids()` via the
--     premises -> practice resolution. Mirrors the lockdown shape of
--     record_capture_event (RPC-write-only access). Fixed `kind` —
--     callers do not get to choose what to write under, this RPC is
--     specifically for the accepted-empty path.
--
-- Existing RPCs touched: NONE. `record_capture_event`,
-- `list_practice_audit`, `get_premises_active_roster` all keep working.
-- The audit feed surfaces accepted-empty rows as
-- 'capture.safe_mode_accepted_empty' via the existing
-- `('capture.' || ce.kind)` concat in list_practice_audit (no RPC
-- change); the portal renders the chip via the new kind added to
-- AUDIT_EVENT_KINDS / kindLabel.
--
-- The live-page 24h drawer reads `get_premises_active_roster` which
-- aggregates kind into the per-trainer `events` jsonb. The new kind
-- will appear there too; the web-player client filters down to
-- photo/video for the visual dot rendering (see web-player/live.js).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Relax the capture_audit_events.kind CHECK to accept the new value.
-- ---------------------------------------------------------------------------
-- The constraint name was implicit (`capture_audit_events_kind_check`)
-- because the table was created with an inline CHECK. Drop by the
-- conventional name + add a new, named constraint with the extended set.
ALTER TABLE public.capture_audit_events
  DROP CONSTRAINT IF EXISTS capture_audit_events_kind_check;

ALTER TABLE public.capture_audit_events
  ADD CONSTRAINT capture_audit_events_kind_check
  CHECK (kind IN (
    'photo',
    'video',
    'safe_mode_accepted_empty'
  ));

-- ---------------------------------------------------------------------------
-- 2. record_safe_mode_capture_event — practitioner-scoped writer for the
--    accepted-empty path.
-- ---------------------------------------------------------------------------
-- Fire-and-forget by contract: the mobile caller wraps this in
-- `unawaited(...)` so a network failure never blocks the capture flow.
-- Errors still RAISE (auth / membership / NULL guards) so the SDK
-- surfaces them to debug logs; production failures fall on the floor.
--
-- The kind is hard-coded inside the function — callers do not select
-- it. This is intentional: every other accepted-empty surface (chip,
-- filter, label) keys off the exact string, so divergence at the RPC
-- boundary would silently lose telemetry.
--
-- started_at defaults to now() at the postgres clock — the mobile
-- caller does not need to supply it (it's a write-time event, not a
-- capture-time event tied to the exercise's wall clock). ended_at
-- stays NULL because there's nothing to bracket.
--
-- The pre-existing capture_audit_idempotency_idx is
-- (trainer_id, kind, started_at). Two rapid successive accepted-empty
-- writes from the same trainer in the same microsecond would collide;
-- realistically this never happens because the conversion service
-- processes captures sequentially. We do NOT add an ON CONFLICT clause
-- here — a collision should propagate as the failure it would be.
DROP FUNCTION IF EXISTS public.record_safe_mode_capture_event(uuid, jsonb);

CREATE FUNCTION public.record_safe_mode_capture_event(
  p_premises_id  uuid,           -- nullable: accepted-empty can fire outside any polygon
  p_metadata     jsonb DEFAULT '{}'::jsonb
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_id           uuid;
  v_started_at   timestamptz := now();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'record_safe_mode_capture_event requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Resolve the practice from the premises. When premises is NULL the
  -- accepted-empty was captured outside any polygon — fall back to the
  -- caller's first practice membership so the row still has a tenant.
  IF p_premises_id IS NULL THEN
    SELECT practice_id INTO v_practice_id
      FROM public.practice_members
     WHERE trainer_id = v_caller
     ORDER BY joined_at ASC
     LIMIT 1;
    IF v_practice_id IS NULL THEN
      RAISE EXCEPTION 'record_safe_mode_capture_event: caller has no practice membership'
        USING ERRCODE = '42501';
    END IF;
  ELSE
    SELECT practice_id INTO v_practice_id
      FROM public.practice_premises
     WHERE id = p_premises_id;
    IF v_practice_id IS NULL THEN
      RAISE EXCEPTION 'record_safe_mode_capture_event: premises % not found', p_premises_id
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Membership check (practitioner must belong to the practice).
  IF NOT (v_practice_id = ANY (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'record_safe_mode_capture_event: caller is not a member of practice %', v_practice_id
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.capture_audit_events (
    practice_id,
    premises_id,
    trainer_id,
    kind,
    started_at,
    ended_at,
    metadata
  ) VALUES (
    v_practice_id,
    p_premises_id,
    v_caller,
    'safe_mode_accepted_empty',
    v_started_at,
    NULL,
    COALESCE(p_metadata, '{}'::jsonb)
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.record_safe_mode_capture_event(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_safe_mode_capture_event(uuid, jsonb) TO authenticated;

COMMIT;
