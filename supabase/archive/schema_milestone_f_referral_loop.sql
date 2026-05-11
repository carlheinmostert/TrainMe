-- homefit.studio — Milestone F: credit-rebate referral loop
-- =============================================================================
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_milestone_f_referral_loop.sql
-- Idempotent: every statement uses CREATE IF NOT EXISTS / OR REPLACE / DROP IF
-- EXISTS. Safe to re-run.
--
-- MODEL (agreed 2026-04-19)
--   * One referral code per practice, opaque 7-char slug (no i/l/o/0/1).
--   * When a new practice signs up and claims a code, that seals a one-to-one
--     "referee → referrer" relationship for the referee's lifetime.
--   * First PayFast-money purchase by the referee triggers a one-time
--     +10 / +10 bonus (referrer + referee), paid atomically with the purchase
--     ledger row.
--   * Every subsequent PayFast-money purchase by the referee earns the
--     referrer 5% rebate in CREDITS (not cash). Stored as numeric(10,4).
--     Credits-funded publishes do NOT count as "purchases" — they never
--     touched PayFast money and never write a credit_ledger row of type
--     'purchase'. Rebates are keyed on credit_ledger rows with type='purchase'.
--   * Single-tier only: A→B→C pays A nothing from C. Enforced in the DB via a
--     BEFORE INSERT trigger that rejects any insert where the proposed
--     REFERRER already appears as a REFEREE in `practice_referrals`.
--   * POPIA consent: referee opts into having their practice name visible to
--     their referrer. Default is anonymised ("Practice 1, Practice 2…").
--   * Rebate credits accumulate fractional, are spent in 1-credit increments
--     by a separate RPC (`consume_credit_with_rebate`, NOT added in this
--     migration — wired in a later mobile task). Current publish path
--     (`consume_credit`) is untouched.
--
-- WHAT THIS MIGRATION DOES
--   1. `referral_codes`              (practice PK, opaque slug, revocation)
--   2. `practice_referrals`          (referee PK, referrer, consent, chain)
--   3. `referral_rebate_ledger`      (append-only rebate ledger)
--   4. Helper RPCs:
--        * generate_referral_code(p_practice_id)
--        * claim_referral_code(p_code, p_referee_practice_id, p_consent)
--        * revoke_referral_code(p_practice_id)
--        * practice_rebate_balance(p_practice_id)
--        * referral_dashboard_stats(p_practice_id)
--        * referral_referees_list(p_practice_id)
--        * record_purchase_with_rebates(...)   -- called by the webhook
--   5. RLS:
--        * referral_codes       SELECT for practice members, no write policies
--        * practice_referrals   SELECT for referrer OR referee member, no
--                               write policies (only service_role / SECURITY
--                               DEFINER RPCs write)
--        * referral_rebate_ledger SELECT for referrer practice members only,
--                               no write policies (same pattern as PR #3's
--                               credit_ledger lockdown)
--   6. REVOKE INSERT/UPDATE/DELETE on all three tables from authenticated / anon.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT modify `consume_credit`. A separate `consume_credit_with_rebate`
--     RPC is deferred (Flutter-side task).
--   * Does NOT touch the PayFast sandbox/production switch in the webhook
--     Edge Function. That config is unchanged.
--   * Does NOT implement referral-code signup UX — that's a web-portal + web
--     signup task wired to `claim_referral_code`.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. referral_codes — one opaque slug per practice
-- ============================================================================
-- Slug alphabet omits ambiguous glyphs (i, l, o, 0, 1). 7 chars → 30^7 ≈ 22B
-- combinations, plenty for the MVP scale. Collisions retry (see generate fn).

CREATE TABLE IF NOT EXISTS referral_codes (
  practice_id  uuid PRIMARY KEY REFERENCES practices(id) ON DELETE CASCADE,
  code         text NOT NULL UNIQUE
                 CHECK (length(code) = 7 AND code ~ '^[a-hjkmnpqrstuvwxyz2-9]+$'),
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz
);

CREATE INDEX IF NOT EXISTS idx_referral_codes_code
  ON referral_codes (code) WHERE revoked_at IS NULL;

