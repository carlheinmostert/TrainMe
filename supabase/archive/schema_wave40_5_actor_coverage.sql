-- ============================================================================
-- Wave 40.5 — full actor coverage on the audit feed.
-- ============================================================================
--
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_wave40_5_actor_coverage.sql
--
-- Idempotent: every statement uses ADD COLUMN IF NOT EXISTS, CREATE OR
-- REPLACE, or guarded DROPs. Safe to re-run.
--
-- WHY
--   Carl's directive (Wave 40.1): "The actor should always be populated.
--   Even if system-triggered, it should ultimately be traceable back to a
--   practitioner."
--
--   Wave 40.1 resolved plan.opened + credit.consumption by deriving the
--   actor from plan_issuances.trainer_id at query time. That left 8 kinds
--   still showing NULL actors:
--
--     credit.purchase           — practitioner who clicked "Buy bundle"
--     credit.refund             — practitioner who triggered the refund
--     credit.adjustment         — attribute to practice owner
--     credit.signup_bonus       — the practitioner who signed up
--     credit.referral_signup_bonus — the referee who signed up
--     referral.rebate           — the referrer practice owner
--     client.create             — practitioner who created the client
--     client.delete             — practitioner who triggered it
--
-- WHAT THIS MIGRATION DOES
--
--   1. credit_ledger.trainer_id (uuid, nullable) — stamps the acting
--      practitioner on every new ledger row going forward. NULL on
--      historical rows; the audit query derives the actor at query time
--      for those via fallback to practice owner.
--
--   2. clients.created_by_user_id (uuid, nullable) — stamps the
--      practitioner who created the client.
--
--   3. clients.deleted_by_user_id (uuid, nullable) — stamps the
--      practitioner who soft-deleted the client.
--
--   4. Updated RPCs that stamp these new columns:
--      - consume_credit        → trainer_id = auth.uid()
--      - refund_credit         → trainer_id = auth.uid()
--      - record_purchase_with_rebates → trainer_id from pending_payments
--                                       (new p_trainer_id arg)
--      - bootstrap_practice_for_user  → trainer_id = auth.uid()
--      - claim_referral_code          → trainer_id = auth.uid()
--      - upsert_client / upsert_client_with_id → created_by_user_id
--      - delete_client                → deleted_by_user_id
--      - restore_client               → clears deleted_by_user_id
--
--   5. list_practice_audit extended: ALL formerly-NULL kinds now resolve
--      an actor. credit.* reads cl.trainer_id first, falls back to
--      practice owner. referral.rebate derives the referrer practice
--      owner. client.create/delete reads created_by / deleted_by, falls
--      back to practice owner.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT backfill historical rows. At-query-time derivation via
--     practice owner handles NULL trainer_id gracefully.
--   * Does NOT add a trainer_id column to referral_rebate_ledger — the
--     referrer is always the practice owner, derived at query time.
--   * Does NOT change the RETURNS TABLE shape of list_practice_audit —
--     only the content of trainer_id/email/full_name columns changes.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. credit_ledger.trainer_id
-- ============================================================================

ALTER TABLE public.credit_ledger
  ADD COLUMN IF NOT EXISTS trainer_id uuid;

COMMENT ON COLUMN public.credit_ledger.trainer_id IS
  'Wave 40.5. The practitioner who triggered this ledger entry. NULL on '
  'historical rows pre-40.5; the audit query falls back to practice owner.';

-- ============================================================================
-- 2. clients.created_by_user_id + deleted_by_user_id
-- ============================================================================

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS created_by_user_id uuid;

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS deleted_by_user_id uuid;

COMMENT ON COLUMN public.clients.created_by_user_id IS
  'Wave 40.5. The practitioner who created this client. NULL on pre-40.5 rows.';
COMMENT ON COLUMN public.clients.deleted_by_user_id IS
  'Wave 40.5. The practitioner who soft-deleted this client. Cleared on restore. NULL on pre-40.5 rows.';

-- ============================================================================
-- 3. Update RPCs — stamp trainer_id on credit_ledger inserts
-- ============================================================================

-- 3a. consume_credit — stamp trainer_id = auth.uid()
-- (latest definition from schema_wave39_1_unlock_resets_clock.sql)

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

  -- Wave 40.5: stamp trainer_id
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

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance
  );
END;
$$;

-- 3b. refund_credit — stamp trainer_id = auth.uid()

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

  SELECT * INTO v_consumption
    FROM credit_ledger
   WHERE plan_id = p_plan_id
     AND type    = 'consumption'
   ORDER BY created_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
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
    RETURN false;
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
$$;

