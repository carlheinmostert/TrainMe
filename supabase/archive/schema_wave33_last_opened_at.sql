-- ============================================================================
-- Wave 33 — plans.last_opened_at + record_plan_opened RPC
-- ============================================================================
--
-- Carl wants engagement-analytics signal on the studio session panel:
-- "First opened {date} · Last opened {date}". `first_opened_at` already
-- exists (Milestone A); this migration adds `last_opened_at` and a
-- dedicated SECURITY DEFINER RPC that idempotently stamps both columns
-- on every plan-open from the web player.
--
-- Why a new RPC instead of folding the `last_opened_at = now()` write
-- into `get_plan_full`?
--
--   - `get_plan_full` already does an opportunistic UPDATE that sets
--     `first_opened_at` only if NULL. Adding an unconditional update on
--     every read would write on every poll, navigate-back, prefetch,
--     service-worker refresh — pollution that hurts both the rebate-
--     ledger trigger story and any future "engagement-decay" analytics.
--
--   - The web player already has discrete "session start" moments
--     (load + slide-0 first paint). One explicit RPC call from those
--     moments gives a clean signal: every call = one practitioner-
--     observable client open.
--
--   - The RPC is also the right surface for a future "session_started"
--     analytics event. Today it just stamps timestamps; tomorrow it
--     can also insert into a `plan_open_events` table without the web
--     player needing a second round-trip.
--
-- The mobile Studio reads both columns through the existing
-- `getPlanPublishState` lightweight fetch (extended in this PR's Dart
-- changes) — no new mobile RPC needed.
--
-- Rollback: drop the column + RPC. `get_plan_full` is unchanged so the
-- web player keeps working with the old "first-fetch only" stamping.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. plans.last_opened_at
-- ============================================================================

ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS last_opened_at timestamptz;

COMMENT ON COLUMN public.plans.last_opened_at IS
  'Wave 33. Stamped by record_plan_opened on every plan open from the web '
  'player. Drives the Studio "First opened {date} · Last opened {date}" '
  'analytics row. NULL when the plan has never been opened (mirrors '
  'first_opened_at IS NULL). Updated on every open, not first-only.';

-- ============================================================================
-- 2. record_plan_opened — idempotent stamp on first_opened_at + last_opened_at
--
-- SECURITY DEFINER + GRANTed to anon (the web player calls this without
-- auth). Returns void — the web player ignores the response.
--
-- Behaviour:
--   - first_opened_at = COALESCE(first_opened_at, now())  -- only on first open
--   - last_opened_at  = now()                              -- every open
--
-- Bounded scope: WHERE id = p_plan_id, single-row UPDATE. No table-scan,
-- no RLS bypass surface beyond the targeted row.
--
-- Idempotency: re-calling for the same plan never undoes first_opened_at;
-- last_opened_at advances on each call — same as a heartbeat.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.record_plan_opened(p_plan_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF p_plan_id IS NULL THEN
    -- No-op on null. The web player can call this defensively; better
    -- to swallow than to throw and surface a network-error to the client.
    RETURN;
  END IF;

  UPDATE plans
     SET first_opened_at = COALESCE(first_opened_at, now()),
         last_opened_at  = now()
   WHERE id = p_plan_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.record_plan_opened(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.record_plan_opened(uuid) FROM public;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
--
-- A. Column exists:
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'plans' AND column_name = 'last_opened_at';
--
-- B. RPC callable as anon:
--   SELECT public.record_plan_opened('<plan-uuid>'::uuid);
--   SELECT id, first_opened_at, last_opened_at FROM plans
--    WHERE id = '<plan-uuid>'::uuid;
--   -- Expect: first_opened_at preserved (or set on first call), last_opened_at = now().
--
-- C. Idempotent:
--   SELECT public.record_plan_opened('<plan-uuid>'::uuid);  -- runs again
--   -- Expect: first_opened_at unchanged, last_opened_at advanced.
-- ============================================================================
