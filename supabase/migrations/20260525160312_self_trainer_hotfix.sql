-- =============================================================================
-- Self-trainer wave DB hotfix (2026-05-25)
--
-- Addresses 15 audit findings from the post-wave review:
--
--   CRITICAL:
--     CA-1 — widen credit_ledger_type_check to include 'publish_free'
--     CA-4 — close RLS bypass on clients.user_id + exercises.self_verified
--     CA-5 — close biometric SELECT leak on practitioners.face_embedding +
--            companions across practice members
--     CB-6 — lock down is_self_trainer_all_verified (revoke PUBLIC, drop
--            p_caller, derive from auth.uid())
--     CB-7 — consume_credit paid path recomputes server cost; mismatched
--            p_credits raises 22023
--     CB-9 — audit events on face-consent grant / revoke
--
--   MEDIUM:
--     R1-M1 / R3-M6 — FOR SHARE on exercises in consume_credit free path
--                     (closes TOCTOU on self_verified)
--     R1-M3 — Flutter consume_credit caller audit (clean; comment-only)
--     R1-M4 — get_plan_full strips plan_artifacts.metadata from anon
--            response (whitelist kind/status/generated_at only)
--     R3-M1 / M-2 — start_safe_mode_subscription owner-only
--     R3-M5 — tighten is_in_active_safe_mode_sub (scope to auth.uid(),
--            revoke anon)
--     R4-M1 / M-3 — Self-client analytics_allowed defaults to FALSE
--
--   LOW:
--     R3-L1 — refund_credit clears publish_free rows (delete + comment)
--     R3-L2 — comment prepaid-unlock no-audit-row decision
--     R4-L2 — server-stamp face_embedding_consented_at (param ignored,
--            kept for backward compat)
--
-- Idempotent. Safe to re-run.
-- =============================================================================


-- =============================================================================
-- CA-1: widen credit_ledger_type_check to include 'publish_free'
-- =============================================================================
-- The self-trainer free-publish branch in consume_credit (PR #6) writes
-- delta=0 type='publish_free' rows so the ledger has an audit trail of
-- every publish. The original CHECK constraint pre-dates that path and
-- silently rejects the new type. Without this fix, every self-trainer
-- free publish raises 23514 mid-transaction.
ALTER TABLE public.credit_ledger
  DROP CONSTRAINT IF EXISTS credit_ledger_type_check;

ALTER TABLE public.credit_ledger
  ADD CONSTRAINT credit_ledger_type_check
  CHECK (type = ANY (ARRAY[
    'purchase'::text,
    'consumption'::text,
    'refund'::text,
    'adjustment'::text,
    'signup_bonus'::text,
    'referral_signup_bonus'::text,
    'safe_mode_month'::text,
    'safe_mode_month_trial'::text,
    'publish_free'::text
  ]));


-- =============================================================================
-- CA-4: close RLS bypass on clients.user_id + exercises.self_verified
-- =============================================================================
-- Both columns are self-trainer load-bearing:
--   * clients.user_id binds a Self-client row to its owning auth user.
--     Only register_self_face / revoke_self_face (SECURITY DEFINER) should
--     set it. A practice member with normal RLS visibility on clients
--     could otherwise UPDATE this column directly and mint themselves a
--     free-publish channel for any plan they own.
--   * exercises.self_verified gates the all-verified free-publish path in
--     consume_credit. Only the capture pipeline via replace_plan_exercises
--     (SECURITY DEFINER) should set it. Direct UPDATEs let any practice
--     member flip self_verified=true on every row and skip credit
--     consumption.
--
-- REVOKE column-level UPDATE from authenticated + anon. SECURITY DEFINER
-- functions run as postgres, so they're unaffected by the REVOKE.
REVOKE UPDATE (user_id) ON public.clients FROM authenticated, anon;
REVOKE UPDATE (self_verified) ON public.exercises FROM authenticated, anon;


-- =============================================================================
-- CA-5: close biometric SELECT leak on practitioners.face_embedding
-- =============================================================================
-- The face_embedding column carries a 2048-byte vector that uniquely
-- identifies a practitioner's face. Practice members SHOULD NOT be able
-- to read each other's biometric vector via a direct SELECT, even
-- though they share a practice. The existing practitioners_select_self
-- RLS policy is the only intended read path, and the SECURITY DEFINER
-- get_my_self_face_embedding() RPC is what the Flutter app uses.
--
-- Column-level REVOKE blocks SELECT regardless of row-level RLS
-- visibility, providing belt-and-braces against any future RLS policy
-- accident. The SECURITY DEFINER RPC continues to work because it runs
-- as postgres.
REVOKE SELECT (face_embedding) ON public.practitioners FROM authenticated, anon;
REVOKE SELECT (face_embedding_consented_at) ON public.practitioners FROM authenticated, anon;
REVOKE SELECT (face_embedding_computed_at) ON public.practitioners FROM authenticated, anon;


-- =============================================================================
-- CB-6: lock down is_self_trainer_all_verified
-- =============================================================================
-- 1) Drop the p_caller parameter — the caller identity must be derived
--    server-side from auth.uid(), never accepted from the client. The old
--    signature let any authenticated caller probe whether ARBITRARY
--    (plan_id, user_id) pairs would self-trainer-free-publish.
-- 2) Revoke EXECUTE from PUBLIC + anon. SECURITY DEFINER callers
--    (consume_credit, preview_publish_cost) run as postgres so they
--    don't need an explicit GRANT.
DROP FUNCTION IF EXISTS public.is_self_trainer_all_verified(uuid, uuid);

