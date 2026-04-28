-- =============================================================
-- Wave 17 — Analytics schema: tables + RPCs + RLS + consent
-- Design doc: docs/design-reviews/analytics-consent-mvp-2026-04-21.md
-- All decisions LOCKED per Carl sign-off.
-- =============================================================

BEGIN;

-- =============================================================
-- 1. TABLES
-- =============================================================

-- 1a. client_sessions — one row per plan-open
CREATE TABLE IF NOT EXISTS public.client_sessions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id          UUID NOT NULL REFERENCES public.plans(id) ON DELETE CASCADE,
  opened_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  user_agent_bucket TEXT,
  consent_granted  BOOLEAN NOT NULL DEFAULT false,
  consent_decided_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_client_sessions_plan_opened
  ON public.client_sessions(plan_id, opened_at DESC);

-- 1b. plan_analytics_events — append-only fact table
CREATE TABLE IF NOT EXISTS public.plan_analytics_events (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_session_id UUID NOT NULL REFERENCES public.client_sessions(id) ON DELETE CASCADE,
  event_kind        TEXT NOT NULL CHECK (event_kind IN (
    'plan_opened','plan_completed','plan_closed',
    'exercise_viewed','exercise_completed','exercise_skipped','exercise_replayed',
    'treatment_switched','pause_tapped','resume_tapped',
    'rest_shortened','rest_extended'
  )),
  exercise_id       UUID,
  event_data        JSONB,
  occurred_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_plan_analytics_events_session
  ON public.plan_analytics_events(client_session_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_plan_analytics_events_kind_occurred
  ON public.plan_analytics_events(event_kind, occurred_at DESC);

-- 1c. plan_analytics_daily_aggregate — rollup table
CREATE TABLE IF NOT EXISTS public.plan_analytics_daily_aggregate (
  plan_id             UUID NOT NULL REFERENCES public.plans(id) ON DELETE CASCADE,
  exercise_id         UUID,
  day                 DATE NOT NULL,
  opens               INT NOT NULL DEFAULT 0,
  completions         INT NOT NULL DEFAULT 0,
  total_elapsed_ms    BIGINT NOT NULL DEFAULT 0,
  exercise_completes  INT NOT NULL DEFAULT 0,
  exercise_skips      INT NOT NULL DEFAULT 0,
  treatment_switches  INT NOT NULL DEFAULT 0
);

-- Composite unique index using COALESCE to handle nullable exercise_id
CREATE UNIQUE INDEX IF NOT EXISTS idx_plan_analytics_daily_agg_pk
  ON public.plan_analytics_daily_aggregate(
    plan_id,
    COALESCE(exercise_id, '00000000-0000-0000-0000-000000000000'),
    day
  );

-- =============================================================
-- 2. RLS
-- =============================================================

ALTER TABLE public.client_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_analytics_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_analytics_daily_aggregate ENABLE ROW LEVEL SECURITY;

-- 2a. client_sessions: authenticated SELECT via practice membership
CREATE POLICY client_sessions_select_own ON public.client_sessions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.plans p
       WHERE p.id = client_sessions.plan_id
         AND p.practice_id IN (SELECT public.user_practice_ids())
    )
  );

-- No INSERT/UPDATE/DELETE for authenticated — RPC-only writes via anon RPCs.
-- Anon gets no direct access at all.

-- 2b. plan_analytics_events: authenticated SELECT via practice membership
CREATE POLICY plan_analytics_events_select_own ON public.plan_analytics_events
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.client_sessions cs
        JOIN public.plans p ON p.id = cs.plan_id
       WHERE cs.id = plan_analytics_events.client_session_id
         AND p.practice_id IN (SELECT public.user_practice_ids())
    )
  );

-- 2c. plan_analytics_daily_aggregate: authenticated SELECT via practice membership
CREATE POLICY plan_analytics_daily_aggregate_select_own ON public.plan_analytics_daily_aggregate
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.plans p
       WHERE p.id = plan_analytics_daily_aggregate.plan_id
         AND p.practice_id IN (SELECT public.user_practice_ids())
    )
  );

-- =============================================================
-- 3. RPCs — all SECURITY DEFINER
-- =============================================================

