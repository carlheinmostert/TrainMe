-- ============================================================================
-- Milestone E (hardening) — revoke client write access to credit_ledger
-- ============================================================================
--
-- WHY
--   `credit_ledger` is the append-only billing source of truth. Every plan
--   publish deducts credits; every PayFast purchase adds them. If a client
--   (Flutter app, web portal) could INSERT/UPDATE/DELETE rows directly, a
--   malicious or buggy client could fabricate refunds, duplicate purchases,
--   or mutate past consumption rows.
--
--   The app already goes through SECURITY DEFINER RPCs for every write:
--     * consume_credit(p_practice_id, p_plan_id, p_credits)
--     * refund_credit(p_plan_id)
--   Both are owned by `postgres` so revoking table privileges from the
--   `authenticated` / `anon` roles does NOT affect them — SECURITY DEFINER
--   functions run with the owner's rights.
--
--   Purchases land via the PayFast ITN webhook (`supabase/functions/payfast-
--   webhook/`) and the sandbox bounce-back path (`web-portal/src/app/credits/
--   return/page.tsx`). Both use the Supabase service_role key, which bypasses
--   both RLS and these grants. So those paths keep working.
--
-- WHAT THIS MIGRATION DOES
--   1. Revokes INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on
--      `credit_ledger` from `authenticated` and `anon`. SELECT stays for
--      `authenticated` (future audit UI will want it; RLS already limits
--      rows to the caller's practice).
--   2. Drops the permissive RLS policy `credit_ledger_insert_own` that
--      previously allowed any practice-member to INSERT. With the table
--      grant gone the policy is redundant; removing it reduces surface area
--      and makes the "RPC-only writes" invariant obvious in pg_policy.
--   3. Keeps the SELECT policy `credit_ledger_select_own` (scoped to
--      `user_practice_ids()`).
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT change the RPC definitions. `consume_credit` and
--     `refund_credit` continue to work unchanged.
--   * Does NOT revoke anything from `postgres` or `service_role`. Both
--     retain full CRUD so migrations, dashboard edits, and the PayFast
--     webhook keep working.
--   * Does NOT touch `plan_issuances`, `practices`, `practice_members`.
--     Separate hardening passes if/when needed.
--
-- IDEMPOTENT
--   REVOKE is idempotent in Postgres. DROP POLICY uses IF EXISTS. Safe
--   to run multiple times.
--
-- ROLLBACK (emergency only)
--   GRANT INSERT ON public.credit_ledger TO authenticated;
--   CREATE POLICY credit_ledger_insert_own ON public.credit_ledger
--     FOR INSERT WITH CHECK (practice_id IN (SELECT user_practice_ids()));
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Revoke client writes
-- ---------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.credit_ledger
  FROM authenticated, anon;

-- anon has no business reading the ledger either. The web player is anon
-- and uses `get_plan_full` (SECURITY DEFINER) — it never touches billing.
REVOKE SELECT ON public.credit_ledger FROM anon;

-- ---------------------------------------------------------------------------
-- 2. Drop the now-redundant INSERT policy
-- ---------------------------------------------------------------------------
-- Without an INSERT grant the policy can never fire for authenticated/anon.
-- Keeping it around would just be noise in pg_policy and would invite the
-- next person to think client INSERTs are still part of the design.
DROP POLICY IF EXISTS credit_ledger_insert_own ON public.credit_ledger;

-- ---------------------------------------------------------------------------
-- 3. Keep SELECT for authenticated (RLS-scoped to own practice)
-- ---------------------------------------------------------------------------
-- No-op for current grants (SELECT already granted). Explicit GRANT here so
-- the intent is visible in this file if Supabase ever re-baselines defaults.
GRANT SELECT ON public.credit_ledger TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Verification (prints to apply output so the CLI caller has receipts)
-- ---------------------------------------------------------------------------
-- Expect exactly two rows per role:
--   postgres        — full CRUD (table owner)
--   service_role    — full CRUD
--   authenticated   — SELECT only
--   anon            — no rows (fully revoked)
SELECT grantee, privilege_type
  FROM information_schema.role_table_grants
 WHERE table_schema = 'public'
   AND table_name   = 'credit_ledger'
   AND grantee IN ('anon', 'authenticated')
 ORDER BY grantee, privilege_type;
