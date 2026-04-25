-- ============================================================================
-- Wave 29 — explicit unlock-for-edit (post-lock plans) + consent confirmation
-- ============================================================================
--
-- Two intertwined changes:
--
--   1. plans.unlock_credit_prepaid_at — practitioner pre-pays a credit to
--      re-open structural editing on a plan that crossed the
--      `first_opened_at + 3 days` lock boundary. consume_credit honours
--      this flag: when set, the next publish is FREE (the unlock already
--      paid for it) and the flag clears in the same transaction so it
--      can't be re-used.
--
--   2. clients.consent_confirmed_at — stamped by set_client_video_consent
--      on every call. Lets the publish flow gate on "the practitioner has
--      explicitly confirmed consent at least once" without scanning the
--      jsonb for non-default values.
--
-- The lock policy itself ("first_opened_at + 3 days") lives in the mobile
-- Studio UI; this migration is purely the data + atomic prepaid book-
-- keeping. Pre-existing rows stay NULL (no backfill).
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. plans.unlock_credit_prepaid_at
-- ============================================================================

ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS unlock_credit_prepaid_at timestamptz;

COMMENT ON COLUMN public.plans.unlock_credit_prepaid_at IS
  'Wave 29. Stamp set by unlock_plan_for_edit when the practitioner pre-pays '
  'a credit to re-open structural editing on a post-lock plan. consume_credit '
  'reads this on the next republish: if non-NULL, the consumption is skipped '
  '(the unlock already paid) and the flag is cleared in the same transaction. '
  'NULL = no prepaid unlock outstanding.';

-- ============================================================================
-- 2. clients.consent_confirmed_at
-- ============================================================================

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS consent_confirmed_at timestamptz;

COMMENT ON COLUMN public.clients.consent_confirmed_at IS
  'Wave 29. Stamped by set_client_video_consent on every call. Publish flow '
  'gates on this: NULL = practitioner has never explicitly set consent, so '
  'the publish is rejected with a confirmation sheet before any credit '
  'consumption.';

-- ============================================================================
-- 3. set_client_video_consent — stamp consent_confirmed_at on every call.
-- Body otherwise unchanged from Milestone L.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id     uuid,
  p_line_drawing  boolean,
  p_grayscale     boolean,
  p_original      boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_deleted_at   timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_line_drawing IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'set_client_video_consent: line_drawing consent cannot be withdrawn (must be true)'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at INTO v_practice_id, v_deleted_at
    FROM clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_video_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE clients
     SET video_consent = jsonb_build_object(
           'line_drawing', true,
           'grayscale',    COALESCE(p_grayscale, false),
           'original',     COALESCE(p_original, false)
         ),
         consent_confirmed_at = now()
   WHERE id = p_client_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean) FROM anon, public;

-- ============================================================================
-- 4. consume_credit — honour unlock_credit_prepaid_at.
--
-- When the flag is non-NULL the unlock already paid for this republish. We
-- clear the flag (same transaction) and return ok=true with the unchanged
-- balance + a `prepaid_unlock_at` marker so audit logs can prove the
-- republish was free because of a prior unlock.
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
    UPDATE plans
       SET unlock_credit_prepaid_at = NULL
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

