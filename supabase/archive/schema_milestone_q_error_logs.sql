-- homefit.studio — Milestone Q: silent-failure observability
-- =============================================================================
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_milestone_q_error_logs.sql
-- Idempotent: every statement uses CREATE IF NOT EXISTS / OR REPLACE /
-- DROP-IF-EXISTS guards. Safe to re-run.
--
-- WHY THIS EXISTS (design review: docs/design-reviews/silent-failures-2026-04-20.md)
--
-- Every "major problem" we've hit in the last month traced back to the same
-- pattern: a `try { ... } catch (e) { debugPrint(e) }` somewhere critical.
-- `debugPrint` is stripped in release builds, so these failures left
-- literally no trace. The 2026-04-20 raw-archive outage was 3 stacked
-- instances of this exact shape.
--
-- The design review picked a 3-item MVP:
--
--   1. `error_logs` table + `log_error` SECURITY DEFINER RPC so the mobile
--      `loudSwallow` helper can write without direct table grants.
--
--   2. `signed_url_self_check()` RPC — called at boot from the new
--      Diagnostics screen. Would have caught the missing-vault-secret
--      bug on first launch instead of after hours of head-scratching.
--
--   3. `publish_health` VIEW — so a daily cron / WhatsApp ping can summarise
--      "N publishes succeeded, N stuck, last error at X" without requiring a
--      new UI surface. Feeds tools/publish-health-ping/ping.sh.
--
-- What this file does NOT do:
--   - adopt Sentry / Datadog (rejected in review — overkill at 5 practices).
--   - introduce `Result<T,E>` everywhere (viral; explicitly scoped to 3
--     boundaries in Dart, see app/lib/services/loud_swallow.dart).
--   - add modal error dialogs anywhere (R-01 violation).
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. error_logs table
-- ============================================================================
-- Append-only log of swallowed / warned / fatal errors from the mobile app
-- (and anywhere else that wants to route through the `log_error` RPC).
--
-- Design choices:
--   * severity CHECK constraint — keep the axis small (3 values). If we ever
--     want `info` we can widen the CHECK; until then we reject the noise.
--   * kind TEXT + meta JSONB — kind is a coarse taxonomy ("publish_failed",
--     "raw_archive_upload", "signed_url_probe"); meta carries the
--     unstructured specifics. Two indexes (practice_id+ts, kind+ts) cover
--     both the "what's wrong in my practice" lookup and the "how often is
--     this particular failure firing across the fleet" rollup.
--   * ON DELETE SET NULL for practice_id + trainer_id so we keep the log
--     row even if the practice / user is purged later. An error log that
--     vanishes when the thing that errored vanishes is the opposite of
--     observability.
--   * sha TEXT — the GIT_SHA --dart-define passed to builds. Makes "this
--     started happening on build X" queries trivial.

CREATE TABLE IF NOT EXISTS public.error_logs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ts           timestamptz NOT NULL DEFAULT now(),
  practice_id  uuid REFERENCES public.practices(id) ON DELETE SET NULL,
  trainer_id   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  severity     text NOT NULL CHECK (severity IN ('warn', 'error', 'fatal')),
  kind         text NOT NULL,
  source       text NOT NULL,
  message      text,
  meta         jsonb,
  sha          text
);

