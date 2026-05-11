-- =============================================================
-- Wave 17 — Analytics retention cron
-- DO NOT APPLY VIA CLI — deploy via Supabase Dashboard > SQL Editor
-- or via pg_cron extension in the dashboard.
--
-- This requires the pg_cron extension to be enabled on your Supabase
-- project (Dashboard > Database > Extensions > pg_cron).
--
-- Schedule: daily at 02:00 UTC
-- =============================================================

-- Step 0: Ensure pg_cron is enabled (run once in dashboard if not already)
-- CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

-- Step 1: Create the retention function
CREATE OR REPLACE FUNCTION public.analytics_daily_rollup_and_purge()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_yesterday DATE := (now() AT TIME ZONE 'UTC')::date - 1;
  v_cutoff    TIMESTAMPTZ := now() - interval '180 days';
BEGIN
  -- 1. Roll yesterday's events into plan_analytics_daily_aggregate.
  INSERT INTO plan_analytics_daily_aggregate (
    plan_id, exercise_id, day,
    opens, completions, total_elapsed_ms,
    exercise_completes, exercise_skips, treatment_switches
  )
  SELECT
    cs.plan_id,
    e.exercise_id,
    v_yesterday,
    COUNT(*) FILTER (WHERE e.event_kind = 'plan_opened'),
    COUNT(*) FILTER (WHERE e.event_kind = 'plan_completed'),
    COALESCE(SUM(
      CASE WHEN e.event_kind = 'plan_completed'
        THEN (e.event_data ->> 'total_elapsed_ms')::bigint
        ELSE 0
      END
    ), 0),
    COUNT(*) FILTER (WHERE e.event_kind = 'exercise_completed'),
    COUNT(*) FILTER (WHERE e.event_kind = 'exercise_skipped'),
    COUNT(*) FILTER (WHERE e.event_kind = 'treatment_switched')
  FROM plan_analytics_events e
    JOIN client_sessions cs ON cs.id = e.client_session_id
  WHERE e.occurred_at >= v_yesterday::timestamptz
    AND e.occurred_at < (v_yesterday + 1)::timestamptz
  GROUP BY cs.plan_id, e.exercise_id
  ON CONFLICT (plan_id, COALESCE(exercise_id, '00000000-0000-0000-0000-000000000000'), day)
  DO UPDATE SET
    opens              = plan_analytics_daily_aggregate.opens + EXCLUDED.opens,
    completions        = plan_analytics_daily_aggregate.completions + EXCLUDED.completions,
    total_elapsed_ms   = plan_analytics_daily_aggregate.total_elapsed_ms + EXCLUDED.total_elapsed_ms,
    exercise_completes = plan_analytics_daily_aggregate.exercise_completes + EXCLUDED.exercise_completes,
    exercise_skips     = plan_analytics_daily_aggregate.exercise_skips + EXCLUDED.exercise_skips,
    treatment_switches = plan_analytics_daily_aggregate.treatment_switches + EXCLUDED.treatment_switches;

  -- 2. Delete raw events older than 180 days.
  DELETE FROM plan_analytics_events
   WHERE occurred_at < v_cutoff;

  -- 3. Clean orphaned client_sessions (no remaining events AND older than 180 days).
  -- The CASCADE on plan_analytics_events already cleans events when sessions are deleted,
  -- but we want to clean sessions that had all their events purged by step 2.
  DELETE FROM client_sessions
   WHERE opened_at < v_cutoff
     AND NOT EXISTS (
       SELECT 1 FROM plan_analytics_events e
        WHERE e.client_session_id = client_sessions.id
     );
END;
$$;

-- Step 2: Schedule the cron job (run this in the dashboard SQL editor)
-- SELECT cron.schedule(
--   'analytics-daily-rollup',
--   '0 2 * * *',  -- daily at 02:00 UTC
--   $$SELECT public.analytics_daily_rollup_and_purge()$$
-- );

-- To verify the job is scheduled:
-- SELECT * FROM cron.job WHERE jobname = 'analytics-daily-rollup';

-- To unschedule:
-- SELECT cron.unschedule('analytics-daily-rollup');
