-- Safe Mode Transparency — switch `report_session` from Postgres GUCs to
-- vault.secrets for the edge-function URL + service-role key.
--
-- Background
-- ----------
-- Phase D (20260522163000_safe_mode_transparency_phase_d.sql) used
-- `current_setting('app.settings.functions_url')` and
-- `current_setting('app.settings.service_role_key')` to invoke the
-- `safe-mode-report` edge function via pg_net. Setting those GUCs
-- requires `ALTER DATABASE postgres SET ...` which is a superuser
-- operation — the Supabase MCP context (postgres role at admin level
-- but NOT superuser) cannot apply it, leaving the email path
-- silently no-op on staging.
--
-- The rest of the codebase reads runtime config from `vault.secrets`
-- (see `sign_storage_url`, `get_plan_full`, every photo-thumb helper).
-- That works because `vault.decrypted_secrets` is readable by
-- SECURITY DEFINER fns and writable by the MCP. Refactoring here
-- aligns Phase D with the established pattern + eliminates the
-- superuser dependency.
--
-- Configuration after this migration applies
-- ------------------------------------------
-- The function URL is derived from the existing `supabase_url` vault
-- secret as `<supabase_url>/functions/v1/safe-mode-report`. That secret
-- is already populated on every project (per the public-profile +
-- thumb-line migrations).
--
-- The service-role key is read from a NEW vault secret named
-- `supabase_service_role_key`. After this migration ships, populate it
-- once per environment:
--
--   INSERT INTO vault.secrets (name, secret)
--   VALUES ('supabase_service_role_key', '<service-role-key>')
--   ON CONFLICT (name)
--     DO UPDATE SET secret = EXCLUDED.secret;
--
-- Until the secret is populated, the edge-function dispatch silently
-- no-ops (the report row still lands; only the email is skipped). The
-- existing EXCEPTION WHEN OTHERS handler keeps the insert path bullet-
-- proof against any vault / pg_net failure.

BEGIN;

CREATE OR REPLACE FUNCTION public.report_session(
  p_session_id           uuid,
  p_reason               text,
  p_reporter_fingerprint text
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
  v_base_url     text;
  v_service_key  text;
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
  -- gets the email without a separate worker. Read config from vault
  -- (matches the rest of the codebase — sign_storage_url, get_plan_full,
  -- photo-thumb helpers). If either secret is missing OR pg_net is
  -- disabled, this block no-ops and the report row still lands.
  BEGIN
    SELECT decrypted_secret INTO v_base_url
      FROM vault.decrypted_secrets
     WHERE name = 'supabase_url'
     LIMIT 1;

    SELECT decrypted_secret INTO v_service_key
      FROM vault.decrypted_secrets
     WHERE name = 'supabase_service_role_key'
     LIMIT 1;

    IF v_base_url IS NOT NULL AND v_service_key IS NOT NULL THEN
      PERFORM net.http_post(
        url := v_base_url || '/functions/v1/safe-mode-report',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_service_key
        ),
        body := jsonb_build_object(
          'report_id', v_id,
          'session_id', p_session_id,
          'practice_id', v_session.practice_id
        )
      );
    END IF;
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
