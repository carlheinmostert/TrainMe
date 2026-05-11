-- homefit.studio — Milestone M: credit model (3/8 free + 5% lifetime + goodwill floor)
-- =============================================================================
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_milestone_m_credit_model.sql
-- Idempotent: every statement uses CREATE IF NOT EXISTS / OR REPLACE / guarded
-- inserts. Safe to re-run.
--
-- MODEL (agreed 2026-04-20, supersedes the Milestone A welcome-bonus and
-- Milestone F +10/+10 signup bonuses)
--
--   +3 credits  on organic signup (no referral code claimed), granted inside
--               bootstrap_practice_for_user when a NEW practice is created
--               (NOT when the Carl-sentinel is claimed — that already has
--               founder credits from Milestone A).
--
--   +5 credits  on top of the +3 when a user signs up via /r/{code} and the
--               claim succeeds, granted inside claim_referral_code.
--               Net: referral-signup users land with 3 + 5 = 8 free credits.
--
--   5% lifetime rebate in credits to the referrer on every PayFast purchase
--               by the referee. On the FIRST rebate only, if the calculated
--               5% value rounds to < 1 credit, it's clamped UP to 1 credit
--               as a goodwill floor. Subsequent rebates use the raw fractional
--               5% with no floor.
--
-- CHANGES vs Milestone F (schema_milestone_f_referral_loop.sql):
--   * REMOVED: one-time +10 to referrer on referee's first purchase.
--   * REMOVED: one-time +10 to referee on their own first purchase.
--   * ADDED:   +3 at organic signup (this migration).
--   * ADDED:   +5 top-up at referral claim (this migration).
--   * ADDED:   goodwill floor on referrer's first rebate from each referee
--              (tracked via practice_referrals.goodwill_floor_applied).
--
-- NOT BACKFILLED: existing test practices (carlhein@icloud.com Practice,
-- carlhein@me.com Practice) do NOT retroactively receive the +3 bonus. Clean
-- cutover — new policy, forward-only. This file does no backfill.
--
-- WHAT THIS MIGRATION DOES
--   1. Extends credit_ledger.type CHECK to allow 'signup_bonus' and
--      'referral_signup_bonus'.
--   2. Adds practice_referrals.goodwill_floor_applied boolean column.
--   3. Replaces bootstrap_practice_for_user to emit a +3 'signup_bonus' row
--      on fresh-practice creation, with an idempotency guard.
--   4. Replaces claim_referral_code to emit a +5 'referral_signup_bonus'
--      row on successful claim, with an idempotency guard.
--   5. Replaces record_purchase_with_rebates to drop the +10/+10 bonuses
--      and apply the goodwill floor to the first referrer rebate.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. Extend credit_ledger.type CHECK to include the new kinds
-- ============================================================================
-- The existing CHECK constraint allowed ('purchase','consumption','refund',
-- 'adjustment'). We now add 'signup_bonus' (organic +3) and
-- 'referral_signup_bonus' (+5 on top when claimed via /r/{code}).
-- DROP + ADD is the only way to widen a CHECK constraint idempotently; both
-- sides are trivially safe because the new set is a strict superset.

-- Drop ALL existing CHECK constraints on credit_ledger.type (whatever the
-- Postgres-generated or prior-milestone name ended up being). Then add the
-- widened constraint with a stable name. Idempotent across re-runs.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT conname
      FROM pg_constraint
     WHERE conrelid = 'public.credit_ledger'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%type%'
  LOOP
    EXECUTE format('ALTER TABLE public.credit_ledger DROP CONSTRAINT %I', r.conname);
  END LOOP;
END$$;

ALTER TABLE public.credit_ledger
  ADD CONSTRAINT credit_ledger_type_check
  CHECK (type IN (
    'purchase',
    'consumption',
    'refund',
    'adjustment',
    'signup_bonus',
    'referral_signup_bonus'
  ));

-- ============================================================================
-- 2. practice_referrals.goodwill_floor_applied — tracks first-rebate clamp
-- ============================================================================
-- Flag set the first time a referrer earns a rebate from a given referee.
-- If the raw 5% rebate < 1 credit at that moment, we clamp UP to 1 credit
-- ("goodwill floor"). All subsequent rebates from the same referee use the
-- raw fractional 5% with no floor. The flag is cheaper than counting rows.