-- 3a. start_analytics_session
--     Checks plan exists + client analytics consent. Returns session UUID or NULL.
--     Callable by anon (web player).
CREATE OR REPLACE FUNCTION public.start_analytics_session(
  p_plan_id UUID,
  p_user_agent_bucket TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id      UUID;
  v_analytics_allowed BOOLEAN;
  v_session_id     UUID;
BEGIN
  -- Check plan exists and resolve client
  SELECT client_id INTO v_client_id
    FROM plans
   WHERE id = p_plan_id
     AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Check client-level analytics consent.
  -- Default TRUE when key is missing (per design doc).
  IF v_client_id IS NOT NULL THEN
    SELECT COALESCE((video_consent ->> 'analytics_allowed')::boolean, true)
      INTO v_analytics_allowed
      FROM clients
     WHERE id = v_client_id
       AND deleted_at IS NULL;

    -- If client row gone, treat as disabled
    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    IF v_analytics_allowed IS FALSE THEN
      RETURN NULL;
    END IF;
  END IF;
  -- If no client_id (legacy plan), allow analytics (no client-level opt-out possible)

  INSERT INTO client_sessions (plan_id, user_agent_bucket)
    VALUES (p_plan_id, p_user_agent_bucket)
    RETURNING id INTO v_session_id;

  RETURN v_session_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_analytics_session(UUID, TEXT) TO anon, authenticated;


-- 3b. log_analytics_event
--     Validates session + consent, rate-limits at ~1/sec, inserts event.
--     Callable by anon.
CREATE OR REPLACE FUNCTION public.log_analytics_event(
  p_session_id UUID,
  p_event_kind TEXT,
  p_exercise_id UUID DEFAULT NULL,
  p_event_data JSONB DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_consent   BOOLEAN;
  v_last_at   TIMESTAMPTZ;
BEGIN
  -- Validate session exists and consent is granted
  SELECT consent_granted INTO v_consent
    FROM client_sessions
   WHERE id = p_session_id;

  IF NOT FOUND OR v_consent IS NOT TRUE THEN
    RETURN; -- silently skip
  END IF;

  -- Rate limit: skip if last event for this session was < 1 second ago
  SELECT MAX(occurred_at) INTO v_last_at
    FROM plan_analytics_events
   WHERE client_session_id = p_session_id;

  IF v_last_at IS NOT NULL AND (now() - v_last_at) < interval '1 second' THEN
    RETURN; -- rate-limited
  END IF;

  INSERT INTO plan_analytics_events (client_session_id, event_kind, exercise_id, event_data)
    VALUES (p_session_id, p_event_kind, p_exercise_id, p_event_data);
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_analytics_event(UUID, TEXT, UUID, JSONB) TO anon, authenticated;


-- 3c. set_analytics_consent
--     Called once when client accepts or rejects the banner.
--     Callable by anon.
CREATE OR REPLACE FUNCTION public.set_analytics_consent(
  p_session_id UUID,
  p_granted BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE client_sessions
     SET consent_granted = p_granted,
         consent_decided_at = now()
   WHERE id = p_session_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_analytics_consent(UUID, BOOLEAN) TO anon, authenticated;


-- 3d. revoke_analytics_consent
--     Called by the "Stop sharing" button on the transparency page.
--     Revokes consent for the current session AND sets a plan-level opt-out
--     flag so future sessions auto-revoke.
--
--     DESIGN DECISION: The design doc asked "via a flag on client_sessions?
--     or a per-plan opt-out row?" — we pick the simpler option: a dedicated
--     lightweight table `plan_analytics_opt_out` with one row per (plan_id,
--     browser fingerprint). This avoids polluting client_sessions with a flag
--     that has to be checked on every start_analytics_session call. Instead,
--     start_analytics_session checks this table before inserting.
--     Actually, even simpler: we store the opt-out on the client_sessions
--     table itself by adding a plan-level check. We'll use a simple approach:
--     mark the current session as revoked, and for future sessions, the web
--     player will check localStorage and skip calling start_analytics_session
--     entirely. Server-side, we also store a marker row so even if localStorage
--     is cleared, the next start_analytics_session can detect the opt-out.
--
--     Simplest approach chosen: add a `plan_analytics_opt_outs` table with
--     just (plan_id) as PK. start_analytics_session checks it.
--     Callable by anon.
CREATE TABLE IF NOT EXISTS public.plan_analytics_opt_outs (
  plan_id UUID PRIMARY KEY REFERENCES public.plans(id) ON DELETE CASCADE,
  opted_out_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.plan_analytics_opt_outs ENABLE ROW LEVEL SECURITY;

-- Authenticated can SELECT opt-outs for their own plans
CREATE POLICY plan_analytics_opt_outs_select_own ON public.plan_analytics_opt_outs
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.plans p
       WHERE p.id = plan_analytics_opt_outs.plan_id
         AND p.practice_id IN (SELECT public.user_practice_ids())
    )
  );

CREATE OR REPLACE FUNCTION public.revoke_analytics_consent(
  p_plan_id UUID,
  p_session_id UUID
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Revoke consent on the current session
  UPDATE client_sessions
     SET consent_granted = false,
         consent_decided_at = now()
   WHERE id = p_session_id
     AND plan_id = p_plan_id;

  -- Record plan-level opt-out for future sessions
  INSERT INTO plan_analytics_opt_outs (plan_id)
    VALUES (p_plan_id)
    ON CONFLICT (plan_id) DO NOTHING;
END;
$$;

GRANT EXECUTE ON FUNCTION public.revoke_analytics_consent(UUID, UUID) TO anon, authenticated;


-- Patch start_analytics_session to also check plan_analytics_opt_outs.
-- (Re-create with the opt-out check added.)
CREATE OR REPLACE FUNCTION public.start_analytics_session(
  p_plan_id UUID,
  p_user_agent_bucket TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id         UUID;
  v_analytics_allowed BOOLEAN;
  v_session_id        UUID;
BEGIN
  -- Check plan exists and resolve client
  SELECT client_id INTO v_client_id
    FROM plans
   WHERE id = p_plan_id
     AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Check plan-level opt-out (from revoke_analytics_consent)
  IF EXISTS (SELECT 1 FROM plan_analytics_opt_outs WHERE plan_id = p_plan_id) THEN
    RETURN NULL;
  END IF;

  -- Check client-level analytics consent.
  -- Default TRUE when key is missing (per design doc).
  IF v_client_id IS NOT NULL THEN
    SELECT COALESCE((video_consent ->> 'analytics_allowed')::boolean, true)
      INTO v_analytics_allowed
      FROM clients
     WHERE id = v_client_id
       AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    IF v_analytics_allowed IS FALSE THEN
      RETURN NULL;
    END IF;
  END IF;

  INSERT INTO client_sessions (plan_id, user_agent_bucket)
    VALUES (p_plan_id, p_user_agent_bucket)
    RETURNING id INTO v_session_id;

  RETURN v_session_id;
END;
$$;


-- 3e. get_plan_sharing_context
--     Anon RPC for the /what-we-share?p={planId} page.
--     Returns practitioner name, practice name, client first name, analytics flag.
CREATE OR REPLACE FUNCTION public.get_plan_sharing_context(p_plan_id UUID)
RETURNS TABLE (
  practitioner_name TEXT,
  practice_name TEXT,
  client_first_name TEXT,
  analytics_allowed BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan_exists    BOOLEAN;
  v_practice_id    UUID;
  v_client_id      UUID;
  v_trainer_id     UUID;
  v_prac_name      TEXT;
  v_practice_label TEXT;
  v_client_name    TEXT;
  v_analytics      BOOLEAN;
  v_trainer_email  TEXT;
  v_trainer_meta   JSONB;
  v_trainer_name   TEXT;
BEGIN
  -- Resolve plan
  SELECT p.practice_id, p.client_id
    INTO v_practice_id, v_client_id
    FROM plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN; -- returns empty result set
  END IF;

  -- Get practice name
  SELECT pr.name INTO v_practice_label
    FROM practices pr
   WHERE pr.id = v_practice_id;

  -- Get client first name + analytics consent
  IF v_client_id IS NOT NULL THEN
    SELECT
      split_part(c.name, ' ', 1),
      COALESCE((c.video_consent ->> 'analytics_allowed')::boolean, true)
    INTO v_client_name, v_analytics
      FROM clients c
     WHERE c.id = v_client_id
       AND c.deleted_at IS NULL;

    IF NOT FOUND THEN
      -- Client deleted — fall back
      v_client_name := NULL;
      v_analytics := false;
    END IF;
  ELSE
    v_client_name := NULL;
    v_analytics := true; -- no client means no client-level opt-out
  END IF;

  -- If analytics disabled at client level, return NULL row (page falls back to generic)
  IF v_analytics IS FALSE THEN
    RETURN;
  END IF;

  -- Get most recent practitioner who published this plan
  SELECT pi.trainer_id INTO v_trainer_id
    FROM plan_issuances pi
   WHERE pi.plan_id = p_plan_id
   ORDER BY pi.issued_at DESC
   LIMIT 1;

  IF v_trainer_id IS NOT NULL THEN
    SELECT u.email, u.raw_user_meta_data
      INTO v_trainer_email, v_trainer_meta
      FROM auth.users u
     WHERE u.id = v_trainer_id;

    -- Try display_name from meta, fall back to email prefix
    v_trainer_name := COALESCE(
      v_trainer_meta ->> 'display_name',
      v_trainer_meta ->> 'full_name',
      split_part(v_trainer_email, '@', 1)
    );
  ELSE
    v_trainer_name := 'your practitioner';
  END IF;

  RETURN QUERY SELECT
    v_trainer_name,
    v_practice_label,
    v_client_name,
    v_analytics;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_plan_sharing_context(UUID) TO anon, authenticated;


-- 3f. get_plan_analytics_summary
--     Authenticated only. Practice-membership check.
--     Aggregates from client_sessions + plan_analytics_events.
CREATE OR REPLACE FUNCTION public.get_plan_analytics_summary(p_plan_id UUID)
RETURNS TABLE (
  opens INT,
  completions INT,
  last_opened_at TIMESTAMPTZ,
  exercise_stats JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller      UUID := auth.uid();
  v_practice_id UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_plan_analytics_summary requires authentication'
      USING ERRCODE = '28000';
  END IF;

  -- Resolve plan and check membership
  SELECT p.practice_id INTO v_practice_id
    FROM plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids()) THEN
    RAISE EXCEPTION 'get_plan_analytics_summary: caller is not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH session_agg AS (
    SELECT
      COUNT(*)::INT AS total_opens,
      MAX(cs.opened_at) AS max_opened_at
    FROM client_sessions cs
    WHERE cs.plan_id = p_plan_id
      AND cs.consent_granted = true
  ),
  completion_agg AS (
    SELECT COUNT(*)::INT AS total_completions
    FROM plan_analytics_events e
      JOIN client_sessions cs ON cs.id = e.client_session_id
    WHERE cs.plan_id = p_plan_id
      AND e.event_kind = 'plan_completed'
  ),
  exercise_agg AS (
    SELECT jsonb_agg(jsonb_build_object(
      'exercise_id', ea.exercise_id,
      'viewed', ea.viewed_count,
      'completed', ea.completed_count,
      'skipped', ea.skipped_count
    )) AS stats
    FROM (
      SELECT
        e.exercise_id,
        COUNT(*) FILTER (WHERE e.event_kind = 'exercise_viewed')::INT AS viewed_count,
        COUNT(*) FILTER (WHERE e.event_kind = 'exercise_completed')::INT AS completed_count,
        COUNT(*) FILTER (WHERE e.event_kind = 'exercise_skipped')::INT AS skipped_count
      FROM plan_analytics_events e
        JOIN client_sessions cs ON cs.id = e.client_session_id
      WHERE cs.plan_id = p_plan_id
        AND e.exercise_id IS NOT NULL
        AND e.event_kind IN ('exercise_viewed', 'exercise_completed', 'exercise_skipped')
      GROUP BY e.exercise_id
    ) ea
  )
  SELECT
    sa.total_opens,
    ca.total_completions,
    sa.max_opened_at,
    COALESCE(exa.stats, '[]'::jsonb)
  FROM session_agg sa
    CROSS JOIN completion_agg ca
    CROSS JOIN exercise_agg exa;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_plan_analytics_summary(UUID) TO authenticated;


-- 3g. get_client_analytics_summary
--     Authenticated only. Practice-membership check.
--     Aggregates across all plans for the client.
CREATE OR REPLACE FUNCTION public.get_client_analytics_summary(p_client_id UUID)
RETURNS TABLE (
  total_plans INT,
  total_opens INT,
  total_completions INT,
  last_opened_at TIMESTAMPTZ,
  avg_completion_rate NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller      UUID := auth.uid();
  v_practice_id UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_analytics_summary requires authentication'
      USING ERRCODE = '28000';
  END IF;

  -- Resolve client and check membership
  SELECT c.practice_id INTO v_practice_id
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids()) THEN
    RAISE EXCEPTION 'get_client_analytics_summary: caller is not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH client_plans AS (
    SELECT p.id AS plan_id
    FROM plans p
    WHERE p.client_id = p_client_id
      AND p.deleted_at IS NULL
  ),
  session_agg AS (
    SELECT
      COUNT(DISTINCT cs.plan_id)::INT AS plans_opened,
      COUNT(*)::INT AS total_open_count,
      MAX(cs.opened_at) AS max_opened
    FROM client_sessions cs
      JOIN client_plans cp ON cp.plan_id = cs.plan_id
    WHERE cs.consent_granted = true
  ),
  completion_agg AS (
    SELECT COUNT(*)::INT AS total_comp
    FROM plan_analytics_events e
      JOIN client_sessions cs ON cs.id = e.client_session_id
      JOIN client_plans cp ON cp.plan_id = cs.plan_id
    WHERE e.event_kind = 'plan_completed'
  )
  SELECT
    (SELECT COUNT(*)::INT FROM client_plans),
    sa.total_open_count,
    ca.total_comp,
    sa.max_opened,
    CASE WHEN sa.total_open_count > 0
      THEN ROUND(ca.total_comp::numeric / sa.total_open_count, 2)
      ELSE 0::numeric
    END
  FROM session_agg sa
    CROSS JOIN completion_agg ca;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_analytics_summary(UUID) TO authenticated;


-- =============================================================
-- 4. Extend set_client_video_consent to accept analytics_allowed
-- =============================================================

-- The 5-param overload already exists. We need to add a 6-param overload
-- that accepts p_analytics_allowed, and update the 4-param + 5-param
-- overloads to forward it.

-- 6-param overload (the new canonical version)
CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id UUID,
  p_line_drawing BOOLEAN,
  p_grayscale BOOLEAN,
  p_original BOOLEAN,
  p_avatar BOOLEAN,
  p_analytics_allowed BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_deleted_at   timestamptz;
  v_prev_consent jsonb;
  v_new_consent  jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_line_drawing IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'set_client_video_consent: line_drawing consent cannot be withdrawn (must be true)'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at, video_consent
    INTO v_practice_id, v_deleted_at, v_prev_consent
    FROM clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_video_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  v_new_consent := jsonb_build_object(
    'line_drawing', true,
    'grayscale',    COALESCE(p_grayscale, false),
    'original',     COALESCE(p_original, false),
    'avatar',       COALESCE(p_avatar, false),
    'analytics_allowed', COALESCE(p_analytics_allowed, true)
  );

  UPDATE clients
     SET video_consent = v_new_consent,
         consent_confirmed_at = now()
   WHERE id = p_client_id;

  IF v_prev_consent IS DISTINCT FROM v_new_consent THEN
    INSERT INTO public.audit_events (
      practice_id,
      actor_id,
      kind,
      ref_id,
      meta
    ) VALUES (
      v_practice_id,
      v_caller,
      'client.consent.update',
      p_client_id,
      jsonb_build_object(
        'from', v_prev_consent,
        'to',   v_new_consent
      )
    );
  END IF;
END;
$$;

-- Update 5-param overload to forward analytics_allowed from existing consent
CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id UUID,
  p_line_drawing BOOLEAN,
  p_grayscale BOOLEAN,
  p_original BOOLEAN,
  p_avatar BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing_analytics boolean;
BEGIN
  SELECT COALESCE((video_consent ->> 'analytics_allowed')::boolean, true)
    INTO v_existing_analytics
    FROM clients WHERE id = p_client_id;

  PERFORM public.set_client_video_consent(
    p_client_id,
    p_line_drawing,
    p_grayscale,
    p_original,
    p_avatar,
    COALESCE(v_existing_analytics, true)
  );
END;
$$;

-- Update 4-param overload to forward avatar + analytics_allowed from existing consent
CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id UUID,
  p_line_drawing BOOLEAN,
  p_grayscale BOOLEAN,
  p_original BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing_avatar boolean;
BEGIN
  SELECT COALESCE((video_consent ->> 'avatar')::boolean, false)
    INTO v_existing_avatar
    FROM clients WHERE id = p_client_id;

  PERFORM public.set_client_video_consent(
    p_client_id,
    p_line_drawing,
    p_grayscale,
    p_original,
    COALESCE(v_existing_avatar, false)
  );
END;
$$;

COMMIT;
