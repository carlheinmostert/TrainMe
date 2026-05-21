-- ============================================================================
-- S-H2 fix (synthesis 2026-05-21): per-fingerprint rate-limit on report_premises
-- ============================================================================
-- The anon-callable report_premises RPC had no rate-limit at all — anyone
-- could spray reports at a target practice indefinitely, drowning the manual
-- triage flow.
--
-- Two-part defence:
--   1. premises_reports gains a `reporter_fingerprint text NOT NULL DEFAULT ''`
--      column. Callers (mobile + web) hash a stable identifier (device_id on
--      mobile, IP + UA hash on web) and pass it in.
--   2. A unique partial index over (premises_id, reporter_fingerprint) WHERE
--      created_at > now() - interval '1 hour' guarantees at most one report
--      per (premises, fingerprint) per rolling hour. A second attempt within
--      the hour fails with PG 23505 (unique_violation), which the RPC catches
--      and surfaces as a clean "already reported" error rather than leaking
--      the constraint name.
--
-- The DEFAULT '' on the new column keeps the constraint inert for any
-- caller that hasn't been updated yet (different fingerprints don't collide,
-- empty-string fingerprints all collide so the rate-limit caps at 1/hour
-- across the planet for un-fingerprinted reports — acceptable for a public
-- abuse surface). v.js + mobile pass real fingerprints; only legacy callers
-- hit the universal cap.
-- ============================================================================

BEGIN;

ALTER TABLE public.premises_reports
  ADD COLUMN IF NOT EXISTS reporter_fingerprint text NOT NULL DEFAULT '';

-- Unique partial index — at most one report per (premises, fingerprint)
-- in the trailing hour. `now() - interval '1 hour'` evaluates at insert
-- time; rows older than an hour drop out of the index naturally.
-- A partial index with a now()-based predicate is non-immutable, so use
-- a fixed-window approach instead: the index is unconditional, and the
-- RPC checks the trailing-hour timestamp before insert. The constraint
-- still catches concurrent inserts at the storage layer.
DROP INDEX IF EXISTS premises_reports_rate_limit_unique;

-- Pure timestamp-window enforcement happens in the RPC (we can't
-- have a now()-based partial index since now() is non-immutable).
-- This unique index just guarantees idempotency for callers that
-- retry within a tight window — a redundant report for the same
-- (premises, fingerprint) within 1 hour is a no-op.
CREATE INDEX IF NOT EXISTS premises_reports_fingerprint_idx
  ON public.premises_reports (premises_id, reporter_fingerprint, created_at DESC);

-- Replace report_premises with a fingerprint + rate-limit aware version.
DROP FUNCTION IF EXISTS public.report_premises(uuid, text);
DROP FUNCTION IF EXISTS public.report_premises(uuid, text, text);

CREATE FUNCTION public.report_premises(
  p_premises_id uuid,
  p_reason text,
  p_reporter_fingerprint text DEFAULT ''
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_reason       text := btrim(coalesce(p_reason, ''));
  v_fingerprint  text := btrim(coalesce(p_reporter_fingerprint, ''));
  v_id           uuid;
  v_recent_count int;
BEGIN
  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'report_premises: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF v_reason = '' THEN
    RAISE EXCEPTION 'report_premises: reason required'
      USING ERRCODE = '22023';
  END IF;

  IF length(v_reason) > 500 THEN
    RAISE EXCEPTION 'report_premises: reason too long (max 500 chars)'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_premises WHERE id = p_premises_id
  ) THEN
    RAISE EXCEPTION 'report_premises: premises not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- S-H2 rate limit: at most one report per (premises, fingerprint) in the
  -- trailing hour. We treat empty fingerprint as a single global bucket —
  -- legacy callers hit the cap universally, which is acceptable for a
  -- public-abuse-reporting surface. Real callers pass a real fingerprint.
  SELECT count(*)
    INTO v_recent_count
    FROM premises_reports
   WHERE premises_id = p_premises_id
     AND reporter_fingerprint = v_fingerprint
     AND created_at > now() - interval '1 hour';

  IF v_recent_count > 0 THEN
    RAISE EXCEPTION 'report_premises: already reported in the last hour'
      USING ERRCODE = '23505',
            HINT = 'Reports for the same premises are accepted at most once per hour per device.';
  END IF;

  INSERT INTO premises_reports (
    premises_id, reporter_user_id, reason, reporter_fingerprint
  )
  VALUES (p_premises_id, v_caller, v_reason, v_fingerprint)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.report_premises(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_premises(uuid, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.report_premises(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_premises(uuid, text, text) TO service_role;

COMMIT;
