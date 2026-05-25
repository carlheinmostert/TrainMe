-- ============================================================================
-- Safe Mode subscription gate (PR #8 of the self-trainer wave)
-- 2026-05-25 — feat/safe-mode-subscription-gate
--
-- Spec: docs/SELF_TRAINER_WAVE.md § "Safe Mode subscription model"
-- ADR: docs/adr/0021-safe-mode-subscription-credit-denominated.md
-- Brief: docs/sub-agent-briefs/08-safe-mode-subscription-gate.md
--
-- Depends on:
--   * PR #1 (20260525074056_self_trainer_wave.sql) for
--       - practice_members.safe_mode_grandfathered column + backfill
--       - credit_ledger_safe_mode_lookup index (built on `type`, currently
--         a no-op because the CHECK constraint forbade those values)
--
-- This migration introduces three SECURITY DEFINER RPCs and a CHECK widen:
--
--   1. Widens credit_ledger_type_check to allow 'safe_mode_month' +
--      'safe_mode_month_trial'.
--   2. is_in_active_safe_mode_sub(p_user_id uuid) RETURNS boolean — STABLE,
--      gating predicate read by mobile capture entry and the portal.
--   3. start_safe_mode_trial(p_user_id uuid) RETURNS boolean — idempotent;
--      writes one trial row (amount=0) and returns true on first call,
--      false on any subsequent call (one trial per lifetime).
--   4. start_safe_mode_subscription() RETURNS jsonb — atomic 4-credit debit
--      from the caller's chosen practice. SECURITY DEFINER, FOR UPDATE on
--      practices to mirror consume_credit. Called from the web portal only
--      (Reader-App compliance — no in-app prices on mobile).
--
-- Deviations from spec (documented for review):
--   * Spec § 4 uses `credit_ledger.kind`; actual column is `credit_ledger.type`.
--     PR #1 already noted this. We use `type` consistently.
--   * Spec § 5 uses `credit_ledger.amount`; actual column is `delta`. PR #1
--     also already wrote inserts against `delta`; we do the same.
--   * Sub-ROW lookup keys on `trainer_id` (the existing column name for the
--     user FK on credit_ledger), not a new `user_id` column. The new
--     credit_ledger_safe_mode_lookup index (PR #1) is already on
--     `(trainer_id, type, created_at DESC)`.
--   * `credit_ledger.practice_id` is NOT NULL. Trial rows use the caller's
--     personal practice (any single practice the user is a member of —
--     trial rows debit 0 so the practice choice is purely informational).
--     The gating fn ignores practice_id entirely (sub state is user-scoped).
--   * start_safe_mode_subscription is called from the portal where the
--     practice context is explicit (the active practice in the portal
--     header). We accept `p_practice_id` as the debit target, mirroring
--     consume_credit's parameter shape.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Widen the credit_ledger type CHECK to admit the two new kinds
-- ---------------------------------------------------------------------------
-- Pre-flight: source the current constraint definition from pg_constraint
-- (per feedback_schema_migration_column_preservation) — replicated literally
-- below from supabase/migrations/20260511065443_baseline.sql:191 so the
-- existing six values are preserved exactly.
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
    'safe_mode_month_trial'::text
  ]));

COMMENT ON CONSTRAINT credit_ledger_type_check ON public.credit_ledger IS
  'Wave 2026-05-25 (self-trainer PR #8): added safe_mode_month + '
  'safe_mode_month_trial. See docs/SELF_TRAINER_WAVE.md § Safe Mode '
  'subscription model + ADR-0021.';

