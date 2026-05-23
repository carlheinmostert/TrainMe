-- ============================================================================
-- Per-capture audit log + 24h roster — PR A (schema + RPCs)
-- 2026-05-23 — feat/capture-audit-and-24h-roster
-- ============================================================================
--
-- Adds the durable audit trail for every photo + video the practitioner
-- captures inside (or outside) a premises polygon. Pairs with the live-view
-- side drawer + per-practitioner timeline popover landing in the same PR.
--
-- Tables introduced:
--   * capture_audit_events — append-only ledger of every capture started by
--     the practitioner. Practice-scoped + practitioner-scoped via indexes;
--     RPC-write-only (mirrors credit_ledger lockdown).
--
-- RPCs introduced:
--   * record_capture_event(...)         — practitioner-scoped writer. Called
--     by the Flutter capture flow (PR B) at photo-shutter / video-stop.
--     Idempotent on (trainer_id, kind, started_at) so retries don't double-
--     log.
--   * get_premises_active_roster(...)   — anon-readable roster. Returns one
--     row per practitioner who captured at the resolved premises in the
--     trailing `p_lookback_hours` window, plus a `currently_active` flag
--     derived from `active_capture_sessions`. Powers the side drawer +
--     timeline popover on the live-view page.
--
-- Lockdown pattern: client INSERT/UPDATE/DELETE revoked on the table;
-- SELECT scoped via `user_practice_ids()`. Writes only via the RPC.
-- Same lockdown shape as `credit_ledger`, `active_capture_sessions`, and
-- `practitioners`.
--
-- Companion PR (B, separate): mobile Dart write path calling
-- record_capture_event from the capture flow. The web-player will render
-- an empty roster gracefully until PR B starts writing rows.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. capture_audit_events table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.capture_audit_events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_id  uuid NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
  -- Nullable: capturing OUTSIDE any polygon still produces an audit row
  -- (the trainer was somewhere; we don't pretend they weren't). Cascade
  -- to NULL on premises delete so historical events are preserved even
  -- if a premises is later removed from the practice.
  premises_id  uuid REFERENCES public.practice_premises(id) ON DELETE SET NULL,
  trainer_id   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind         text NOT NULL CHECK (kind IN ('photo', 'video')),
  started_at   timestamptz NOT NULL,
  -- NULL for photo (instantaneous); set for video on stop. The
  -- record_capture_event RPC validates the kind ↔ ended_at invariant.
  ended_at     timestamptz,
  metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Live-view roster query: (practice_id, premises_id, started_at DESC)
-- for the "events in the last N hours at this premises" rollup.
CREATE INDEX IF NOT EXISTS capture_audit_practice_premises_at_idx
  ON public.capture_audit_events (practice_id, premises_id, started_at DESC);

-- Portal per-practitioner drilldown (future use): (trainer_id, started_at DESC).
CREATE INDEX IF NOT EXISTS capture_audit_trainer_at_idx
  ON public.capture_audit_events (trainer_id, started_at DESC);

-- Idempotency: the same trainer can't double-log the same kind at the
-- same instant. Retries (network blip, video-stop fired twice) collapse
-- onto a single row via ON CONFLICT in the RPC.
CREATE UNIQUE INDEX IF NOT EXISTS capture_audit_idempotency_idx
  ON public.capture_audit_events (trainer_id, kind, started_at);

-- ---------------------------------------------------------------------------
-- 2. RLS — RPC-write-only, SELECT scoped to practice members.
-- ---------------------------------------------------------------------------
ALTER TABLE public.capture_audit_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS capture_audit_select_member ON public.capture_audit_events;
CREATE POLICY capture_audit_select_member
  ON public.capture_audit_events
  FOR SELECT
  TO authenticated
  USING (practice_id = ANY (SELECT public.user_practice_ids()));

-- No INSERT/UPDATE/DELETE policies on authenticated — writes only via
-- record_capture_event RPC (mirrors credit_ledger lockdown).
REVOKE INSERT, UPDATE, DELETE ON public.capture_audit_events FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.capture_audit_events FROM anon;
GRANT SELECT ON public.capture_audit_events TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. record_capture_event — practitioner-scoped writer
-- ---------------------------------------------------------------------------
-- Idempotency contract: (trainer_id, kind, started_at) is the natural
-- key. The ON CONFLICT DO UPDATE shape means a duplicate insert (e.g.
-- network retry) updates ended_at + metadata in place rather than
-- failing. Because ended_at is set at video-stop time on the device,
-- duplicate retries inside the same retry window all carry the same
-- value — the UPDATE is effectively a no-op but keeps the call
-- idempotent regardless.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.record_capture_event(uuid, uuid, text, timestamptz, timestamptz, jsonb);

