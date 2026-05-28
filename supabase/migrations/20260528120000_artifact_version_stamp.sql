-- =============================================================================
-- Artefact versioning (#565) — stamp the plan/session version per artefact.
-- =============================================================================
--
-- WHAT
--   Each plan_artifacts row carries the plan/session version AS OF the
--   artefact's LAST publish — NOT an independent counter. Carl's spec:
--   "It must reflect the session version at which it was last published.
--   So if the artefact was last published at session V2 but the session
--   version is now 6 and I publish the artefact it should skip from
--   version 2 to 7."
--
-- SEMANTICS
--   * Publishing an artefact bumps the plan version (6 -> 7, as today) AND
--     stamps the NEW (post-bump) plan version (7) onto every artefact that
--     was (re)generated in that publish.
--   * An artefact NOT regenerated in a publish keeps its prior stamp.
--   * Two artefacts published together show the same number; they diverge
--     only when one is republished without the other.
--
-- WHERE THE POST-BUMP VALUE COMES FROM (deterministic, no exception flow)
--   The Flutter publish flow (app/lib/services/upload_service.dart) runs in
--   this order, all in one logical publish:
--       Step 3b: upsert plans with version = session.version       (OLD)
--       Step 3b: call publish_plan_artifacts(...)  <-- artefacts stamped here
--                  -> internally calls consume_credit(...)
--       Step 4 : upsert plans with version = session.version + 1   (NEW)
--   So at the moment the artefact rows are written, plans.version is still
--   the OLD value. Stamping `version = plans.version + 1` therefore yields
--   the SAME number Step 4 will write — the post-bump value. Brand-new plans
--   (session.version 0 -> cloud row version 0) stamp 0+1 = 1, matching the
--   first-publish bump. Republishes (6) stamp 6+1 = 7. Both branches are
--   pure arithmetic on the locked-for-update plan row — no try/catch, no
--   guessing.
--
-- COLUMN-PRESERVATION DISCIPLINE (feedback_schema_migration_column_preservation.md)
--   consume_credit, publish_plan_artifacts and get_plan_full are re-emitted
--   below in full, carried forward VERBATIM from their latest defining
--   migrations, with the ONLY delta being the `version` stamp on each
--   plan_artifacts (re)write + the `version` key on get_plan_full's artefact
--   projection. Sources:
--     consume_credit          -> 20260525160312_self_trainer_hotfix.sql
--     publish_plan_artifacts  -> 20260526150953_artifact_system_foundation.sql
--     get_plan_full           -> 20260528090000_get_plan_full_referral_code.sql
--   The CLI is linked to PROD; staging pg_get_functiondef was not reachable,
--   so the latest migration bodies are the source of truth (permitted
--   fallback). Every existing column / behaviour is preserved unchanged.
--
-- Idempotent. Safe to re-run.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. plan_artifacts.version — the plan/session version at last publish.
-- -----------------------------------------------------------------------------
-- DEFAULT 1 mirrors plans.version's own default (1 = first publish). The
-- backfill below overwrites every existing row with its plan's CURRENT
-- version so pre-#565 artefacts read truthfully rather than all showing 1.

ALTER TABLE public.plan_artifacts
  ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1;

COMMENT ON COLUMN public.plan_artifacts.version IS
  'Plan/session version stamped at this artefact''s LAST publish (#565). NOT an independent counter — equals plans.version as of the publish that (re)generated this artefact. Stamped server-side by consume_credit / publish_plan_artifacts to plans.version + 1 (the post-bump value, since those RPCs run before the Flutter Step-4 version bump). Surfaced per-artefact via get_plan_full + list_plan_artifact_statuses.';

-- Backfill: every existing artefact adopts its plan's current version.
UPDATE public.plan_artifacts pa
   SET version = p.version
  FROM public.plans p
 WHERE p.id = pa.plan_id
   AND pa.version IS DISTINCT FROM p.version;


-- =============================================================================
-- 2. consume_credit — stamp version on the three plan_artifacts upserts.
-- =============================================================================
-- Verbatim carry-forward of 20260525160312_self_trainer_hotfix.sql's
-- consume_credit. ONLY delta: `version` added to each of the three
-- INSERT ... ON CONFLICT plan_artifacts writes (prepaid-unlock / self-free /
-- paid), set to (plans.version + 1) — the post-bump value. Every other line
-- (consent backstop, FOR SHARE lock, self-trainer free path, server-side
-- cost recompute, ledger writes, return shapes) is unchanged.
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
  v_stamp_version integer;
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

  -- #565: the version to stamp on every artefact (re)written in this
  -- publish. plans.version here is the PRE-bump value (the Flutter
  -- Step-4 upsert bumps it after this RPC returns), so +1 is the
  -- post-bump number both surfaces will agree on. NULL-safe for a plan
  -- row that somehow doesn't exist (falls back to 1 = first publish).
  SELECT COALESCE(version, 0) + 1
    INTO v_stamp_version
    FROM plans
   WHERE id = p_plan_id;
  v_stamp_version := COALESCE(v_stamp_version, 1);

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
      INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at, version)
      VALUES (p_plan_id, 'plan_url', 'ready', now(), v_stamp_version)
      ON CONFLICT (plan_id, kind) DO UPDATE
        SET generated_at = now(),
            status       = 'ready',
            version      = v_stamp_version;
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
      INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at, version)
      VALUES (p_plan_id, 'plan_url', 'ready', now(), v_stamp_version)
      ON CONFLICT (plan_id, kind) DO UPDATE
        SET generated_at = now(),
            status       = 'ready',
            version      = v_stamp_version;
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
    INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at, version)
    VALUES (p_plan_id, 'plan_url', 'ready', now(), v_stamp_version)
    ON CONFLICT (plan_id, kind) DO UPDATE
      SET generated_at = now(),
          status       = 'ready',
          version      = v_stamp_version;
  END IF;

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance
  );
