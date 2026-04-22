-- ============================================================================
-- Wave 18.1 — atomic replace-all-exercises RPC for publish
-- ============================================================================
--
-- Closes the 23505 regression where re-publishing a plan with reordered
-- exercises collided on UNIQUE (plan_id, position). Before: the client
-- called PostgREST .upsert(exerciseRows) followed by a separate .delete()
-- to drop stale rows. Even though the unique index is DEFERRABLE
-- INITIALLY DEFERRED, each PostgREST HTTP call auto-commits, so
-- intermediate collisions were not deferred — just two transactions
-- racing each other against the same (plan_id, position) slots.
--
-- Fix: wrap DELETE + INSERT in ONE SECURITY DEFINER transaction. The
-- DEFERRABLE constraint check now genuinely defers to end-of-transaction,
-- so reorder-and-re-publish no longer races.
--
-- Practice-membership gate mirrors every other SECURITY DEFINER RPC —
-- caller must be a member of the plan's owning practice. We don't infer
-- this from the rows themselves (they can arrive forged); instead we
-- look up `plans.practice_id` server-side and check membership against
-- the canonical source.
--
-- Column map: explicit INSERT column list matches the shape Flutter
-- sends (app/lib/services/upload_service.dart :: exerciseRows). Missing
-- columns (e.g. `created_at`) fall back to their table-level DEFAULT.
-- Unknown keys in `p_rows` are ignored by `jsonb_populate_recordset`.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.replace_plan_exercises(
  p_plan_id uuid,
  p_rows    jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller uuid := auth.uid();
  v_practice_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_plan_id IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises: p_plan_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id INTO v_practice_id
    FROM public.plans
   WHERE id = p_plan_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'replace_plan_exercises: plan % not found', p_plan_id
      USING ERRCODE = '22023';
  END IF;

  -- Practice-membership gate — mirrors every other SECURITY DEFINER RPC.
  IF NOT (v_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'replace_plan_exercises: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Atomic DELETE + INSERT in one transaction. The DEFERRABLE INITIALLY
  -- DEFERRED UNIQUE (plan_id, position) index holds its check until the
  -- end of this transaction, so intermediate collisions during INSERT
  -- (from reorders) are resolved before the check fires.
  DELETE FROM public.exercises WHERE plan_id = p_plan_id;

  -- Explicit column list keeps the RPC tolerant of forward-compatible
  -- schema additions. Any column Flutter doesn't send uses its table
  -- DEFAULT (e.g. `created_at DEFAULT now()`, `id DEFAULT gen_random_uuid()`).
  IF jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 0 THEN
    INSERT INTO public.exercises (
      id,
      plan_id,
      position,
      name,
      media_url,
      thumbnail_url,
      media_type,
      reps,
      sets,
      hold_seconds,
      notes,
      circuit_id,
      include_audio,
      custom_duration_seconds,
      preferred_treatment,
      prep_seconds
    )
    SELECT
      (r->>'id')::uuid,
      (r->>'plan_id')::uuid,
      (r->>'position')::integer,
      r->>'name',
      r->>'media_url',
      r->>'thumbnail_url',
      r->>'media_type',
      NULLIF(r->>'reps', '')::integer,
      NULLIF(r->>'sets', '')::integer,
      NULLIF(r->>'hold_seconds', '')::integer,
      r->>'notes',
      r->>'circuit_id',
      COALESCE((r->>'include_audio')::boolean, false),
      NULLIF(r->>'custom_duration_seconds', '')::integer,
      r->>'preferred_treatment',
      NULLIF(r->>'prep_seconds', '')::integer
    FROM jsonb_array_elements(p_rows) AS r;
  END IF;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.replace_plan_exercises(uuid, jsonb) FROM anon, public;
