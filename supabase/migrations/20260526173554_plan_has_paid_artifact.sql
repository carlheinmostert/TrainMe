-- =============================================================================
-- Wave 3 (artifact-system) — plan_has_paid_artifact predicate
-- =============================================================================
--
-- ADR 0028: the edit-lock is paid-only. A plan that has only ever shipped
-- free artifacts (handout today; future poster / calendar) MUST NEVER lock —
-- no credit was spent so there's no abuse vector to enforce. The mobile
-- Studio `_isPlanLocked` getter consults this predicate before considering
-- the 14-day grace clock.
--
-- This is a thin, side-effect-free, IMMUTABLE-shaped (STABLE in practice
-- because plan_artifacts is mutable across transactions) helper. Marking it
-- SECURITY DEFINER means callers do not need any direct grant on
-- plan_artifacts — the RLS policy + this membership check together gate
-- access. Without the wrapper, an anon caller could query without context.
--
-- "Paid" kinds are the ones whose `_artifact_kind_price` returns > 0 for a
-- non-zero plan duration:
--
--   * plan_url  — 1 or 2 credits (duration tier)
--   * reel      — premium TBD (not shippable yet but the registry has it)
--   * ai_reel   — premium TBD
--
-- The free kinds are handout, poster, calendar — they will NEVER cause the
-- edit lock to arm. If a future wave adds a new paid kind, append it here
-- alongside its registry entry.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.plan_has_paid_artifact(
  p_plan_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
BEGIN
  -- Anonymous callers have no business asking about lock state. Returning
  -- false silently would mask a misconfigured surface; raise instead.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'plan_has_paid_artifact requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RETURN false;
  END IF;

  -- Resolve practice for membership check. Plan-not-found returns false
  -- (no plan, no lock).
  SELECT practice_id
    INTO v_practice_id
    FROM public.plans
   WHERE id = p_plan_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN false;
  END IF;

  -- Membership gate: a practitioner can only inspect lock state for plans
  -- in their own practice. The function is SECURITY DEFINER so the
  -- underlying SELECTs bypass RLS — this check is the only thing standing
  -- between an authenticated caller and another practice's metadata.
  IF NOT EXISTS (
    SELECT 1 FROM public.practice_members
     WHERE practice_id = v_practice_id
       AND trainer_id  = v_caller
  ) THEN
    RAISE EXCEPTION
      'plan_has_paid_artifact: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- A "paid" artifact is one whose registered price was > 0 at the time
  -- it was published. We check the persisted credits_charged column
  -- rather than re-deriving via `_artifact_kind_price` so a future
  -- registry edit (e.g. reel goes from premium → free as a promo) does
  -- NOT retroactively un-lock plans that genuinely paid. Provenance
  -- preserved by the stamped charge, not by the registry-of-today.
  RETURN EXISTS (
    SELECT 1
      FROM public.plan_artifacts
     WHERE plan_id = p_plan_id
       AND published_at IS NOT NULL
       AND credits_charged > 0
  );
END;
$$;

COMMENT ON FUNCTION public.plan_has_paid_artifact(uuid) IS
  'Wave 3 (artifact-system, ADR 0028): true iff this plan has at least one paid plan_artifacts row (credits_charged > 0). Used by the Flutter Studio edit-lock check to skip the 14-day grace for free-only plans. SECURITY DEFINER + explicit membership check.';

GRANT EXECUTE ON FUNCTION public.plan_has_paid_artifact(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.plan_has_paid_artifact(uuid) FROM anon;