END;
$function$;


-- =============================================================================
-- 3. publish_plan_artifacts — stamp version on the per-kind upsert.
-- =============================================================================
-- Verbatim carry-forward of 20260526150953_artifact_system_foundation.sql's
-- publish_plan_artifacts. ONLY delta: `version` added to the per-kind
-- INSERT ... ON CONFLICT plan_artifacts write, set to (plans.version + 1) —
-- the same post-bump value consume_credit stamps. Every other line
-- (validation, total-seconds compute, already-published filter, credit
-- consumption, plan_issuances audit, return shapes) is unchanged.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.publish_plan_artifacts(
  p_practice_id uuid,
  p_plan_id     uuid,
  p_kinds       text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller            uuid := auth.uid();
  v_is_member         boolean;
  v_total_seconds     integer := 0;
  v_kind              text;
  v_price             numeric(10, 4);
  v_paid_sum          numeric(10, 4) := 0;
  v_paid_sum_int      integer;
  v_consume_result    jsonb;
  v_existing_kinds    text[];
  v_kinds_to_publish  text[] := ARRAY[]::text[];
  v_kind_prices       jsonb := '{}'::jsonb;
  v_plan_version      integer;
  v_exercise_count    integer;
  v_stamp_version     integer;
BEGIN
  -- ===== Validation ========================================================

  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'publish_plan_artifacts requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'publish_plan_artifacts: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'publish_plan_artifacts: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_kinds IS NULL OR array_length(p_kinds, 1) IS NULL THEN
    RAISE EXCEPTION 'publish_plan_artifacts: p_kinds must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION
      'publish_plan_artifacts: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Plan ownership: defence-in-depth. consume_credit also checks this,
  -- but the free path here skips that call so we need our own gate.
  IF NOT EXISTS (
    SELECT 1 FROM public.plans
     WHERE id = p_plan_id
       AND practice_id = p_practice_id
  ) THEN
    RAISE EXCEPTION
      'publish_plan_artifacts: plan % does not belong to practice %',
      p_plan_id, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Validate every kind against the CHECK list. The CHECK on plan_artifacts
  -- would catch this at INSERT time, but raising EARLY gives a clean error
  -- message rather than a generic constraint violation.
  FOREACH v_kind IN ARRAY p_kinds LOOP
    IF v_kind NOT IN ('plan_url', 'handout', 'poster', 'reel', 'ai_reel', 'calendar') THEN
      RAISE EXCEPTION
        'publish_plan_artifacts: unknown kind "%" (allowed: plan_url, handout, poster, reel, ai_reel, calendar)',
        v_kind
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- ===== Compute plan total seconds =======================================
  -- Same formula consume_credit uses. Used by the price helper.
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

  -- ===== Filter to newly-published kinds + sum unpaid =====================
  -- A kind that already has a row in plan_artifacts with published_at IS
  -- NOT NULL is a no-op (already-Live). We DO NOT re-charge for it.
  SELECT COALESCE(array_agg(kind), ARRAY[]::text[])
    INTO v_existing_kinds
    FROM public.plan_artifacts
   WHERE plan_id = p_plan_id
     AND published_at IS NOT NULL;

  FOREACH v_kind IN ARRAY p_kinds LOOP
    -- Skip already-published kinds — no-op + don't re-charge.
    IF v_kind = ANY(v_existing_kinds) THEN
      CONTINUE;
    END IF;

    v_price := public._artifact_kind_price(v_kind, v_total_seconds);
    IF v_price IS NULL THEN
      RAISE EXCEPTION
        'publish_plan_artifacts: kind "%" is not yet shippable in this wave',
        v_kind
        USING ERRCODE = 'P0003';
    END IF;

    v_paid_sum := v_paid_sum + v_price;
    v_kind_prices := v_kind_prices || jsonb_build_object(v_kind, v_price);
    v_kinds_to_publish := array_append(v_kinds_to_publish, v_kind);
  END LOOP;

  -- Every requested kind was already-published → no-op success.
  IF array_length(v_kinds_to_publish, 1) IS NULL THEN
    RETURN jsonb_build_object(
      'ok',         true,
      'published',  ARRAY[]::text[],
      'reason',     'already_published'
    );
  END IF;

  -- ===== Consume credits if needed =======================================
  -- The current consume_credit only accepts integer p_credits in {1, 2}.
  -- Wave 1's only paid kind is plan_url (1 or 2 credits) and handout is
  -- free, so the sum is always 0, 1, or 2 — well within range. If a future
  -- wave introduces a non-integer-priced kind (e.g. premium reel at 5
  -- credits) the publish RPC will need to chunk consume_credit calls,
  -- but that's not a Wave 1 concern.
  IF v_paid_sum > 0 THEN
    v_paid_sum_int := v_paid_sum::integer;
    IF v_paid_sum_int::numeric <> v_paid_sum THEN
      RAISE EXCEPTION
        'publish_plan_artifacts: fractional credit sums not supported in this wave (sum=%); future kind requires consume_credit widening',
        v_paid_sum
        USING ERRCODE = '0A000';
    END IF;

    v_consume_result := public.consume_credit(p_practice_id, p_plan_id, v_paid_sum_int);
    IF NOT (v_consume_result->>'ok')::boolean THEN
      -- Pass the failure shape through unchanged (insufficient_credits etc).
      RETURN v_consume_result;
    END IF;
  END IF;

  -- #565: the version to stamp on every artefact (re)written in this
  -- publish. plans.version is the PRE-bump value (the Flutter Step-4
  -- upsert bumps it after this RPC returns), so +1 is the post-bump
  -- number. Matches the value consume_credit stamps on the plan_url row
  -- so both agree within the same transaction. NULL-safe (1 = first
  -- publish) for a defensive missing plan row.
  SELECT COALESCE(version, 0) + 1
    INTO v_stamp_version
    FROM public.plans
   WHERE id = p_plan_id;
  v_stamp_version := COALESCE(v_stamp_version, 1);

  -- ===== Upsert plan_artifacts rows =======================================
  -- consume_credit's existing implementation upserts the plan_url row
  -- on the paid path. We re-upsert here to set published_at +
  -- credits_charged for every requested kind, including plan_url. The
  -- upsert is idempotent — re-running with the same kind set is safe.
  FOREACH v_kind IN ARRAY v_kinds_to_publish LOOP
    INSERT INTO public.plan_artifacts (
      plan_id, kind, status, generated_at, published_at, credits_charged, version
    )
    VALUES (
      p_plan_id,
      v_kind,
      'ready',
      now(),
      now(),
      COALESCE((v_kind_prices->>v_kind)::numeric, 0),
      v_stamp_version
    )
    ON CONFLICT (plan_id, kind) DO UPDATE
      SET generated_at    = EXCLUDED.generated_at,
          published_at    = COALESCE(plan_artifacts.published_at, EXCLUDED.published_at),
          credits_charged = plan_artifacts.credits_charged + EXCLUDED.credits_charged,
          status          = 'ready',
          version         = EXCLUDED.version;
  END LOOP;

  -- ===== Audit: plan_issuances row per kind ==============================
  -- One row per newly-published kind. Carries the per-kind credit charge
  -- so the portal audit feed can later break down "this publish cost N
  -- credits across these K artifacts." Pre-Wave-1 rows have NULL kind
  -- (legacy Flutter direct-INSERT path); post-Wave-1 rows from this RPC
  -- have a populated kind.
  SELECT version, (
    SELECT COUNT(*) FROM public.exercises
     WHERE plan_id = p_plan_id
       AND media_type <> 'rest'
  )::integer
    INTO v_plan_version, v_exercise_count
    FROM public.plans
   WHERE id = p_plan_id;

  FOREACH v_kind IN ARRAY v_kinds_to_publish LOOP
    INSERT INTO public.plan_issuances (
      plan_id, practice_id, trainer_id, version, exercise_count,
      credits_charged, issued_at, kind
    )
    VALUES (
      p_plan_id,
      p_practice_id,
      v_caller,
      COALESCE(v_plan_version, 1),
      COALESCE(v_exercise_count, 0),
      COALESCE((v_kind_prices->>v_kind)::numeric, 0)::integer,
      now(),
      v_kind
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok',         true,
    'published',  v_kinds_to_publish,
    'paid_sum',   v_paid_sum
  );
END;
$function$;


-- =============================================================================
-- 4. list_plan_artifact_statuses — return per-artefact version.
-- =============================================================================
-- Verbatim carry-forward of 20260526173718_list_plan_artifact_statuses.sql.
-- ONLY delta: `version` added to the RETURNS TABLE + the RETURN QUERY
-- projection. Drives the mobile Studio / accordion per-row "Published · v{N}"
-- pill. Every other line (auth + membership gate, plan-not-found empty
-- return, ordering) is unchanged.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.list_plan_artifact_statuses(
  p_plan_id uuid
)
RETURNS TABLE (
  kind             text,
  status           text,
  generated_at     timestamptz,
  published_at     timestamptz,
  credits_charged  numeric,
  first_opened_at  timestamptz,
  version          integer
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_plan_artifact_statuses requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'list_plan_artifact_statuses: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id
    INTO v_practice_id
    FROM public.plans
   WHERE id = p_plan_id
   LIMIT 1;

  -- Plan-not-found: empty rather than error so a fresh, never-published
  -- session can call this on every Studio open without burning RPC
  -- latency budget on an exception path. The UI renders zero pills,
  -- which is the right answer.
  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.practice_members
     WHERE practice_id = v_practice_id
       AND trainer_id  = v_caller
  ) THEN
    RAISE EXCEPTION
      'list_plan_artifact_statuses: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      pa.kind,
      pa.status,
      pa.generated_at,
      pa.published_at,
      pa.credits_charged,
      pa.first_opened_at,
      pa.version
      FROM public.plan_artifacts pa
     WHERE pa.plan_id = p_plan_id
     ORDER BY pa.generated_at ASC;
END;
$$;

COMMENT ON FUNCTION public.list_plan_artifact_statuses(uuid) IS
  'Wave 3 (artifact-system): enumerates the plan_artifacts rows for a plan with their published/credits state + per-artefact version (#565). Drives the mobile Studio artifact-status row and the Publish gate''s Live-row rendering. SECURITY DEFINER + explicit membership check.';

GRANT EXECUTE ON FUNCTION public.list_plan_artifact_statuses(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.list_plan_artifact_statuses(uuid) FROM anon;


-- =============================================================================
-- 5. get_plan_full — add per-artefact `version` to the artefacts projection.
-- =============================================================================
-- Verbatim carry-forward of 20260528090000_get_plan_full_referral_code.sql.
-- ONLY delta: `version` key added to the whitelisted plan_artifacts
-- projection. SENSITIVE RPC: SECURITY DEFINER + anon-callable. Every other
-- line is preserved UNCHANGED — the consent gating, all five per-exercise
-- treatment URL CASE blocks, sets/rest/thumbnail projection, the brand-skin
-- fields (brand_color / public_logo_url / practice_name / brand_skin_active),
-- and the referral_code lookup all flow through exactly as before. Per
-- feedback_schema_migration_column_preservation.md.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  plan_row             plans;
  v_consent            jsonb;
  v_gray_ok            boolean;
  v_orig_ok            boolean;
  v_base_url           text;
  exes                 jsonb;
  v_brand_color        text;
  v_public_logo_url    text;
  v_practice_name      text;
  v_artifacts          jsonb;
  v_brand_skin_active  boolean := false;
  v_referral_code      text;
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
    v_brand_skin_active := public.practice_has_active_brand_skin(plan_row.practice_id);

    -- Printable Workout Guide footer QR: the practice's single
    -- non-revoked referral slug. NULL when the practice has none.
    SELECT rc.code INTO v_referral_code
      FROM referral_codes rc
     WHERE rc.practice_id = plan_row.practice_id
       AND rc.revoked_at IS NULL
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

  -- R1-M4 + Wave 1 artifact-system extension: whitelisted projection.
  -- #565 — per-artefact `version` (the plan/session version at this
  -- artefact's last publish) is appended to the whitelist so the web
  -- player can render "Published · v{N}" per artefact card.
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'kind',             a.kind,
               'status',           a.status,
               'generated_at',     a.generated_at,
               'published_at',     a.published_at,
               'first_opened_at',  a.first_opened_at,
               'version',          a.version
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
             'brand_color',        v_brand_color,
             'public_logo_url',    v_public_logo_url,
             'practice_name',      v_practice_name,
             'brand_skin_active',  v_brand_skin_active,
             'referral_code',      v_referral_code
           ),
    'exercises', exes,
    'artifacts', v_artifacts
  );