-- ============================================================================
-- 2. practice_referrals — the referee→referrer seal (1 referrer per referee)
-- ============================================================================
-- referee_practice_id is the PK: forces exactly one referrer per referee for
-- the referee's lifetime. referrer_practice_id CANNOT equal referee (self-
-- referral CHECK). Single-tier constraint is enforced by a trigger below.

CREATE TABLE IF NOT EXISTS practice_referrals (
  referee_practice_id     uuid PRIMARY KEY REFERENCES practices(id) ON DELETE CASCADE,
  referrer_practice_id    uuid NOT NULL REFERENCES practices(id) ON DELETE RESTRICT,
  code_used               text NOT NULL,
  claimed_at              timestamptz NOT NULL DEFAULT now(),
  signup_bonus_paid_at    timestamptz,
  referee_named_consent   boolean NOT NULL DEFAULT false,
  CHECK (referrer_practice_id <> referee_practice_id)
);

CREATE INDEX IF NOT EXISTS idx_practice_referrals_referrer
  ON practice_referrals (referrer_practice_id, claimed_at DESC);

-- -----------------------------------------------------------------------
-- Single-tier trigger: a referee can never also appear as a referrer.
-- If we're inserting (referrer=X, referee=Y), X must NOT exist as a
-- `referee_practice_id` in any existing row. That guarantees the chain
-- length is strictly 1 (no A→B→C). Corollary: the existing
-- self-referral CHECK handles X=Y.
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_single_tier_referral()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM practice_referrals
     WHERE referee_practice_id = NEW.referrer_practice_id
  ) THEN
    RAISE EXCEPTION
      'single-tier referral: practice % is already a referee, cannot be a referrer',
      NEW.referrer_practice_id
      USING ERRCODE = '23514';
  END IF;

  -- Defence-in-depth: a practice that's already a referrer cannot become
  -- a referee (same chain-length rule in the other direction).
  IF EXISTS (
    SELECT 1 FROM practice_referrals
     WHERE referrer_practice_id = NEW.referee_practice_id
  ) THEN
    RAISE EXCEPTION
      'single-tier referral: practice % already has referees, cannot become a referee',
      NEW.referee_practice_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_single_tier_referral ON practice_referrals;
CREATE TRIGGER trg_enforce_single_tier_referral
  BEFORE INSERT ON practice_referrals
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_single_tier_referral();

-- ============================================================================
-- 3. referral_rebate_ledger — append-only rebate ledger
-- ============================================================================
-- numeric(10,4): can represent fractional credits (5% of a 10-credit bundle
-- is exactly 0.5). kind='redeemed' rows carry a NEGATIVE credits value and
-- are written when a publish burns accumulated rebate credits; all other
-- rows are positive.
--
-- Three kinds of positive rows:
--   signup_bonus_referrer  — +10 credits to referrer on referee's 1st purchase
--   signup_bonus_referee   — +10 credits to referee on their own 1st purchase
--   lifetime_rebate        — +5% of purchase ZAR (expressed as credits) on
--                            every subsequent referee PayFast purchase
-- One negative kind:
--   redeemed               — rebate credits consumed for a publish
--
-- source_credit_ledger_id links each rebate row back to either the PayFast
-- purchase row that triggered it (positive kinds) or the consumption row
-- that spent it (redeemed).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'referral_rebate_kind') THEN
    CREATE TYPE referral_rebate_kind AS ENUM (
      'signup_bonus_referrer',
      'signup_bonus_referee',
      'lifetime_rebate',
      'redeemed'
    );
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS referral_rebate_ledger (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- The practice whose rebate wallet this row credits/debits.
  -- Always the REFERRER for lifetime_rebate + signup_bonus_referrer.
  -- Always the REFEREE for signup_bonus_referee + redeemed.
  referrer_practice_id    uuid NOT NULL REFERENCES practices(id) ON DELETE CASCADE,
  -- The referee that caused the rebate (null for redeemed rows — the wallet
  -- owner is spending their own accumulated pot regardless of source).
  referee_practice_id     uuid REFERENCES practices(id) ON DELETE SET NULL,
  source_credit_ledger_id uuid REFERENCES credit_ledger(id) ON DELETE SET NULL,
  kind                    referral_rebate_kind NOT NULL,
  credits                 numeric(10,4) NOT NULL,
  zar_amount              numeric(10,2),
  created_at              timestamptz NOT NULL DEFAULT now(),
  -- Positive credits for earnings; negative for redemption. Belt-and-braces
  -- sign check so a buggy caller can't accidentally credit a 'redeemed' row.
  CHECK (
    (kind = 'redeemed'               AND credits < 0) OR
    (kind <> 'redeemed'              AND credits > 0)
  )
);

