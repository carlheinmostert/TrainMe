-- =============================================================================
-- Lobby self-grant consent — anon RPC for the web-player lobby
-- =============================================================================
--
-- Date: 2026-05-04
-- Author: Frontend Architect agent (PR 4/4 of the web-player lobby train)
-- Status: WRITTEN, NOT APPLIED. Carl reviews + applies via
--   `supabase db query --linked --file supabase/schema_lobby_self_grant.sql`
--
-- WHAT THIS DOES
--   Adds ONE anon-callable RPC, `client_self_grant_consent(p_plan_id, p_kind)`,
--   that lets the client (the subject of the videos) self-grant `grayscale`
--   or `original` treatment playback for the current plan, from inside the
--   web-player lobby.
--
-- BACKSTORY
--   The web-player lobby ships a treatment selector (Line / B&W / Colour).
--   Treatments not granted by the practitioner show a lock glyph; tapping
--   one opens a "I am {ClientName}" self-grant modal. The modal's Allow
--   button calls this RPC, which:
--     1. Looks up the client_id via plans (anon can't read clients directly).
--     2. Sets the requested kind on `clients.video_consent` to true.
--     3. Emits a `client.consent.update` audit row with
--        `meta.source = 'client_self_grant'` so practitioners can see who
--        self-granted what.
--   The RPC mirrors `set_client_video_consent`'s audit shape (Wave 40.3),
--   but is callable by `anon` because the web-player has no auth identity.
--   The plan-id acts as a capability token: knowledge of the plan UUID
--   means knowledge of the share link, which is the trust model already
--   established by `get_plan_full`.
--
-- SECURITY MODEL
--   * `p_kind` is restricted to 'grayscale' or 'original'. Any other value
--     raises a validation error. `line_drawing` cannot be set by this
--     route (it's always true; consent can't be withdrawn) and `avatar`
--     is a practitioner-side permission only.
--   * The plan must exist and not be deleted. Otherwise, a generic error.
--   * `analytics_allowed` and other side-channel keys cannot be modified.
--   * The RPC is RPC-write-only — clients have no INSERT/UPDATE on
--     `public.clients` (Milestone C RLS lockdown).
--   * `actor_id` on the audit row is NULL (anon caller). The
--     `meta.source = 'client_self_grant'` discriminator + the client name
--     in the existing audit display are how practitioners spot self-grants.
--
-- FORWARD COMPAT
--   Same shape as `set_client_video_consent` so a future "self-grant
--   avatar" expansion can land by extending the kind allowlist + audit
--   meta. Out of scope here.
--
-- VERIFICATION (post-apply)
--
--   A. Plan existence error path:
--     SELECT public.client_self_grant_consent(
--       '00000000-0000-0000-0000-000000000000'::uuid, 'grayscale'
--     );
--     -- Expect: error 'plan not found'.
--
--   B. Invalid kind:
--     SELECT public.client_self_grant_consent(
--       '<plan-uuid>'::uuid, 'avatar'
--     );
--     -- Expect: error '... kind must be one of grayscale, original'.
--
--   C. Successful grant emits audit row:
--     SELECT public.client_self_grant_consent(
--       '<plan-uuid>'::uuid, 'grayscale'
--     );
--     SELECT kind, ref_id, meta->'source', meta->'from'->'grayscale',
--            meta->'to'->'grayscale'
--       FROM public.audit_events
--      WHERE kind = 'client.consent.update'
--      ORDER BY ts DESC LIMIT 1;
--     -- Expect: source='client_self_grant', from.grayscale=false,
--     --         to.grayscale=true.
--
--   D. Idempotent re-grant emits no row:
--     -- Run C twice. The second call should not emit a new audit row
--     -- because v_prev_consent IS NOT DISTINCT FROM v_new_consent.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.client_self_grant_consent(
  p_plan_id uuid,
  p_kind    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_practice_id   uuid;
  v_client_id     uuid;
  v_prev_consent  jsonb;
  v_new_consent   jsonb;
  v_kind_norm     text;
BEGIN
  -- Argument validation. Mirrors set_client_video_consent's ERRCODE
  -- pattern so the wire-level errors look familiar.
  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'client_self_grant_consent: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_kind IS NULL THEN
    RAISE EXCEPTION 'client_self_grant_consent: p_kind is required'
      USING ERRCODE = '22023';
  END IF;

  v_kind_norm := lower(trim(p_kind));
  IF v_kind_norm NOT IN ('grayscale', 'original') THEN
    RAISE EXCEPTION 'client_self_grant_consent: p_kind must be one of grayscale, original'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve plan → client. anon has no SELECT on plans/clients (Milestone
  -- C RLS), but this fn is SECURITY DEFINER so the lookup runs as
  -- postgres.
  SELECT p.practice_id, p.client_id
    INTO v_practice_id, v_client_id
    FROM plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'client_self_grant_consent: plan % not found', p_plan_id
      USING ERRCODE = '22023';
  END IF;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'client_self_grant_consent: plan % has no linked client', p_plan_id
      USING ERRCODE = '22023';
  END IF;

  -- Capture previous consent for the audit diff. Default shape mirrors
  -- the migration G default so legacy clients (pre-Wave 40.3) still
  -- produce a clean diff.
  SELECT video_consent INTO v_prev_consent
    FROM clients
   WHERE id = v_client_id
   LIMIT 1;

  IF v_prev_consent IS NULL THEN
    v_prev_consent := jsonb_build_object(
      'line_drawing', true,
      'grayscale',    false,
      'original',     false
    );
  END IF;

  -- Build the new consent jsonb. We preserve every key on v_prev_consent
  -- and only flip the requested kind to true. line_drawing stays true
  -- (the schema CHECK / set_client_video_consent enforce this on the
  -- practitioner path; we keep parity here for safety).
  v_new_consent := v_prev_consent || jsonb_build_object('line_drawing', true);

  IF v_kind_norm = 'grayscale' THEN
    v_new_consent := v_new_consent || jsonb_build_object('grayscale', true);
  ELSIF v_kind_norm = 'original' THEN
    v_new_consent := v_new_consent || jsonb_build_object('original', true);
  END IF;

  UPDATE clients
     SET video_consent        = v_new_consent,
         consent_confirmed_at = now()
   WHERE id = v_client_id;

  -- Emit audit row only if the consent actually changed. A second
  -- self-grant of an already-true kind is a no-op (silently succeeds,
  -- no audit noise).
  IF v_prev_consent IS DISTINCT FROM v_new_consent THEN
    INSERT INTO public.audit_events (
      practice_id,
      actor_id,
      kind,
      ref_id,
      meta
    ) VALUES (
      v_practice_id,
      NULL, -- anon caller — no auth.uid()
      'client.consent.update',
      v_client_id,
      jsonb_build_object(
        'from',   v_prev_consent,
        'to',     v_new_consent,
        'source', 'client_self_grant',
        'kind',   v_kind_norm
      )
    );
  END IF;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.client_self_grant_consent(uuid, text) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.client_self_grant_consent(uuid, text) FROM public;

COMMIT;