END;
$function$;


-- =============================================================================
-- 6. list_my_plans — source `version` from the ARTEFACT row, not the plan.
-- =============================================================================
-- Verbatim carry-forward of 20260526173515_artifact_system_claim.sql's
-- list_my_plans (the consumer-side `/me` "My Workouts" feed). The web
-- player's me.js already renders `row.version` as "Published · v{N}" per
-- artefact card, but the row's `version` was sourced from `plans.version`
-- (the plan-level CURRENT version) — so every artefact of a plan showed the
-- same number even when one was republished without the other. #565 fixes
-- the source: each (plan, kind) row now carries its OWN
-- `plan_artifacts.version`, so the consumer's cards diverge correctly and
-- stay in R-10 parity with the mobile accordion. ONLY delta: the `version`
-- value moves from `mp.version` to `a.version` (added to artifact_rows +
-- the jsonb projection). Every other line (claim join, exercise counts,
-- practitioner lookup, sort order, grants) is unchanged.
-- =============================================================================
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
    --
    -- #565: `version` comes from the ARTEFACT row (a.version) — the
    -- plan/session version at THIS artefact's last publish — not from
    -- the plan-level mp.version. That keeps two siblings of the same plan
    -- distinguishable when only one was republished.
    SELECT mp.plan_id,
           mp.plan_title,
           mp.practice_client_id,
           mp.practice_id,
           a.version,
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
  'Consumer-side My Workouts feed (Wave 2). Returns one row per (plan, published-artifact-kind) for every plan owned by clients the consumer has claimed. Recency-sorted by artifact.published_at. Per-artefact `version` (#565) is the plan/session version at that artefact''s last publish. Authenticated only. Distinct from list_my_workouts which is the practitioner self-trainer RPC.';

REVOKE ALL ON FUNCTION public.list_my_plans() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_plans() TO authenticated;

COMMIT;
