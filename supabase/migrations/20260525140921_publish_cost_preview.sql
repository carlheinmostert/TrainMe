-- ============================================================================
-- Self-trainer wave PR #6 (2026-05-25): publish cost preview + consume_credit
-- conditional free path for self-verified self-trainer publishes.
-- ============================================================================
--
-- Per docs/SELF_TRAINER_WAVE.md § "Publish flow changes": when the linked
-- client is the practitioner themselves (clients.user_id = auth.uid()) AND
-- every cloud exercises row for the plan has self_verified = true, the
-- publish is FREE (delta = 0) — the practitioner doesn't burn a credit on
-- their own self-recorded plan. Everything else stays on the existing
-- duration-based pricing (≤ 75 min = 1 credit, > 75 min = 2 credits).
--
-- This migration:
--
--   1. Adds public.preview_publish_cost(p_session_id uuid) → integer
--      Side-effect-free RPC the mobile Studio workflow pill calls to
--      surface the right "Publish · Free / 1 credit / 2 credits" label
--      without burning a credit. SECURITY DEFINER + practice-membership
--      check (mirrors consume_credit's pattern).
--
--   2. Extends public.consume_credit with the same conditional free-path
--      logic. CREATE OR REPLACE preserves EVERY existing column /
--      behaviour per feedback_schema_migration_column_preservation:
--        - SEC-2 validate_plan_treatment_consent backstop fires FIRST.
--        - prepaid-unlock fast path (Wave 29) is preserved verbatim.
--        - Wave 40.5 trainer_id stamp on the consumption ledger row.
--        - PR #7 plan_artifacts (plan_url) write on both write paths.
--      Adds:
--        - Self-verified check (clients.user_id = auth.uid() AND every
--          cloud exercises row for this plan has self_verified = true).
--          When true: write a `delta=0, type='publish_free'` audit row
--          + upsert the plan_artifacts row + skip the balance check +
--          ledger debit.
--        - Defensive p_credits validation when cost > 0: the caller's
--          claimed credit count must equal 1 or 2 (matches the
--          duration-based tiering); mismatched values RAISE 22023.
--          When p_credits IS NULL the function falls through to the
--          computed-cost path (default 1).
--
-- credit_ledger column names: `delta` (integer NOT NULL), `type` (text
-- NOT NULL, free-form — no CHECK constraint). Adding the new
-- `'publish_free'` value requires no constraint change.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Helper: is this plan a "self-trainer + all verified" publish?
--
-- Returns true ONLY when:
--   1. The plan has a linked client (clients row exists).
--   2. clients.user_id = the supplied caller uuid (i.e. the client IS
--      the practitioner — Self-client per PR #1).
--   3. The plan has at least one exercises row in the cloud (avoids the
--      first-publish edge where exercises haven't been upserted yet, in
--      which case we want the cost to default to the duration-based
--      tier, NOT zero).
--   4. EVERY non-rest exercise for this plan has self_verified = true.
--      Rest exercises don't carry self-verification — they're excluded
--      from the check entirely.
--
-- SECURITY DEFINER so the helper can read clients.user_id + exercises
-- regardless of the calling role's RLS visibility. Callers are
-- responsible for their own membership checks.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_self_trainer_all_verified(
  p_plan_id uuid,
  p_caller  uuid
)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_client_user_id uuid;
  v_total          integer;
  v_unverified     integer;
BEGIN
  IF p_plan_id IS NULL OR p_caller IS NULL THEN
    RETURN false;
  END IF;

  -- (1) + (2): plan -> client -> user_id must equal the caller.
  SELECT c.user_id
    INTO v_client_user_id
    FROM public.plans  p
    JOIN public.clients c ON c.id = p.client_id
   WHERE p.id = p_plan_id
   LIMIT 1;

  IF v_client_user_id IS NULL OR v_client_user_id <> p_caller THEN
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
  --     false fails the check — conservative per the PR #5 comment on
  --     exercises.self_verified).
  SELECT count(*)
    INTO v_unverified
    FROM public.exercises
   WHERE plan_id = p_plan_id
     AND media_type <> 'rest'
     AND (self_verified IS NULL OR self_verified = false);

  RETURN v_unverified = 0;
END;
$function$;

ALTER FUNCTION public.is_self_trainer_all_verified(uuid, uuid) OWNER TO postgres;

-- ---------------------------------------------------------------------------
-- preview_publish_cost(p_session_id) -> integer (0, 1, or 2)
--
-- Side-effect-free. SECURITY DEFINER + practice-membership check
-- mirrors consume_credit's pattern. Returns:
--   - 0 if is_self_trainer_all_verified(plan, caller) = true
--   - 2 if computed plan duration > 75 minutes (4500 seconds)
--   - 1 otherwise (including empty-plan / first-publish — there is no
--     legitimate "zero-cost non-self-trainer" path).
--
-- Duration math (best-effort server-side approximation):
--   For each non-rest exercise, sum across its exercise_sets rows:
--     per_set_seconds =
--         reps * 3                           -- secondsPerRep default
--       + CASE hold_position
--           WHEN 'per_rep'         THEN reps * hold_seconds
--           WHEN 'end_of_set'      THEN hold_seconds
--           WHEN 'end_of_exercise' THEN
--                CASE WHEN is_last_set THEN hold_seconds ELSE 0 END
--         END
--       + breather_seconds_after
--
-- The 3-seconds-per-rep is a server-side approximation — the Flutter
-- model uses the actual videoDurationMs/repsPerLoop when available, but
-- the cloud doesn't store videoDurationMs. For the cost-tier decision
-- (≤75 vs >75 minutes) this is accurate enough; the mobile client's own
-- creditCostForDuration is still the primary cost source on the wire.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.preview_publish_cost(p_session_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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

  -- Self-trainer all-verified short-circuit.
  IF public.is_self_trainer_all_verified(p_session_id, v_caller) THEN
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

ALTER FUNCTION public.preview_publish_cost(uuid) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.preview_publish_cost(uuid) TO authenticated;

COMMENT ON FUNCTION public.preview_publish_cost(uuid) IS
  'Self-trainer wave PR #6 (2026-05-25). Side-effect-free preview of the '
  'credit cost for publishing this plan. Returns 0 / 1 / 2: 0 when the '
  'plan is a self-trainer publish with every non-rest exercise marked '
  'self_verified = true; otherwise the duration tier from exercise_sets. '
  'Membership-checked. consume_credit applies the same logic '
  'authoritatively at publish time.';

-- ---------------------------------------------------------------------------
-- consume_credit extension — conditional free path + defensive p_credits.
--
-- CREATE OR REPLACE preserves EVERY existing column / branch from the
-- live function (per feedback_schema_migration_column_preservation):
--   * 28000 auth-required guard
--   * p_practice_id-required guard
--   * Practice membership check
--   * SEC-2 validate_plan_treatment_consent backstop (FIRST, unchanged)
--   * Practice row lock (FOR UPDATE)
--   * Wave 29 prepaid-unlock fast path (clears the prepaid stamp +
--     resets first_opened_at / last_opened_at + writes plan_artifacts)
--   * Insufficient credits return shape
--   * Wave 40.5 trainer_id stamp on the consumption ledger row
--   * PR #7 plan_artifacts (plan_url) write on both write paths
--
-- New behaviour:
--   * Computes v_self_free := is_self_trainer_all_verified(plan, caller)
--     AFTER membership + consent backstop, BEFORE the prepaid-unlock
--     branch. When true: skip balance check, skip ledger debit, write a
--     `delta = 0, type = 'publish_free'` audit row, upsert
--     plan_artifacts, return {ok: true, new_balance: <unchanged>,
--     free: true, reason: 'self_trainer_all_verified'}.
--   * Relaxed p_credits validation. When v_self_free = true, p_credits
--     is ignored (caller may pass 0 / 1 / 2 / NULL — all are accepted).
--     When v_self_free = false:
--       - NULL / <=0 still raise 22023 (unchanged hard floor).
--       - p_credits NOT IN (1, 2) raises 22023 (defensive — the only
--         valid duration-tier values).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.consume_credit(p_practice_id uuid, p_plan_id uuid, p_credits integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_balance      integer;
  v_new_balance  integer;
  v_prepaid_at   timestamptz;
  v_self_free    boolean := false;
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

  -- PR #6 (2026-05-25) — self-trainer all-verified short-circuit.
  -- Computed AFTER the consent backstop so any unconsented treatments
  -- still surface even on a free publish.
  IF p_plan_id IS NOT NULL THEN
    v_self_free := public.is_self_trainer_all_verified(p_plan_id, v_caller);
  END IF;

  -- Defensive p_credits validation. Only enforced on the paid path —
  -- self-trainer free publishes are allowed to omit / mis-specify
  -- p_credits since the server overrides the cost to zero.
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

  -- Paid path — original Milestone D1 logic, unchanged.
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

ALTER FUNCTION public.consume_credit(uuid, uuid, integer) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.consume_credit(uuid, uuid, integer) TO authenticated;

COMMENT ON FUNCTION public.consume_credit(uuid, uuid, integer) IS
  'Atomic credit consumption for plan publish. SECURITY DEFINER, '
  'membership-checked, FOR UPDATE row locked. Branches: (a) prepaid '
  'unlock fast path (Wave 29) — clears stamp + writes plan_artifacts, '
  'no debit; (b) self-trainer all-verified free path (PR #6 / '
  '2026-05-25) — delta=0 publish_free ledger row + plan_artifacts, no '
  'debit; (c) paid path — insufficient_credits early return OR '
  'consumption ledger row (delta=-p_credits, type=consumption, '
  'trainer_id=caller per Wave 40.5) + plan_artifacts. SEC-2 consent '
  'backstop fires first regardless of branch. p_credits must be 1 or 2 '
  'on the paid path; ignored on the free / prepaid paths.';

COMMIT;
