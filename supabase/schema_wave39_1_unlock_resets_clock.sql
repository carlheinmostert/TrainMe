-- ============================================================================
-- Wave 39.1 hotfix — paid unlock resets the 14-day clock on republish.
-- ============================================================================
--
-- Bug: After paying 1 credit to unlock a locked plan and republishing, the
-- plan immediately re-locks because consume_credit's prepaid-unlock fast
-- path only cleared `unlock_credit_prepaid_at`, leaving `first_opened_at`
-- set to the value that triggered the original lock. So the next reconcile
-- still showed >14 days elapsed → SessionShell rendered "Republish costs 1
-- credit" again.
--
-- Policy (per Carl, 2026-04-28): paying for an unlock buys a fresh 14-day
-- grace window starting when the client opens the new version. To deliver
-- that, consume_credit's prepaid-unlock branch ALSO clears
-- `first_opened_at` and `last_opened_at`. The web player's
-- `record_plan_opened` will stamp them again on the next client open,
-- restarting the 14-day clock cleanly.
--
-- This change ONLY applies to the prepaid-unlock fast path. A first-publish
-- consume_credit run leaves first_opened_at NULL (already clean). A
-- normally-charged republish that happened to predate the lock policy is
-- not affected (no prepaid flag was set). So the reset is precisely scoped
-- to "unlock was paid → next publish resets the clock".
--
-- Apply with:
--   supabase db query --linked --file supabase/schema_wave39_1_unlock_resets_clock.sql
--
-- Verify post-apply:
--   1. Set a plan's unlock_credit_prepaid_at + first_opened_at to non-NULL.
--   2. Call consume_credit on it as the practice owner.
--   3. Confirm both unlock_credit_prepaid_at AND first_opened_at are NULL.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.consume_credit(
  p_practice_id uuid,
  p_plan_id     uuid,
  p_credits     integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_balance      integer;
  v_new_balance  integer;
  v_prepaid_at   timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'consume_credit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'consume_credit: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_credits IS NULL OR p_credits <= 0 THEN
    RAISE EXCEPTION 'consume_credit: p_credits must be positive (got %)', p_credits
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

  -- Serialise concurrent publishes for the same practice. Other publishes
  -- for the same practice wait here.
  PERFORM 1 FROM practices WHERE id = p_practice_id FOR UPDATE;

  -- Prepaid-unlock fast path: lock the plan row, read + clear the flag in
  -- one atomic step so a concurrent publisher can't double-spend the
  -- prepaid credit.
  SELECT unlock_credit_prepaid_at
    INTO v_prepaid_at
    FROM plans
   WHERE id = p_plan_id
     AND practice_id = p_practice_id
   FOR UPDATE;

  IF v_prepaid_at IS NOT NULL THEN
    -- Wave 39.1 — also reset first_opened_at + last_opened_at so the
    -- 14-day grace clock restarts cleanly on the next client open.
    -- See migration header for the full rationale.
    UPDATE plans
       SET unlock_credit_prepaid_at = NULL,
           first_opened_at          = NULL,
           last_opened_at           = NULL
     WHERE id = p_plan_id;

    SELECT COALESCE(SUM(delta), 0)::integer
      INTO v_balance
      FROM credit_ledger
     WHERE practice_id = p_practice_id;

    RETURN jsonb_build_object(
      'ok',                true,
      'new_balance',       v_balance,
      'prepaid_unlock_at', v_prepaid_at
    );
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

  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes)
  VALUES (
    p_practice_id,
    -p_credits,
    'consumption',
    p_plan_id,
    'consume_credit(' || p_credits::text || ')'
  );

  v_new_balance := v_balance - p_credits;

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance
  );
END;
$$;
