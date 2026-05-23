-- Safe Mode v2 (2026-05-23) — preserve safe_mode_face_recognition through
-- set_client_video_consent.
--
-- Background: set_client_video_consent rebuilds the video_consent jsonb
-- via jsonb_build_object() from its 5 args (line_drawing, grayscale,
-- original, avatar, analytics_allowed). After the Safe Mode v2 schema
-- migration added a 6th key (safe_mode_face_recognition), every call to
-- this RPC silently dropped that key from the jsonb. The mobile Save
-- handler calls set_client_safe_mode_consent first (sets the key) then
-- set_client_video_consent immediately after (wipes it). End-user
-- symptom: toggling the Face-recognition switch ON + Save shows it
-- flipping right back to OFF.
--
-- Fix: read the existing safe_mode_face_recognition value from
-- v_prev_consent (which we already loaded for the audit-diff path) and
-- carry it into v_new_consent. Same shape as how this function already
-- preserves analytics_allowed and avatar across lower-arity overloads.
--
-- Future-proofing note: the rebuild-from-scratch pattern is fragile.
-- Every new consent key has to be re-added here AND to every lower-arity
-- overload's COALESCE preservation block. A jsonb_set-per-key pattern
-- would be cleaner but is a bigger refactor — out of scope for this hotfix.

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

  -- Rebuild the jsonb from the 5 args PLUS the carried-forward
  -- safe_mode_face_recognition key. Default false if the key was never
  -- set (e.g. legacy clients pre-dating Safe Mode v2).
  v_new_consent := jsonb_build_object(
    'line_drawing', true,
    'grayscale',    COALESCE(p_grayscale, false),
    'original',     COALESCE(p_original, false),
    'avatar',       COALESCE(p_avatar, false),
    'analytics_allowed', COALESCE(p_analytics_allowed, true),
    'safe_mode_face_recognition',
      COALESCE((v_prev_consent ->> 'safe_mode_face_recognition')::boolean, false)
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
    )
    VALUES (
      v_practice_id,
      v_caller,
      'client.consent.update',
      p_client_id,
      jsonb_build_object('from', v_prev_consent, 'to', v_new_consent)
    );
  END IF;
END;
$function$;
