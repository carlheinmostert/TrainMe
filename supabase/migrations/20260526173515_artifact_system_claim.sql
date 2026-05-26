-- =============================================================================
-- Artifact-system claim flow + consumer identity (Wave 2)
-- =============================================================================
--
-- Builds on the Wave 1 foundation (migration
-- `20260526150953_artifact_system_foundation.sql`). Implements the claim flow
-- + spanning consumer identity ratified across the artifact-system design doc
-- (`docs/ARTIFACT_SYSTEM.md`) and locked in ADRs 0024 (anonymous link
-- survives; claim is opt-in) and 0026 (practice-grain consent, client-
-- controlled on claim).
--
-- This migration ships:
--
--   1. `client_accounts` — the spanning consumer identity. One row per
--      (consumer_user_id, practice_client_id) pair. A consumer linked to N
--      practices has N rows. Carries the consumer's per-relationship
--      `consent` jsonb (six toggles) which OVERRIDES the practitioner-proxy
--      `clients.video_consent` once any row exists for that practice_client.
--      Stays RPC-write-only (INSERT/UPDATE/DELETE revoked from anon +
--      authenticated; SELECT scoped by RLS to the row's owner or a
--      practitioner with practice membership).
--
--   2. `get_effective_consent(consumer_user_id, practice_client_id)` —
--      SECURITY DEFINER helper. Returns the `client_accounts.consent`
--      jsonb when the row exists; falls back to `clients.video_consent`
--      otherwise. The single read-path every consent-aware renderer should
--      use going forward.
--
--   3. `claim_plan(p_plan_id)` — SECURITY DEFINER, `authenticated`-only.
--      Reads `plans.client_id` (the practitioner-side client row), upserts
--      a `client_accounts` row with `consent` INHERITED from the
--      practitioner-proxy `clients.video_consent` (decision #17 — continuity
--      on claim; consumer adjusts from there). Writes an `artifact.claimed`
--      audit event. Idempotent — re-calling for the same plan returns
--      `{ok: true, already_claimed: true}`.
--
--   4. `list_my_practitioner_relationships()` — SECURITY DEFINER. Returns
--      one row per practice the calling consumer is linked to, with the
--      effective consent + plan count + practice metadata. Drives the
--      `/me/data` consent panel.
--
--   5. `set_my_consent(p_practice_client_id, p_consent)` — SECURITY
--      DEFINER. Updates a single `client_accounts.consent` row. Validates
--      the row belongs to the calling consumer; rejects attempts to flip
--      `line_drawing` off (always-on per ADR 0026, decision #27). Writes
--      a `consumer.consent.update` audit event with `{from, to}` diff.
--
--   6. `list_my_plans()` — SECURITY DEFINER. The consumer-side
--      "all my workouts" RPC. Joins through `client_accounts` to find every
--      practice_client_id the consumer is linked to, then every plan
--      belonging to those clients, then enumerates the published
--      `plan_artifacts` per plan so the consumer surface can render the
--      "Workout player / Workout handout" kind labels. Naming note —
--      `list_my_workouts()` already exists as a DIFFERENT, practitioner-
--      side RPC (joins via `clients.user_id` not `client_accounts`), so
--      we deliberately pick `list_my_plans()` to avoid collision.
--
-- Pre-flight against staging (2026-05-26) confirmed:
--   * `client_accounts` table does not exist.
--   * `plan_invitations` table does NOT exist on staging — Wave 1 did not
--     add it, and the design doc's `claimed_by_user_id` extension is
--     conditional ("if plan_invitations already tracks who-claimed"). The
--     Wave 2 brief explicitly says skip the column-extend if the table
--     isn't there. We do — `claim_plan` writes only to `client_accounts`
--     + `audit_events`. A future `plan_invitations` introduction can layer
--     `claimed_by_user_id` on top without churning Wave 2.
--   * `clients.video_consent` jsonb has 6 keys live (one row may carry a
--     subset, but the union across rows): `line_drawing`, `grayscale`,
--     `original`, `avatar`, `safe_mode_face_recognition`, `analytics_allowed`.
--     The artifact-system design doc names the biometric toggle
--     `face_recognition` in prose but the LIVE column key is
--     `safe_mode_face_recognition` (set by the Safe Mode v2 wave). We use
--     the live name everywhere so the override lookups stay consistent.
--   * `claim_plan`, `list_my_plans`, `list_my_practitioner_relationships`,
--     `set_my_consent`, `get_effective_consent` do not exist — clean
--     runway.
--   * `audit_events(id, ts, practice_id, actor_id, kind, ref_id, meta)`
--     is the canonical audit table; new `artifact.claimed` +
--     `consumer.consent.update` kinds are unconstrained text so no CHECK
--     to extend.
--   * `list_my_workouts()` already exists — that's the practitioner self-
--     trainer RPC (`clients.user_id = auth.uid()`). Different table-join
--     shape; we name our consumer-side RPC `list_my_plans()` to avoid
--     collision.
--
-- Reference rules followed:
--   * `feedback_no_direct_db_access.md` — all consumer surfaces will route
--     through these SECURITY DEFINER RPCs; no direct anon/auth table reads
--     on `client_accounts`.
--   * `feedback_schema_migration_column_preservation.md` — we do NOT
--     CREATE OR REPLACE any existing RPC in this migration. New RPCs only.
--   * `feedback_supabase_branching_one_source.md` — this migration file
--     is the only apply path. NO `supabase db push`, no MCP
--     apply_migration, no dashboard SQL editor.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. client_accounts — the spanning consumer-identity link table
-- -----------------------------------------------------------------------------
-- Composite PK (consumer_user_id, practice_client_id). A consumer linked to
-- N practices has N rows. The `consent` jsonb shape mirrors
-- `clients.video_consent` exactly so the override lookup is a drop-in: same
-- key shape, same six toggles, same null-means-default semantics.
--
-- Default `consent` is the empty object — the upsert in `claim_plan` will
-- inherit from `clients.video_consent` at claim time (decision #17 —
-- continuity on claim). Subsequent `set_my_consent` calls can write a
-- subset; missing keys fall through to the practitioner-proxy default via
-- the merge logic in `get_effective_consent`.

CREATE TABLE IF NOT EXISTS public.client_accounts (
  consumer_user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  practice_client_id  uuid        NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  consent             jsonb       NOT NULL DEFAULT '{}'::jsonb,
  claimed_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (consumer_user_id, practice_client_id)
);

COMMENT ON TABLE public.client_accounts IS
  'Spanning consumer-identity link table (ADR 0024). One row per (consumer auth.users.id, practice client row) pair. The consent jsonb mirrors clients.video_consent shape (six keys: line_drawing, grayscale, original, avatar, safe_mode_face_recognition, analytics_allowed) and OVERRIDES the practitioner-proxy default once any row exists for the practice_client. Read through get_effective_consent(consumer_user_id, practice_client_id); write through claim_plan / set_my_consent only.';

COMMENT ON COLUMN public.client_accounts.consent IS
  'Per-relationship consent override. Shape matches clients.video_consent. Keys present here win over the practitioner-proxy row; keys absent fall through to clients.video_consent via get_effective_consent. line_drawing is always true (de-identified by pipeline; set_my_consent rejects attempts to flip it off).';

-- Reverse-lookup index for the practitioner-transparency join.
-- Practitioners SELECT client_accounts via the matching practice_members,
-- so the common access path is "given a practice_client_id, list any
-- linked consumer accounts." Default PK index covers the consumer-side
-- lookup; add a secondary on the practice_client side.
CREATE INDEX IF NOT EXISTS client_accounts_by_practice_client_idx
  ON public.client_accounts (practice_client_id);

-- -----------------------------------------------------------------------------
-- 2. RLS — consumer owns their rows; practitioners SELECT-only via practice
-- -----------------------------------------------------------------------------
-- Two policies on SELECT:
--   (a) consumer reads their own rows (`consumer_user_id = auth.uid()`).
--   (b) practitioner reads rows whose practice_client_id joins through to
--       a practice the caller is a member of — TRANSPARENCY per ADR 0026
--       decision #16. Practitioner sees what's off; they cannot override.
--
-- INSERT/UPDATE/DELETE are NOT exposed via RLS — every write is funneled
-- through SECURITY DEFINER RPCs that own the policy. This mirrors the
-- credit_ledger / clients lockdown pattern.

ALTER TABLE public.client_accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS client_accounts_select_own        ON public.client_accounts;
DROP POLICY IF EXISTS client_accounts_select_by_pract   ON public.client_accounts;

CREATE POLICY client_accounts_select_own ON public.client_accounts
  FOR SELECT TO authenticated
  USING (consumer_user_id = auth.uid());

CREATE POLICY client_accounts_select_by_pract ON public.client_accounts
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
        FROM public.clients c
        JOIN public.practice_members pm
          ON pm.practice_id = c.practice_id
       WHERE c.id = client_accounts.practice_client_id
         AND pm.trainer_id = auth.uid()
    )
  );

