-- ============================================================================
-- Artifact-system Wave 4 + 5 — code-review follow-ups
-- 2026-05-26 — fix/artifact-system-review-followups
--
-- Findings from the post-merge code review of PRs #539 + #541. Sev1 + sev2
-- items rolled into a single migration. Items addressed:
--
--   1. SEV1 — owner-only gate on subscription debit RPCs.
--      `start_brand_skin_trial`, `start_brand_skin_subscription`, AND the
--      existing `start_safe_mode_subscription` (same monetization-bypass
--      class — flagged by the reviewer as a paired fix) now require the
--      caller to be a member with role = 'owner', not any member. The
--      portal UI already gates these surfaces with the owner check; the
--      RPC tightening closes the bypass (any practitioner-role member
--      with the RPC name + a JWT could otherwise drain credits the owner
--      paid for).
--
--      `start_safe_mode_trial` is intentionally NOT widened — it writes a
--      delta=0 ledger row (no credit movement), so any-member is fine.
--
--   2. SEV2 — `practice_brand_skin_state.next_renewal_at` returns NULL
--      when the subscription is fully lapsed (was returning a past date).
--      The Flutter widget tolerates null already.
--
-- Both fixes use CREATE OR REPLACE preserving every existing branch +
-- column per feedback_schema_migration_column_preservation.md. Sources:
--   * `20260525144158_safe_mode_sub_gate.sql` (Safe Mode subscription).
--   * `20260526184005_brand_skin_subscription.sql` (Wave 4).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. start_brand_skin_trial — owner-only
-- ---------------------------------------------------------------------------
-- The trial writes delta=0 BUT consumes the practice's one-time-per-lifetime
-- trial slot. A non-owner could burn that for the owner if any-member is
-- allowed. Plus the trial transitions the practice into the "active" branch
-- of the lapse predicate — material to the public-facing handout chrome.
-- Owner-only is the consistent UX with the paid debit. Both gates now match.
CREATE OR REPLACE FUNCTION public.start_brand_skin_trial(
  p_practice_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_owner     boolean;
  v_ledger_id    uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'start_brand_skin_trial requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'start_brand_skin_trial: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- SEV1 follow-up — was `trainer_id = v_caller` only; now also requires
  -- role = 'owner' to match the paid path and the portal UI gate.
  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
       AND role        = 'owner'
  ) INTO v_is_owner;

  IF NOT v_is_owner THEN
    -- Soft-fail (not RAISE) so the UI can render a friendly chip rather
    -- than show a bare 5xx. The portal already gates non-owners at the
    -- UI level; this is the RPC-level backstop.
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'owner_only'
    );
  END IF;

  -- Idempotency: any prior trial row (of any age) for this practice
  -- blocks a new one. "One trial per practice".
  IF EXISTS (
    SELECT 1 FROM credit_ledger
    WHERE (metadata ->> 'practice_id') = p_practice_id::text
      AND type = 'brand_skin_month_trial'
  ) THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'trial_already_used'
    );
  END IF;

  INSERT INTO credit_ledger (
    practice_id, delta, type, notes, trainer_id, metadata
  ) VALUES (
    p_practice_id,
    0,
    'brand_skin_month_trial',
    'start_brand_skin_trial(): 30-day free trial start',
    v_caller,
    jsonb_build_object('practice_id', p_practice_id::text)
  )
  RETURNING id INTO v_ledger_id;

  RETURN jsonb_build_object(
    'ok',        true,
    'ledger_id', v_ledger_id
  );
END;
$function$;

COMMENT ON FUNCTION public.start_brand_skin_trial(uuid) IS
  'Artifact-system Wave 4 — start the 30-day brand-skin free trial for the '
  'practice. Owner-only (post-review-follow-up 2026-05-26). Idempotent (one '
  'trial per practice). Returns {ok:true, ledger_id} on first call, '
  '{ok:false, reason:trial_already_used} on repeat, {ok:false, '
  'reason:owner_only} on non-owner caller. SECURITY DEFINER + membership '
  '+ owner check. ADR-0029.';