CREATE OR REPLACE FUNCTION public.is_self_trainer_all_verified(p_plan_id uuid)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  v_caller         uuid := auth.uid();
  v_client_user_id uuid;
  v_total          integer;
  v_unverified     integer;
BEGIN
  IF p_plan_id IS NULL OR v_caller IS NULL THEN
    RETURN false;
  END IF;

  -- (1) + (2): plan -> client -> user_id must equal the caller.
  SELECT c.user_id
    INTO v_client_user_id
    FROM public.plans   p
    JOIN public.clients c ON c.id = p.client_id
   WHERE p.id = p_plan_id
   LIMIT 1;

  IF v_client_user_id IS NULL OR v_client_user_id <> v_caller THEN
    RETURN false;
  END IF;

  -- (3): the plan must have at least one non-rest cloud exercise.
  --     First publish has no cloud rows; we MUST charge the duration
  --     tier in that case, NOT zero.
  SELECT count(*)
    INTO v_total
    FROM public.exercises
   WHERE plan_id = p_plan_id
     AND media_type <> 'rest';

  IF v_total = 0 THEN
    RETURN false;
  END IF;

  -- (4): EVERY non-rest exercise must be self_verified = true (NULL or
  --     false fails the check — conservative per PR #5).
  SELECT count(*)
    INTO v_unverified
    FROM public.exercises
   WHERE plan_id = p_plan_id
     AND media_type <> 'rest'
     AND (self_verified IS NULL OR self_verified = false);

  RETURN v_unverified = 0;
END;
$function$;

-- CB-6 / preview_publish_cost grants — revoke PUBLIC, keep authenticated.
REVOKE EXECUTE ON FUNCTION public.is_self_trainer_all_verified(uuid)
  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.preview_publish_cost(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.preview_publish_cost(uuid)
  TO authenticated;


-- =============================================================================
-- CB-7 + R1-M1 / R3-M6 + R3-L1 + R3-L2: consume_credit hardening
--
-- Three concerns rolled into one CREATE OR REPLACE:
--   * Single-arg is_self_trainer_all_verified (CB-6).
--   * FOR SHARE on exercises rows before reading self_verified (R1-M1 /
--     R3-M6) — closes TOCTOU between the all-verified check and the
--     plan_artifacts write.
--   * Server-side recompute of paid-path cost; mismatch raises 22023
--     (CB-7).
--   * Inline comment on prepaid-unlock no-ledger-row design (R3-L2).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.consume_credit(
  p_practice_id uuid,
  p_plan_id     uuid,
  p_credits     integer
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  v_caller        uuid := auth.uid();
  v_is_member     boolean;
  v_balance       integer;
  v_new_balance   integer;
  v_prepaid_at    timestamptz;
  v_self_free     boolean := false;
  v_computed_cost integer;
  v_total_seconds integer := 0;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'consume_credit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'consume_credit: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'consume_credit: caller % is not a member of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- SEC-2 (C-2 / restore Milestone V): publish-time consent backstop.
  -- Fires FIRST per the documented ordering; do not reorder.
  IF p_plan_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.validate_plan_treatment_consent(p_plan_id)
  ) THEN
    RAISE EXCEPTION
      'consume_credit: plan % has exercises with unconsented treatments', p_plan_id
      USING ERRCODE = 'P0003';
  END IF;

  -- R1-M1 / R3-M6: take a FOR SHARE lock on the plan's exercise rows
  -- BEFORE reading self_verified. The SHARE lock blocks concurrent
  -- UPDATEs to the gating column without blocking other SELECTs, so
  -- two parallel publish attempts can't both observe a "fresh-set
  -- self_verified=true" snapshot that the column-REVOKE in CA-4 was
  -- meant to prevent. Belt-and-braces: CA-4 removes the attack
  -- surface (no client can UPDATE self_verified anymore) and FOR
  -- SHARE additionally protects against races inside the publish
  -- path itself (e.g. replace_plan_exercises racing with consume).
  IF p_plan_id IS NOT NULL THEN
    PERFORM 1
      FROM public.exercises
     WHERE plan_id = p_plan_id
     FOR SHARE;
  END IF;

  -- PR #6 (2026-05-25) — self-trainer all-verified short-circuit.
  -- Computed AFTER the consent backstop so any unconsented treatments
  -- still surface even on a free publish. Single-arg form (CB-6) — the
  -- function reads auth.uid() internally.
  IF p_plan_id IS NOT NULL THEN
    v_self_free := public.is_self_trainer_all_verified(p_plan_id);
  END IF;

  -- R1-M3 — Flutter callers (app/lib/services/upload_service.dart)
  -- always pass creditsToCharge in {0, 1, 2}: 0 only when the
  -- preview_publish_cost RPC returned 0 (self-trainer all-verified).
  -- The order below is load-bearing: the p_credits validation MUST
  -- only run on the paid path so a self-trainer caller passing 0 isn't
  -- rejected before the self_free branch can absorb the request.
  -- Prepaid-unlock callers always pass 1 or 2 (the mobile-computed
  -- duration cost), so validation runs and passes for them on the
  -- non-self-trainer flow.
  IF NOT v_self_free THEN
    IF p_credits IS NULL OR p_credits <= 0 THEN
      RAISE EXCEPTION 'consume_credit: p_credits must be positive (got %)', p_credits
        USING ERRCODE = '22023';
    END IF;

    IF p_credits NOT IN (1, 2) THEN
      RAISE EXCEPTION
        'consume_credit: p_credits must be 1 or 2 (got %) — duration tier mismatch', p_credits
        USING ERRCODE = '22023';
    END IF;
  END IF;

  PERFORM 1 FROM practices WHERE id = p_practice_id FOR UPDATE;

  SELECT unlock_credit_prepaid_at
    INTO v_prepaid_at
    FROM plans
   WHERE id = p_plan_id
     AND practice_id = p_practice_id
   FOR UPDATE;

  -- R3-L2: prepaid-unlock fast path deliberately writes NO ledger row.
  -- The unlock_plan_for_edit RPC already wrote the consumption row when
  -- the unlock was prepaid; charging again here would double-bill. The
  -- audit trail for the resulting publish lives in plan_artifacts +
  -- plan_issuances downstream.
  IF v_prepaid_at IS NOT NULL THEN
    UPDATE plans
       SET unlock_credit_prepaid_at = NULL,
           first_opened_at          = NULL,
           last_opened_at           = NULL
     WHERE id = p_plan_id;

    SELECT COALESCE(SUM(delta), 0)::integer
      INTO v_balance
      FROM credit_ledger
     WHERE practice_id = p_practice_id;

    -- PR #7 — plan_artifacts write on publish. Same transaction.
    IF p_plan_id IS NOT NULL THEN
      INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at)
      VALUES (p_plan_id, 'plan_url', 'ready', now())
      ON CONFLICT (plan_id, kind) DO UPDATE
        SET generated_at = now(),
            status       = 'ready';
    END IF;

    RETURN jsonb_build_object(
      'ok',                true,
      'new_balance',       v_balance,
      'prepaid_unlock_at', v_prepaid_at
    );
  END IF;

  -- PR #6 — self-trainer free publish path.
  -- Writes a delta=0, type='publish_free' audit row so the publish has
  -- the same auditable presence in the ledger as a paid publish, then
  -- mirrors the paid-path plan_artifacts upsert.
  IF v_self_free THEN
    SELECT COALESCE(SUM(delta), 0)::integer
      INTO v_balance
      FROM credit_ledger
     WHERE practice_id = p_practice_id;

    INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes, trainer_id)
    VALUES (
      p_practice_id,
      0,
      'publish_free',
      p_plan_id,
      'self-trainer publish — all exercises self-verified',
      v_caller
    );

    IF p_plan_id IS NOT NULL THEN
      INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at)
      VALUES (p_plan_id, 'plan_url', 'ready', now())
      ON CONFLICT (plan_id, kind) DO UPDATE
        SET generated_at = now(),
            status       = 'ready';
    END IF;

    RETURN jsonb_build_object(
      'ok',           true,
      'new_balance',  v_balance,
      'free',         true,
      'reason',       'self_trainer_all_verified'
    );
  END IF;

  -- =====================================================================
  -- CB-7: paid path — recompute cost server-side and reject mismatches.
  -- =====================================================================
  -- The Flutter client computes its own duration tier and passes it as
  -- p_credits. We MUST re-derive the cost from the cloud exercise_sets
  -- and refuse to consume if the client lied (or drifted, or was
  -- attacked). Mirrors the exact formula in preview_publish_cost.
  v_computed_cost := 1;

  IF p_plan_id IS NOT NULL THEN
    SELECT COALESCE(SUM(
              (s.reps * 3)
              + CASE s.hold_position
                  WHEN 'per_rep'         THEN s.reps * s.hold_seconds
                  WHEN 'end_of_set'      THEN s.hold_seconds
                  WHEN 'end_of_exercise' THEN
                    CASE WHEN s.position = (
                          SELECT MAX(s2.position) FROM public.exercise_sets s2
                           WHERE s2.exercise_id = s.exercise_id
                         )
                         THEN s.hold_seconds ELSE 0
                    END
                END
              + s.breather_seconds_after
           ), 0)::integer
      INTO v_total_seconds
      FROM public.exercise_sets s
      JOIN public.exercises   e ON e.id = s.exercise_id
     WHERE e.plan_id = p_plan_id
       AND e.media_type <> 'rest';

    -- 75 minutes = 4500 seconds (matches AppConfig.creditDurationThresholdSeconds).
    IF v_total_seconds > 4500 THEN
      v_computed_cost := 2;
    END IF;
  END IF;

  -- First-publish edge: if there are no cloud exercise rows yet
  -- (v_total_seconds = 0), trust the client value as long as it's in
  -- {1, 2}. The validation above already enforced that range.
  IF v_total_seconds > 0 AND p_credits <> v_computed_cost THEN
    RAISE EXCEPTION
      'consume_credit: p_credits=% does not match server-computed cost=% for plan %',
      p_credits, v_computed_cost, p_plan_id
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(SUM(delta), 0)::integer
    INTO v_balance
    FROM credit_ledger
   WHERE practice_id = p_practice_id;

  IF v_balance < p_credits THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'reason',  'insufficient_credits',
      'balance', v_balance
    );
  END IF;

  -- Wave 40.5: stamp trainer_id on the consumption ledger row.
  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes, trainer_id)
  VALUES (
    p_practice_id,
    -p_credits,
    'consumption',
    p_plan_id,
    'consume_credit(' || p_credits::text || ')',
    v_caller
  );

  v_new_balance := v_balance - p_credits;

  IF p_plan_id IS NOT NULL THEN
    INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at)
    VALUES (p_plan_id, 'plan_url', 'ready', now())
    ON CONFLICT (plan_id, kind) DO UPDATE
      SET generated_at = now(),
          status       = 'ready';
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance
  );
