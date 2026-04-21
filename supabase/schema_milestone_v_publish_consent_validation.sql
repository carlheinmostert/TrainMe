-- ============================================================================
-- Milestone V — Publish-time consent validation
-- ============================================================================
-- Context: Wave 16 (2026-04-21). A practitioner can set
-- `exercises.preferred_treatment` to 'grayscale' or 'original' while the
-- linked client's `clients.video_consent` has those treatments switched
-- off. Before this migration the publish flow accepted that silently —
-- the client web player would fall back to line-drawing for those
-- exercises with no signal on either side. The 2026-04-21 QA finding
-- (plan dcbdb9ca-984f-424d-bdd8-386098f3992e, client "Garry") motivated
-- this fix.
--
-- What this migration does:
--
--   1. Adds `validate_plan_treatment_consent(p_plan_id uuid)` — a
--      SECURITY DEFINER RPC returning the set of exercises whose
--      `preferred_treatment` is denied by the linked client's consent
--      jsonb. Empty set = pass. Called by the mobile publish pre-flight
--      and (via EXISTS) by `consume_credit` as the authoritative backstop.
--
--   2. Patches `consume_credit(p_practice_id, p_plan_id, p_credits)` so
--      the validation runs AFTER the membership check but BEFORE any
--      ledger write, raising a custom ERRCODE P0003 ("business rule
--      violation") on any violation. This guarantees that even a mobile
--      client that skipped the pre-flight cannot burn credits on a plan
--      with mismatched treatments.
--
-- Idempotent:
--   * The RPC uses CREATE OR REPLACE.
--   * The `consume_credit` patch is a full CREATE OR REPLACE of the
--     function body carried forward from schema_milestone_c.sql with the
--     new IF EXISTS guard inserted between membership and ledger write.
--     Signature and return shape are unchanged.
--
-- Grants:
--   * `validate_plan_treatment_consent` → EXECUTE to `authenticated`;
--     REVOKE from `public, anon` (consent data is practice-private).
--   * `consume_credit` grants carried forward unchanged.
--
-- Rollback: re-apply schema_milestone_c.sql to restore the original
-- `consume_credit` body + `DROP FUNCTION public.validate_plan_treatment_consent(uuid)`.
--
-- Apply: supabase db query --linked --file \
--   supabase/schema_milestone_v_publish_consent_validation.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. validate_plan_treatment_consent
-- ----------------------------------------------------------------------------
-- Returns the set of (exercise_id, preferred_treatment, consent_key) rows
-- whose requested treatment is NOT granted by the plan's client. Empty set
-- means the plan is safe to publish.
--
-- Legacy plans (client_id IS NULL) return empty — there's no client to
-- validate against, and the publish flow is allowed to proceed. Newly
-- published plans always resolve client_id via `upsert_client`, so this
-- branch only covers historic rows that predate Milestone G.
--
-- Treatment → consent key mapping (fixed in spec):
--   'line'      → 'line_drawing' (always true; never blocks — see CLAUDE.md)
--   'grayscale' → 'grayscale'
--   'original'  → 'original'
--
-- `preferred_treatment = 'line'` is intentionally excluded from the
-- output: line-drawing consent is always true by platform design (the
-- pipeline de-identifies; consent can't be withdrawn). The IN clause
-- keeps the query cheap — we never even evaluate the CASE for 'line'.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.validate_plan_treatment_consent(p_plan_id uuid)
RETURNS TABLE (
  exercise_id          uuid,
  preferred_treatment  text,
  consent_key          text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_client_id    uuid;
  v_consent      jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'validate_plan_treatment_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'validate_plan_treatment_consent: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve plan + membership. SECURITY DEFINER bypasses RLS, so we must
  -- check membership explicitly.
  SELECT p.practice_id, p.client_id
    INTO v_practice_id, v_client_id
    FROM public.plans p
   WHERE p.id = p_plan_id
     AND p.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'validate_plan_treatment_consent: plan % not found', p_plan_id
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'validate_plan_treatment_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Legacy plans without client_id: nothing to validate; return empty.
  IF v_client_id IS NULL THEN
    RETURN;
  END IF;

  SELECT c.video_consent
    INTO v_consent
    FROM public.clients c
   WHERE c.id = v_client_id
   LIMIT 1;

  -- Missing consent row (shouldn't happen — FK from plans to clients
  -- guarantees the row exists, and the default is always set). Treat as
  -- no violations rather than blocking — matches get_plan_full's fallback
  -- of "line-drawing only" for robustness.
  IF v_consent IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    e.id                                        AS exercise_id,
    e.preferred_treatment                       AS preferred_treatment,
    CASE e.preferred_treatment
      WHEN 'line'      THEN 'line_drawing'
      WHEN 'grayscale' THEN 'grayscale'
      WHEN 'original'  THEN 'original'
    END                                         AS consent_key
    FROM public.exercises e
   WHERE e.plan_id = p_plan_id
     AND e.preferred_treatment IS NOT NULL
     AND e.preferred_treatment IN ('grayscale', 'original')
     AND COALESCE(
           (v_consent ->> CASE e.preferred_treatment
             WHEN 'grayscale' THEN 'grayscale'
             WHEN 'original'  THEN 'original'
           END)::boolean,
           false
         ) = false
   ORDER BY e.position NULLS LAST, e.id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.validate_plan_treatment_consent(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.validate_plan_treatment_consent(uuid) FROM public, anon;

COMMENT ON FUNCTION public.validate_plan_treatment_consent(uuid) IS
  'Milestone V — Publish-time consent validation. Returns the set of exercises '
  'on a plan whose preferred_treatment is denied by the linked client''s '
  'video_consent. Empty set = safe to publish. Called both by the mobile '
  'pre-flight and by consume_credit as the authoritative backstop.';

-- ----------------------------------------------------------------------------
-- 2. consume_credit — add the IF EXISTS guard
-- ----------------------------------------------------------------------------
-- Full CREATE OR REPLACE carried forward from schema_milestone_c.sql with
-- the single new IF EXISTS block inserted after the membership check and
-- before the ledger write. Everything else (locking, balance recompute,
-- INSERT, return shape) is identical.
--
-- A violation raises SQLSTATE P0003 ('business rule violation'). The
-- mobile client catches this as a typed UnconsentedTreatmentsException
-- and shows the unblock sheet; the server-side pathway is the backstop
-- for any client that skipped the pre-flight.
-- ----------------------------------------------------------------------------

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

  -- Membership check. Must be done explicitly since SECURITY DEFINER bypasses RLS.
  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'consume_credit: caller % is not a member of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Milestone V guard: reject the publish if any exercise on this plan
  -- has a preferred_treatment that the client hasn't consented to. Runs
  -- BEFORE the ledger write so a violation leaves the balance untouched.
  -- The RPC is SECURITY DEFINER + membership-checks internally, so it's
  -- safe to call without additional guarding here.
  IF EXISTS (
    SELECT 1 FROM public.validate_plan_treatment_consent(p_plan_id)
  ) THEN
    RAISE EXCEPTION
      'consume_credit: plan % has exercises with unconsented treatments', p_plan_id
      USING ERRCODE = 'P0003';
  END IF;

  -- Serialise concurrent publishes for the same practice by locking the
  -- practice row. Other publishes for the same practice wait here; publishes
  -- for other practices are unaffected.
  PERFORM 1 FROM practices WHERE id = p_practice_id FOR UPDATE;

  -- Recompute balance under the lock.
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

COMMENT ON FUNCTION public.consume_credit(uuid, uuid, integer) IS
  'Milestone D1 + V. Atomic credit burn for publish. '
  'Milestone V (2026-04-21) added the validate_plan_treatment_consent '
  'backstop — raises SQLSTATE P0003 if any exercise preferred_treatment '
  'isn''t in the linked client''s video_consent.';