-- No INSERT/UPDATE/DELETE policies → no client write path. The
-- SECURITY DEFINER RPCs below own all writes.
REVOKE INSERT, UPDATE, DELETE ON public.client_accounts FROM authenticated, anon;
REVOKE SELECT ON public.client_accounts FROM anon;
GRANT SELECT ON public.client_accounts TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. get_effective_consent(consumer_user_id, practice_client_id) → jsonb
-- -----------------------------------------------------------------------------
-- The single read-path every consent-aware renderer uses going forward.
-- Returns the consumer's per-relationship `client_accounts.consent` if a
-- row exists, else falls back to the practitioner-proxy
-- `clients.video_consent`. Keys present on the override win; keys absent
-- on the override fall through to the practitioner row, then to a
-- hardcoded default for the six known keys.
--
-- The default object documents the consent matrix shape so callers see
-- what every key means without spelunking the schema.

CREATE OR REPLACE FUNCTION public.get_effective_consent(
  p_consumer_user_id   uuid,
  p_practice_client_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_default       jsonb := jsonb_build_object(
                              'line_drawing',                true,
                              'grayscale',                   false,
                              'original',                    false,
                              'avatar',                      false,
                              'safe_mode_face_recognition',  false,
                              'analytics_allowed',           false
                            );
  v_practitioner  jsonb;
  v_consumer      jsonb;
BEGIN
  IF p_practice_client_id IS NULL THEN
    RETURN v_default;
  END IF;

  SELECT video_consent INTO v_practitioner
    FROM public.clients
   WHERE id = p_practice_client_id;

  IF v_practitioner IS NULL THEN
    v_practitioner := '{}'::jsonb;
  END IF;

  IF p_consumer_user_id IS NOT NULL THEN
    SELECT consent INTO v_consumer
      FROM public.client_accounts
     WHERE consumer_user_id    = p_consumer_user_id
       AND practice_client_id  = p_practice_client_id;
  END IF;

  IF v_consumer IS NULL THEN
    v_consumer := '{}'::jsonb;
  END IF;

  -- Layer: default <- practitioner-proxy <- consumer override.
  -- Consumer keys win where present (ADR 0026 — client-controlled
  -- post-claim with full autonomy).
  -- line_drawing is always true regardless of any override (locked
  -- decision #27 — "Line drawing is always on; consent can't be withdrawn
  -- because there's nothing identifying to withdraw").
  RETURN (v_default || v_practitioner || v_consumer)
         || jsonb_build_object('line_drawing', true);
END;
$function$;

COMMENT ON FUNCTION public.get_effective_consent(uuid, uuid) IS
  'Effective consent for a (consumer, practice_client) pair. Returns the consumer-controlled client_accounts.consent merged over the practitioner-proxy clients.video_consent, with line_drawing pinned true. Callable by authenticated only; the helper is internal — surfaces should route through list_my_practitioner_relationships or list_my_plans which call this.';

REVOKE ALL ON FUNCTION public.get_effective_consent(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_effective_consent(uuid, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. claim_plan(p_plan_id) → jsonb — the claim RPC
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER. `authenticated`-only. Magic-link-only auth means by
-- the time we get here the auth.uid() is a verified consumer.
--
-- Behaviour:
--   * Returns `{ok: false, reason: 'unauthenticated'}` if auth.uid() is null
--     (defensive — the RPC ACL already rejects anon, but a 401-style payload
--     is nicer for the caller than a raw PG error).
--   * Reads `plans.client_id`. If null, returns `{ok: false, reason:
--     'no_client_link'}` — a legacy / self-trainer plan with no consumer
--     side to claim against.
--   * Upserts the (consumer_user_id, practice_client_id) row. `consent`
--     INHERITS from clients.video_consent on FIRST claim (so the consumer
--     sees continuity — "here's what's currently shared"). Subsequent calls
--     for the same plan return `already_claimed: true` and DO NOT overwrite
--     the consumer's saved consent (decision #17 — claim is one-time
--     inherit; consumer adjustments are persistent).
--   * Writes an `artifact.claimed` audit event with meta carrying the
--     plan_id + practice_client_id. The actor_id is the consumer's
--     auth.uid() — practitioner-side audit views need to handle a non-
--     practitioner actor on this kind (Wave 6 territory; Wave 2 just lands
--     the row).
--   * Idempotent.

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
  SELECT video_consent INTO v_inherited_consent
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

  RETURN jsonb_build_object(
    'ok',                  true,
    'already_claimed',     v_already,
    'consumer_user_id',    v_caller,
    'practice_client_id',  v_practice_client_id,
    'inherited_consent',   v_inherited_consent
  );
END;
$function$;

COMMENT ON FUNCTION public.claim_plan(uuid) IS
  'Magic-link claim RPC (ADR 0024 + Wave 2). Upserts a client_accounts row linking auth.uid() to plans.client_id, inheriting consent from clients.video_consent on first claim (decision #17). Idempotent — re-calling sets already_claimed=true and never overwrites consumer adjustments. Writes an artifact.claimed audit row.';

REVOKE ALL ON FUNCTION public.claim_plan(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_plan(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. list_my_practitioner_relationships() → jsonb — /me/data panel feed
-- -----------------------------------------------------------------------------
-- Returns an array of one row per practice the calling consumer is linked
-- to. Each row carries:
--   { practice_id, practice_name, practice_brand_color, practice_logo_url,
--     practitioner_first_name, practitioner_last_name,
--     plan_count, effective_consent, claimed_at }
--
-- "practitioner_*" picks the practice's most-engaged practitioner with
-- this consumer (the trainer_id of the most recent plan_issuances row for
-- any plan owned by the consumer's practice_client). Consumer surfaces
-- display the practitioner avatar / name on each card (mockup parity).
--
-- effective_consent is the merged six-toggle jsonb produced by
-- get_effective_consent — what the /me/data panel actually renders.

CREATE OR REPLACE FUNCTION public.list_my_practitioner_relationships()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_my_practitioner_relationships requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  WITH my_links AS (
    SELECT ca.practice_client_id,
           ca.claimed_at,
           ca.consent          AS consumer_consent,
           c.practice_id,
           c.video_consent     AS practitioner_consent,
           c.deleted_at
      FROM public.client_accounts ca
      JOIN public.clients c
        ON c.id = ca.practice_client_id
     WHERE ca.consumer_user_id = v_caller
       AND c.deleted_at IS NULL
  ),
  plans_per_link AS (
    -- Count visible plans for this consumer × practice_client. A "visible"
    -- plan is one that is not soft-deleted; whether it's published is
    -- handled per-plan downstream.
    SELECT ml.practice_client_id, COUNT(*)::integer AS plan_count
      FROM my_links ml
      JOIN public.plans p
        ON p.client_id = ml.practice_client_id
       AND p.deleted_at IS NULL
     GROUP BY ml.practice_client_id
  ),
  latest_practitioner AS (
    -- Most recent trainer to publish for this consumer's practice_client.
    -- That's the practitioner the consumer sees on the card (mockup
    -- shows e.g. "Margaret Vorster · Cape Biokinetics").
    SELECT DISTINCT ON (p.client_id)
           p.client_id    AS practice_client_id,
           pi.trainer_id  AS practitioner_user_id
      FROM public.plans p
      JOIN public.plan_issuances pi
        ON pi.plan_id = p.id
     WHERE p.client_id IN (SELECT practice_client_id FROM my_links)
     ORDER BY p.client_id, pi.issued_at DESC
  )
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'practice_client_id',  ml.practice_client_id,
               'practice_id',         pr.id,
               'practice_name',       pr.name,
               'practice_brand_color', pr.brand_color,
               'practice_logo_url',   pr.public_logo_url,
               'practitioner_user_id', lp.practitioner_user_id,
               'practitioner_email',  u.email::text,
               'plan_count',          COALESCE(ppl.plan_count, 0),
               'effective_consent',   public.get_effective_consent(v_caller, ml.practice_client_id),
               'claimed_at',          ml.claimed_at
             )
             ORDER BY ml.claimed_at DESC
           ),
           '[]'::jsonb
         )
    INTO v_result
    FROM my_links ml
    LEFT JOIN public.practices         pr  ON pr.id = ml.practice_id
    LEFT JOIN plans_per_link           ppl ON ppl.practice_client_id = ml.practice_client_id
    LEFT JOIN latest_practitioner      lp  ON lp.practice_client_id = ml.practice_client_id
    LEFT JOIN auth.users               u   ON u.id = lp.practitioner_user_id;

  RETURN jsonb_build_object(
    'ok',             true,
    'consumer_user_id', v_caller,
    'relationships',  COALESCE(v_result, '[]'::jsonb)
  );
END;
$function$;

COMMENT ON FUNCTION public.list_my_practitioner_relationships() IS
  'Consumer-side /me/data feed (Wave 2). Returns one row per linked practice with effective consent, plan count, and most-recent practitioner metadata. Authenticated only.';

REVOKE ALL ON FUNCTION public.list_my_practitioner_relationships() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_practitioner_relationships() TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. set_my_consent(p_practice_client_id, p_consent) → jsonb — /me/data write
-- -----------------------------------------------------------------------------
-- Updates the calling consumer's consent override for one practice_client.
-- Validates:
--   * caller is authenticated
--   * the (caller, practice_client_id) row exists in client_accounts
--   * the proposed jsonb only contains known keys
--   * line_drawing CANNOT be set to false (always-on, decision #27)
--
-- Writes a `consumer.consent.update` audit row with a {from, to} diff.
-- The diff lets the practitioner-side audit feed (Wave 6) show
-- "consumer turned analytics OFF" without needing to query the history.

CREATE OR REPLACE FUNCTION public.set_my_consent(
  p_practice_client_id uuid,
  p_consent            jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_before       jsonb;
  v_after        jsonb;
  v_practice_id  uuid;
  v_known_keys   text[] := ARRAY[
    'line_drawing', 'grayscale', 'original', 'avatar',
    'safe_mode_face_recognition', 'analytics_allowed'
  ];
  v_key          text;
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unauthenticated');
  END IF;

  IF p_practice_client_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_practice_client_id');
  END IF;

  IF p_consent IS NULL OR jsonb_typeof(p_consent) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_consent_shape');
  END IF;

  -- Reject unknown keys to keep the override jsonb tight.
  FOR v_key IN SELECT jsonb_object_keys(p_consent) LOOP
    IF NOT (v_key = ANY(v_known_keys)) THEN
      RETURN jsonb_build_object(
        'ok',     false,
        'reason', 'unknown_consent_key',
        'key',    v_key
      );
    END IF;
  END LOOP;

  -- Reject line_drawing=false attempts (decision #27).
  IF (p_consent ? 'line_drawing')
     AND COALESCE((p_consent ->> 'line_drawing')::boolean, true) = false THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'line_drawing_locked_on');
  END IF;

  -- Verify the consumer owns the link row. Pull current consent for the
  -- diff. SECURITY DEFINER bypasses RLS, so this is the gate.
  SELECT consent INTO v_before
    FROM public.client_accounts
   WHERE consumer_user_id   = v_caller
     AND practice_client_id = p_practice_client_id;

  IF v_before IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_link');
  END IF;

  -- Merge the patch over the existing consent. Keys not in p_consent
  -- stay at their previous value. line_drawing is force-pinned true.
  v_after := (v_before || p_consent)
              || jsonb_build_object('line_drawing', true);

  UPDATE public.client_accounts
     SET consent    = v_after,
         updated_at = now()
   WHERE consumer_user_id   = v_caller
     AND practice_client_id = p_practice_client_id;

  -- Audit. Pull the practice_id from the linked client for scoping.
  SELECT practice_id INTO v_practice_id
    FROM public.clients
   WHERE id = p_practice_client_id;

  INSERT INTO public.audit_events (practice_id, actor_id, kind, ref_id, meta)
  VALUES (
    v_practice_id,
    v_caller,
    'consumer.consent.update',
    p_practice_client_id,
    jsonb_build_object(
      'practice_client_id', p_practice_client_id,
      'from',               v_before,
      'to',                 v_after,
      'patch',              p_consent
    )
  );

  RETURN jsonb_build_object(
    'ok',     true,
    'before', v_before,
    'after',  v_after
  );
END;
$function$;

COMMENT ON FUNCTION public.set_my_consent(uuid, jsonb) IS
  'Consumer-side per-relationship consent setter (Wave 2). Validates ownership + key whitelist; refuses to flip line_drawing off (ADR 0026 decision #27). Writes consumer.consent.update audit row with {from, to} diff. Authenticated only.';

REVOKE ALL ON FUNCTION public.set_my_consent(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_my_consent(uuid, jsonb) TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. list_my_plans() → jsonb — consumer-side My Workouts feed
-- -----------------------------------------------------------------------------
-- The consumer's "all my workouts" surface (`/me` signed-in state). Joins
-- through client_accounts → clients → plans, then enumerates the published
-- plan_artifacts so the consumer card surface can label each plan with its
-- kind ("Workout player" vs "Workout handout"). One row per (plan, artifact-
-- kind) pair, recency-sorted by `published_at` then `claimed_at`.
--
-- Naming: `list_my_workouts()` already exists as the practitioner self-
-- trainer RPC; deliberately picking `list_my_plans()` to avoid the
-- collision. The consumer surface UI says "My Workouts" — DB name differs
-- by design.

CREATE OR REPLACE FUNCTION public.list_my_plans()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_my_plans requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  WITH my_clients AS (
    SELECT ca.practice_client_id,
           ca.claimed_at
      FROM public.client_accounts ca
      JOIN public.clients c
        ON c.id = ca.practice_client_id
     WHERE ca.consumer_user_id = v_caller
       AND c.deleted_at IS NULL
  ),
  my_plans AS (
    SELECT p.id              AS plan_id,
           p.title           AS plan_title,
           p.client_id       AS practice_client_id,
           p.practice_id,
           p.version,
           p.first_opened_at,
           p.last_opened_at,
           mc.claimed_at
      FROM my_clients mc
      JOIN public.plans p
        ON p.client_id   = mc.practice_client_id
       AND p.deleted_at IS NULL
  ),
  artifact_rows AS (
    -- One row per (plan_id, kind) pair for PUBLISHED artifacts. NULL
    -- published_at means "offered but never minted" — those don't go in
    -- the consumer's list.
    SELECT mp.plan_id,
           mp.plan_title,
           mp.practice_client_id,
           mp.practice_id,
           mp.version,
           mp.first_opened_at,
           mp.last_opened_at,
           mp.claimed_at,
           a.kind,
           a.published_at,
           a.first_opened_at  AS artifact_first_opened_at
      FROM my_plans mp
      JOIN public.plan_artifacts a
        ON a.plan_id = mp.plan_id
     WHERE a.published_at IS NOT NULL
  ),
  exercise_counts AS (
    SELECT plan_id, COUNT(*)::integer AS exercise_count
      FROM public.exercises
     WHERE plan_id IN (SELECT plan_id FROM my_plans)
       AND media_type IS DISTINCT FROM 'rest'
     GROUP BY plan_id
  ),
  latest_practitioner AS (
    SELECT DISTINCT ON (pi.plan_id)
           pi.plan_id,
           pi.trainer_id,
           pi.issued_at AS last_published_at
      FROM public.plan_issuances pi
     WHERE pi.plan_id IN (SELECT plan_id FROM my_plans)
     ORDER BY pi.plan_id, pi.issued_at DESC
  )
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'plan_id',                ar.plan_id,
               'plan_title',             ar.plan_title,
               'kind',                   ar.kind,
               'version',                ar.version,
               'published_at',           ar.published_at,
               'artifact_first_opened_at', ar.artifact_first_opened_at,
               'first_opened_at',        ar.first_opened_at,
               'last_opened_at',         ar.last_opened_at,
               'claimed_at',             ar.claimed_at,
               'practice_id',            ar.practice_id,
               'practice_name',          pr.name,
               'practice_brand_color',   pr.brand_color,
               'practice_logo_url',      pr.public_logo_url,
               'practice_client_id',     ar.practice_client_id,
               'practitioner_user_id',   lp.trainer_id,
               'practitioner_email',     u.email::text,
               'exercise_count',         COALESCE(ec.exercise_count, 0),
               'last_published_at',      lp.last_published_at
             )
             ORDER BY ar.published_at DESC NULLS LAST, ar.claimed_at DESC, ar.plan_id, ar.kind
           ),
           '[]'::jsonb
         )
    INTO v_result
    FROM artifact_rows ar
    LEFT JOIN public.practices       pr ON pr.id = ar.practice_id
    LEFT JOIN exercise_counts        ec ON ec.plan_id = ar.plan_id
    LEFT JOIN latest_practitioner    lp ON lp.plan_id = ar.plan_id
    LEFT JOIN auth.users             u  ON u.id = lp.trainer_id;

  RETURN jsonb_build_object(
    'ok',              true,
    'consumer_user_id', v_caller,
    'plans',           COALESCE(v_result, '[]'::jsonb)
  );
END;
$function$;

COMMENT ON FUNCTION public.list_my_plans() IS
  'Consumer-side My Workouts feed (Wave 2). Returns one row per (plan, published-artifact-kind) for every plan owned by clients the consumer has claimed. Recency-sorted by artifact.published_at. Authenticated only. Distinct from list_my_workouts which is the practitioner self-trainer RPC.';

REVOKE ALL ON FUNCTION public.list_my_plans() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_plans() TO authenticated;

COMMIT;