END;
$function$;


-- =============================================================================
-- CB-6 follow-through: preview_publish_cost now uses single-arg
-- is_self_trainer_all_verified.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.preview_publish_cost(p_session_id uuid)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  v_caller         uuid := auth.uid();
  v_practice_id    uuid;
  v_is_member      boolean;
  v_total_seconds  integer := 0;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'preview_publish_cost requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'preview_publish_cost: p_session_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id INTO v_practice_id
    FROM public.plans
   WHERE id = p_session_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    -- Fresh client-generated plan ID — not in the cloud yet. Default to
    -- duration tier 1; the client's own creditCostForDuration will
    -- override on the publish path.
    RETURN 1;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.practice_members
     WHERE practice_id = v_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'preview_publish_cost: caller % is not a member of practice %', v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Self-trainer all-verified short-circuit (single-arg per CB-6).
  IF public.is_self_trainer_all_verified(p_session_id) THEN
    RETURN 0;
  END IF;

  -- Duration-based estimate from exercise_sets.
  SELECT COALESCE(SUM(
            (s.reps * 3)
            + CASE s.hold_position
                WHEN 'per_rep'         THEN s.reps * s.hold_seconds
                WHEN 'end_of_set'      THEN s.hold_seconds
                WHEN 'end_of_exercise' THEN
                  CASE WHEN s.position = (
                        SELECT MAX(s2.position) FROM public.exercise_sets s2
                         WHERE s2.exercise_id = s.exercise_id
                       )
                       THEN s.hold_seconds ELSE 0
                  END
              END
            + s.breather_seconds_after
         ), 0)::integer
    INTO v_total_seconds
    FROM public.exercise_sets s
    JOIN public.exercises   e ON e.id = s.exercise_id
   WHERE e.plan_id = p_session_id
     AND e.media_type <> 'rest';

  -- 75 minutes = 4500 seconds (matches AppConfig.creditDurationThresholdSeconds).
  IF v_total_seconds > 4500 THEN
    RETURN 2;
  END IF;

  RETURN 1;
