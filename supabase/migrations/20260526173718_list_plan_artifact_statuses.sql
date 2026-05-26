-- =============================================================================
-- Wave 3 (artifact-system) — list_plan_artifact_statuses reader RPC
-- =============================================================================
--
-- The mobile Studio AppBar's artifact-status row and the multi-select Publish
-- gate sheet both need the same answer: "which kinds have a plan_artifacts
-- row for this plan, and what's the per-kind state?"
--
-- Per `feedback_no_direct_db_access.md` — Flutter never SELECTs from
-- plan_artifacts directly. This RPC is the single enumerated reader the
-- ApiClient calls. RLS on plan_artifacts would already gate the read but
-- routing through a SECURITY DEFINER wrapper keeps the access-layer rule
-- uniform across all surfaces (api_client.dart / api.ts / api.js).
--
-- Return shape: a list with one row per published-or-pending kind. Rows
-- with `published_at IS NULL` (kinds that exist in the table but were
-- never actually published — currently impossible since publish_plan_artifacts
-- always stamps published_at, but future render-async kinds may transit
-- through this state) are still surfaced so the UI can show a "minting…"
-- pill if needed; the mobile UI today treats both states identically.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.list_plan_artifact_statuses(
  p_plan_id uuid
)
RETURNS TABLE (
  kind             text,
  status           text,
  generated_at     timestamptz,
  published_at     timestamptz,
  credits_charged  numeric,
  first_opened_at  timestamptz
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_plan_artifact_statuses requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'list_plan_artifact_statuses: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id
    INTO v_practice_id
    FROM public.plans
   WHERE id = p_plan_id
   LIMIT 1;

  -- Plan-not-found: empty rather than error so a fresh, never-published
  -- session can call this on every Studio open without burning RPC
  -- latency budget on an exception path. The UI renders zero pills,
  -- which is the right answer.
  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.practice_members
     WHERE practice_id = v_practice_id
       AND trainer_id  = v_caller
  ) THEN
    RAISE EXCEPTION
      'list_plan_artifact_statuses: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      pa.kind,
      pa.status,
      pa.generated_at,
      pa.published_at,
      pa.credits_charged,
      pa.first_opened_at
      FROM public.plan_artifacts pa
     WHERE pa.plan_id = p_plan_id
     ORDER BY pa.generated_at ASC;
END;
$$;

COMMENT ON FUNCTION public.list_plan_artifact_statuses(uuid) IS
  'Wave 3 (artifact-system): enumerates the plan_artifacts rows for a plan with their published/credits state. Drives the mobile Studio artifact-status row and the Publish gate''s Live-row rendering. SECURITY DEFINER + explicit membership check.';

GRANT EXECUTE ON FUNCTION public.list_plan_artifact_statuses(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.list_plan_artifact_statuses(uuid) FROM anon;
