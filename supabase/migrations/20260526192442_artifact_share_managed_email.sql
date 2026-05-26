-- ============================================================================
-- Artifact-system Wave 5 — managed email + verified-claim supersession
-- 2026-05-26 — feat/artifact-share-managed-email
--
-- ADR: docs/adr/0024-anonymous-link-survives-claim-is-opt-in.md
-- Design: docs/ARTIFACT_SYSTEM.md § Share sheet (managed email path)
-- Mockup: docs/design/mockups/2026-05-26-share-sheet.html
--
-- What this lands:
--
--   1. clients.email TEXT NULL — the practitioner-typed transient email a
--      practitioner enters in the Studio share sheet ("Send by email"). It is
--      transient in the ADR-0024 sense: useful for one-off branded delivery
--      until the recipient claims the plan and surfaces a verified email of
--      their own.
--
--   2. clients.email_verified_at TIMESTAMPTZ NULL — NULL while the typed
--      address sits there. The claim flow stamps it to now() when the
--      recipient's auth.users.email_confirmed_at is non-null (magic-link
--      confirms inherently → ADR 0024 "verified email supersedes typed
--      email"). The send-artifact-email edge function refuses to overwrite
--      a verified address — once verified, the typed-email path is dead.
--
--   3. set_client_email(p_client_id uuid, p_email text) → jsonb —
--      SECURITY DEFINER, membership-checked. Empty string = clear. Returns
--      {ok: true} or {ok: false, reason: 'invalid_email' | 'forbidden'}.
--      Writes audit_events kind 'client.email.set'. Setting via this RPC
--      always clears email_verified_at (the typed value is by definition
--      unverified).
--
--   4. claim_plan(uuid) — extended to write a verified email into
--      clients.email + stamp email_verified_at when the claiming consumer's
--      auth.users.email_confirmed_at is non-null AND the existing
--      email_verified_at is NULL (or older — the most recent verified email
--      wins on a reclaim). Writes a separate 'client.email.verified' audit
--      row in that branch. All existing claim_plan behaviour preserved
--      verbatim per feedback_schema_migration_column_preservation.md —
--      sourced from 20260526173515_artifact_system_claim.sql.
--
-- audit_events.kind is unconstrained text (only `length(kind) > 0`) so the
-- two new kinds need no CHECK widening. Verified via baseline schema.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS email             text,
  ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;

COMMENT ON COLUMN public.clients.email IS
  'Optional contact email. Two write paths:'
  ' (1) practitioner-typed via set_client_email RPC or the send-artifact-email'
  ' edge function — UNverified (email_verified_at IS NULL).'
  ' (2) verified-claim supersession via claim_plan when auth.users.email_confirmed_at'
  ' is non-null — sets email_verified_at = now() in the same statement.'
  ' Once verified the typed-email path will not overwrite (ADR 0024).';

COMMENT ON COLUMN public.clients.email_verified_at IS
  'When the email column was last verified via a magic-link claim flow.'
  ' NULL = unverified or absent. Set by claim_plan; cleared by set_client_email.'
  ' ADR 0024.';