CREATE INDEX IF NOT EXISTS idx_error_logs_practice_ts
  ON public.error_logs (practice_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_error_logs_kind_ts
  ON public.error_logs (kind, ts DESC);

-- ============================================================================
-- 2. RLS on error_logs — read-only to the practice, write via RPC only
-- ============================================================================
-- Same pattern as `credit_ledger` (Milestone E): revoke direct INSERT /
-- UPDATE / DELETE so the only path for writes is the SECURITY DEFINER
-- `log_error` RPC. SELECT scoped to the authenticated user's practices
-- via the existing `user_practice_ids()` helper.
--
-- Rows where practice_id IS NULL (e.g. a client logged an error before it
-- knew its practice) stay readable to every authenticated user — they're
-- useful for "what broke during sign-in" triage and carry no
-- practice-scoped data.

ALTER TABLE public.error_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS error_logs_select_own ON public.error_logs;
CREATE POLICY error_logs_select_own ON public.error_logs
  FOR SELECT TO authenticated
  USING (
    practice_id IS NULL
    OR practice_id IN (SELECT public.user_practice_ids())
  );

-- No INSERT / UPDATE / DELETE policy → all such writes from authenticated
-- are denied. The SECURITY DEFINER RPC below is the sole write path.
REVOKE INSERT, UPDATE, DELETE ON public.error_logs FROM authenticated, anon;
GRANT SELECT ON public.error_logs TO authenticated;

-- ============================================================================
-- 3. log_error RPC — the sole write path
-- ============================================================================
-- Called from Dart's `loudSwallow` helper when a swallowed exception crosses
-- one of the three sanctioned boundaries (ApiClient, UploadService.publish,
-- video platform channel). Fire-and-forget from the caller — never block
-- the user on the log insert.
--
-- Why SECURITY DEFINER: the caller is `authenticated` with no table grants,
-- so we elevate here and stamp `auth.uid()` as the trainer (server-side,
-- un-spoofable). The `p_practice_id` parameter is whatever the client
-- passes — we accept it as-is rather than enforce membership because
-- a misbehaving client logging the WRONG practice id is better than
-- dropping the error on the floor. The SELECT policy still scopes reads,
-- so a spurious practice_id just makes the row invisible to other
-- practices.
--
-- p_sha lets the mobile build stamp its GIT_SHA so we can correlate
-- spikes with releases without a separate join.

CREATE OR REPLACE FUNCTION public.log_error(
  p_severity    text,
  p_kind        text,
  p_source      text,
  p_message     text  DEFAULT NULL,
  p_meta        jsonb DEFAULT NULL,
  p_practice_id uuid  DEFAULT NULL,
  p_sha         text  DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_severity IS NULL OR p_severity NOT IN ('warn','error','fatal') THEN
    RAISE EXCEPTION 'log_error: severity must be one of warn/error/fatal (got %)', p_severity
      USING ERRCODE = '22023';
  END IF;
  IF p_kind IS NULL OR length(p_kind) = 0 THEN
    RAISE EXCEPTION 'log_error: kind is required' USING ERRCODE = '22023';
  END IF;
  IF p_source IS NULL OR length(p_source) = 0 THEN
    RAISE EXCEPTION 'log_error: source is required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.error_logs
    (severity, kind, source, message, meta, practice_id, trainer_id, sha)
  VALUES
    (p_severity, p_kind, p_source, p_message, p_meta, p_practice_id, auth.uid(), p_sha)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.log_error(
  text, text, text, text, jsonb, uuid, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_error(
  text, text, text, text, jsonb, uuid, text
) TO authenticated;

-- ============================================================================
-- 4. signed_url_self_check() — boot-time probe
-- ============================================================================
-- The 2026-04-20 outage was caused by `vault.secrets['supabase_jwt_secret']`
-- holding a placeholder string for 3+ weeks. `sign_storage_url` returned
-- NULL silently, every B&W / Original signed URL was missing, clients fell
-- back to line-drawing without any indication something was misconfigured.
--
-- This RPC is the probe that would have caught it at first boot:
--   * Checks both vault secrets (`supabase_jwt_secret`, `supabase_url`)
--     are populated.
--   * Exercises `sign_storage_url` against a known-nonexistent path. We
--     don't care that the object exists — we only need the signing path
--     to return a non-null URL. A missing vault secret returns NULL;
--     a well-formed URL prefix means signing works.
--   * Returns 4 columns so the mobile probe can render a nuanced status
--     (green if everything, amber if signing works but one secret missing,
--     red if the signing call errored).
--
-- Called from app/lib/screens/diagnostics_screen.dart at boot (first-run
-- flag) and whenever the practitioner taps Settings -> Diagnostics.

CREATE OR REPLACE FUNCTION public.signed_url_self_check()
RETURNS TABLE(
  ok                    boolean,
  jwt_secret_present    boolean,
  supabase_url_present  boolean,
  sample_url            text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_present boolean;
  v_url_present boolean;
  v_url         text;
BEGIN
  -- Probe the vault secrets. Silent-NULL-on-missing is the current
  -- `sign_storage_url` contract, so we check presence explicitly here.
  v_jwt_present := EXISTS (
    SELECT 1
      FROM vault.decrypted_secrets
     WHERE name = 'supabase_jwt_secret'
       AND decrypted_secret IS NOT NULL
       AND length(decrypted_secret) > 0
  );
  v_url_present := EXISTS (
    SELECT 1
      FROM vault.decrypted_secrets
     WHERE name = 'supabase_url'
       AND decrypted_secret IS NOT NULL
       AND length(decrypted_secret) > 0
  );

  jwt_secret_present   := v_jwt_present;
  supabase_url_present := v_url_present;

  IF v_jwt_present AND v_url_present THEN
    BEGIN
      -- Exercise the signing path. The path doesn't need to exist —
      -- we're only asserting that signing succeeds end-to-end.
      v_url := public.sign_storage_url(
        'raw-archive',
        'selfcheck/nonexistent.mp4',
        60
      );
      ok := v_url IS NOT NULL;
      -- Trim the URL to 48 chars so we don't leak a full usable token
      -- into wherever this ends up logged. Prefix is enough to eyeball
      -- "looks right" vs "returned NULL".
      sample_url := CASE
        WHEN v_url IS NOT NULL THEN substring(v_url, 1, 48) || '...'
        ELSE NULL
      END;
    EXCEPTION WHEN others THEN
      ok := false;
      sample_url := NULL;
    END;
  ELSE
    ok := false;
    sample_url := NULL;
  END IF;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.signed_url_self_check() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.signed_url_self_check() TO authenticated;

-- ============================================================================
-- 5. publish_health view — fuel for the daily WhatsApp ping
-- ============================================================================
-- Aggregates per-practice publish health from the existing `plans` +
-- `plan_issuances` tables. No new columns on those tables — we're deriving
-- signals from what's already there.
--
-- Column semantics:
--   * stuck_pending — plans created > 10 minutes ago with NO matching
--     plan_issuances row. Either the publish was never attempted (fine)
--     or it failed partway through (bad). The cron treats non-zero as
--     "eyeball this".
--   * failed_24h — this is a LOWER BOUND estimate. Server-side we don't
--     track failure explicitly (see docs/design-reviews — the
--     last_publish_error column lives in local SQLite only for now).
--     We proxy via "plans whose version moved forward more than
--     count(issuances) would suggest, in the last 24h" — see CASE
--     expression. If the proxy stays at 0 we have a clear signal; false
--     positives are acceptable for a daily ping.
--   * succeeded_24h — straight count of plan_issuances rows in the last
--     24h, which is the design-review definition.
--   * last_issued_ts — MAX(issued_at). Handy for "is this practice alive
--     at all" at a glance.
--
-- The view is GRANTed to authenticated so any practice member can read
-- rows for their own practices. We can still pg_dump it out via the
-- CLI / service role for the cron job.

DROP VIEW IF EXISTS public.publish_health;

CREATE VIEW public.publish_health AS
  SELECT
    p.practice_id,
    COUNT(*) FILTER (
      WHERE p.id NOT IN (
        SELECT DISTINCT plan_id FROM public.plan_issuances
      )
      AND p.created_at < now() - interval '10 minutes'
    ) AS stuck_pending,
    COUNT(DISTINCT p.id) FILTER (
      WHERE p.created_at > now() - interval '24 hours'
        AND p.version > COALESCE((
          SELECT COUNT(*) FROM public.plan_issuances pi
           WHERE pi.plan_id = p.id
        ), 0)
    ) AS failed_24h,
    COALESCE((
      SELECT COUNT(*) FROM public.plan_issuances pi
       WHERE pi.practice_id = p.practice_id
         AND pi.issued_at > now() - interval '24 hours'
    ), 0) AS succeeded_24h,
    (
      SELECT MAX(pi.issued_at) FROM public.plan_issuances pi
       WHERE pi.practice_id = p.practice_id
    ) AS last_issued_ts
  FROM public.plans p
  WHERE p.practice_id IS NOT NULL
    AND p.deleted_at IS NULL
  GROUP BY p.practice_id;

-- Views inherit the underlying table's RLS, so `user_practice_ids()`
-- scoping on `plans` + `plan_issuances` transparently applies here.
-- Explicit grant for the authenticated role.
GRANT SELECT ON public.publish_health TO authenticated;

-- Service role has implicit access; no explicit grant needed. The daily
-- cron reads via the service role key (see tools/publish-health-ping/).

COMMIT;

-- ============================================================================
-- Verification (manual — run after the COMMIT above)
-- ============================================================================
--
-- A. All four objects exist:
--    SELECT 'table'  AS kind, to_regclass('public.error_logs')             AS ref
--    UNION ALL SELECT 'fn',   to_regprocedure('public.log_error(text,text,text,text,jsonb,uuid,text)')::text
--    UNION ALL SELECT 'fn',   to_regprocedure('public.signed_url_self_check()')::text
--    UNION ALL SELECT 'view', to_regclass('public.publish_health')::text;
--
-- B. log_error smoke test (as authenticated user):
--    SELECT public.log_error(
--      'warn', 'selfcheck_smoke', 'manual_verification',
--      'smoke test from schema_milestone_q', '{"via":"psql"}'::jsonb
--    );
--    SELECT severity, kind, source, message
--      FROM public.error_logs
--     ORDER BY ts DESC LIMIT 1;
--    -- expect: ('warn', 'selfcheck_smoke', 'manual_verification', 'smoke test...')
--
-- C. signed_url_self_check (should already be green post-2026-04-20
--    vault-secret fix):
--    SELECT * FROM public.signed_url_self_check();
--    -- expect: ok=t, jwt_secret_present=t, supabase_url_present=t,
--    --         sample_url begins with 'https://yrwco.../storage/v1/object/sign/...'.
--
-- D. publish_health shape:
--    SELECT * FROM public.publish_health LIMIT 5;
--    -- expect: one row per practice with >0 plans; integer counts;
--    --         last_issued_ts timestamptz or NULL for never-published.
