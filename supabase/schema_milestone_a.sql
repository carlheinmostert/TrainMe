-- homefit.studio — Milestone A: multi-tenant billing foundation
-- =============================================================================
-- Run in Supabase SQL Editor. Safe to re-run (every statement is idempotent).
--
-- WHAT THIS MIGRATION DOES
--   1. Adds `practices` + `practice_members` (the tenant / membership model).
--   2. Adds `credit_ledger` (append-only ledger) and a balance function.
--   3. Adds `plan_issuances` (append-only publish audit trail).
--   4. Extends `plans` with `practice_id` (nullable for now) and
--      `first_opened_at` (for the future publish-lock rule).
--   5. Backfills a "Carl-sentinel" practice + membership + founder credits and
--      stamps every existing plan with that practice id.
--   6. Updates the `get_plan_full` RPC so the web player stamps
--      `first_opened_at` on first fetch.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT tighten RLS. The permissive POV policies (or their hardened
--     variants from `schema_hardening.sql`) stay in place. Per-practice RLS
--     lands in Milestone D once auth.uid() is wired up in Milestone B.
--   * Does NOT decrement credits on publish. The client writes a
--     `plan_issuances` row as an audit signal only; consumption ledger rows
--     land in Milestone D together with the PayFast webhook.
--   * Does NOT make `plans.practice_id` NOT NULL. That tightens in
--     Milestone C once we are confident every code path is stamping it.
--
-- SENTINEL UUIDS (hardcoded, shared with app/lib/config.dart)
--   practice id : 00000000-0000-0000-0000-0000000ca71e   ("CA71E" ≈ "Carlie")
--   trainer id  : 00000000-0000-0000-0000-000000000001   (first trainer)
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. practices — top-level tenant / billing boundary
-- ============================================================================
CREATE TABLE IF NOT EXISTS practices (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL,
  -- Owner trainer. Nullable for now; FK to a future `trainers` table lands in
  -- Milestone B once auth is wired up. Kept untyped (no FK) for now.
  owner_trainer_id  uuid,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- 2. practice_members — which trainers belong to which practice, in what role
-- ============================================================================
CREATE TABLE IF NOT EXISTS practice_members (
  practice_id  uuid NOT NULL REFERENCES practices(id) ON DELETE CASCADE,
  -- Trainer uuid. No FK yet (trainers table arrives in Milestone B).
  trainer_id   uuid NOT NULL,
  role         text NOT NULL CHECK (role IN ('owner', 'practitioner')),
  joined_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (practice_id, trainer_id)
);

-- ============================================================================
-- 3. credit_ledger — append-only ledger. Balance = SUM(delta) per practice.
-- ============================================================================
CREATE TABLE IF NOT EXISTS credit_ledger (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_id         uuid NOT NULL REFERENCES practices(id) ON DELETE CASCADE,
  -- Positive for purchase / refund / positive adjustment.
  -- Negative for consumption / negative adjustment.
  delta               integer NOT NULL,
  type                text NOT NULL CHECK (type IN ('purchase', 'consumption', 'refund', 'adjustment')),
  -- Populated only when type = 'consumption' (points at the plan that burnt the credit).
  plan_id             uuid REFERENCES plans(id) ON DELETE SET NULL,
  -- Populated only when type = 'purchase' (PayFast's pf_payment_id).
  payfast_payment_id  text,
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- Balance-read index: practice_credit_balance() sums all rows for a practice;
-- the DESC on created_at also serves any "recent activity" UI we build later.
CREATE INDEX IF NOT EXISTS idx_credit_ledger_practice_created
  ON credit_ledger (practice_id, created_at DESC);

-- Cheap helper: current credit balance for a practice. Function, not view —
-- lets callers parameterise and index-seeks via the index above.
CREATE OR REPLACE FUNCTION public.practice_credit_balance(p_practice_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(delta), 0)::integer
    FROM credit_ledger
   WHERE practice_id = p_practice_id;
$$;

GRANT EXECUTE ON FUNCTION public.practice_credit_balance(uuid) TO anon, authenticated;

-- ============================================================================
-- 4. plan_issuances — append-only audit of every successful publish
-- ============================================================================
-- One row per successful publish. We write this BEFORE (Milestone D) the
-- consumption ledger row so we always have an audit trail even if the ledger
-- write fails. For now (Milestone A) only the audit row is written.
CREATE TABLE IF NOT EXISTS plan_issuances (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id           uuid NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  practice_id       uuid NOT NULL REFERENCES practices(id),
  -- Who hit publish. Free-form uuid until Milestone B adds the trainers table.
  trainer_id        uuid NOT NULL,
  version           integer NOT NULL,
  exercise_count    integer NOT NULL,
  credits_charged   integer NOT NULL,
  issued_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_plan_issuances_practice_issued
  ON plan_issuances (practice_id, issued_at DESC);

-- ============================================================================
-- 5. plans — extend with practice_id + first_opened_at
-- ============================================================================
-- practice_id is nullable today; Milestone C flips it to NOT NULL after the
-- backfill (below) plus a grace period confirms every client writes it.
ALTER TABLE plans
  ADD COLUMN IF NOT EXISTS practice_id uuid REFERENCES practices(id);

-- Set by the web player on first fetch (via get_plan_full RPC below). Used by
-- Milestone C/D to decide whether add/reorder/swap edits are locked.
ALTER TABLE plans
  ADD COLUMN IF NOT EXISTS first_opened_at timestamptz;

-- Lookup index for future "which plans belong to this practice" queries.
CREATE INDEX IF NOT EXISTS idx_plans_practice
  ON plans (practice_id);

-- ============================================================================
-- 6. Carl-sentinel backfill (idempotent)
-- ============================================================================
-- Single-tenant transition: give Carl a practice row, make him the owner,
-- drop 1000 founder credits in the ledger (once), and stamp every existing
-- plan with his practice id.

INSERT INTO practices (id, name, owner_trainer_id)
VALUES (
  '00000000-0000-0000-0000-0000000ca71e',
  'Carl''s Practice',
  '00000000-0000-0000-0000-000000000001'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO practice_members (practice_id, trainer_id, role)
VALUES (
  '00000000-0000-0000-0000-0000000ca71e',
  '00000000-0000-0000-0000-000000000001',
  'owner'
)
ON CONFLICT (practice_id, trainer_id) DO NOTHING;

-- Founder credits: only insert if the practice has zero ledger rows yet.
-- Re-running the migration is a no-op (idempotent). Manual top-ups via a
-- separate INSERT later aren't blocked.
INSERT INTO credit_ledger (practice_id, delta, type, notes)
SELECT
  '00000000-0000-0000-0000-0000000ca71e'::uuid,
  1000,
  'adjustment',
  'Pre-auth founder credits'
WHERE NOT EXISTS (
  SELECT 1 FROM credit_ledger
   WHERE practice_id = '00000000-0000-0000-0000-0000000ca71e'::uuid
);

-- Backfill every pre-migration plan with Carl's practice id.
-- Safe to re-run: WHERE practice_id IS NULL keeps it a no-op after the first
-- run, and never overwrites a practice_id set by a newer multi-tenant client.
UPDATE plans
   SET practice_id = '00000000-0000-0000-0000-0000000ca71e'::uuid
 WHERE practice_id IS NULL;

-- ============================================================================
-- 7. get_plan_full — also stamp first_opened_at on first fetch
-- ============================================================================
-- Replaces the function from schema_hardening.sql. Return shape is identical;
-- the only behavioural change is the atomic UPDATE that sets first_opened_at
-- if still null. The UPDATE is idempotent — subsequent fetches are no-ops.
CREATE OR REPLACE FUNCTION public.get_plan_full(plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  plan_row  plans;
  exes      jsonb;
BEGIN
  -- Stamp first_opened_at atomically. RETURNING gives us the post-update row
  -- so we read `first_opened_at = now()` on the very first fetch. All later
  -- fetches fall through the WHERE guard and leave the column untouched.
  UPDATE plans
     SET first_opened_at = now()
   WHERE id = plan_id
     AND first_opened_at IS NULL
  RETURNING * INTO plan_row;

  -- If the UPDATE didn't hit a row (either wrong id or already stamped), fall
  -- back to a plain SELECT so we can still return the plan.
  IF plan_row IS NULL THEN
    SELECT * INTO plan_row FROM plans WHERE id = plan_id LIMIT 1;
  END IF;

  IF plan_row IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.position), '[]'::jsonb)
    INTO exes
    FROM exercises e
   WHERE e.plan_id = plan_id;

  RETURN jsonb_build_object(
    'plan',      to_jsonb(plan_row),
    'exercises', exes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;

-- ============================================================================
-- 8. Permissive RLS on the new tables (POV posture — tightens in Milestone D)
-- ============================================================================
-- Same security-by-unguessable-uuid posture as the existing tables. Anon can
-- read/insert. Hardening into per-practice policies lands in Milestone D
-- after auth.uid() is populated by Milestone B.

ALTER TABLE practices         ENABLE ROW LEVEL SECURITY;
ALTER TABLE practice_members  ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_ledger     ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_issuances    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pov_all ON practices;
CREATE POLICY pov_all ON practices          FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS pov_all ON practice_members;
CREATE POLICY pov_all ON practice_members   FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS pov_all ON credit_ledger;
CREATE POLICY pov_all ON credit_ledger      FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS pov_all ON plan_issuances;
CREATE POLICY pov_all ON plan_issuances     FOR ALL USING (true) WITH CHECK (true);

COMMIT;

-- ============================================================================
-- Verification — run these after the migration to sanity-check
-- ============================================================================
--
-- Carl's practice should exist, owned by the sentinel trainer:
--   SELECT * FROM practices WHERE id = '00000000-0000-0000-0000-0000000ca71e';
--
-- Founder credits should be 1000:
--   SELECT public.practice_credit_balance('00000000-0000-0000-0000-0000000ca71e');
--
-- Every plan should now carry the sentinel practice id:
--   SELECT COUNT(*) FROM plans WHERE practice_id IS NULL;  -- expect 0
--
-- get_plan_full still round-trips — pick any plan id and:
--   SELECT public.get_plan_full('<plan uuid>'::uuid);
--   SELECT id, first_opened_at FROM plans WHERE id = '<plan uuid>';