REVOKE ALL ON FUNCTION public.refund_credit(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_credit(uuid) TO authenticated;

-- 3c. record_purchase_with_rebates — add p_trainer_id arg

DROP FUNCTION IF EXISTS public.record_purchase_with_rebates(
  uuid, integer, numeric, text, text, numeric
);

CREATE OR REPLACE FUNCTION public.record_purchase_with_rebates(
  p_practice_id           uuid,
  p_credits               integer,
  p_amount_zar            numeric,
  p_payfast_payment_id    text,
  p_bundle_key            text,
  p_cost_per_credit_zar   numeric,
  p_trainer_id            uuid DEFAULT NULL
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

  SELECT * INTO v_referral
    FROM practice_referrals
   WHERE referee_practice_id = p_practice_id
   LIMIT 1;

  -- Wave 40.5: stamp trainer_id on the purchase ledger row
  INSERT INTO credit_ledger (practice_id, delta, type, payfast_payment_id, notes, trainer_id)
  VALUES (
    p_practice_id,
    p_credits,
    'purchase',
    p_payfast_payment_id,
    'PayFast ' || COALESCE(p_bundle_key, 'bundle') || ' (' || p_credits::text || ' credits)',
    p_trainer_id
  )
  RETURNING id INTO v_purchase_id;

  IF v_referral.referrer_practice_id IS NOT NULL THEN
    v_rebate_credits := ROUND(
      (p_amount_zar * 0.05) / p_cost_per_credit_zar,
      4
    );

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
  uuid, integer, numeric, text, text, numeric, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_purchase_with_rebates(
  uuid, integer, numeric, text, text, numeric, uuid
) TO authenticated, service_role;

-- 3d. bootstrap_practice_for_user — stamp trainer_id on signup_bonus

-- Read the full existing function to rebuild it properly.
-- We need the full body from schema_milestone_m_credit_model.sql.

-- We only patch the INSERT INTO credit_ledger call to add trainer_id.
-- Since CREATE OR REPLACE requires the full body, let's grab it.

-- Read the latest bootstrap_practice_for_user:
CREATE OR REPLACE FUNCTION public.bootstrap_practice_for_user()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller    uuid := auth.uid();
  v_existing  uuid;
  v_sentinel  uuid;
  v_new_pid   uuid;
  v_has_bonus boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'bootstrap_practice_for_user requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- (a) Already has a membership? Return the first practice.
  SELECT practice_id INTO v_existing
    FROM practice_members
   WHERE trainer_id = v_caller
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  -- (b) Carl-sentinel practice — claim it if unclaimed.
  SELECT id INTO v_sentinel
    FROM practices
   WHERE name = 'Carl Practice'
     AND NOT EXISTS (
       SELECT 1 FROM practice_members WHERE practice_id = practices.id
     )
   LIMIT 1;

  IF v_sentinel IS NOT NULL THEN
    INSERT INTO practice_members (practice_id, trainer_id, role)
    VALUES (v_sentinel, v_caller, 'owner');
    RETURN v_sentinel;
  END IF;

  -- (c) Fresh personal practice.
  INSERT INTO practices (name)
  VALUES (
    COALESCE(
      (SELECT raw_user_meta_data->>'full_name' FROM auth.users WHERE id = v_caller),
      split_part((SELECT email FROM auth.users WHERE id = v_caller), '@', 1)
    ) || ' Practice'
  )
  RETURNING id INTO v_new_pid;

  INSERT INTO practice_members (practice_id, trainer_id, role)
  VALUES (v_new_pid, v_caller, 'owner');

  -- Grant the organic signup bonus (+3). Idempotency: check first.
  SELECT EXISTS (
    SELECT 1 FROM credit_ledger
     WHERE practice_id = v_new_pid
       AND type = 'signup_bonus'
  ) INTO v_has_bonus;

  IF NOT v_has_bonus THEN
    -- Wave 40.5: stamp trainer_id
    INSERT INTO credit_ledger (practice_id, delta, type, notes, trainer_id)
    VALUES (v_new_pid, 3, 'signup_bonus', 'Organic signup bonus', v_caller);
  END IF;

  RETURN v_new_pid;
END;
$$;

-- 3e. claim_referral_code — stamp trainer_id on referral_signup_bonus
-- Read current from schema_milestone_m_credit_model.sql and patch.

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

  IF v_inserted THEN
    SELECT EXISTS (
      SELECT 1 FROM credit_ledger
       WHERE practice_id = p_referee_practice_id
         AND type = 'referral_signup_bonus'
    ) INTO v_has_bonus;

    IF NOT v_has_bonus THEN
      -- Wave 40.5: stamp trainer_id
      INSERT INTO credit_ledger (practice_id, delta, type, notes, trainer_id)
      VALUES (
        p_referee_practice_id,
        5,
        'referral_signup_bonus',
        'Referral signup bonus (code ' || p_code || ')',
        v_caller
      );
    END IF;
  END IF;

  RETURN true;
END;
$$;

-- 3f. upsert_client — stamp created_by_user_id

CREATE OR REPLACE FUNCTION public.upsert_client(
  p_practice_id uuid,
  p_name        text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller uuid := auth.uid();
  v_id     uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'upsert_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'upsert_client: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'upsert_client: p_name must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'upsert_client: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_id
    FROM clients
   WHERE practice_id = p_practice_id AND name = trim(p_name)
   LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  -- Wave 40.5: stamp created_by_user_id
  INSERT INTO clients (practice_id, name, created_by_user_id)
  VALUES (p_practice_id, trim(p_name), v_caller)
  ON CONFLICT (practice_id, name) DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$fn$;

-- 3g. upsert_client_with_id — stamp created_by_user_id

CREATE OR REPLACE FUNCTION public.upsert_client_with_id(
  p_id          uuid,
  p_practice_id uuid,
  p_name        text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trimmed     text := btrim(coalesce(p_name, ''));
  v_existing_id uuid;
BEGIN
  IF v_trimmed = '' THEN
    RAISE EXCEPTION 'name required' USING ERRCODE = '22023';
  END IF;

  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (SELECT 1 FROM clients WHERE id = p_id) THEN
    RETURN p_id;
  END IF;

  SELECT id INTO v_existing_id
  FROM clients
  WHERE practice_id = p_practice_id AND name = v_trimmed;
  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  -- Wave 40.5: stamp created_by_user_id
  INSERT INTO clients (id, practice_id, name, created_by_user_id)
  VALUES (p_id, p_practice_id, v_trimmed, auth.uid());
  RETURN p_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_client_with_id(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_client_with_id(uuid, uuid, text) TO authenticated;

-- 3h. delete_client — stamp deleted_by_user_id

CREATE OR REPLACE FUNCTION public.delete_client(p_client_id uuid)
 RETURNS TABLE(id uuid, practice_id uuid, name text, deleted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_now          timestamptz := now();
  v_existing_ts  timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'delete_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'delete_client: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_existing_ts
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'delete_client: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF v_existing_ts IS NOT NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  -- Wave 40.5: stamp deleted_by_user_id
  UPDATE clients AS c
     SET deleted_at = v_now,
         updated_at = v_now,
         deleted_by_user_id = v_caller
   WHERE c.id = p_client_id;

  UPDATE plans AS p
     SET deleted_at = v_now
   WHERE p.client_id = p_client_id
     AND p.deleted_at IS NULL;

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$function$;

-- 3i. restore_client — clear deleted_by_user_id

CREATE OR REPLACE FUNCTION public.restore_client(p_client_id uuid)
 RETURNS TABLE(id uuid, practice_id uuid, name text, deleted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
  v_deleted_ts  timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'restore_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'restore_client: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id, c.deleted_at
    INTO v_practice_id, v_deleted_ts
    FROM clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'restore_client: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  IF v_deleted_ts IS NULL THEN
    RETURN QUERY
    SELECT c.id, c.practice_id, c.name, c.deleted_at
      FROM clients c
     WHERE c.id = p_client_id;
    RETURN;
  END IF;

  -- Wave 40.5: clear deleted_by_user_id on restore
  UPDATE clients AS c
     SET deleted_at = NULL,
         updated_at = now(),
         deleted_by_user_id = NULL
   WHERE c.id = p_client_id;

  UPDATE plans AS p
     SET deleted_at = NULL
   WHERE p.client_id = p_client_id
     AND p.deleted_at = v_deleted_ts;

  INSERT INTO audit_events (practice_id, actor_id, kind, ref_id)
  VALUES (v_practice_id, v_caller, 'client.restore', p_client_id);

  RETURN QUERY
  SELECT c.id, c.practice_id, c.name, c.deleted_at
    FROM clients c
   WHERE c.id = p_client_id;
END;
$function$;

-- ============================================================================
-- 4. list_practice_audit — full actor coverage
-- ============================================================================
-- Extends the Wave 40.1 definition. Changes per branch:
--
-- credit_ledger:
--   Previously: only credit.consumption had an actor (via plan_issuances).
--   Now: cl.trainer_id FIRST, then plan_issuances fallback for consumption,
--        then practice owner fallback for all credit.* kinds.
--
-- referral.rebate:
--   Previously: NULL actor.
--   Now: derive the referrer practice owner via practice_members.
--
-- client.create:
--   Previously: NULL actor.
--   Now: clients.created_by_user_id, fallback to practice owner.
--
-- client.delete:
--   Previously: NULL actor.
--   Now: clients.deleted_by_user_id, fallback to practice owner.
-- ============================================================================

DROP FUNCTION IF EXISTS public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
);

CREATE OR REPLACE FUNCTION public.list_practice_audit(
  p_practice_id uuid,
  p_offset      int         DEFAULT 0,
  p_limit       int         DEFAULT 50,
  p_kinds       text[]      DEFAULT NULL,
  p_actor       uuid        DEFAULT NULL,
  p_from        timestamptz DEFAULT NULL,
  p_to          timestamptz DEFAULT NULL
)
RETURNS TABLE (
  ts             timestamptz,
  kind           text,
  trainer_id     uuid,
  email          text,
  full_name      text,
  title          text,
  credits_delta  numeric,
  balance_after  numeric,
  ref_id         uuid,
  meta           jsonb,
  client_id      uuid,
  client_name    text,
  total_count    bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_id uuid;
BEGIN
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  -- Pre-fetch the practice owner for fallback attribution. One query
  -- instead of per-row lateral joins.
  SELECT pm.trainer_id INTO v_owner_id
    FROM practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.role = 'owner'
   LIMIT 1;

  RETURN QUERY
  WITH unioned AS (
    -- ------------------------------------------------------------------
    -- plan_issuances -> kind = 'plan.publish'
    -- ------------------------------------------------------------------
    SELECT
      pi.issued_at                                    AS a_ts,
      'plan.publish'::text                            AS a_kind,
      pi.trainer_id                                   AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      p.title::text                                   AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      pi.plan_id                                      AS a_ref_id,
      jsonb_build_object(
        'version',           pi.version,
        'prepaid_unlock_at', pi.prepaid_unlock_at
      )                                               AS a_meta,
      p.client_id                                     AS a_client_id,
      cli.name::text                                  AS a_client_name
    FROM public.plan_issuances pi
    JOIN public.plans p ON p.id = pi.plan_id
    LEFT JOIN auth.users u ON u.id = pi.trainer_id
    LEFT JOIN public.clients cli ON cli.id = p.client_id
    WHERE pi.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- credit_ledger -> kind = 'credit.' || type
    -- Wave 40.5: full actor coverage.
    --   Priority: cl.trainer_id (stamped on new rows) ->
    --             plan_issuances (for consumption/refund with plan_id) ->
    --             practice owner (fallback for historical rows).
    -- ------------------------------------------------------------------
    SELECT
      cl.created_at                                   AS a_ts,
      ('credit.' || cl.type)::text                    AS a_kind,
      COALESCE(cl.trainer_id, derived_pi.trainer_id, v_owner_id) AS a_trainer_id,
      COALESCE(
        cl_u.email,
        derived_u.email,
        owner_u.email
      )::text                                         AS a_email,
      COALESCE(
        cl_u.raw_user_meta_data->>'full_name',
        derived_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      cl.notes::text                                  AS a_title,
      cl.delta::numeric                               AS a_credits_delta,
      (SUM(cl.delta) OVER (
        ORDER BY cl.created_at, cl.id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ))::numeric                                     AS a_balance_after,
      cl.plan_id                                      AS a_ref_id,
      CASE
        WHEN cl.payfast_payment_id IS NOT NULL
          THEN jsonb_build_object('payfast_payment_id', cl.payfast_payment_id)
        ELSE NULL
      END                                             AS a_meta,
      pl.client_id                                    AS a_client_id,
      cli.name::text                                  AS a_client_name
    FROM public.credit_ledger cl
    LEFT JOIN public.plans pl ON pl.id = cl.plan_id
    LEFT JOIN public.clients cli ON cli.id = pl.client_id
    -- Direct trainer_id lookup (Wave 40.5 rows)
    LEFT JOIN auth.users cl_u ON cl_u.id = cl.trainer_id
    -- Plan-based derivation (consumption/refund with plan_id, pre-40.5)
    LEFT JOIN LATERAL (
      SELECT pi.trainer_id
        FROM public.plan_issuances pi
       WHERE pi.plan_id = cl.plan_id
       ORDER BY pi.issued_at DESC
       LIMIT 1
    ) derived_pi ON cl.plan_id IS NOT NULL AND cl.trainer_id IS NULL
    LEFT JOIN auth.users derived_u ON derived_u.id = derived_pi.trainer_id
    -- Practice owner fallback (pre-40.5 rows without plan_id)
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id
      AND cl.trainer_id IS NULL
      AND derived_pi.trainer_id IS NULL
    WHERE cl.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- referral_rebate_ledger -> kind = 'referral.rebate'
    -- Wave 40.5: derive the referrer practice owner as the actor.
    -- ------------------------------------------------------------------
    SELECT
      rrl.created_at                                  AS a_ts,
      'referral.rebate'::text                         AS a_kind,
      owner_pm.trainer_id                             AS a_trainer_id,
      owner_u.email::text                             AS a_email,
      COALESCE(owner_u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      NULL::text                                      AS a_title,
      rrl.credits::numeric                            AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      rrl.referee_practice_id                         AS a_ref_id,
      jsonb_build_object(
        'referee_practice_id',     rrl.referee_practice_id,
        'source_credit_ledger_id', rrl.source_credit_ledger_id,
        'rebate_kind',             rrl.kind,
        'zar_amount',              rrl.zar_amount
      )                                               AS a_meta,
      NULL::uuid                                      AS a_client_id,
      NULL::text                                      AS a_client_name
    FROM public.referral_rebate_ledger rrl
    LEFT JOIN public.practice_members owner_pm
      ON owner_pm.practice_id = rrl.referrer_practice_id
     AND owner_pm.role = 'owner'
    LEFT JOIN auth.users owner_u ON owner_u.id = owner_pm.trainer_id
    WHERE rrl.referrer_practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- clients (created_at) -> kind = 'client.create'
    -- Wave 40.5: created_by_user_id as actor, fallback to practice owner.
    -- ------------------------------------------------------------------
    SELECT
      c.created_at                                    AS a_ts,
      'client.create'::text                           AS a_kind,
      COALESCE(c.created_by_user_id, v_owner_id)     AS a_trainer_id,
      COALESCE(creator_u.email, owner_u.email)::text  AS a_email,
      COALESCE(
        creator_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      c.id                                            AS a_client_id,
      c.name::text                                    AS a_client_name
    FROM public.clients c
    LEFT JOIN auth.users creator_u ON creator_u.id = c.created_by_user_id
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id AND c.created_by_user_id IS NULL
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NULL

    UNION ALL

    -- ------------------------------------------------------------------
    -- clients (deleted_at) -> kind = 'client.delete'
    -- Wave 40.5: deleted_by_user_id as actor, fallback to practice owner.
    -- ------------------------------------------------------------------
    SELECT
      c.deleted_at                                    AS a_ts,
      'client.delete'::text                           AS a_kind,
      COALESCE(c.deleted_by_user_id, v_owner_id)     AS a_trainer_id,
      COALESCE(deleter_u.email, owner_u.email)::text  AS a_email,
      COALESCE(
        deleter_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      c.id                                            AS a_client_id,
      c.name::text                                    AS a_client_name
    FROM public.clients c
    LEFT JOIN auth.users deleter_u ON deleter_u.id = c.deleted_by_user_id
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id AND c.deleted_by_user_id IS NULL
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NOT NULL

    UNION ALL

    -- ------------------------------------------------------------------
    -- practice_members -> kind = 'member.join'
    -- ------------------------------------------------------------------
    SELECT
      pm.joined_at                                    AS a_ts,
      'member.join'::text                             AS a_kind,
      pm.trainer_id                                   AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      pm.role::text                                   AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      pm.trainer_id                                   AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      NULL::uuid                                      AS a_client_id,
      NULL::text                                      AS a_client_name
    FROM public.practice_members pm
    LEFT JOIN auth.users u ON u.id = pm.trainer_id
    WHERE pm.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- audit_events catchall (member.role_change / member.remove /
    -- practice.rename / client.restore / plan.opened / ...)
    --
    -- plan.opened: derive actor from latest plan_issuance (Wave 40.1).
    -- All other audit_events carry actor_id directly.
    -- ------------------------------------------------------------------
    SELECT
      ae.ts                                           AS a_ts,
      ae.kind                                         AS a_kind,
      COALESCE(ae.actor_id, derived_open_pi.trainer_id) AS a_trainer_id,
      COALESCE(u.email, derived_open_u.email)::text   AS a_email,
      COALESCE(
        u.raw_user_meta_data->>'full_name',
        derived_open_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      NULL::text                                      AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      ae.ref_id                                       AS a_ref_id,
      ae.meta                                         AS a_meta,
      CASE
        WHEN ae.kind LIKE 'plan.%' THEN plan_for_ae.client_id
        WHEN ae.kind LIKE 'client.%' THEN ae.ref_id
        ELSE NULL
      END                                             AS a_client_id,
      CASE
        WHEN ae.kind LIKE 'plan.%' THEN cli_for_plan.name::text
        WHEN ae.kind LIKE 'client.%' THEN cli_for_ae.name::text
        ELSE NULL
      END                                             AS a_client_name
    FROM public.audit_events ae
    LEFT JOIN auth.users u ON u.id = ae.actor_id
    LEFT JOIN public.plans plan_for_ae
      ON ae.kind LIKE 'plan.%' AND plan_for_ae.id = ae.ref_id
    LEFT JOIN public.clients cli_for_plan
      ON cli_for_plan.id = plan_for_ae.client_id
    LEFT JOIN public.clients cli_for_ae
      ON ae.kind LIKE 'client.%' AND cli_for_ae.id = ae.ref_id
    LEFT JOIN LATERAL (
      SELECT pi.trainer_id
        FROM public.plan_issuances pi
       WHERE pi.plan_id = ae.ref_id
       ORDER BY pi.issued_at DESC
       LIMIT 1
    ) derived_open_pi
      ON ae.kind = 'plan.opened' AND ae.actor_id IS NULL
    LEFT JOIN auth.users derived_open_u
      ON derived_open_u.id = derived_open_pi.trainer_id
    WHERE ae.practice_id = p_practice_id
  ),
  filtered AS (
    SELECT *
      FROM unioned un
     WHERE (p_kinds IS NULL OR un.a_kind        = ANY (p_kinds))
       AND (p_actor IS NULL OR un.a_trainer_id  = p_actor)
       AND (p_from  IS NULL OR un.a_ts         >= p_from)
       AND (p_to    IS NULL OR un.a_ts         <= p_to)
  )
  SELECT
    f.a_ts            AS ts,
    f.a_kind          AS kind,
    f.a_trainer_id    AS trainer_id,
    f.a_email         AS email,
    f.a_full_name     AS full_name,
    f.a_title         AS title,
    f.a_credits_delta AS credits_delta,
    f.a_balance_after AS balance_after,
    f.a_ref_id        AS ref_id,
    f.a_meta          AS meta,
    f.a_client_id     AS client_id,
    f.a_client_name   AS client_name,
    COUNT(*) OVER ()::bigint AS total_count
  FROM filtered f
  ORDER BY f.a_ts DESC
  OFFSET GREATEST(p_offset, 0)
  LIMIT  GREATEST(p_limit, 1);
END;
$$;

REVOKE ALL ON FUNCTION public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
) TO authenticated;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
--
-- A. New columns exist:
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'credit_ledger' AND column_name = 'trainer_id';
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'clients' AND column_name IN ('created_by_user_id', 'deleted_by_user_id');
--
-- B. credit.purchase rows now resolve an actor (practice owner for historical):
--   SELECT kind, email FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, ARRAY['credit.purchase'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: email IS NOT NULL (the practice owner).
--
-- C. credit.signup_bonus shows the practitioner who signed up:
--   SELECT kind, email FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, ARRAY['credit.signup_bonus'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: email IS NOT NULL.
--
-- D. referral.rebate shows the referrer practice owner:
--   SELECT kind, email FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, ARRAY['referral.rebate'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: email IS NOT NULL.
--
-- E. client.create / client.delete show the actor:
--   SELECT kind, email FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, ARRAY['client.create','client.delete'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: email IS NOT NULL (created_by_user_id or practice owner).
--
-- F. No NULL actors in the full feed:
--   SELECT kind, email FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 200, NULL, NULL, NULL, NULL
--   ) WHERE email IS NULL;
--   -- Expect: zero rows (or only edge-case audit_events with truly no actor).
-- ============================================================================
