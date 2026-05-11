-- ============================================================================
-- Wave 40.3 — Client consent redesign: avatar exposed to portal + audit-log
-- every consent change.
-- ============================================================================
--
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_wave40_3_consent_avatar_audit.sql
--
-- Idempotent: every statement uses CREATE OR REPLACE / DROP IF EXISTS.
-- Safe to re-run.
--
-- BACKGROUND
--   Wave 30 introduced the `avatar` consent slot when the body-focus avatar
--   feature shipped on mobile. Wave 30's `set_client_video_consent`
--   already accepts a fifth `p_avatar` parameter, and the `clients.video_consent`
--   jsonb already carries an `avatar` boolean. The portal, however, never
--   surfaced the avatar toggle — `ClientVideoConsent` in the portal still
--   reads three keys (line_drawing / grayscale / original), and the
--   `ClientDetailPanel` form stops at three rows.
--
--   This wave bridges the gap (a) on the portal side (covered in app code,
--   not in this migration) and (b) extends the existing 5-arg RPC to drop
--   an `audit_events` row on every successful consent change so the portal
--   /audit feed surfaces consent updates the same way it surfaces
--   `client.create` / `client.delete`.
--
-- WHAT THIS MIGRATION DOES
--   1. `set_client_video_consent(p_client_id, p_line_drawing, p_grayscale,
--      p_original, p_avatar)` — keeps the existing 5-arg shape (Wave 30),
--      preserves all security checks, but now:
--        a. SELECTs the prior `video_consent` jsonb into a local before
--           the UPDATE runs.
--        b. After the UPDATE, INSERTs into `public.audit_events` with
--           `kind='client.consent.update'`, `actor_id = auth.uid()`,
--           `ref_id = p_client_id`, `meta = {from: <prev>, to: <new>}`.
--        c. No-ops the audit insert when the from/to jsonb are equal
--           (saves SHOULD record an event only when something actually
--           changed). The portal de-duplicates rapid-fire saves on the
--           client side too, but the server-side guard means stray
--           identical saves don't bloat the audit log.
--
--   2. The 3-arg forwarding shim is preserved unchanged — it forwards into
--      the 5-arg path, which means stale (pre-Wave-30) mobile builds also
--      get audit rows for free.
--
--   3. `list_practice_audit` already surfaces `client.consent.update` rows
--      via its audit_events catchall branch (Wave 39 renamed the comment;
--      Wave 40.1 already routes plan.* and client.* rows through the
--      `client_id` / `client_name` derivation). Confirm the existing
--      `CASE WHEN ae.kind LIKE 'client.%' THEN ae.ref_id END` branch
--      catches `client.consent.update` — it does, because LIKE matches
--      on the prefix. No RPC change needed for the Client column to
--      populate.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT backfill historical `set_client_video_consent` calls. The
--     audit log starts from this migration forward.
--   * Does NOT introduce a new `p_avatar_visible` parameter — the existing
--     `p_avatar` parameter / `avatar` jsonb key shipped in Wave 30 and is
--     in production. Adding a parallel field would split the consent
--     namespace. The portal type widening (covered in app code) treats
--     `avatar` as the canonical key.
--   * Does NOT touch the 4-arg pre-Wave-30 shape — it never existed.
--   * Does NOT change `set_client_video_consent`'s argument signature.
--     The 5-arg shape is what mobile + portal converge on.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. set_client_video_consent — extend with audit-log emission
-- ============================================================================
--
-- The 5-arg shape from Wave 30 is preserved verbatim. We layer the audit
-- insert in via a prior-value capture + post-UPDATE comparison. When the
-- UPDATE is a no-op (consent jsonb unchanged), the audit row is suppressed
-- so saves that toggle a row and toggle it back don't double-bloat the log.
--
-- Postgres rejects argument-count changes via CREATE OR REPLACE. The 5-arg
-- shape ALREADY exists, so CREATE OR REPLACE is enough for this body update.

CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id     uuid,
  p_line_drawing  boolean,
  p_grayscale     boolean,
  p_original      boolean,
  p_avatar        boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
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

  -- Capture prior state before mutation. The same SELECT also resolves
  -- practice_id + deleted_at so we don't make two round-trips.
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
    'avatar',       COALESCE(p_avatar, false)
  );

  UPDATE clients
     SET video_consent = v_new_consent,
         consent_confirmed_at = now()
   WHERE id = p_client_id;

  -- Wave 40.3 — log the change. Suppress if the jsonb didn't actually
  -- move (e.g. a save that toggled a value back before commit). The
  -- jsonb equality check is order-sensitive but jsonb_build_object emits
  -- keys in a stable order, so this is safe.
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
$fn$;

GRANT EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean, boolean) FROM anon, public;

-- The 3-arg forwarding shim is unchanged — it PERFORMs the 5-arg variant
-- and inherits the audit-log behaviour for free. Stale mobile builds that
-- only know the 3-arg shape get audit rows automatically.

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
--
-- A. RPC body now references audit_events:
--   SELECT proname FROM pg_proc
--    WHERE proname = 'set_client_video_consent'
--      AND prosrc LIKE '%client.consent.update%';
--   -- Expect: 1 row (the 5-arg variant).
--
-- B. Round-trip a save:
--   SELECT public.set_client_video_consent(
--     '<client-uuid>'::uuid,
--     true, true, false, false  -- flip grayscale on
--   );
--   SELECT id, kind, ref_id, meta->'from', meta->'to' FROM public.audit_events
--    WHERE kind = 'client.consent.update' AND ref_id = '<client-uuid>'::uuid
--    ORDER BY ts DESC LIMIT 1;
--   -- Expect: a row whose meta.from has grayscale=false and meta.to has grayscale=true.
--
-- C. No-op save does NOT emit a row:
--   SELECT public.set_client_video_consent(
--     '<client-uuid>'::uuid, true, true, false, false  -- same as before
--   );
--   -- Expect: no new audit_events row appended.
--
-- D. list_practice_audit surfaces the new kind via its catchall:
--   SELECT kind, client_id, client_name FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50,
--     ARRAY['client.consent.update'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: client_id = ref_id, client_name populated via the
--   --         existing 'client.%' branch in list_practice_audit.
-- ============================================================================