ALTER TABLE public.practice_referrals
  ADD COLUMN IF NOT EXISTS goodwill_floor_applied boolean NOT NULL DEFAULT false;

-- ============================================================================
-- 3. bootstrap_practice_for_user — +3 on fresh-practice creation
-- ============================================================================
-- Replaces Milestone E's definition. Same three paths:
--   (a) user already has a membership → return that practice_id.
--   (b) claim the Carl-sentinel practice → no bonus (already has founder
--       credits from Milestone A backfill).
--   (c) fresh personal practice → insert owner membership + a +3
--       'signup_bonus' credit_ledger row. Guarded against double-granting
--       by checking if a 'signup_bonus' row already exists for the
--       practice — even though (c) only runs once per practice, belt-and-
--       braces so a future caller re-running this can't double up.
--
-- NOTE: replaces the previous +5 'adjustment' "Welcome bonus" row with a
-- +3 'signup_bonus' row. The adjustment-row convention leaks "welcome
-- bonus" prose into the audit trail; the typed kind is cleaner.

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
  v_has_bonus     boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'bootstrap_practice_for_user requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- --------------------------------------------------------------
  -- Path (a): user already has a membership. Return the first one.
  -- --------------------------------------------------------------
  SELECT practice_id
    INTO v_existing_pid
    FROM practice_members
   WHERE trainer_id = v_caller
   ORDER BY joined_at ASC
   LIMIT 1;

  IF v_existing_pid IS NOT NULL THEN
    RETURN v_existing_pid;
  END IF;

  -- --------------------------------------------------------------
  -- Path (b): try to claim the sentinel practice. No bonus — the
  -- sentinel already holds founder credits from the Milestone A
  -- backfill.
  -- --------------------------------------------------------------
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
    RETURN v_sentinel_id;
  END IF;

  -- --------------------------------------------------------------
  -- Path (c): fresh personal practice for this user.
  -- --------------------------------------------------------------
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

  -- Signup bonus: +3 credits, idempotent guard even though path (c) only
  -- runs once per practice. Belt-and-braces: if a caller somehow retries
  -- or a future migration calls this fn manually, we don't double-grant.
  SELECT EXISTS (
    SELECT 1 FROM credit_ledger
     WHERE practice_id = v_new_pid
       AND type = 'signup_bonus'
  ) INTO v_has_bonus;

  IF NOT v_has_bonus THEN
    INSERT INTO credit_ledger (practice_id, delta, type, notes)
    VALUES (v_new_pid, 3, 'signup_bonus', 'Organic signup bonus');
  END IF;

  RETURN v_new_pid;
END;
$$;

REVOKE ALL ON FUNCTION public.bootstrap_practice_for_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bootstrap_practice_for_user() TO authenticated;

-- ============================================================================
-- 4. claim_referral_code — grants +5 on successful new claim
-- ============================================================================
-- Replaces Milestone F's definition. The existing logic (code lookup,
-- single-tier trigger catching, self-referral rejection, silent-fail) is
-- preserved. The new behaviour is the +5 'referral_signup_bonus' ledger
-- row emitted AFTER the practice_referrals insert succeeds.
--
-- Idempotency: the PK on practice_referrals (referee_practice_id) already
-- enforces one-shot per referee — the "already referred" check returns
-- false early. We also guard the +5 insert against a pre-existing
-- 'referral_signup_bonus' row for the same practice, in case the ledger
-- row lands but the function is retried (unlikely — INSERTs in a SECURITY
-- DEFINER fn are atomic within the call).