-- ---------------------------------------------------------------------------
-- 2. is_in_active_safe_mode_sub(p_user_id uuid) — gating predicate
-- ---------------------------------------------------------------------------
-- Returns true if ANY of:
--   (a) grandfathered: practice_members.safe_mode_grandfathered = true
--       on any membership owned by this user.
--   (b) active paid subscription: any 'safe_mode_month' row in the last
--       30 days for this user.
--   (c) active trial: any 'safe_mode_month_trial' row in the last 3 days
--       for this user.
--
-- STABLE because no side effects + idempotent within a transaction.
-- SECURITY DEFINER because the credit_ledger SELECT RLS is scoped to
-- the caller's practice, but the trial/sub rows for a user span every
-- practice they're in; the gating predicate must see all of them.
-- The fn intentionally accepts p_user_id rather than reading auth.uid()
-- so the portal can pass it explicitly when needed (e.g. server-side
-- pre-render); callers from mobile pass auth.uid().
CREATE OR REPLACE FUNCTION public.is_in_active_safe_mode_sub(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    -- Grandfathered: perpetual free Safe Mode for early adopters.
    EXISTS (
      SELECT 1
      FROM practice_members
      WHERE trainer_id = p_user_id
        AND safe_mode_grandfathered = true
    )
    OR EXISTS (
      -- Active paid subscription within 30-day window.
      SELECT 1
      FROM credit_ledger
      WHERE trainer_id = p_user_id
        AND type = 'safe_mode_month'
        AND created_at > now() - INTERVAL '30 days'
    )
    OR EXISTS (
      -- Active trial within 3-day window.
      SELECT 1
      FROM credit_ledger
      WHERE trainer_id = p_user_id
        AND type = 'safe_mode_month_trial'
        AND created_at > now() - INTERVAL '3 days'
    );
$function$;

COMMENT ON FUNCTION public.is_in_active_safe_mode_sub(uuid) IS
  'Self-trainer wave PR #8 — Safe Mode subscription gate predicate. '
  'Reads grandfathered flag + credit_ledger sub/trial rows for the '
  'supplied user. STABLE + SECURITY DEFINER. Returns true if any '
  '(grandfathered, sub <30d, trial <3d) condition is met. Spec: '
  'docs/SELF_TRAINER_WAVE.md § Safe Mode subscription model.';

REVOKE ALL ON FUNCTION public.is_in_active_safe_mode_sub(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_in_active_safe_mode_sub(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_in_active_safe_mode_sub(uuid) TO anon;

-- ---------------------------------------------------------------------------
-- 3. start_safe_mode_trial(p_user_id uuid) — idempotent trial starter
-- ---------------------------------------------------------------------------
-- Writes one safe_mode_month_trial row with delta=0 for the supplied user.
-- Idempotent — if a trial row of this kind already exists for the user
-- (any age), returns false without inserting. Returns true on first-ever
-- trial start.
--
-- practice_id is required NOT NULL on credit_ledger; we use one of the
-- caller's existing memberships (preferring an owner role, falling back
-- to any). The choice is purely informational — sub state is queried
-- per-user, not per-practice.
--
-- Caller authorisation: p_user_id must equal auth.uid(). Anyone signed
-- in can start their own trial; no admin path.
CREATE OR REPLACE FUNCTION public.start_safe_mode_trial(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'start_safe_mode_trial requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'start_safe_mode_trial: p_user_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_user_id <> v_caller THEN
    RAISE EXCEPTION 'start_safe_mode_trial: caller % may only start their own trial', v_caller
      USING ERRCODE = '42501';
  END IF;

  -- Idempotency: any prior trial row (of any age) blocks a new one.
  -- "One trial per lifetime" per spec § Safe Mode subscription model.
  IF EXISTS (
    SELECT 1 FROM credit_ledger
    WHERE trainer_id = p_user_id
      AND type = 'safe_mode_month_trial'
  ) THEN
    RETURN false;
  END IF;

  -- Pick the user's preferred-owner practice as the audit target.
  -- Falls back to ANY membership if no owner role is found.
  SELECT practice_id
    INTO v_practice_id
    FROM practice_members
   WHERE trainer_id = p_user_id
   ORDER BY (role = 'owner') DESC, joined_at ASC
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'start_safe_mode_trial: user % has no practice memberships', p_user_id
      USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO credit_ledger (
    practice_id, delta, type, notes, trainer_id
  ) VALUES (
    v_practice_id,
    0,
    'safe_mode_month_trial',
    'start_safe_mode_trial(): 3-day free trial start',
    p_user_id
  );

  RETURN true;
END;
$function$;

COMMENT ON FUNCTION public.start_safe_mode_trial(uuid) IS
  'Self-trainer wave PR #8 — start the 3-day Safe Mode trial for the '
  'caller. Idempotent: returns true on first call, false thereafter '
  '(one trial per lifetime). Caller must be auth.uid(). practice_id '
  'on the ledger row is purely informational; sub state queries are '
  'per-user. Spec: docs/SELF_TRAINER_WAVE.md § Safe Mode subscription '
  'model.';

REVOKE ALL ON FUNCTION public.start_safe_mode_trial(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_safe_mode_trial(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. start_safe_mode_subscription(p_practice_id) — atomic 4-credit debit
-- ---------------------------------------------------------------------------
-- Mirrors consume_credit pattern: FOR UPDATE on the practice row to prevent
-- concurrent debits beating the balance check. SECURITY DEFINER so the
-- function-owned writes bypass the RPC-only RLS on credit_ledger
-- (REVOKE'd from authenticated by Milestone E).
--
-- Returns jsonb:
--   { ok: true, new_balance: N, ledger_id: uuid } on success
--   { ok: false, reason: 'insufficient_credits', balance: N } on shortfall
--
-- Called from the web portal (manage.homefit.studio/safe-mode). Reader-App
-- compliance forbids in-app purchase flows on mobile; the gating fn
-- (is_in_active_safe_mode_sub) just observes the resulting ledger row.
CREATE OR REPLACE FUNCTION public.start_safe_mode_subscription(p_practice_id uuid)
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

COMMENT ON FUNCTION public.start_safe_mode_subscription(uuid) IS
  'Self-trainer wave PR #8 — debit 4 credits for a 30-day Safe Mode '
  'subscription from the supplied practice. Atomic via FOR UPDATE on '
  'practices (mirrors consume_credit). Returns jsonb {ok, new_balance, '
  'ledger_id} on success or {ok:false, reason:insufficient_credits, '
  'balance} on shortfall. Called from the portal only (Reader-App '
  'compliance). ADR-0021. BILLING-SENSITIVE.';

REVOKE ALL ON FUNCTION public.start_safe_mode_subscription(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_safe_mode_subscription(uuid) TO authenticated;

COMMIT;
