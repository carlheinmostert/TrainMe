-- homefit.studio — Milestone E: safe RPCs for refund + bootstrap
-- =============================================================================
-- Run in Supabase SQL Editor (or via the linked CLI:
--   supabase db query --linked --file supabase/schema_milestone_e_safe_rpcs.sql
-- Safe to re-run. Every function is CREATE OR REPLACE; every grant is idempotent.
--
-- WHAT THIS MIGRATION DOES
--   1. Adds `refund_credit(p_plan_id uuid)` — idempotent SECURITY DEFINER RPC
--      that inserts a compensating `type='refund'` ledger row for a failed
--      publish. Replaces the direct client INSERT in upload_service._refundCredits.
--      Validates:
--        (a) a matching `type='consumption'` row exists for this plan,
--        (b) no prior `type='refund'` row exists for the same plan at the
--            same version (no double refunds).
--
--   2. Adds `bootstrap_practice_for_user() RETURNS uuid` — idempotent
--      SECURITY DEFINER RPC that replaces the multi-step sentinel-claim /
--      fresh-practice-create logic currently inlined in
--      auth_service.ensurePracticeMembership. Returns the practice_id.
--      Three sub-paths, all atomic within the function:
--        (a) user already has a membership row → return that practice_id.
--        (b) Carl-sentinel has no owner → claim it, insert membership as
--            owner, seed `adjustment` +1000 founder-credit row only if the
--            ledger is empty (matches Milestone A backfill semantics).
--        (c) otherwise → create a fresh practice named from the user's
--            email local-part (fallback "My Practice"), insert membership
--            as owner, seed `adjustment` +5 welcome-bonus row.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT revoke direct client INSERT on credit_ledger. That hardening
--     step waits until Carl has verified the RPC path end-to-end on device.
--   * Does NOT change RLS on `practices` or `practice_members`.
--   * Does NOT take the fresh-practice name from any user-supplied field
--     other than the auth email local-part — UI-driven practice naming is
--     a separate, post-MVP concern.
--
-- SENTINEL UUID (hardcoded, matches AppConfig.sentinelPracticeId)
--   practice id : 00000000-0000-0000-0000-0000000ca71e   ("CA71E" ≈ "Carlie")
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. refund_credit — idempotent compensating refund
-- ============================================================================
-- Contract:
--   * caller must be an authed trainer (auth.uid() not null).
--   * caller must be a member of the practice that owns the matching
--     consumption row (so a stranger can't refund someone else's plan).
--   * p_plan_id must reference an existing consumption row in credit_ledger.
--     If there's no prior consumption for this plan, the RPC is a no-op and
--     returns false (keeps the caller's catch-all tolerant on stale retries).
--   * If a refund row already exists for this plan_id, the RPC is a no-op
--     and returns false (idempotent — double-refund guard).
--
-- Returns boolean: true = refund row written, false = no-op (already refunded
-- or no matching consumption found). Raises on auth / membership violations.
--
-- Refund row carries:
--   delta       = ABS(consumption.delta)  (positive int — un-do the negative)
--   type        = 'refund'
--   practice_id = inherited from the matching consumption row (NOT re-derived
--                 from any client-passed argument — the ledger is the truth)
--   plan_id     = p_plan_id
--   notes       = 'refund_credit(<plan_id>)'
CREATE OR REPLACE FUNCTION public.refund_credit(p_plan_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller          uuid := auth.uid();
  v_consumption     credit_ledger%ROWTYPE;
  v_already_refunded boolean;
  v_is_member       boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'refund_credit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'refund_credit: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- Find the most recent matching consumption row for this plan. If none
  -- exists the caller is trying to refund something that was never charged
  -- — return false and move on (do NOT raise, so stale retries on a plan
  -- that was never successfully consumed don't mask the original publish
  -- error in the client's try/catch).
  SELECT * INTO v_consumption
    FROM credit_ledger
   WHERE plan_id = p_plan_id
     AND type    = 'consumption'
   ORDER BY created_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Membership check. Even though SECURITY DEFINER bypasses RLS, we still
  -- don't let a stranger refund a plan they aren't entitled to touch.
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

  -- Idempotency guard: a refund row for this plan already exists.
  SELECT EXISTS (
    SELECT 1 FROM credit_ledger
     WHERE plan_id = p_plan_id
       AND type    = 'refund'
  ) INTO v_already_refunded;

  IF v_already_refunded THEN
    RETURN false;
  END IF;

  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes)
  VALUES (
    v_consumption.practice_id,
    ABS(v_consumption.delta),
    'refund',
    p_plan_id,
    'refund_credit(' || p_plan_id::text || ')'
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.refund_credit(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_credit(uuid) TO authenticated;

-- ============================================================================
-- 2. bootstrap_practice_for_user — idempotent membership bootstrap
-- ============================================================================
-- Replaces the multi-round-trip logic currently in auth_service.dart:
--   1. If the caller already has a membership row → return its practice_id.
--   2. Else, attempt to claim the Carl-sentinel practice (conditional UPDATE
--      on owner_trainer_id IS NULL, so only the first caller wins). On a
--      successful claim insert the owner membership row. No welcome bonus
--      row is seeded here because Milestone A's backfill already dropped
--      1000 founder credits into the sentinel's ledger — seeding another
--      row would double-count. Returns the sentinel practice_id.
--   3. Else, create a fresh personal practice named from the auth email's
--      local-part (falls back to "My Practice"), insert the owner membership,
--      and seed a welcome_bonus_credits (5) `adjustment` ledger row. Returns
--      the new practice_id.
--
-- All three sub-paths are atomic within the function. Membership INSERTs
-- and the welcome-bonus ledger row bypass RLS via SECURITY DEFINER.
--
-- Returns uuid: the practice_id the caller is now (or was already) a member of.
CREATE OR REPLACE FUNCTION public.bootstrap_practice_for_user()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller        uuid := auth.uid();
  v_email         text;
  v_existing_pid  uuid;
  v_claimed       boolean;
  v_new_pid       uuid;
  v_practice_name text;
  v_local_part    text;
  v_sentinel_id   uuid := '00000000-0000-0000-0000-0000000ca71e';
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'bootstrap_practice_for_user requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- ------------------------------------------------------------------
  -- Path (a): user already has a membership. Return the first one.
  -- ------------------------------------------------------------------
  SELECT practice_id
    INTO v_existing_pid
    FROM practice_members
   WHERE trainer_id = v_caller
   ORDER BY joined_at ASC
   LIMIT 1;

  IF v_existing_pid IS NOT NULL THEN
    RETURN v_existing_pid;
  END IF;

  -- ------------------------------------------------------------------
  -- Path (b): try to claim the sentinel practice. Conditional UPDATE
  -- on owner_trainer_id IS NULL so only the first caller wins. Losers
  -- of the race get v_claimed = false and fall through to Path (c).
  -- ------------------------------------------------------------------
  WITH claim AS (
    UPDATE practices
       SET owner_trainer_id = v_caller
     WHERE id = v_sentinel_id
       AND owner_trainer_id IS NULL
    RETURNING id
  )
  SELECT EXISTS (SELECT 1 FROM claim) INTO v_claimed;

  IF v_claimed THEN
    INSERT INTO practice_members (practice_id, trainer_id, role)
    VALUES (v_sentinel_id, v_caller, 'owner');
    -- No welcome bonus — Milestone A's backfill already seeded the
    -- sentinel with 1000 founder credits. Double-seeding would be
    -- a silent billing error.
    RETURN v_sentinel_id;
  END IF;

  -- ------------------------------------------------------------------
  -- Path (c): fresh personal practice for this user.
  -- ------------------------------------------------------------------
  SELECT email INTO v_email FROM auth.users WHERE id = v_caller;

  IF v_email IS NULL OR position('@' IN v_email) < 2 THEN
    v_practice_name := 'My Practice';
  ELSE
    v_local_part := split_part(v_email, '@', 1);
    IF length(v_local_part) = 0 THEN
      v_practice_name := 'My Practice';
    ELSE
      v_practice_name := v_local_part || ' Practice';
    END IF;
  END IF;

  INSERT INTO practices (name, owner_trainer_id)
  VALUES (v_practice_name, v_caller)
  RETURNING id INTO v_new_pid;

  INSERT INTO practice_members (practice_id, trainer_id, role)
  VALUES (v_new_pid, v_caller, 'owner');

  -- Welcome bonus: 5 credits, matches AppConfig.welcomeBonusCredits.
  INSERT INTO credit_ledger (practice_id, delta, type, notes)
  VALUES (v_new_pid, 5, 'adjustment', 'Welcome bonus');

  RETURN v_new_pid;
END;
$$;

REVOKE ALL ON FUNCTION public.bootstrap_practice_for_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bootstrap_practice_for_user() TO authenticated;

COMMIT;

-- ============================================================================
-- Verification — run these after the migration to sanity-check
-- ============================================================================
--
-- A. Grants are correct. Only authenticated can execute.
--   SELECT proname, proacl FROM pg_proc
--    WHERE proname IN ('refund_credit', 'bootstrap_practice_for_user');
--
-- B. refund_credit no-ops when the plan was never consumed.
--   SELECT public.refund_credit('11111111-1111-1111-1111-111111111111');
--   -- expect: false
--
-- C. refund_credit round-trip (as a real authed user with a matching
--    consumption row in place):
--   SELECT public.refund_credit('<consumed-plan-uuid>');
--   -- expect: true on first call, false on every subsequent call.
--
-- D. bootstrap_practice_for_user returning-user case:
--   SELECT public.bootstrap_practice_for_user();
--   -- expect: same practice_id on every call for the same user.
--
-- E. bootstrap_practice_for_user fresh user (staged via a new auth user):
--   SELECT public.bootstrap_practice_for_user();
--   -- expect: either the sentinel uuid (if still unclaimed) or a fresh uuid,
--   -- plus matching practice_members + credit_ledger rows.
