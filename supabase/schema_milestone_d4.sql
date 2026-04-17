-- homefit.studio — Milestone D4: PayFast payment intents
-- =============================================================================
-- Adds the `pending_payments` table — the server-side intent record that
-- links a PayFast checkout (keyed by m_payment_id) back to a practice, a
-- bundle, and the expected ZAR amount. The ITN webhook uses this table as
-- its source of truth: it matches `m_payment_id`, verifies `amount_gross`
-- equals the `amount_zar` we recorded here, then inserts the `credit_ledger`
-- purchase row and marks the intent `complete`.
--
-- Runs as a single transaction. Safe to re-run.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. pending_payments table
-- ============================================================================
CREATE TABLE IF NOT EXISTS pending_payments (
  id            uuid PRIMARY KEY,
  practice_id   uuid NOT NULL REFERENCES practices(id) ON DELETE CASCADE,
  credits       integer NOT NULL CHECK (credits > 0),
  amount_zar    numeric(10,2) NOT NULL CHECK (amount_zar > 0),
  bundle_key    text,
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','complete','cancelled','failed')),
  pf_payment_id text,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  completed_at  timestamptz
);

-- Support the webhook's lookup and any future "stale intents" cleanup job.
CREATE INDEX IF NOT EXISTS idx_pending_payments_practice
  ON pending_payments (practice_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pending_payments_status
  ON pending_payments (status, created_at DESC);

-- ============================================================================
-- 2. RLS — visible to practice members, mutated only by service role
-- ============================================================================
-- The ITN webhook runs with the service role key, which bypasses RLS
-- automatically, so we don't need INSERT/UPDATE policies for it. Trainers
-- get SELECT so the portal can show "Payment pending…" UI if needed.

ALTER TABLE pending_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pending_payments_select_own ON pending_payments;

CREATE POLICY pending_payments_select_own
  ON pending_payments FOR SELECT
  USING (practice_id IN (SELECT user_practice_ids()));

-- No INSERT / UPDATE / DELETE policies => RLS denies them for authenticated
-- and anon roles. Service role bypasses RLS and is the only writer.

COMMIT;

-- ============================================================================
-- Verification queries
-- ============================================================================
--   SELECT policyname, cmd FROM pg_policies
--    WHERE tablename = 'pending_payments' ORDER BY cmd, policyname;
--   -- expect a single `pending_payments_select_own` SELECT row.
--
--   SET ROLE anon;
--   SELECT count(*) FROM pending_payments;  -- expect 0 (RLS denies anon).
--   RESET ROLE;