CREATE FUNCTION public.record_capture_event(
  p_practice_id  uuid,
  p_premises_id  uuid,           -- nullable: captured outside any polygon
  p_kind         text,           -- 'photo' or 'video'
  p_started_at   timestamptz,
  p_ended_at     timestamptz,    -- required for kind='video'; NULL for 'photo'
  p_metadata     jsonb DEFAULT '{}'::jsonb
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_id     uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'record_capture_event requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'record_capture_event: practice_id required'
      USING ERRCODE = '22023';
  END IF;

  IF p_started_at IS NULL THEN
    RAISE EXCEPTION 'record_capture_event: started_at required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT (p_practice_id = ANY(SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'record_capture_event: caller is not a member of practice %', p_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF p_kind NOT IN ('photo', 'video') THEN
    RAISE EXCEPTION 'record_capture_event: kind must be photo or video (got %)', p_kind
      USING ERRCODE = '22023';
  END IF;

  IF p_kind = 'video' AND p_ended_at IS NULL THEN
    RAISE EXCEPTION 'record_capture_event: kind=video requires ended_at'
      USING ERRCODE = '22023';
  END IF;

  IF p_kind = 'photo' AND p_ended_at IS NOT NULL THEN
    RAISE EXCEPTION 'record_capture_event: kind=photo must not have ended_at'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.capture_audit_events
    (practice_id, premises_id, trainer_id, kind, started_at, ended_at, metadata)
  VALUES
    (p_practice_id, p_premises_id, v_caller, p_kind, p_started_at, p_ended_at,
     COALESCE(p_metadata, '{}'::jsonb))
  ON CONFLICT (trainer_id, kind, started_at)
    DO UPDATE SET
      ended_at = EXCLUDED.ended_at,
      metadata = EXCLUDED.metadata
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.record_capture_event(uuid, uuid, text, timestamptz, timestamptz, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_capture_event(uuid, uuid, text, timestamptz, timestamptz, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. get_premises_active_roster — anon-readable roster for the live page
-- ---------------------------------------------------------------------------
-- Resolves practice + premises by slug (only listed practices visible);
-- returns one row per practitioner who has captured anything at the
-- resolved premises in the trailing window (`p_lookback_hours`, clamped
-- to [1, 168] = 1h..1 week, default 24h). `currently_active` is derived
-- from active_capture_sessions (heartbeat <= 60s ago).
--
-- The `events` jsonb column carries the per-trainer timeline so the
-- popover can render without a second round-trip.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_premises_active_roster(text, text, int);

CREATE FUNCTION public.get_premises_active_roster(
  p_practice_slug   text,
  p_premises_slug   text,
  p_lookback_hours  int DEFAULT 24
)
 RETURNS TABLE (
   trainer_id        uuid,
   first_name        text,
   last_name         text,
   avatar_url        text,
   currently_active  boolean,
   last_event_at     timestamptz,
   event_count_24h   int,
   events            jsonb
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', extensions
AS $function$
DECLARE
  v_practice_slug text := nullif(btrim(lower(coalesce(p_practice_slug, ''))), '');
  v_premises_slug text := nullif(btrim(lower(coalesce(p_premises_slug, ''))), '');
  v_practice      public.practices%ROWTYPE;
  v_premises      public.practice_premises%ROWTYPE;
  v_lookback      timestamptz;
BEGIN
  IF v_practice_slug IS NULL OR v_premises_slug IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_practice
    FROM public.practices p
   WHERE p.public_slug = v_practice_slug
     AND coalesce(p.public_profile_listed, false) = true
   LIMIT 1;

  IF v_practice.id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_premises
    FROM public.practice_premises pp
   WHERE pp.practice_id = v_practice.id
     AND pp.public_slug = v_premises_slug
     AND pp.deleted_at IS NULL
   LIMIT 1;

  IF v_premises.id IS NULL THEN
    RETURN;
  END IF;

  -- Clamp lookback to [1, 168] hours. 168 = 7 days; the index will still
  -- serve sub-second reads at that range for any real-world practice.
  v_lookback := now() - make_interval(hours => GREATEST(1, LEAST(168, COALESCE(p_lookback_hours, 24))));

  RETURN QUERY
  WITH events_window AS (
    SELECT ce.trainer_id, ce.kind, ce.started_at, ce.ended_at
      FROM public.capture_audit_events ce
     WHERE ce.practice_id = v_practice.id
       AND ce.premises_id = v_premises.id
       AND ce.started_at >= v_lookback
  ),
  active_now AS (
    SELECT DISTINCT acs.trainer_id
      FROM public.active_capture_sessions acs
     WHERE acs.practice_id = v_practice.id
       AND acs.premises_id = v_premises.id
       AND acs.ended_at IS NULL
       AND acs.last_heartbeat_at >= now() - interval '60 seconds'
  ),
  per_trainer AS (
    SELECT
      e.trainer_id,
      max(e.started_at) AS last_event_at,
      count(*)::int     AS event_count_24h,
      jsonb_agg(
        jsonb_build_object(
          'kind',       e.kind,
          'started_at', e.started_at,
          'ended_at',   e.ended_at
        )
        ORDER BY e.started_at DESC
      ) AS events
    FROM events_window e
    GROUP BY e.trainer_id
  )
  SELECT
    pt.trainer_id,
    prac.first_name,
    prac.last_name,
    prac.avatar_url,
    (an.trainer_id IS NOT NULL) AS currently_active,
    pt.last_event_at,
    pt.event_count_24h,
    pt.events
  FROM per_trainer pt
  LEFT JOIN public.practitioners prac
    ON prac.user_id = pt.trainer_id
  LEFT JOIN active_now an
    ON an.trainer_id = pt.trainer_id
  ORDER BY (an.trainer_id IS NOT NULL) DESC, pt.last_event_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_premises_active_roster(text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_premises_active_roster(text, text, int) TO anon;
GRANT EXECUTE ON FUNCTION public.get_premises_active_roster(text, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_premises_active_roster(text, text, int) TO service_role;

COMMIT;
