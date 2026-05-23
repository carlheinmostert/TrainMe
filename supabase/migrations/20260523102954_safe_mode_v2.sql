-- 2026-05-23 — Safe Mode v2 (face-recognition keep-the-client rewrite)
--
-- Spec: docs/specs/2026-05-23-safe-mode-face-rec.md
--
-- Part 1 of 3 (schema + RPCs). Native iOS (MobileFaceNet enrolment +
-- per-frame matching) and Dart wiring follow in subsequent PRs.
--
-- Background: Safe Mode v1 (PR #389) used the largest detected human
-- bounding box as the "client" and painted everyone else coral. That
-- heuristic broke in multi-person frames where a bystander entered
-- closer to the camera (bigger bbox than the actual client). v2 replaces
-- bbox-size with face-recognition: on first capture for a client the
-- practitioner enrols a 128-dim FP32 face embedding via MobileFaceNet,
-- and subsequent captures match every detected face against the stored
-- embedding — the matching face's segmentation mask renders normally,
-- everyone else gets the coral overlay.
--
-- Three column adds + two new SECURITY DEFINER RPCs + a return-table
-- extension on `list_practice_clients`. Privacy-first: opting OUT of
-- `safe_mode_face_recognition` consent ALSO zeros the stored embedding,
-- so withdrawing consent is a full data deletion (matches POPIA).

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Column adds
-- ----------------------------------------------------------------------------

-- clients.face_embedding stores 128 FP32 little-endian floats = 512 bytes.
-- MobileFaceNet v1 is the only generator today (model_version = 1). A
-- future model upgrade bumps the version + invalidates older rows.
ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS face_embedding bytea,
  ADD COLUMN IF NOT EXISTS face_embedding_model_version smallint;

COMMENT ON COLUMN public.clients.face_embedding IS
  'Safe Mode v2 — 128-dim FP32 little-endian face embedding produced by '
  'MobileFaceNet. Exactly 512 bytes when present. NULL = client has not '
  'been enrolled, OR enrolment was wiped via set_client_safe_mode_consent '
  '(p_consent = false). Withdrawing consent erases this column.';

COMMENT ON COLUMN public.clients.face_embedding_model_version IS
  'Safe Mode v2 — generator version for face_embedding. Currently always '
  '1 (MobileFaceNet v1). When the model is upgraded this column gets '
  'bumped so legacy embeddings can be detected and re-enrolled.';

-- exercises.safe_mode_algorithm_version captures which Safe Mode generation
-- produced this exercise's safe variant. v1 was bbox-largest (never shipped
-- to prod), v2 is face-rec MobileFaceNet (this design). NULL = the capture
-- predates Safe Mode v2 or was not captured with Safe Mode active.
ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS safe_mode_algorithm_version smallint;

COMMENT ON COLUMN public.exercises.safe_mode_algorithm_version IS
  'Safe Mode algorithm version stamped at capture time. NULL = non-Safe-'
  'Mode capture (or Safe-Mode-off). 1 = anchor-box (legacy, never shipped '
  'to prod). 2 = face-rec MobileFaceNet (current). Audit feed surfaces '
  'this so the portal can show "Safe Mode v2" chip.';