CREATE OR REPLACE FUNCTION public.claim_referral_code(
  p_code                 text,
  p_referee_practice_id  uuid,
  p_consent_to_naming    boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller         uuid := auth.uid();
  v_referrer_pid   uuid;
  v_is_member      boolean;
  v_has_bonus      boolean;
  v_inserted       boolean := false;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'claim_referral_code requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_code IS NULL OR p_referee_practice_id IS NULL THEN
    RETURN false;
  END IF;

  p_code := lower(trim(p_code));

  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_referee_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RETURN false;
  END IF;

  SELECT practice_id INTO v_referrer_pid
    FROM referral_codes
   WHERE code = p_code
     AND revoked_at IS NULL;

  IF v_referrer_pid IS NULL THEN
    RETURN false;
  END IF;

  IF v_referrer_pid = p_referee_practice_id THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM practice_referrals
     WHERE referee_practice_id = p_referee_practice_id
  ) THEN
    RETURN false;
  END IF;

  BEGIN
    INSERT INTO practice_referrals (
      referee_practice_id,
      referrer_practice_id,
      code_used,
      referee_named_consent
    ) VALUES (
      p_referee_practice_id,
      v_referrer_pid,
      p_code,
      COALESCE(p_consent_to_naming, false)
    );
    v_inserted := true;
  EXCEPTION
    WHEN check_violation THEN
      RETURN false;
    WHEN unique_violation THEN
      RETURN false;
  END;

  -- Grant the referral signup top-up. Organic +3 already landed via
  -- bootstrap_practice_for_user (signup was a prerequisite), so this +5
  -- lands on top → net 8 starter credits for the referee.
  IF v_inserted THEN
    SELECT EXISTS (
      SELECT 1 FROM credit_ledger
       WHERE practice_id = p_referee_practice_id
         AND type = 'referral_signup_bonus'
    ) INTO v_has_bonus;

    IF NOT v_has_bonus THEN
      INSERT INTO credit_ledger (practice_id, delta, type, notes)
      VALUES (
        p_referee_practice_id,
        5,
        'referral_signup_bonus',
        'Referral signup bonus (code ' || p_code || ')'
      );
    END IF;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_referral_code(text, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_referral_code(text, uuid, boolean) TO authenticated;

-- ============================================================================
-- 5. record_purchase_with_rebates — 5% + goodwill floor, no +10/+10 bonuses
-- ============================================================================
-- Replaces Milestone F's definition. Changes:
--   * REMOVED: the two +10 'signup_bonus_referrer' / 'signup_bonus_referee'
--              inserts on referee's first paid purchase.
--   * KEPT:    the 5% lifetime rebate to the referrer on every purchase.
--   * ADDED:   goodwill floor — if goodwill_floor_applied = false on the
--              referral and the computed rebate < 1 credit, clamp to 1 and
--              flip the flag. Happens once per (referrer, referee) pair.
--
-- The signup_bonus_paid_at column is now vestigial (no +10/+10 logic uses
-- it) but we leave it in place — harmless, avoids a column drop with its
-- own migration risk, and may come back if we ever reintroduce a bonus.

CREATE OR REPLACE FUNCTION public.record_purchase_with_rebates(
  p_practice_id           uuid,
  p_credits               integer,
  p_amount_zar            numeric,
  p_payfast_payment_id    text,
  p_bundle_key            text,
  p_cost_per_credit_zar   numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_purchase_id          uuid;
  v_referral             practice_referrals%ROWTYPE;
  v_rebate_rows          integer := 0;
  v_rebate_credits       numeric(10,4);
  v_goodwill_applied     boolean := false;
BEGIN
  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'record_purchase_with_rebates: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_credits IS NULL OR p_credits <= 0 THEN
    RAISE EXCEPTION 'record_purchase_with_rebates: p_credits must be positive'
      USING ERRCODE = '22023';
  END IF;
  IF p_amount_zar IS NULL OR p_amount_zar <= 0 THEN
    RAISE EXCEPTION 'record_purchase_with_rebates: p_amount_zar must be positive'
      USING ERRCODE = '22023';
  END IF;
  IF p_cost_per_credit_zar IS NULL OR p_cost_per_credit_zar <= 0 THEN
    RAISE EXCEPTION 'record_purchase_with_rebates: p_cost_per_credit_zar must be positive'
      USING ERRCODE = '22023';
  END IF;

  -- Is this practice a referee? One row max thanks to the PK.
  SELECT * INTO v_referral
    FROM practice_referrals
   WHERE referee_practice_id = p_practice_id
   LIMIT 1;

  -- 1. Insert the purchase ledger row.
  INSERT INTO credit_ledger (practice_id, delta, type, payfast_payment_id, notes)
  VALUES (
    p_practice_id,
    p_credits,
    'purchase',
    p_payfast_payment_id,
    'PayFast ' || COALESCE(p_bundle_key, 'bundle') || ' (' || p_credits::text || ' credits)'
  )
  RETURNING id INTO v_purchase_id;

  -- 2. If this practice has a referrer, book the 5% lifetime rebate.
  IF v_referral.referrer_practice_id IS NOT NULL THEN
    -- Formula: rebate_credits = (amount_zar * 0.05) / cost_per_credit_zar
    v_rebate_credits := ROUND(
      (p_amount_zar * 0.05) / p_cost_per_credit_zar,
      4
    );

    -- Goodwill floor: on the FIRST rebate from this referee to this
    -- referrer, if the raw 5% rebate rounds to < 1 credit, clamp UP to 1.
    -- Subsequent rebates stay at raw fractional 5% with no floor.
    IF NOT COALESCE(v_referral.goodwill_floor_applied, false)
       AND v_rebate_credits < 1 THEN
      v_rebate_credits := 1;
      v_goodwill_applied := true;
    END IF;

    IF v_rebate_credits > 0 THEN
      INSERT INTO referral_rebate_ledger
        (referrer_practice_id, referee_practice_id,
         source_credit_ledger_id, kind, credits, zar_amount)
      VALUES
        (v_referral.referrer_practice_id, v_referral.referee_practice_id,
         v_purchase_id, 'lifetime_rebate', v_rebate_credits, p_amount_zar);
      v_rebate_rows := v_rebate_rows + 1;
    END IF;

    -- Mark the flag on the first rebate (regardless of whether the floor
    -- actually kicked in — "first rebate processed" is the invariant).
    IF NOT COALESCE(v_referral.goodwill_floor_applied, false) THEN
      UPDATE practice_referrals
         SET goodwill_floor_applied = true
       WHERE referee_practice_id = v_referral.referee_practice_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',                 true,
    'purchase_ledger_id', v_purchase_id,
    'rebate_rows',        v_rebate_rows,
    'goodwill_applied',   v_goodwill_applied
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_purchase_with_rebates(
  uuid, integer, numeric, text, text, numeric
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_purchase_with_rebates(
  uuid, integer, numeric, text, text, numeric
) TO service_role;
REVOKE EXECUTE ON FUNCTION public.record_purchase_with_rebates(
  uuid, integer, numeric, text, text, numeric
) FROM authenticated, anon;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
--
-- A. CHECK constraint accepts new kinds:
--    SELECT pg_get_constraintdef(oid)
--      FROM pg_constraint
--     WHERE conrelid = 'public.credit_ledger'::regclass
--       AND contype = 'c';
--    -- expect: list containing 'signup_bonus' and 'referral_signup_bonus'.
--
-- B. Flag column present:
--    \d public.practice_referrals
--    -- expect: goodwill_floor_applied | boolean | not null | default false
--
-- C. Organic signup grants +3 (manual — needs a fresh auth.uid()):
--    -- Under authenticated context with no existing membership:
--    SELECT public.bootstrap_practice_for_user();
--    SELECT type, delta FROM credit_ledger
--     WHERE practice_id = <returned uuid>;
--    -- expect: one row, (signup_bonus, 3).
--
-- D. Referral claim grants +5 on top (manual — needs a real flow):
--    -- After bootstrap_practice_for_user above, a code claim:
--    SELECT public.claim_referral_code(
--      '<active-code>', <returned uuid>, false
--    );
--    -- expect: true, and credit_ledger now has:
--    --   (signup_bonus, 3), (referral_signup_bonus, 5)  → balance 8.
--
-- E. Goodwill floor — first sandbox purchase of R250 / 10 credits:
--    -- Referee practice buys the starter bundle for the first time.
--    --   raw rebate = (250 * 0.05) / 25 = 0.5 credits
--    --   goodwill floor fires → rebate clamped to 1.
--    -- expect: referral_rebate_ledger row with credits=1.0000, kind=lifetime_rebate;
--    --         practice_referrals.goodwill_floor_applied flipped true.
--
-- F. Subsequent purchase R1000 / 40 credits:
--    --   raw rebate = (1000 * 0.05) / 25 = 2.0 credits
--    --   no floor (flag set) → stored as 2.0000.
--    -- expect: referral_rebate_ledger row with credits=2.0000, no clamp.
