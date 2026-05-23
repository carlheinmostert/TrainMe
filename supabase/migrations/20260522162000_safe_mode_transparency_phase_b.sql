-- ============================================================================
-- Safe Mode Transparency — Phase B: live page + heartbeat
-- ============================================================================
-- Spec: docs/specs/2026-05-22-safe-mode-transparency.md
--
-- Phase B adds the public live transparency page at
-- `session.homefit.studio/v/{slug}/now`. Practitioners send a 20s
-- heartbeat while Safe Mode is active; the live page polls every 12s
-- and renders active sessions as floating cards over an SVG polygon map.
--
-- New objects:
--   * active_capture_sessions   — append-then-stamp state table.
--   * start_capture_session     — INSERT, returns new id.
--   * heartbeat_capture_session — UPDATE last_heartbeat + position.
--   * end_capture_session       — stamp ended_at.
--   * get_live_sessions(p_slug) — anon-readable; returns active rows.
--
-- Anonymous read surface returns:
--   - practitioner first_name / last_name / avatar_url (already public
--     by virtue of Phase A's contract).
--   - session lat / lng / started_at / heartbeat_at.
--   - the practice's polygon coordinates as JSON arrays (one polygon
--     per premises) so the live page can render the map without any
--     PostGIS client.
--
-- Lockdown:
--   active_capture_sessions is RPC-write-only (mirrors credit_ledger).
--   SELECT is scoped to practice members; the anon RPC returns a
--   curated row shape, never a direct SELECT.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. active_capture_sessions table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.active_capture_sessions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_id         uuid NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
  trainer_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  premises_id         uuid REFERENCES public.practice_premises(id) ON DELETE SET NULL,
  started_at          timestamptz NOT NULL DEFAULT now(),
  last_heartbeat_at   timestamptz NOT NULL DEFAULT now(),
  last_latitude       double precision,
  last_longitude      double precision,
  ended_at            timestamptz,
  manual_mode         boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS active_sessions_practice_live_idx
  ON public.active_capture_sessions (practice_id, ended_at)
  WHERE ended_at IS NULL;

CREATE INDEX IF NOT EXISTS active_sessions_heartbeat_idx
  ON public.active_capture_sessions (last_heartbeat_at)
  WHERE ended_at IS NULL;

CREATE INDEX IF NOT EXISTS active_sessions_trainer_idx
  ON public.active_capture_sessions (trainer_id, ended_at);

-- ---------------------------------------------------------------------------
-- 2. RLS — RPC-write-only, SELECT scoped to practice members.
-- ---------------------------------------------------------------------------
ALTER TABLE public.active_capture_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS active_sessions_select_member ON public.active_capture_sessions;
CREATE POLICY active_sessions_select_member
  ON public.active_capture_sessions
  FOR SELECT
  TO authenticated
  USING (practice_id = ANY (SELECT public.user_practice_ids()));

REVOKE INSERT, UPDATE, DELETE ON public.active_capture_sessions FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.active_capture_sessions FROM anon;
GRANT SELECT ON public.active_capture_sessions TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. start_capture_session
--    Inserts a new active session for the caller's (practice, trainer).
--    Returns the new id. The trainer must be a member of the practice.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.start_capture_session(uuid, uuid, double precision, double precision, boolean);

