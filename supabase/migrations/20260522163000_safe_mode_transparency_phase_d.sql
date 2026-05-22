-- ============================================================================
-- Safe Mode Transparency — Phase D: reporting + escalation
-- ============================================================================
-- Spec: docs/specs/2026-05-22-safe-mode-transparency.md
--
-- Phase D wires the Report button on the live transparency page to a
-- real notification flow. Reports land in `safe_mode_session_reports`,
-- per-(session, fingerprint) rate-limited to one per 60 minutes, and an
-- edge function (`safe-mode-report`) emails the practice's listed
-- contact via Resend.
--
-- WhatsApp routing is deferred — the column lands here so the edge
-- function can fill it in later without another migration.
--
-- The anon RPC `report_session` is the only public-write surface on
-- this table; `safe_mode_session_reports` itself is RPC-write-only.
-- SELECT is scoped to the reported practice's members so the audit
-- log can surface a report list in a future phase.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. safe_mode_session_reports table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.safe_mode_session_reports (
  id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id                    uuid NOT NULL REFERENCES public.active_capture_sessions(id) ON DELETE CASCADE,
  practice_id                   uuid NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
  reporter_fingerprint          text NOT NULL DEFAULT '',
  reason                        text NOT NULL,
  reported_at                   timestamptz NOT NULL DEFAULT now(),
  practice_notified_at          timestamptz,
  practice_whatsapp_notified_at timestamptz, -- deferred — Phase D ships email only
  escalated_at                  timestamptz,
  CONSTRAINT safe_mode_session_reports_reason_length
    CHECK (length(btrim(reason)) BETWEEN 1 AND 500)
);

CREATE INDEX IF NOT EXISTS safe_mode_session_reports_practice_idx
  ON public.safe_mode_session_reports (practice_id, reported_at DESC);

CREATE INDEX IF NOT EXISTS safe_mode_session_reports_session_idx
  ON public.safe_mode_session_reports (session_id, reported_at DESC);

CREATE INDEX IF NOT EXISTS safe_mode_session_reports_unresolved_idx
  ON public.safe_mode_session_reports (reported_at DESC)
  WHERE escalated_at IS NULL;

-- Helper index for the (session, fingerprint) rate-limit check.
CREATE INDEX IF NOT EXISTS safe_mode_session_reports_rate_limit_idx
  ON public.safe_mode_session_reports (session_id, reporter_fingerprint, reported_at DESC);

-- ---------------------------------------------------------------------------
-- 2. RLS — RPC-write-only, SELECT scoped to the reported practice's members.
-- ---------------------------------------------------------------------------
ALTER TABLE public.safe_mode_session_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS safe_mode_session_reports_select_member ON public.safe_mode_session_reports;
CREATE POLICY safe_mode_session_reports_select_member
  ON public.safe_mode_session_reports
  FOR SELECT
  TO authenticated
  USING (practice_id = ANY (SELECT public.user_practice_ids()));

REVOKE INSERT, UPDATE, DELETE ON public.safe_mode_session_reports FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.safe_mode_session_reports FROM anon;
GRANT SELECT ON public.safe_mode_session_reports TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. report_session RPC
--
--   Anon-callable. Inserts a row + invokes the safe-mode-report edge
--   function via pg_net so the email goes out within the same
--   transaction.
--
--   Per-(session, fingerprint) rate limit: at most one report per 60
--   minutes. Empty fingerprint reverts to a single global bucket
--   (acceptable cap for an unfingerprinted public-abuse-reporting
--   surface — the live page always sets a stable localStorage UUID).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.report_session(uuid, text, text);

CREATE FUNCTION public.report_session(
  p_session_id          uuid,
  p_reason              text,
  p_reporter_fingerprint text DEFAULT ''
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason       text := btrim(coalesce(p_reason, ''));
  v_fingerprint  text := btrim(coalesce(p_reporter_fingerprint, ''));
  v_session      public.active_capture_sessions%ROWTYPE;
  v_id           uuid;
  v_recent_count int;
BEGIN
  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'report_session: session_id required'
      USING ERRCODE = '22023';
  END IF;

  IF v_reason = '' THEN
    RAISE EXCEPTION 'report_session: reason required'
      USING ERRCODE = '22023';
  END IF;

  IF length(v_reason) > 500 THEN
    RAISE EXCEPTION 'report_session: reason too long (max 500 chars)'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_session
    FROM public.active_capture_sessions
   WHERE id = p_session_id;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'report_session: session not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Rate limit: at most one report per (session, fingerprint) in the
  -- trailing hour. Same shape as report_premises (PR S-H2).
  SELECT count(*)
    INTO v_recent_count
    FROM public.safe_mode_session_reports
   WHERE session_id = p_session_id
     AND reporter_fingerprint = v_fingerprint
     AND reported_at > now() - interval '1 hour';

  IF v_recent_count > 0 THEN
    RAISE EXCEPTION 'report_session: already reported in the last hour'
      USING ERRCODE = '23505',
            HINT = 'Reports for the same session are accepted at most once per hour per device.';
  END IF;

  INSERT INTO public.safe_mode_session_reports (
    session_id, practice_id, reporter_fingerprint, reason
  )
  VALUES (
    p_session_id, v_session.practice_id, v_fingerprint, v_reason
  )
  RETURNING id INTO v_id;

  -- Best-effort: invoke the edge function via pg_net so the practice
  -- gets the email without a separate worker. The function name is
  -- resolved at runtime against the project's Functions URL; if the
  -- request fails (mis-config, function down) the row still lands and
  -- a future digest catches it.
  --
  -- The pg_net extension is enabled on the project by default; if it's
  -- not, this block is a no-op (the EXCEPTION catches it).
  BEGIN
    PERFORM net.http_post(
      url := current_setting('app.settings.functions_url', true)
             || '/safe-mode-report',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization',
        'Bearer ' || current_setting('app.settings.service_role_key', true)
      ),
      body := jsonb_build_object(
        'report_id', v_id,
        'session_id', p_session_id,
        'practice_id', v_session.practice_id
      )
    );
  EXCEPTION WHEN OTHERS THEN
    -- Don't fail the insert if the function dispatch failed.
    NULL;
  END;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.report_session(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_session(uuid, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.report_session(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_session(uuid, text, text) TO service_role;

COMMIT;