END;
$function$;


-- =============================================================================
-- CB-9 + R4-L2 + R4-M1: register_self_face — audit event, server-stamped
-- consent timestamp, analytics_allowed=false default on Self-client.
-- =============================================================================
-- * R4-L2: server-stamp p_consented_at via now(). The parameter is
--   kept in the signature for backward compat with the existing Dart
--   caller (app/lib/services/api_client.dart::registerSelfFace passes
--   consentedAt.toUtc().toIso8601String()) but its value is ignored
--   internally. A future cleanup will drop the parameter; until then
--   the Hotfix B brief will move the Dart side to not send it.
-- * R4-M1: when the function inserts a fresh Self-client row, the
--   video_consent jsonb explicitly sets analytics_allowed:false so the
--   COALESCE in get_plan_full reads false (not absent-defaulting-true).
-- * CB-9: append a 'practitioner.face_consent.granted' row to
--   audit_events at the end of the function. practice_id is the
--   resolved owner-practice; actor_id is the caller; meta carries the
--   consented_at + embedding_dim. The new event kind only requires
--   length > 0 (the existing audit_events_kind_nonempty CHECK).
CREATE OR REPLACE FUNCTION public.register_self_face(
  p_embedding      vector,
  p_consented_at   timestamp with time zone
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_self_client  uuid;
  v_consented_at timestamptz := now();
BEGIN
  -- Authentication gate.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'register_self_face requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Argument validation. p_consented_at is intentionally ignored — see
  -- R4-L2 above — but we still accept it for API stability. p_embedding
  -- remains required.
  IF p_embedding IS NULL THEN
    RAISE EXCEPTION 'register_self_face: p_embedding is required'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve the user's personal practice. Prefer the owned practice
  -- (the one bootstrap_practice_for_user creates at signup). Fall back
  -- to any practice the user belongs to if for some reason no owned
  -- practice exists (defensive — bootstrap always creates one).
  SELECT practice_id INTO v_practice_id
    FROM public.practice_members
   WHERE trainer_id = v_caller
     AND role = 'owner'
   ORDER BY joined_at ASC NULLS LAST
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    SELECT practice_id INTO v_practice_id
      FROM public.practice_members
     WHERE trainer_id = v_caller
     ORDER BY joined_at ASC NULLS LAST
     LIMIT 1;
  END IF;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'register_self_face: caller % has no practice membership; '
                    'call bootstrap_practice_for_user first',
                    v_caller
      USING ERRCODE = '42501';
  END IF;

  -- Upsert the practitioners row. The base row may or may not already
  -- exist (set_practitioner_profile creates it on first profile save;
  -- a user may opt into face-verification before saving a name).
  INSERT INTO public.practitioners (
    user_id,
    face_embedding,
    face_embedding_consented_at,
    face_embedding_computed_at,
    updated_at
  )
  VALUES (
    v_caller,
    p_embedding,
    v_consented_at,
    now(),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE
     SET face_embedding              = EXCLUDED.face_embedding,
         face_embedding_consented_at = EXCLUDED.face_embedding_consented_at,
         face_embedding_computed_at  = EXCLUDED.face_embedding_computed_at,
         updated_at                  = now();

  -- Resolve or create the Self-client row. The partial unique index
  -- `clients_one_self_per_user_per_practice` (PR #1) guarantees at
  -- most one non-deleted self-client per (practice, user) pair, so the
  -- SELECT-then-INSERT race is bounded — the index will reject any
  -- concurrent second insert with 23505 and the caller can retry.
  SELECT id INTO v_self_client
    FROM public.clients
   WHERE practice_id = v_practice_id
     AND user_id     = v_caller
     AND deleted_at IS NULL
   LIMIT 1;

  IF v_self_client IS NULL THEN
    -- R4-M1: explicitly default analytics_allowed=false on the
    -- Self-client video_consent. The COALESCE in get_plan_full
    -- (baseline.sql) reads false when the key is present-and-false,
    -- but defaults absent-keys to true; the Self-client is a
    -- practitioner-owned row that should NOT silently opt into
    -- plan-analytics collection on its own data.
    INSERT INTO public.clients (
      id,
      practice_id,
      name,
      user_id,
      created_by_user_id,
      video_consent
    )
    VALUES (
      gen_random_uuid(),
      v_practice_id,
      'Me',
      v_caller,
      v_caller,
      jsonb_build_object(
        'line_drawing',      true,
        'grayscale',         false,
        'original',          false,
        'avatar',            false,
        'analytics_allowed', false
      )
    )
    RETURNING id INTO v_self_client;
  END IF;

  -- CB-9: audit-event write for face-consent grant. The audit_events
  -- table is the existing per-practice audit feed (kind/meta/actor_id/
  -- practice_id/ref_id schema). Practitioner face consent is closest
  -- to a profile-level event, NOT a capture event, so it does not
  -- belong in capture_audit_events (which is per-capture and carries
  -- a SHA-256 file fingerprint).
  INSERT INTO public.audit_events (
    practice_id,
    actor_id,
    kind,
    ref_id,
    meta
  ) VALUES (
    v_practice_id,
    v_caller,
    'practitioner.face_consent.granted',
    v_self_client,
    jsonb_build_object(
      'consented_at',  v_consented_at,
      'embedding_dim', 512
    )
  );

  RETURN v_self_client;
END;
$function$;


-- =============================================================================
-- CB-9: revoke_self_face — append audit event on revocation.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.revoke_self_face()
  RETURNS TABLE(embedding_cleared boolean, self_client_deleted uuid)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_had_embed    boolean := false;
  v_self_client  uuid;
  v_practice_id  uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'revoke_self_face requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Resolve the user's owner-practice for the audit row. Mirrors the
  -- precedence in register_self_face (owner first, any-membership
  -- fallback).
  SELECT practice_id INTO v_practice_id
    FROM public.practice_members
   WHERE trainer_id = v_caller
     AND role = 'owner'
   ORDER BY joined_at ASC NULLS LAST
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    SELECT practice_id INTO v_practice_id
      FROM public.practice_members
     WHERE trainer_id = v_caller
     ORDER BY joined_at ASC NULLS LAST
     LIMIT 1;
  END IF;

  -- Clear the embedding + consent + computed timestamps on the
  -- practitioners row. We only flip `embedding_cleared` true if there
  -- was actually an embedding to clear — lets the caller distinguish
  -- "we revoked something" from "you weren't a self-trainer to begin
  -- with" for the SnackBar copy.
  UPDATE public.practitioners
     SET face_embedding              = NULL,
         face_embedding_consented_at = NULL,
         face_embedding_computed_at  = NULL,
         updated_at                  = now()
   WHERE user_id = v_caller
     AND face_embedding IS NOT NULL
  RETURNING true INTO v_had_embed;

  IF v_had_embed IS NULL THEN
    v_had_embed := false;
  END IF;

  -- Soft-delete the Self-client row, if present. The partial unique
  -- index filters on deleted_at IS NULL so this frees the slot for a
  -- future re-registration via register_self_face.
  UPDATE public.clients
     SET deleted_at         = now(),
         deleted_by_user_id = v_caller
   WHERE practice_id IN (
           SELECT practice_id
             FROM public.practice_members
            WHERE trainer_id = v_caller
         )
     AND user_id     = v_caller
     AND deleted_at IS NULL
  RETURNING id INTO v_self_client;

  -- CB-9: audit row for the revocation. Always emit, even if no
  -- embedding was cleared, so the audit feed shows the user's intent.
  -- Only skip if we couldn't resolve a practice (corner case — a user
  -- with zero memberships should not have reached this code path at
  -- all).
  IF v_practice_id IS NOT NULL THEN
    INSERT INTO public.audit_events (
      practice_id,
      actor_id,
      kind,
      ref_id,
      meta
    ) VALUES (
      v_practice_id,
      v_caller,
      'practitioner.face_consent.revoked',
      v_self_client,
      jsonb_build_object(
        'embedding_cleared',         v_had_embed,
        'self_client_soft_deleted',  v_self_client IS NOT NULL
      )
    );
  END IF;

  embedding_cleared   := v_had_embed;
  self_client_deleted := v_self_client;
  RETURN NEXT;
END;
$function$;


-- =============================================================================
-- R1-M4: get_plan_full whitelists artifact keys returned to anon.
-- =============================================================================
-- The plan_artifacts.metadata jsonb is internal scratch space for the
-- artifact generator (cost, attempt count, intermediate URLs, etc.). It
-- must not leak to anonymous web-player clients. Restrict the projection
-- to {kind, status, generated_at} until a future feature explicitly
-- opts a metadata key into the public surface.
--
-- output_url stays excluded for the same reason — it can leak signed
-- storage URLs that bypass the consent gate. If a player feature ever
-- needs an artifact URL, it should arrive via a dedicated signed-URL
-- RPC, not via a free-form metadata leak.
CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  plan_row          plans;
  v_consent         jsonb;
  v_gray_ok         boolean;
  v_orig_ok         boolean;
  v_base_url        text;
  exes              jsonb;
  v_brand_color     text;
  v_public_logo_url text;
  v_practice_name   text;
  v_artifacts       jsonb;
BEGIN
  UPDATE plans
     SET first_opened_at = now()
   WHERE id = p_plan_id
     AND first_opened_at IS NULL
  RETURNING * INTO plan_row;

  IF plan_row IS NULL THEN
    SELECT * INTO plan_row FROM plans WHERE id = p_plan_id LIMIT 1;
  END IF;

  IF plan_row IS NULL THEN
    RETURN NULL;
  END IF;

  IF plan_row.client_id IS NOT NULL THEN
    SELECT video_consent INTO v_consent
      FROM clients WHERE id = plan_row.client_id LIMIT 1;
  END IF;

  IF v_consent IS NULL THEN
    v_consent := '{"line_drawing": true, "grayscale": false, "original": false}'::jsonb;
  END IF;

  v_gray_ok := COALESCE((v_consent ->> 'grayscale')::boolean, false);
  v_orig_ok := COALESCE((v_consent ->> 'original')::boolean, false);

  SELECT decrypted_secret INTO v_base_url
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_url'
   LIMIT 1;

  IF plan_row.practice_id IS NOT NULL THEN
    SELECT pr.brand_color, pr.public_logo_url, pr.name
      INTO v_brand_color, v_public_logo_url, v_practice_name
      FROM practices pr
     WHERE pr.id = plan_row.practice_id
     LIMIT 1;
  END IF;

  SELECT COALESCE(
           jsonb_agg(
             to_jsonb(e)
               || jsonb_build_object(
                    'line_drawing_url', e.media_url,
                    'grayscale_url',
                      CASE
                        WHEN v_gray_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mp4',
                               1800)
                        WHEN v_gray_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'original_url',
                      CASE
                        WHEN v_orig_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mp4',
                               1800)
                        WHEN v_orig_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'grayscale_segmented_url',
                      CASE
                        WHEN v_gray_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.mp4',
                               1800)
                        WHEN v_gray_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'original_segmented_url',
                      CASE
                        WHEN v_orig_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.mp4',
                               1800)
                        WHEN v_orig_ok AND e.media_type = 'photo' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.segmented.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'mask_url',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok) AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mask.mp4',
                               1800)
                        ELSE NULL
                      END,
                    'sets',
                      COALESCE(
                        (
                          SELECT jsonb_agg(
                                   jsonb_build_object(
                                     'position',                 s.position,
                                     'reps',                     s.reps,
                                     'hold_seconds',             s.hold_seconds,
                                     'hold_position',            s.hold_position,
                                     'weight_kg',                s.weight_kg,
                                     'breather_seconds_after',   s.breather_seconds_after
                                   )
                                   ORDER BY s.position
                                 )
                            FROM public.exercise_sets s
                           WHERE s.exercise_id = e.id
                        ),
                        '[]'::jsonb
                      ),
                    'rest_seconds', e.rest_seconds,
                    'thumbnail_url_line',
                      CASE
                        WHEN e.media_type IN ('video', 'photo')
                          AND v_base_url IS NOT NULL
                          AND length(v_base_url) > 0
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'media'
                               AND o.name = plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_line.jpg'
                          )
                        THEN rtrim(v_base_url, '/') ||
                             '/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_line.jpg'
                        ELSE NULL
                      END,
                    'thumbnail_url_color',
                      CASE
                        WHEN (v_gray_ok OR v_orig_ok)
                          AND e.media_type IN ('video', 'photo')
                          AND plan_row.practice_id IS NOT NULL
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'raw-archive'
                               AND o.name = plan_row.practice_id::text || '/' ||
                                            plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_color.jpg'
                          )
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '_thumb_color.jpg',
                               1800)
                        ELSE NULL
                      END,
                    'thumbnail_url_bw',
                      CASE
                        WHEN e.media_type = 'photo'
                          AND v_base_url IS NOT NULL
                          AND length(v_base_url) > 0
                          AND EXISTS (
                            SELECT 1 FROM storage.objects o
                             WHERE o.bucket_id = 'media'
                               AND o.name = plan_row.id::text || '/' ||
                                            e.id::text || '_thumb_bw.jpg'
                          )
                        THEN rtrim(v_base_url, '/') ||
                             '/storage/v1/object/public/media/' ||
                             plan_row.id::text || '/' || e.id::text || '_thumb_bw.jpg'
                        ELSE NULL
                      END
                  )
               ORDER BY e.position
           ),
           '[]'::jsonb
         )
    INTO exes
    FROM exercises e
   WHERE e.plan_id = p_plan_id;

  -- R1-M4: whitelist artifact projection to {kind, status, generated_at}.
  -- metadata + output_url deliberately dropped — both can leak internal
  -- generator state or signed storage URLs that bypass consent gates.
  -- Future features that need a specific artifact metadata key should
  -- opt that key into the public surface explicitly.
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'kind',         a.kind,
               'status',       a.status,
               'generated_at', a.generated_at
             )
             ORDER BY a.generated_at DESC
           ),
           '[]'::jsonb
         )
    INTO v_artifacts
    FROM public.plan_artifacts a
   WHERE a.plan_id = p_plan_id;

  RETURN jsonb_build_object(
    'plan',
      to_jsonb(plan_row)
        || jsonb_build_object(
             'brand_color',     v_brand_color,
             'public_logo_url', v_public_logo_url,
             'practice_name',   v_practice_name
           ),
    'exercises', exes,
    'artifacts', v_artifacts
  );