REVOKE ALL ON FUNCTION public.start_brand_skin_trial(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_brand_skin_trial(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. start_brand_skin_subscription — owner-only
-- ---------------------------------------------------------------------------
-- 4-credit atomic debit. Owner-only — only owners hold the credit-balance
-- contract per the same Reader-App pattern as the portal UI. Any
-- practitioner-role member with the RPC name + a JWT could otherwise drain
-- credits the owner paid for, with no consent. SEV1.
CREATE OR REPLACE FUNCTION public.start_brand_skin_subscription(
  p_practice_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_owner     boolean;
  v_balance      integer;
  v_new_balance  integer;
  v_ledger_id    uuid;
  v_credits      integer := 4;   -- 4 credits / month, locked by ADR-0029
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'start_brand_skin_subscription requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'start_brand_skin_subscription: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- SEV1 follow-up — was `trainer_id = v_caller` only; now also requires
  -- role = 'owner'. The portal subscribe page already gates non-owners at
  -- the UI level (`isOwner` check + warning message); this is the RPC-level
  -- backstop that closes the bypass.
  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
       AND role        = 'owner'
  ) INTO v_is_owner;

  IF NOT v_is_owner THEN
    -- Soft-fail (not RAISE) so the UI can render a friendly chip.
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'owner_only'
    );
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
    practice_id, delta, type, notes, trainer_id, metadata
  ) VALUES (
    p_practice_id,
    -v_credits,
    'brand_skin_month',
    'start_brand_skin_subscription(): 4 credits / 30 days',
    v_caller,
    jsonb_build_object('practice_id', p_practice_id::text)
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

COMMENT ON FUNCTION public.start_brand_skin_subscription(uuid) IS
  'Artifact-system Wave 4 — debit 4 credits for a 30-day brand-skin '
  'subscription. Owner-only (post-review-follow-up 2026-05-26). Atomic FOR '
  'UPDATE on practices. Returns jsonb on success or {ok:false, '
  'reason:insufficient_credits | owner_only}. Portal-only entry point '
  '(Reader-App). ADR-0029. BILLING-SENSITIVE. TODO (wave fast-follow): '
  'day-25 renewal-reminder hook lands here.';

REVOKE ALL ON FUNCTION public.start_brand_skin_subscription(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_brand_skin_subscription(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. start_safe_mode_subscription — owner-only (paired sev1 fix)
-- ---------------------------------------------------------------------------
-- Same monetization-bypass class as the brand-skin sub. The reviewer
-- flagged this during the artifact-system audit; closing it here in the
-- same migration is the safest option (one migration to deploy + revert
-- if needed). All existing branches preserved verbatim from
-- 20260525144158_safe_mode_sub_gate.sql.
CREATE OR REPLACE FUNCTION public.start_safe_mode_subscription(p_practice_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_owner     boolean;
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

  -- SEV1 follow-up — was member-only; now requires role = 'owner'. The
  -- /safe-mode/subscribe page already shows the owner-only message in
  -- the UI when role != 'owner'; the RPC was the bypass surface.
  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
       AND role        = 'owner'
  ) INTO v_is_owner;

  IF NOT v_is_owner THEN
    -- Mirror the brand-skin pattern: soft-fail with reason rather than
    -- raise. The portal can render a friendly chip; bare 5xx is bad UX.
    RETURN jsonb_build_object(
      'ok',     false,
      'reason', 'owner_only'
    );
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
  'subscription. Owner-only (post-review-follow-up 2026-05-26). Atomic via '
  'FOR UPDATE on practices. Returns {ok, new_balance, ledger_id} on success '
  'or {ok:false, reason:insufficient_credits | owner_only} on miss. Called '
  'from the portal only (Reader-App compliance). ADR-0021. BILLING-SENSITIVE.';

REVOKE ALL ON FUNCTION public.start_safe_mode_subscription(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_safe_mode_subscription(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. practice_brand_skin_state — NULL next_renewal_at when inactive
-- ---------------------------------------------------------------------------
-- SEV2 follow-up. Was returning `v_latest.created_at + INTERVAL '30 days'`
-- unconditionally; for a row past day 37 that's a past date with no
-- semantic meaning. Set NULL when not active. The Flutter widget tolerates
-- null already (banner renders only on in_grace anyway).
CREATE OR REPLACE FUNCTION public.practice_brand_skin_state(
  p_practice_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_latest       credit_ledger;
  v_active       boolean;
  v_in_grace     boolean;
  v_trial        boolean;
  v_days_left    integer;
  v_next_renew   timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'practice_brand_skin_state requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'practice_brand_skin_state: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- Read-only — any member can see state (the portal banner mounts on
  -- every authenticated page, including non-owners). Owner-only enforcement
  -- happens on the writers above, not here.
  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    -- Soft-fail: return an inactive snapshot instead of raising. The portal
    -- routes practice switches through `?practice=<uuid>` and a stale link
    -- shouldn't crash the page.
    RETURN jsonb_build_object(
      'active',           false,
      'in_grace',         false,
      'trial',            false,
      'days_until_lapse', NULL,
      'next_renewal_at',  NULL
    );
  END IF;

  -- Pick the most recent paid OR trial row, regardless of age. We compute
  -- active / in_grace from the timestamp so a 90-day-old row returns
  -- {active:false} without needing a second query.
  SELECT *
    INTO v_latest
    FROM credit_ledger
   WHERE (metadata ->> 'practice_id') = p_practice_id::text
     AND type = ANY (ARRAY[
           'brand_skin_month'::text,
           'brand_skin_month_trial'::text
         ])
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_latest.id IS NULL THEN
    RETURN jsonb_build_object(
      'active',           false,
      'in_grace',         false,
      'trial',            false,
      'days_until_lapse', NULL,
      'next_renewal_at',  NULL
    );
  END IF;

  v_trial := (v_latest.type = 'brand_skin_month_trial');

  -- Active any time the chrome is still rendering (≤ 37 days from creation).
  v_active   := (v_latest.created_at > now() - INTERVAL '37 days');
  -- In grace = past day 30 but ≤ day 37.
  v_in_grace := (v_latest.created_at <= now() - INTERVAL '30 days')
                AND v_active;

  IF v_active THEN
    v_next_renew := v_latest.created_at + INTERVAL '30 days';
    -- Days remaining until full revert (day 37).
    v_days_left := GREATEST(
      0,
      CEIL(
        EXTRACT(EPOCH FROM (v_latest.created_at + INTERVAL '37 days' - now()))
        / 86400
      )::integer
    );
  ELSE
    -- SEV2 follow-up — when fully lapsed, suppress the would-be past date.
    -- Caller surfaces this as "subscription lapsed, renew to restart".
    v_next_renew := NULL;
    v_days_left  := NULL;
  END IF;

  RETURN jsonb_build_object(
    'active',           v_active,
    'in_grace',         v_in_grace,
    'trial',            v_trial,
    'days_until_lapse', v_days_left,
    'next_renewal_at',  v_next_renew
  );
END;
$function$;

COMMENT ON FUNCTION public.practice_brand_skin_state(uuid) IS
  'Artifact-system Wave 4 — returns a jsonb snapshot of brand-skin '
  'subscription state for the practice: {active, in_grace, trial, '
  'days_until_lapse, next_renewal_at}. next_renewal_at is NULL when not '
  'active (post-review-follow-up 2026-05-26 — was returning a past date). '
  'STABLE + SECURITY DEFINER + membership-checked. ADR-0029.';

REVOKE ALL ON FUNCTION public.practice_brand_skin_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.practice_brand_skin_state(uuid) TO authenticated;

COMMIT;