GRANT EXECUTE ON FUNCTION public.consume_credit(uuid, uuid, integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.consume_credit(uuid, uuid, integer) FROM public, anon;

-- ============================================================================
-- 5. unlock_plan_for_edit — pre-pay one credit to re-open structural edits.
--
-- Membership-checked, atomic credit consumption (mirrors the consume_credit
-- locking pattern), stamps unlock_credit_prepaid_at. Idempotent on a
-- back-to-back call: if prepaid_at is already set, returns ok=true with
-- the existing stamp and does NOT charge again.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.unlock_plan_for_edit(
  p_plan_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_prepaid_at   timestamptz;
  v_balance      integer;
  v_new_balance  integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unlock_plan_for_edit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'unlock_plan_for_edit: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, unlock_credit_prepaid_at
    INTO v_practice_id, v_prepaid_at
    FROM plans
   WHERE id = p_plan_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'unlock_plan_for_edit: plan % not found', p_plan_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) THEN
    RAISE EXCEPTION 'unlock_plan_for_edit: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Already prepaid (idempotent re-tap from the sheet): return current
  -- balance + the existing stamp. No double-charge.
  IF v_prepaid_at IS NOT NULL THEN
    SELECT COALESCE(SUM(delta), 0)::integer
      INTO v_balance
      FROM credit_ledger
     WHERE practice_id = v_practice_id;
    RETURN jsonb_build_object(
      'ok',          true,
      'balance',     v_balance,
      'prepaid_at',  v_prepaid_at
    );
  END IF;

  PERFORM 1 FROM practices WHERE id = v_practice_id FOR UPDATE;
  PERFORM 1 FROM plans     WHERE id = p_plan_id     FOR UPDATE;

  SELECT COALESCE(SUM(delta), 0)::integer
    INTO v_balance
    FROM credit_ledger
   WHERE practice_id = v_practice_id;

  IF v_balance < 1 THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'reason',  'insufficient_credits',
      'balance', v_balance
    );
  END IF;

  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes)
  VALUES (
    v_practice_id,
    -1,
    'consumption',
    p_plan_id,
    'unlock_plan_for_edit'
  );

  v_new_balance := v_balance - 1;

  UPDATE plans
     SET unlock_credit_prepaid_at = now()
   WHERE id = p_plan_id
  RETURNING unlock_credit_prepaid_at INTO v_prepaid_at;

  RETURN jsonb_build_object(
    'ok',          true,
    'balance',     v_new_balance,
    'prepaid_at',  v_prepaid_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.unlock_plan_for_edit(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.unlock_plan_for_edit(uuid) FROM anon, public;

-- ============================================================================
-- 6. list_practice_clients / get_client_by_id — surface consent_confirmed_at.
--
-- Additive change to the RETURNS TABLE shape. The mobile sync path reads
-- this column to seed the local cache mirror; the portal UI is free to
-- ignore it (PostgREST tolerates extra columns).
--
-- Postgres rejects RETURN TYPE mutation under CREATE OR REPLACE — drop
-- both first, then recreate.
-- ============================================================================

DROP FUNCTION IF EXISTS public.list_practice_clients(uuid);
DROP FUNCTION IF EXISTS public.get_client_by_id(uuid);

CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
RETURNS TABLE (
  id                    uuid,
  name                  text,
  video_consent         jsonb,
  consent_confirmed_at  timestamptz,
  last_plan_at          timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = p_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_practice_clients: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         c.consent_confirmed_at,
         (SELECT MAX(COALESCE(p.sent_at, p.created_at))
            FROM plans p
           WHERE p.client_id = c.id
             AND p.deleted_at IS NULL) AS last_plan_at
    FROM clients c
   WHERE c.practice_id = p_practice_id
     AND c.deleted_at IS NULL
   ORDER BY last_plan_at DESC NULLS LAST, c.name ASC;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.list_practice_clients(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.list_practice_clients(uuid) FROM anon, public;

CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
RETURNS TABLE (
  id                    uuid,
  name                  text,
  video_consent         jsonb,
  consent_confirmed_at  timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_by_id requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = v_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT c.id, c.name, c.video_consent, c.consent_confirmed_at
    FROM clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.get_client_by_id(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_client_by_id(uuid) FROM anon, public;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
--
-- A. Columns exist:
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'plans' AND column_name = 'unlock_credit_prepaid_at';
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'clients' AND column_name = 'consent_confirmed_at';
--
-- B. RPCs callable:
--   SELECT public.unlock_plan_for_edit('<plan-uuid>'::uuid);   -- {ok:true, balance:N, prepaid_at:...}
--   SELECT public.unlock_plan_for_edit('<plan-uuid>'::uuid);   -- idempotent
--
-- C. Republish on a prepaid plan is free:
--   SELECT public.consume_credit('<practice>', '<plan>', 1);   -- {ok:true, prepaid_unlock_at:..., new_balance:N}
--   SELECT public.consume_credit('<practice>', '<plan>', 1);   -- {ok:true, new_balance:N-1}  (flag cleared)