-- ----------------------------------------------------------------------------
-- 2. RPC: set_client_face_embedding
--
--    Practitioner enrols the per-client face embedding generated locally
--    on iOS (MobileFaceNet inference). The embedding itself is NOT a
--    consent decision — no audit_events row. Consent for face recognition
--    flows through set_client_safe_mode_consent (below).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_client_face_embedding(
  p_client_id     uuid,
  p_embedding     bytea,
  p_model_version smallint
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
  v_deleted_at  timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_face_embedding requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_face_embedding: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_embedding IS NULL THEN
    RAISE EXCEPTION 'set_client_face_embedding: p_embedding is required'
      USING ERRCODE = '22023';
  END IF;

  -- Sanity check: 128 FP32 little-endian floats = 512 bytes. Any other
  -- size is a client-side bug; refuse to persist a malformed embedding.
  IF length(p_embedding) <> 512 THEN
    RAISE EXCEPTION 'set_client_face_embedding: expected 512-byte embedding, got % bytes',
      length(p_embedding)
      USING ERRCODE = '22023';
  END IF;

  IF p_model_version IS NULL OR p_model_version < 1 THEN
    RAISE EXCEPTION 'set_client_face_embedding: p_model_version must be >= 1'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at
    INTO v_practice_id, v_deleted_at
    FROM clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_face_embedding: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_face_embedding: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids())
     AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_face_embedding: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE clients
     SET face_embedding               = p_embedding,
         face_embedding_model_version = p_model_version
   WHERE id = p_client_id;

  -- Deliberately no audit_events row. The embedding is biometric data
  -- but the act of enrolling is part of capture, not a consent toggle.
  -- Consent flips go through set_client_safe_mode_consent below and DO
  -- emit client.consent.update events.
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.set_client_face_embedding(uuid, bytea, smallint) FROM public;
GRANT  EXECUTE ON FUNCTION public.set_client_face_embedding(uuid, bytea, smallint) TO authenticated;


-- ----------------------------------------------------------------------------
-- 3. RPC: set_client_safe_mode_consent
--
--    Toggles the `safe_mode_face_recognition` key in clients.video_consent.
--    When set to false, ALSO zeros the stored face_embedding +
--    face_embedding_model_version so withdrawing consent is a full data
--    deletion (POPIA-aligned). Emits a client.consent.update audit_events
--    row with the {from, to} jsonb diff, mirroring set_client_video_consent.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_client_safe_mode_consent(
  p_client_id uuid,
  p_consent   boolean
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
    RAISE EXCEPTION 'set_client_safe_mode_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_consent IS NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: p_consent is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at, video_consent
    INTO v_practice_id, v_deleted_at, v_prev_consent
    FROM clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids())
     AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Patch the safe_mode_face_recognition key. jsonb_set with
  -- create_missing := true handles both "key absent" + "key present"
  -- cases without a NULL pitfall when video_consent itself is NULL.
  v_new_consent := jsonb_set(
    COALESCE(v_prev_consent, '{}'::jsonb),
    '{safe_mode_face_recognition}',
    to_jsonb(p_consent),
    true
  );

  IF p_consent = false THEN
    -- Privacy: withdrawing consent erases the biometric data. The
    -- practitioner can re-enrol on the next capture if the client
    -- changes their mind.
    UPDATE clients
       SET video_consent               = v_new_consent,
           face_embedding               = NULL,
           face_embedding_model_version = NULL
     WHERE id = p_client_id;
  ELSE
    UPDATE clients
       SET video_consent = v_new_consent
     WHERE id = p_client_id;
  END IF;

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

REVOKE EXECUTE ON FUNCTION public.set_client_safe_mode_consent(uuid, boolean) FROM public;
GRANT  EXECUTE ON FUNCTION public.set_client_safe_mode_consent(uuid, boolean) TO authenticated;


-- ----------------------------------------------------------------------------
-- 4. list_practice_clients — surface face_embedding +
--    face_embedding_model_version so the mobile cache + UI can show
--    "enrolled" state without a second round-trip.
--
--    Every other column carried forward verbatim per the column-
--    preservation gotcha (feedback_schema_migration_column_preservation).
--    Source was pulled from the live function definition (latest patch
--    landed in 20260513065845_consent_explicitly_set_at.sql).
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_practice_clients(uuid);
CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
 RETURNS TABLE(
   id                            uuid,
   name                          text,
   video_consent                 jsonb,
   consent_confirmed_at          timestamp with time zone,
   consent_explicitly_set_at     timestamp with time zone,
   avatar_path                   text,
   avatar_url                    text,
   client_exercise_defaults      jsonb,
   last_plan_at                  timestamp with time zone,
   face_embedding                bytea,
   face_embedding_model_version  smallint
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
             AND p.deleted_at IS NULL) AS last_plan_at,
         c.face_embedding,
         c.face_embedding_model_version
    FROM clients c
   WHERE c.practice_id = p_practice_id
     AND c.deleted_at IS NULL
   ORDER BY last_plan_at DESC NULLS LAST, c.name ASC;
END;
$function$;

COMMIT;
