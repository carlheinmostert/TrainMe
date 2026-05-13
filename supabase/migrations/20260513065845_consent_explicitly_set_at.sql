-- 2026-05-13 — consent_explicitly_set_at
--
-- Auto-open the consent sheet on the practitioner's first entry into a
-- client detail view (covers BOTH newly-created clients AND legacy
-- clients whose consent was never explicitly toggled). The mobile
-- ClientSessionsScreen reads this column on initState and, when NULL,
-- expands + scrolls-into-view the consent accordion.
--
-- Backing the behaviour with a TIMESTAMPTZ rather than a boolean lets
-- future "remind me again in 90 days" / re-consent flows reuse the same
-- column without a schema bump.
--
-- IMPORTANT — NO BACKFILL. Existing rows stay NULL on purpose so legacy
-- clients ALSO trigger the auto-open on next entry (Carl-signoff
-- 2026-05-13). The 5-arg overload of `set_client_video_consent` (the
-- canonical writer; the 3- and 4-arg overloads delegate to it) is
-- patched to stamp NOW() on every call. Any consent toggle — including
-- a no-op save that just confirms current state — flips the row from
-- NULL to a real timestamp and suppresses the auto-open thereafter.
--
-- Edge case: if the practitioner opens the sheet but closes it without
-- toggling anything, the column stays NULL and the next entry re-opens.
-- Acceptable for v1; a future iteration may add a "consent.viewed" stamp
-- to suppress repeat auto-opens after a dismissal.
--
-- Surfaces returning the column:
--   - public.list_practice_clients(p_practice_id)
--   - public.get_client_by_id(p_client_id)
--
-- See `gotcha_schema_migration_column_preservation` — both RPCs are
-- re-CREATEd via pg_get_functiondef-style full rewrites to carry every
-- existing column forward.

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Column
-- ----------------------------------------------------------------------------
ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS consent_explicitly_set_at TIMESTAMPTZ;

COMMENT ON COLUMN public.clients.consent_explicitly_set_at IS
  'Stamped by set_client_video_consent on every call. NULL = '
  'practitioner has never explicitly set this client''s consent. '
  'Mobile auto-opens the consent sheet on first client entry when NULL.';

-- ----------------------------------------------------------------------------
-- 2. set_client_video_consent (5-arg canonical writer) — stamp the column.
--    All shorter overloads delegate to this one; patching here covers them.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id        uuid,
  p_line_drawing     boolean,
  p_grayscale        boolean,
  p_original         boolean,
  p_avatar           boolean,
  p_analytics_allowed boolean
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- Stamp consent_explicitly_set_at unconditionally — every call to this
  -- RPC, even a no-op save that re-affirms current values, counts as an
  -- explicit acknowledgement and suppresses the auto-open on subsequent
  -- entries.
  UPDATE clients
     SET video_consent             = v_new_consent,
         consent_confirmed_at      = now(),
         consent_explicitly_set_at = now()
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
$function$;

-- ----------------------------------------------------------------------------
-- 3. list_practice_clients — return consent_explicitly_set_at so the
--    mobile cache + UI can gate auto-open without a second round-trip.
--    Every other column carried forward verbatim per the column-
--    preservation gotcha.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_practice_clients(uuid);
CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
 RETURNS TABLE(
   id                          uuid,
   name                        text,
   video_consent               jsonb,
   consent_confirmed_at        timestamp with time zone,
   consent_explicitly_set_at   timestamp with time zone,
   avatar_path                 text,
   avatar_url                  text,
   client_exercise_defaults    jsonb,
   last_plan_at                timestamp with time zone
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = p_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_practice_clients: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         c.consent_confirmed_at,
         c.consent_explicitly_set_at,
         c.avatar_path,
         CASE
           WHEN c.avatar_path IS NOT NULL AND length(c.avatar_path) > 0
           THEN public.sign_storage_url('raw-archive', c.avatar_path, 3600)
           ELSE NULL
         END AS avatar_url,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults,
         (SELECT MAX(COALESCE(p.sent_at, p.created_at))
            FROM plans p
           WHERE p.client_id = c.id
             AND p.deleted_at IS NULL) AS last_plan_at
    FROM clients c
   WHERE c.practice_id = p_practice_id
     AND c.deleted_at IS NULL
   ORDER BY last_plan_at DESC NULLS LAST, c.name ASC;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 4. get_client_by_id — same column addition, same forward-port.
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_client_by_id(uuid);
CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
 RETURNS TABLE(
   id                          uuid,
   name                        text,
   video_consent               jsonb,
   consent_confirmed_at        timestamp with time zone,
   consent_explicitly_set_at   timestamp with time zone,
   avatar_path                 text,
   avatar_url                  text,
   client_exercise_defaults    jsonb
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_by_id requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = v_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         c.consent_confirmed_at,
         c.consent_explicitly_set_at,
         c.avatar_path,
         CASE
           WHEN c.avatar_path IS NOT NULL AND length(c.avatar_path) > 0
           THEN public.sign_storage_url('raw-archive', c.avatar_path, 3600)
           ELSE NULL
         END AS avatar_url,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;
END;
$function$;

COMMIT;
