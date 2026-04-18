-- Fix: get_plan_full(plan_id) had an ambiguous column reference.
--
-- The parameter was named `plan_id`, which shadows the `exercises.plan_id`
-- column in the body's SELECT. Postgres raised
--   ERROR 42702: column reference "plan_id" is ambiguous
-- at the `WHERE e.plan_id = plan_id` site, causing the anonymous web-player
-- fetch to fail with "plan not found" for every published plan.
--
-- The fix is a pure rename of the parameter to `p_plan_id`, matching the
-- project's existing convention (see `consume_credit(p_practice_id, p_plan_id,
-- p_credits)`). Behaviour is otherwise unchanged:
--   - Updates first_opened_at on first anonymous read.
--   - Returns { plan: {...}, exercises: [...] } or NULL when the plan is
--     missing.
--   - Runs SECURITY DEFINER, so RLS is bypassed and the anon role can read.

-- Parameter rename requires a DROP first — Postgres refuses to change a
-- parameter name via CREATE OR REPLACE.
DROP FUNCTION IF EXISTS public.get_plan_full(uuid);

CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  plan_row  plans;
  exes      jsonb;
BEGIN
  UPDATE plans
     SET first_opened_at = now()
   WHERE id = p_plan_id
     AND first_opened_at IS NULL
  RETURNING * INTO plan_row;

  IF plan_row IS NULL THEN
    SELECT * INTO plan_row FROM plans WHERE id = p_plan_id LIMIT 1;
  END IF;

  IF plan_row IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.position), '[]'::jsonb)
    INTO exes
    FROM exercises e
   WHERE e.plan_id = p_plan_id;

  RETURN jsonb_build_object(
    'plan',      to_jsonb(plan_row),
    'exercises', exes
  );
END;
$function$;