CREATE FUNCTION public.start_capture_session(
  p_practice_id uuid,
  p_premises_id uuid,
  p_lat         double precision,
  p_lng         double precision,
  p_manual      boolean DEFAULT false
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
    RAISE EXCEPTION 'start_capture_session requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'start_capture_session: practice_id required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT (p_practice_id = ANY(SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'start_capture_session: caller is not a practice member'
      USING ERRCODE = '42501';
  END IF;

  -- Auto-close any stale active sessions for this trainer to keep the
  -- table from growing unbounded if the client crashed without calling
  -- end_capture_session. Same-trainer-only — never touch a teammate's
  -- row even if it looks stale.
  UPDATE public.active_capture_sessions
     SET ended_at = now()
   WHERE trainer_id = v_caller
     AND ended_at IS NULL;

  INSERT INTO public.active_capture_sessions (
    practice_id, trainer_id, premises_id,
    last_latitude, last_longitude, manual_mode
  )
  VALUES (
    p_practice_id, v_caller, p_premises_id,
    p_lat, p_lng, coalesce(p_manual, false)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.start_capture_session(uuid, uuid, double precision, double precision, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_capture_session(uuid, uuid, double precision, double precision, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_capture_session(uuid, uuid, double precision, double precision, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. heartbeat_capture_session
--    Updates last_heartbeat_at + position on the caller's own row. No-op
--    if the session is already ended OR belongs to a different trainer
--    (silent — the client may have raced an end_capture_session call).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.heartbeat_capture_session(uuid, double precision, double precision);

CREATE FUNCTION public.heartbeat_capture_session(
  p_session_id uuid,
  p_lat        double precision,
  p_lng        double precision
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'heartbeat_capture_session requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  UPDATE public.active_capture_sessions
     SET last_heartbeat_at = now(),
         last_latitude     = coalesce(p_lat, last_latitude),
         last_longitude    = coalesce(p_lng, last_longitude)
   WHERE id = p_session_id
     AND trainer_id = v_caller
     AND ended_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.heartbeat_capture_session(uuid, double precision, double precision) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.heartbeat_capture_session(uuid, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.heartbeat_capture_session(uuid, double precision, double precision) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. end_capture_session
--    Stamps ended_at = now() on the caller's own row. Idempotent — if
--    the row is already ended, the UPDATE matches zero rows.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.end_capture_session(uuid);

CREATE FUNCTION public.end_capture_session(
  p_session_id uuid
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'end_capture_session requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  UPDATE public.active_capture_sessions
     SET ended_at = now()
   WHERE id = p_session_id
     AND trainer_id = v_caller
     AND ended_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.end_capture_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.end_capture_session(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.end_capture_session(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. get_live_sessions — anon-readable.
--    Returns active sessions for the practice identified by slug, plus
--    the practice's polygon coordinates so the live page can draw the
--    map without a PostGIS client.
--
--    Only sessions with last_heartbeat_at >= now() - 60s are surfaced;
--    stale rows are filtered server-side so polling clients never see
--    them.
--
--    Returned shape (one row per active session, plus one extra row
--    per premises with NULL session fields — the client merges):
--      practice_id, practice_name, practice_slug,
--      premises_id, premises_name, premises_polygon (jsonb array of [lng, lat] pairs),
--      session_id, trainer_id, first_name, last_name, avatar_url,
--      started_at, last_heartbeat_at, last_latitude, last_longitude,
--      manual_mode, kind text   -- 'session' or 'premises'
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_live_sessions(text);

CREATE FUNCTION public.get_live_sessions(
  p_slug text
)
 RETURNS TABLE (
   practice_id        uuid,
   practice_name      text,
   practice_slug      text,
   premises_id        uuid,
   premises_name      text,
   premises_polygon   jsonb,
   session_id         uuid,
   trainer_id         uuid,
   first_name         text,
   last_name          text,
   avatar_url         text,
   started_at         timestamptz,
   last_heartbeat_at  timestamptz,
   last_latitude      double precision,
   last_longitude     double precision,
   manual_mode        boolean,
   kind               text
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', extensions
AS $function$
DECLARE
  v_slug      text := nullif(btrim(lower(coalesce(p_slug, ''))), '');
  v_practice  public.practices%ROWTYPE;
BEGIN
  IF v_slug IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_practice
    FROM public.practices p
   WHERE p.public_slug = v_slug
     AND coalesce(p.public_profile_listed, false) = true
   LIMIT 1;

  IF v_practice.id IS NULL THEN
    RETURN;
  END IF;

  -- One row per premises so the client can draw the polygons. Empty
  -- session columns; kind = 'premises'.
  RETURN QUERY
    SELECT
      v_practice.id           AS practice_id,
      v_practice.name         AS practice_name,
      v_practice.public_slug  AS practice_slug,
      pp.id                   AS premises_id,
      pp.name                 AS premises_name,
      to_jsonb(
        ARRAY(
          SELECT jsonb_build_array(extensions.ST_X(pt), extensions.ST_Y(pt))
            FROM extensions.ST_DumpPoints(pp.polygon) AS d(path, pt)
           ORDER BY (d.path)[2]
        )
      )                       AS premises_polygon,
      NULL::uuid              AS session_id,
      NULL::uuid              AS trainer_id,
      NULL::text              AS first_name,
      NULL::text              AS last_name,
      NULL::text              AS avatar_url,
      NULL::timestamptz       AS started_at,
      NULL::timestamptz       AS last_heartbeat_at,
      NULL::double precision  AS last_latitude,
      NULL::double precision  AS last_longitude,
      NULL::boolean           AS manual_mode,
      'premises'::text        AS kind
    FROM public.practice_premises pp
   WHERE pp.practice_id = v_practice.id
     AND pp.deleted_at IS NULL
     AND pp.safe_mode_enforced = true;

  -- One row per active capture session (heartbeat < 60s ago).
  RETURN QUERY
    SELECT
      v_practice.id           AS practice_id,
      v_practice.name         AS practice_name,
      v_practice.public_slug  AS practice_slug,
      acs.premises_id         AS premises_id,
      pp.name                 AS premises_name,
      NULL::jsonb             AS premises_polygon,
      acs.id                  AS session_id,
      acs.trainer_id          AS trainer_id,
      prac.first_name         AS first_name,
      prac.last_name          AS last_name,
      prac.avatar_url         AS avatar_url,
      acs.started_at          AS started_at,
      acs.last_heartbeat_at   AS last_heartbeat_at,
      acs.last_latitude       AS last_latitude,
      acs.last_longitude      AS last_longitude,
      acs.manual_mode         AS manual_mode,
      'session'::text         AS kind
    FROM public.active_capture_sessions acs
    LEFT JOIN public.practice_premises pp
      ON pp.id = acs.premises_id
    LEFT JOIN public.practitioners prac
      ON prac.user_id = acs.trainer_id
   WHERE acs.practice_id = v_practice.id
     AND acs.ended_at IS NULL
     AND acs.last_heartbeat_at >= now() - interval '60 seconds';
END;
$function$;

REVOKE ALL ON FUNCTION public.get_live_sessions(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text) TO service_role;

COMMIT;