END;
$function$;


-- =============================================================================
-- R3-M1 / M-2: start_safe_mode_subscription is owner-only.
-- =============================================================================
-- Mirrors the rename_practice (Milestone N) pattern: practice members
-- can SEE the subscription state, but only owners can spend the
-- practice's credits on a Safe Mode month. user_is_practice_owner is
-- the SECURITY DEFINER helper that handles RLS-safe membership lookup.
CREATE OR REPLACE FUNCTION public.start_safe_mode_subscription(p_practice_id uuid)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_balance      integer;
  v_new_balance  integer;
  v_ledger_id    uuid;
  v_credits      integer := 4;   -- 4 credits / month, locked by ADR-0021
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'start_safe_mode_subscription requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'start_safe_mode_subscription: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'start_safe_mode_subscription: caller % is not a member of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- R3-M1 / M-2: owner-only enforcement. Mirrors rename_practice.
  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'start_safe_mode_subscription: caller % is not an owner of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Serialise concurrent debits against the same practice.
  PERFORM 1 FROM practices WHERE id = p_practice_id FOR UPDATE;

  SELECT COALESCE(SUM(delta), 0)::integer
    INTO v_balance
    FROM credit_ledger
   WHERE practice_id = p_practice_id;

  IF v_balance < v_credits THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'reason',  'insufficient_credits',
      'balance', v_balance
    );
  END IF;

  INSERT INTO credit_ledger (
    practice_id, delta, type, notes, trainer_id
  ) VALUES (
    p_practice_id,
    -v_credits,
    'safe_mode_month',
    'start_safe_mode_subscription(): 4 credits / 30 days',
    v_caller
  )
  RETURNING id INTO v_ledger_id;

  v_new_balance := v_balance - v_credits;

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance,
    'ledger_id',   v_ledger_id
  );