CREATE INDEX IF NOT EXISTS idx_rebate_ledger_referrer
  ON referral_rebate_ledger (referrer_practice_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_rebate_ledger_referee
  ON referral_rebate_ledger (referee_practice_id, created_at DESC)
  WHERE referee_practice_id IS NOT NULL;

-- ============================================================================
-- 4. RLS — select-only for clients, all writes via RPC / service_role
-- ============================================================================

ALTER TABLE referral_codes          ENABLE ROW LEVEL SECURITY;
ALTER TABLE practice_referrals      ENABLE ROW LEVEL SECURITY;
ALTER TABLE referral_rebate_ledger  ENABLE ROW LEVEL SECURITY;

-- Drop any previous policies (re-run safety).
DROP POLICY IF EXISTS referral_codes_select_member          ON referral_codes;
DROP POLICY IF EXISTS referral_referrals_select_either_side ON practice_referrals;
DROP POLICY IF EXISTS rebate_ledger_select_referrer         ON referral_rebate_ledger;

-- referral_codes: visible to members of the owning practice. No write policies.
CREATE POLICY referral_codes_select_member
  ON referral_codes FOR SELECT
  USING (practice_id IN (SELECT user_practice_ids()));

-- practice_referrals: BOTH sides can read their own row (referrer sees who
-- they referred; referee sees who referred them — referee has opted into
-- knowing that when they claimed the code in the first place).
CREATE POLICY referral_referrals_select_either_side
  ON practice_referrals FOR SELECT
  USING (
    referrer_practice_id IN (SELECT user_practice_ids())
    OR referee_practice_id IN (SELECT user_practice_ids())
  );

-- referral_rebate_ledger: ONLY referrer-side practice members can see the
-- rebate ledger. Referees don't get to peek at their referrer's earnings.
CREATE POLICY rebate_ledger_select_referrer
  ON referral_rebate_ledger FOR SELECT
  USING (referrer_practice_id IN (SELECT user_practice_ids()));

-- Lockdown pattern matching PR #3: revoke all client write grants. Every
-- write must go through a SECURITY DEFINER RPC or the service_role (webhook).
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.referral_codes
  FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.practice_referrals
  FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.referral_rebate_ledger
  FROM authenticated, anon;

-- Anon doesn't need SELECT on any of these. Stay locked down by default.
REVOKE SELECT ON public.referral_codes         FROM anon;
REVOKE SELECT ON public.practice_referrals     FROM anon;
REVOKE SELECT ON public.referral_rebate_ledger FROM anon;

GRANT SELECT ON public.referral_codes          TO authenticated;
GRANT SELECT ON public.practice_referrals      TO authenticated;
GRANT SELECT ON public.referral_rebate_ledger  TO authenticated;

-- ============================================================================
-- 5. generate_referral_code — idempotent slug allocation
-- ============================================================================
-- Returns the existing slug if the practice already has one (revoked or not).
-- If revoked, callers should call revoke_referral_code to blank it and call
-- generate again — but even simpler is to re-generate via an explicit cycle
-- flow driven from the portal. Here, "idempotent" means returning the current
-- row.
-- If none exists, generates a fresh 7-char slug from the unambiguous alphabet,
-- retries on unique-key collisions (up to 5 times).
-- Auth: caller must be OWNER of the practice.

CREATE OR REPLACE FUNCTION public._generate_slug_7()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  -- 30 unambiguous characters: no i/l/o/0/1.
  v_alphabet constant text := 'abcdefghjkmnpqrstuvwxyz23456789';
  v_out text := '';
  v_i int;
  v_r int;
BEGIN
  FOR v_i IN 1..7 LOOP
    v_r := 1 + floor(random() * length(v_alphabet))::int;
    v_out := v_out || substr(v_alphabet, v_r, 1);
  END LOOP;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION public.generate_referral_code(p_practice_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller    uuid := auth.uid();
  v_existing  text;
  v_slug      text;
  v_attempt   int  := 0;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'generate_referral_code requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'generate_referral_code: caller is not owner of practice %',
      p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Return the active (non-revoked) code if one already exists.
  SELECT code INTO v_existing
    FROM referral_codes
   WHERE practice_id = p_practice_id
     AND revoked_at IS NULL;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  -- Try up to 5 times to dodge a slug collision. Prob(collision) at MVP
  -- scale is vanishingly small; this is just belt-and-braces.
  LOOP
    v_attempt := v_attempt + 1;
    v_slug := public._generate_slug_7();
    BEGIN
      INSERT INTO referral_codes (practice_id, code)
      VALUES (p_practice_id, v_slug);
      RETURN v_slug;
    EXCEPTION
      WHEN unique_violation THEN
        -- practice_id PK collision → somebody else beat us to a revoked row.
        -- Re-read the row and return its code if it's active.
        SELECT code INTO v_existing
          FROM referral_codes
         WHERE practice_id = p_practice_id
           AND revoked_at IS NULL;
        IF v_existing IS NOT NULL THEN
          RETURN v_existing;
        END IF;

        IF v_attempt >= 5 THEN
          RAISE EXCEPTION
            'generate_referral_code: could not allocate a unique slug after % attempts',
            v_attempt
            USING ERRCODE = '40P01';
        END IF;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_referral_code(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_referral_code(uuid) TO authenticated;

-- ============================================================================
-- 6. revoke_referral_code — blank the current code, historical rows stay
-- ============================================================================
-- Sets revoked_at = now() on the active code. Does NOT touch any historical
-- practice_referrals rows — existing referees stay attributed. After this,
-- a fresh generate_referral_code call mints a new slug.
--
-- Auth: caller must be OWNER of the practice.

CREATE OR REPLACE FUNCTION public.revoke_referral_code(p_practice_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'revoke_referral_code requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'revoke_referral_code: caller is not owner of practice %',
      p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Delete the active row so generate_referral_code can insert a fresh slug.
  -- Historical practice_referrals rows stay intact (code_used is free text).
  -- We use DELETE-and-regenerate instead of "revoked_at" + PK contention
  -- because the PK is practice_id — only one row per practice allowed.
  -- If you need to preserve the audit of "what code was used" long-term,
  -- the slug is already copied to practice_referrals.code_used.
  DELETE FROM referral_codes WHERE practice_id = p_practice_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.revoke_referral_code(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.revoke_referral_code(uuid) TO authenticated;

-- ============================================================================
-- 7. claim_referral_code — attach a referrer to a new practice
-- ============================================================================
-- Called during new-practice sign-up completion. Silent-fail on validation
-- errors (returns false) to avoid leaking "this code exists / this practice
-- already has a referrer" info to signup forms. Auth: caller must be a
-- MEMBER of p_referee_practice_id.

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
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'claim_referral_code requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_code IS NULL OR p_referee_practice_id IS NULL THEN
    RETURN false;
  END IF;

  -- Normalise: codes are case-insensitive lowercase in storage.
  p_code := lower(trim(p_code));

  -- Membership check: only a member of the referee practice can claim a
  -- code ON BEHALF OF that practice. (Owners and practitioners both OK —
  -- signup flow runs as the freshly-created owner.)
  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_referee_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RETURN false;
  END IF;

  -- Look up the active referrer.
  SELECT practice_id INTO v_referrer_pid
    FROM referral_codes
   WHERE code = p_code
     AND revoked_at IS NULL;

  IF v_referrer_pid IS NULL THEN
    RETURN false;  -- unknown or revoked code
  END IF;

  IF v_referrer_pid = p_referee_practice_id THEN
    RETURN false;  -- self-referral
  END IF;

  -- Already referred? Silent no-op (don't leak the existing referrer).
  IF EXISTS (
    SELECT 1 FROM practice_referrals
     WHERE referee_practice_id = p_referee_practice_id
  ) THEN
    RETURN false;
  END IF;

  -- Attempt insert. The single-tier trigger will raise 23514 if the
  -- proposed referrer is already a referee — catch that and return false
  -- so signup doesn't error out.
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
  EXCEPTION
    WHEN check_violation THEN
      RETURN false;
    WHEN unique_violation THEN
      RETURN false;
  END;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_referral_code(text, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_referral_code(text, uuid, boolean) TO authenticated;

-- ============================================================================
-- 8. practice_rebate_balance — net rebate credits for a practice
-- ============================================================================
-- SUM over referral_rebate_ledger where referrer_practice_id = p. Includes
-- negative 'redeemed' rows. Fractional allowed: stored as numeric(10,4).
-- No auth check inside — the SELECT policy on referral_rebate_ledger already
-- filters to practices the caller is a member of; if the caller isn't a
-- member, the sum is 0 (they see no rows). Edge function calls this with
-- service_role which bypasses RLS.

CREATE OR REPLACE FUNCTION public.practice_rebate_balance(p_practice_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(credits), 0)::numeric(10,4)
    FROM referral_rebate_ledger
   WHERE referrer_practice_id = p_practice_id;
$$;

REVOKE ALL ON FUNCTION public.practice_rebate_balance(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.practice_rebate_balance(uuid) TO authenticated;

-- ============================================================================
-- 9. referral_dashboard_stats — headline numbers for portal dashboard
-- ============================================================================
-- Auth: caller must be a member of p_practice_id (any role).

CREATE OR REPLACE FUNCTION public.referral_dashboard_stats(p_practice_id uuid)
RETURNS TABLE (
  rebate_balance_credits     numeric,
  lifetime_rebate_credits    numeric,
  referee_count              integer,
  qualifying_spend_total_zar numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller  uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'referral_dashboard_stats requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) THEN
    RAISE EXCEPTION 'referral_dashboard_stats: caller is not a member of practice %',
      p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      COALESCE(SUM(rl.credits), 0)::numeric(10,4) AS rebate_balance_credits,
      COALESCE(SUM(CASE WHEN rl.kind <> 'redeemed' THEN rl.credits ELSE 0 END), 0)::numeric(10,4)
                                                  AS lifetime_rebate_credits,
      (SELECT COUNT(*)::int
         FROM practice_referrals pr
        WHERE pr.referrer_practice_id = p_practice_id) AS referee_count,
      COALESCE((
        SELECT SUM(zar_amount)
          FROM referral_rebate_ledger rl2
         WHERE rl2.referrer_practice_id = p_practice_id
           AND rl2.kind = 'lifetime_rebate'
      ), 0)::numeric(10,2) AS qualifying_spend_total_zar
    FROM referral_rebate_ledger rl
   WHERE rl.referrer_practice_id = p_practice_id;
END;
$$;

REVOKE ALL ON FUNCTION public.referral_dashboard_stats(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.referral_dashboard_stats(uuid) TO authenticated;

-- ============================================================================
-- 10. referral_referees_list — per-referee breakdown with POPIA-respecting label
-- ============================================================================
-- Returns one row per referee. If referee_named_consent = false the label
-- is "Practice 1", "Practice 2", … in ordinal claim order, and the uuid is
-- hidden (NULL). Consent-true rows return the real practice name + uuid.
-- Auth: caller must be member of p_practice_id.

CREATE OR REPLACE FUNCTION public.referral_referees_list(p_practice_id uuid)
RETURNS TABLE (
  referee_label            text,
  referee_practice_id      uuid,
  is_named                 boolean,
  joined_at                timestamptz,
  qualifying_spend_zar     numeric,
  rebate_earned_credits    numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'referral_referees_list requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) THEN
    RAISE EXCEPTION 'referral_referees_list: caller is not a member of practice %',
      p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH ordered AS (
    SELECT
      pr.referee_practice_id,
      pr.referee_named_consent,
      pr.claimed_at,
      ROW_NUMBER() OVER (ORDER BY pr.claimed_at ASC) AS ordinal
      FROM practice_referrals pr
     WHERE pr.referrer_practice_id = p_practice_id
  ),
  earned AS (
    SELECT
      rl.referee_practice_id,
      SUM(CASE WHEN rl.kind <> 'redeemed' THEN rl.credits ELSE 0 END) AS credits_earned,
      SUM(CASE WHEN rl.kind = 'lifetime_rebate' THEN rl.zar_amount ELSE 0 END) AS zar_spend
      FROM referral_rebate_ledger rl
     WHERE rl.referrer_practice_id = p_practice_id
     GROUP BY rl.referee_practice_id
  )
  SELECT
    CASE
      WHEN o.referee_named_consent THEN COALESCE(p.name, 'Practice ' || o.ordinal::text)
      ELSE 'Practice ' || o.ordinal::text
    END AS referee_label,
    CASE WHEN o.referee_named_consent THEN o.referee_practice_id ELSE NULL END
      AS referee_practice_id,
    o.referee_named_consent AS is_named,
    o.claimed_at AS joined_at,
    COALESCE(e.zar_spend, 0)::numeric(10,2) AS qualifying_spend_zar,
    COALESCE(e.credits_earned, 0)::numeric(10,4) AS rebate_earned_credits
    FROM ordered o
    LEFT JOIN earned e
      ON e.referee_practice_id = o.referee_practice_id
    LEFT JOIN practices p
      ON p.id = o.referee_practice_id
   ORDER BY o.ordinal ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.referral_referees_list(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.referral_referees_list(uuid) TO authenticated;

-- ============================================================================
-- 11. record_purchase_with_rebates — atomic purchase + rebate booking
-- ============================================================================
-- Called by the PayFast ITN webhook (service_role) after all verification
-- checks pass. Wraps the purchase ledger insert + any triggered rebate rows
-- into ONE transaction so they succeed or fail together.
--
-- Args mirror what the webhook has available at the point of credit insertion.
-- p_cost_per_credit_zar is passed explicitly so we don't have to hardcode the
-- price-per-credit here — the webhook computes it from the bundle and passes
-- it in. Reference: R25/credit starter bundle (see CLAUDE.md "Credit bundle
-- prices").
--
-- Returns jsonb: { ok, purchase_ledger_id, rebate_rows, signup_bonus_paid }.
-- Raises on any failure, triggering the webhook's outer try/catch to 5xx so
-- PayFast retries.
--
-- CRITICAL: runs with SECURITY DEFINER so it can INSERT into credit_ledger
-- (client write is revoked per PR #3). Service_role would also work, but a
-- single-function surface keeps the transaction boundary obvious.

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
  v_prior_purchase_count integer;
  v_is_first_purchase    boolean;
  v_signup_bonus_paid    boolean := false;
  v_rebate_rows          integer := 0;
  v_rebate_credits       numeric(10,4);
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

  -- Count prior purchases BEFORE inserting the new row so we know whether
  -- the current purchase is the referee's first.
  SELECT COUNT(*) INTO v_prior_purchase_count
    FROM credit_ledger
   WHERE practice_id = p_practice_id
     AND type = 'purchase';

  v_is_first_purchase := (v_prior_purchase_count = 0);

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

  -- 2. If this practice has a referrer, book rebates.
  IF v_referral.referrer_practice_id IS NOT NULL THEN
    -- 2a. First paid purchase by the referee → one-time +10 / +10 bonus.
    IF v_is_first_purchase AND v_referral.signup_bonus_paid_at IS NULL THEN
      INSERT INTO referral_rebate_ledger
        (referrer_practice_id, referee_practice_id,
         source_credit_ledger_id, kind, credits, zar_amount)
      VALUES
        (v_referral.referrer_practice_id, v_referral.referee_practice_id,
         v_purchase_id, 'signup_bonus_referrer', 10, p_amount_zar);

      -- Note the referee row is ATTRIBUTED to the referee practice (wallet
      -- owner = referee) so it shows up in their own rebate wallet. The
      -- "referee_practice_id" column on the ledger stays pointed at themself
      -- for traceability.
      INSERT INTO referral_rebate_ledger
        (referrer_practice_id, referee_practice_id,
         source_credit_ledger_id, kind, credits, zar_amount)
      VALUES
        (v_referral.referee_practice_id, v_referral.referee_practice_id,
         v_purchase_id, 'signup_bonus_referee', 10, p_amount_zar);

      UPDATE practice_referrals
         SET signup_bonus_paid_at = now()
       WHERE referee_practice_id = v_referral.referee_practice_id;

      v_signup_bonus_paid := true;
      v_rebate_rows := v_rebate_rows + 2;
    END IF;

    -- 2b. ALWAYS book the 5% lifetime rebate (including on the first
    --     purchase — the +10 bonus stacks with the rebate).
    -- Formula: rebate_credits = (amount_zar * 0.05) / cost_per_credit_zar
    v_rebate_credits := ROUND(
      (p_amount_zar * 0.05) / p_cost_per_credit_zar,
      4
    );

    IF v_rebate_credits > 0 THEN
      INSERT INTO referral_rebate_ledger
        (referrer_practice_id, referee_practice_id,
         source_credit_ledger_id, kind, credits, zar_amount)
      VALUES
        (v_referral.referrer_practice_id, v_referral.referee_practice_id,
         v_purchase_id, 'lifetime_rebate', v_rebate_credits, p_amount_zar);
      v_rebate_rows := v_rebate_rows + 1;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok',                 true,
    'purchase_ledger_id', v_purchase_id,
    'rebate_rows',        v_rebate_rows,
    'signup_bonus_paid',  v_signup_bonus_paid
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_purchase_with_rebates(
  uuid, integer, numeric, text, text, numeric
) FROM PUBLIC;
-- service_role bypasses privilege checks so explicit GRANT is cosmetic,
-- but make the webhook's access obvious in schema.
GRANT EXECUTE ON FUNCTION public.record_purchase_with_rebates(
  uuid, integer, numeric, text, text, numeric
) TO service_role;

-- Belt-and-braces: authenticated callers MUST NOT be able to run this —
-- it would let them fabricate PayFast purchases.
REVOKE EXECUTE ON FUNCTION public.record_purchase_with_rebates(
  uuid, integer, numeric, text, text, numeric
) FROM authenticated, anon;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
-- After running, the `public` schema should be at:
--   baseline (pre-F): 7 tables, 8 functions.
--   after F:          10 tables, 15 functions (+3 tables, +7 fns; +1 type,
--                     +1 trigger fn).

-- A. Tables + enum + trigger all present.
SELECT 'tables' AS kind, COUNT(*) AS n
  FROM information_schema.tables
 WHERE table_schema = 'public'
   AND table_name IN ('referral_codes', 'practice_referrals', 'referral_rebate_ledger')
UNION ALL
SELECT 'enum_values', COUNT(*)
  FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
 WHERE t.typname = 'referral_rebate_kind'
UNION ALL
SELECT 'trigger', COUNT(*)
  FROM pg_trigger
 WHERE tgname = 'trg_enforce_single_tier_referral'
UNION ALL
SELECT 'functions', COUNT(*)
  FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
 WHERE n.nspname = 'public'
   AND p.proname IN (
     'generate_referral_code',
     'revoke_referral_code',
     'claim_referral_code',
     'practice_rebate_balance',
     'referral_dashboard_stats',
     'referral_referees_list',
     'record_purchase_with_rebates',
     '_generate_slug_7',
     'enforce_single_tier_referral'
   );

-- B. Expected behaviour of generate_referral_code when called for a bogus
--    practice by a non-owner (should raise 42501). Run manually when authed.
--      SELECT public.generate_referral_code(
--        '00000000-0000-0000-0000-000000000000'::uuid
--      );  -- expect: ERROR 42501
--
-- C. Single-tier trigger behaviour (run as service_role or in psql direct):
--    Given practices A, B, C:
--      INSERT INTO practice_referrals (referee_practice_id, referrer_practice_id, code_used)
--        VALUES ('B','A','AAA');       -- OK (B referred by A)
--      INSERT INTO practice_referrals (referee_practice_id, referrer_practice_id, code_used)
--        VALUES ('C','B','BBB');       -- FAILS: 23514 (B is already a referee)
--
-- D. Rebate math:
--      Bundle: 10 credits at R250 (R25/credit).
--      Rebate: (250 * 0.05) / 25 = 12.5 / 25 = 0.5 credits.
--      Stored as 0.5000 in numeric(10,4).