-- Length guard so a pasted megastring doesn't slip past Postgres into the
-- send queue. 254 is the RFC 5321 cap; this is a defensive ceiling not a
-- format check — the format check lives in set_client_email + the edge
-- function (both happy paths).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'clients_email_length'
  ) THEN
    ALTER TABLE public.clients
      ADD CONSTRAINT clients_email_length
        CHECK (email IS NULL OR length(email) <= 254);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. set_client_email(p_client_id uuid, p_email text) → jsonb
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER. Practice-membership-checked.
--
-- p_email = NULL or '' → clears clients.email + clients.email_verified_at.
-- p_email = otherwise → must match a basic email regex; rejects with
--                       {ok: false, reason: 'invalid_email'} on miss.
--
-- Writes an audit_events row with kind = 'client.email.set' on every
-- successful change (both set + clear). Meta carries {from_present, to_present}
-- so the audit feed can render "email added" / "email cleared" without
-- exposing the address itself.
--
-- Returns:
--   * {ok: true, cleared: <bool>}                  on success
--   * {ok: false, reason: 'invalid_email'}         on regex miss
--   * {ok: false, reason: 'forbidden'}             on RLS / membership miss
--   * {ok: false, reason: 'unauthenticated'}       on anon caller (defensive)
--
-- The basic regex `^[^@\s]+@[^@\s]+\.[^@\s]+$` is intentionally permissive —
-- the receiving edge function does the actual SMTP-grade validation by
-- handing the address to Resend. This regex is the "obviously not an email"
-- guard, not a deliverability check.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_client_email(
  p_client_id uuid,
  p_email     text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller         uuid := auth.uid();
  v_practice_id    uuid;
  v_existing_email text;
  v_normalised     text;
  v_cleared        boolean := false;
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unauthenticated');
  END IF;

  IF p_client_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_client_id');
  END IF;

  -- Resolve the practice + check membership in one shot.
  SELECT c.practice_id, c.email
    INTO v_practice_id, v_existing_email
    FROM public.clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;

  IF v_practice_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.practice_members
     WHERE practice_id = v_practice_id
       AND trainer_id  = v_caller
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  -- Normalise. Empty string → NULL (clear). Whitespace-only → NULL.
  -- Anything else has surrounding whitespace stripped and is lowercased
  -- (case-insensitive equality is the only sane default).
  v_normalised := nullif(trim(lower(coalesce(p_email, ''))), '');

  IF v_normalised IS NULL THEN
    -- Clear path. Skip the write if there's nothing to clear so the audit
    -- feed doesn't surface no-op events.
    IF v_existing_email IS NULL THEN
      RETURN jsonb_build_object('ok', true, 'cleared', true, 'noop', true);
    END IF;

    UPDATE public.clients
       SET email             = NULL,
           email_verified_at = NULL
     WHERE id = p_client_id;

    v_cleared := true;
  ELSE
    -- Lenient format check — defensive only. Real validation = Resend.
    IF v_normalised !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_email');
    END IF;

    -- Idempotent — skip write + audit if the value matches.
    IF v_existing_email IS NOT DISTINCT FROM v_normalised THEN
      -- The typed-write contract IS that the result is unverified. If we
      -- managed to land on a value that's already there, the verified
      -- stamp stays whatever it was (verified rows shouldn't be touched
      -- by this code path — see the send-artifact-email refusal — but if
      -- we get here we leave the stamp alone).
      RETURN jsonb_build_object('ok', true, 'noop', true);
    END IF;

    UPDATE public.clients
       SET email             = v_normalised,
           email_verified_at = NULL  -- typed = unverified
     WHERE id = p_client_id;
  END IF;

  -- Audit. Practice scope is the client's practice. The address itself
  -- is NOT in meta (POPIA — typed contact is per-client PII, not log fodder).
  INSERT INTO public.audit_events (practice_id, actor_id, kind, ref_id, meta)
  VALUES (
    v_practice_id,
    v_caller,
    'client.email.set',
    p_client_id,
    jsonb_build_object(
      'from_present', v_existing_email IS NOT NULL,
      'to_present',   NOT v_cleared,
      'cleared',      v_cleared
    )
  );

  RETURN jsonb_build_object('ok', true, 'cleared', v_cleared);
END;
$function$;

COMMENT ON FUNCTION public.set_client_email(uuid, text) IS
  'Wave 5 — sets the practitioner-typed transient client email. Empty input '
  'clears the column. Always clears email_verified_at (the typed value is '
  'by definition unverified). Writes audit_events kind ''client.email.set'' '
  'with from_present/to_present booleans only — the address itself is not in '
  'meta (POPIA). ADR 0024.';

REVOKE ALL ON FUNCTION public.set_client_email(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_client_email(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. claim_plan — extended with verified-email supersession (ADR 0024)
-- ---------------------------------------------------------------------------
-- Source: 20260526173515_artifact_system_claim.sql (Wave 2). Every existing
-- branch preserved verbatim. The only additions are:
--   * Read auth.users.email + email_confirmed_at for the claiming consumer.
--   * After the existing client_accounts upsert, if email_confirmed_at IS
--     NOT NULL: write the verified email into clients.email + stamp
--     clients.email_verified_at = now(). Idempotent — if the same address
--     is already verified on the row, skip the write.
--   * On a write, append an extra audit_events row kind 'client.email.verified'
--     so the practitioner-side audit feed sees the supersession alongside
--     the existing 'artifact.claimed' row.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.claim_plan(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller             uuid := auth.uid();
  v_practice_client_id uuid;
  v_practice_id        uuid;
  v_inherited_consent  jsonb;
  v_already            boolean := false;
  -- Wave 5 additions
  v_consumer_email     text;
  v_consumer_confirmed timestamptz;
  v_existing_email     text;
  v_existing_verified  timestamptz;
  v_email_superseded   boolean := false;
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unauthenticated');
  END IF;

  IF p_plan_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_plan_id');
  END IF;

  -- Pull plan_id → client_id → practice_id. Deleted plans cannot be
  -- claimed.
  SELECT p.client_id, p.practice_id
    INTO v_practice_client_id, v_practice_id
    FROM public.plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL;

  IF v_practice_client_id IS NULL THEN
    -- Either the plan doesn't exist / is deleted, OR the plan exists but
    -- has no client_id (legacy pre-spine row). Both fail the same way —
    -- the consumer surface renders a generic error.
    RETURN jsonb_build_object('ok', false, 'reason', 'no_client_link');
  END IF;

  -- Inherit consent from the practitioner-proxy at claim time. Decision
  -- #17 — continuity. Default to the hardcoded matrix if the clients
  -- row's video_consent is unexpectedly null.
  SELECT video_consent, email, email_verified_at
    INTO v_inherited_consent, v_existing_email, v_existing_verified
    FROM public.clients
   WHERE id = v_practice_client_id;

  IF v_inherited_consent IS NULL THEN
    v_inherited_consent := jsonb_build_object(
      'line_drawing',                true,
      'grayscale',                   false,
      'original',                    false,
      'avatar',                      false,
      'safe_mode_face_recognition',  false,
      'analytics_allowed',           false
    );
  END IF;

  -- line_drawing is always true regardless (ADR 0026 decision #27).
  v_inherited_consent := v_inherited_consent
                          || jsonb_build_object('line_drawing', true);

  -- Upsert the link row. ON CONFLICT DO NOTHING because re-claiming MUST
  -- NOT overwrite the consumer's saved consent.
  INSERT INTO public.client_accounts
    (consumer_user_id, practice_client_id, consent, claimed_at, updated_at)
  VALUES
    (v_caller, v_practice_client_id, v_inherited_consent, now(), now())
  ON CONFLICT (consumer_user_id, practice_client_id) DO NOTHING;

  IF NOT FOUND THEN
    v_already := true;
  END IF;

  -- Audit. Practitioner audit feed (Wave 6) will surface this. actor_id
  -- is the consumer; ref_id is the plan; practice_id scopes the row to
  -- the relevant practice.
  INSERT INTO public.audit_events (practice_id, actor_id, kind, ref_id, meta)
  VALUES (
    v_practice_id,
    v_caller,
    CASE WHEN v_already THEN 'artifact.claim_reattempted' ELSE 'artifact.claimed' END,
    p_plan_id,
    jsonb_build_object(
      'plan_id',            p_plan_id,
      'practice_client_id', v_practice_client_id,
      'inherited_consent',  v_inherited_consent,
      'already_claimed',    v_already
    )
  );

  -- ---------- Wave 5 — verified-email supersession (ADR 0024) ----------
  -- Magic-link auth means a confirmed consumer email IS verified by
  -- Supabase. If the caller has email_confirmed_at, propagate the address
  -- to clients.email + stamp clients.email_verified_at. The typed-email
  -- path is dead from here.
  SELECT u.email, u.email_confirmed_at
    INTO v_consumer_email, v_consumer_confirmed
    FROM auth.users u
   WHERE u.id = v_caller;

  IF v_consumer_confirmed IS NOT NULL
     AND v_consumer_email IS NOT NULL
     AND length(trim(v_consumer_email)) > 0
  THEN
    -- Lowercase + trim for case-insensitive equality with what
    -- set_client_email writes.
    v_consumer_email := lower(trim(v_consumer_email));

    -- Only write when there's something to change. The two cases that
    -- count as "something to change":
    --   * email is different to what's stored (either NULL or a stale
    --     practitioner-typed value).
    --   * email matches but email_verified_at is NULL (the typed value
    --     was verified by-accident-equality with the claim email).
    IF v_existing_email IS DISTINCT FROM v_consumer_email
       OR v_existing_verified IS NULL
    THEN
      UPDATE public.clients
         SET email             = v_consumer_email,
             email_verified_at = now()
       WHERE id = v_practice_client_id;

      v_email_superseded := true;

      INSERT INTO public.audit_events
        (practice_id, actor_id, kind, ref_id, meta)
      VALUES (
        v_practice_id,
        v_caller,
        'client.email.verified',
        p_plan_id,
        jsonb_build_object(
          'practice_client_id', v_practice_client_id,
          'had_typed_email',    v_existing_email IS NOT NULL
                                AND (v_existing_verified IS NULL),
          'was_verified',       v_existing_verified IS NOT NULL,
          'changed',            v_existing_email IS DISTINCT FROM v_consumer_email
        )
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',                  true,
    'already_claimed',     v_already,
    'consumer_user_id',    v_caller,
    'practice_client_id',  v_practice_client_id,
    'inherited_consent',   v_inherited_consent,
    'email_superseded',    v_email_superseded
  );
END;
$function$;

COMMENT ON FUNCTION public.claim_plan(uuid) IS
  'Magic-link claim RPC (ADR 0024 + Waves 2 and 5). Upserts a client_accounts row '
  'linking auth.uid() to plans.client_id, inheriting consent on first claim. '
  'Wave 5 addition: when the consumer''s auth.users.email_confirmed_at is '
  'non-null, writes the verified email into clients.email + stamps '
  'clients.email_verified_at = now(), superseding any practitioner-typed value. '
  'Writes artifact.claimed + client.email.verified audit rows. Idempotent.';

REVOKE ALL ON FUNCTION public.claim_plan(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_plan(uuid) TO authenticated;

COMMIT;
