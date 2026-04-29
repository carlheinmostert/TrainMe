-- Wave 17.1 — Add exercise_navigation_jump to the analytics event_kind CHECK constraint
-- =====================================================================================
--
-- The original CHECK on plan_analytics_events.event_kind allows 12 kinds.
-- This migration adds a 13th: exercise_navigation_jump, fired when the
-- client taps a progress pill to jump to a different exercise.
--
-- Safe to re-run: drops-and-recreates the constraint idempotently.

ALTER TABLE public.plan_analytics_events
  DROP CONSTRAINT IF EXISTS plan_analytics_events_event_kind_check;

ALTER TABLE public.plan_analytics_events
  ADD CONSTRAINT plan_analytics_events_event_kind_check
  CHECK (event_kind IN (
    'plan_opened','plan_completed','plan_closed',
    'exercise_viewed','exercise_completed','exercise_skipped','exercise_replayed',
    'treatment_switched','pause_tapped','resume_tapped',
    'rest_shortened','rest_extended',
    'exercise_navigation_jump'
  ));