END;
$function$;


-- =============================================================================
-- R3-M5: tighten is_in_active_safe_mode_sub
-- =============================================================================
-- The function currently accepts an arbitrary user_id parameter and
-- returns subscription state for any user — a probe channel for any
-- authenticated caller. Tighten by:
--   * Scoping to auth.uid() only — refuse any cross-user query.
--   * Revoke EXECUTE from anon; grant authenticated.
--
-- The helper `user_is_practice_owner_of_user` referenced in the brief
-- does not exist in this schema, so we scope strictly to self. The
-- portal's "is this user's safe mode active" lookups already go
-- through the caller's own session, so this is non-breaking for the
-- production callers.
CREATE OR REPLACE FUNCTION public.is_in_active_safe_mode_sub(p_user_id uuid)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'is_in_active_safe_mode_sub requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- R3-M5: only allow self-queries. Cross-user probing is rejected.
  IF p_user_id IS DISTINCT FROM v_caller THEN
    RAISE EXCEPTION 'is_in_active_safe_mode_sub: caller may only query its own subscription state'
      USING ERRCODE = '42501';
  END IF;

  RETURN
    EXISTS (
      SELECT 1
      FROM practice_members
      WHERE trainer_id = p_user_id
        AND safe_mode_grandfathered = true
    )
    OR EXISTS (
      SELECT 1
      FROM credit_ledger
      WHERE trainer_id = p_user_id
        AND type = 'safe_mode_month'
        AND created_at > now() - INTERVAL '30 days'
    )
    OR EXISTS (
      SELECT 1
      FROM credit_ledger
      WHERE trainer_id = p_user_id
        AND type = 'safe_mode_month_trial'
        AND created_at > now() - INTERVAL '3 days'
    );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.is_in_active_safe_mode_sub(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_in_active_safe_mode_sub(uuid)
  TO authenticated;


-- =============================================================================
-- R3-L1: refund_credit handles publish_free rows.
-- =============================================================================
-- Pre-existing refund_credit only matches type='consumption'. For
-- self-trainer free-publish rows (type='publish_free', delta=0) a
-- post-consume failure must also clear the audit row so the next
-- publish-from-clean-state can succeed. Since delta=0, the "refund"
-- semantics are a hard delete of the publish_free row rather than an
-- offsetting +N entry — there's nothing to refund balance-wise.
--
-- Order matters: try the publish_free clear FIRST (zero-delta, cheap
-- DELETE), then fall through to the legacy consumption-refund path.
-- This keeps the function idempotent (re-calling on an already-cleaned
-- plan returns false from the consumption branch).
CREATE OR REPLACE FUNCTION public.refund_credit(p_plan_id uuid)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = 'public'
AS $function$
DECLARE
  v_caller            uuid := auth.uid();
  v_consumption       credit_ledger%ROWTYPE;
  v_publish_free      credit_ledger%ROWTYPE;
  v_already_refunded  boolean;
  v_is_member         boolean;
  v_cleared_free      boolean := false;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'refund_credit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'refund_credit: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- R3-L1: clear any publish_free audit rows first. These have
  -- delta=0 so there's no balance impact; the DELETE just removes the
  -- "this plan was published" audit hint so a retry isn't blocked by a
  -- stale entry. Safe even on plans that never had a publish_free row
  -- (no rows matched → no-op).
  SELECT * INTO v_publish_free
    FROM credit_ledger
   WHERE plan_id = p_plan_id
     AND type    = 'publish_free'
   ORDER BY created_at DESC
   LIMIT 1;

  IF FOUND THEN
    SELECT EXISTS (
      SELECT 1 FROM practice_members
       WHERE practice_id = v_publish_free.practice_id
         AND trainer_id  = v_caller
    ) INTO v_is_member;

    IF NOT v_is_member THEN
      RAISE EXCEPTION 'refund_credit: caller % is not a member of practice %',
        v_caller, v_publish_free.practice_id
        USING ERRCODE = '42501';
    END IF;

    DELETE FROM credit_ledger
     WHERE plan_id = p_plan_id
       AND type    = 'publish_free';

    v_cleared_free := true;
  END IF;

  -- Original consumption-refund path.
  SELECT * INTO v_consumption
    FROM credit_ledger
   WHERE plan_id = p_plan_id
     AND type    = 'consumption'
   ORDER BY created_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    -- No paid consumption to refund — return true iff we at least
    -- cleared a publish_free row so the caller knows something
    -- happened.
    RETURN v_cleared_free;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_consumption.practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'refund_credit: caller % is not a member of practice %',
      v_caller, v_consumption.practice_id
      USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM credit_ledger
     WHERE plan_id = p_plan_id
       AND type    = 'refund'
  ) INTO v_already_refunded;

  IF v_already_refunded THEN
    RETURN v_cleared_free;
  END IF;

  -- Wave 40.5: stamp trainer_id
  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes, trainer_id)
  VALUES (
    v_consumption.practice_id,
    ABS(v_consumption.delta),
    'refund',
    p_plan_id,
    'refund_credit(' || p_plan_id::text || ')',
    v_caller
  );

  RETURN true;
END;
$function$;


-- =============================================================================
-- End of hotfix migration.
-- =============================================================================
