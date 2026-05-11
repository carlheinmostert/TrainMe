-- Wave 27 — Per-plan crossfade timing (2026-04-25)
--
-- Two new nullable smallint columns on `plans` so each plan carries its
-- own dual-video crossfade tuning (lead-time + fade-duration). NULL means
-- "use the surface's default" (250ms lead / 200ms fade today). The
-- practitioner tunes these in the mobile `_MediaViewer` bottom-sheet
-- sliders; the values are written back through the existing PostgREST
-- upsert on `plans` and surface to the web player via `get_plan_full`'s
-- `to_jsonb(plan_row)` (no RPC change required).
--
-- Why per-plan and not per-practice or global: each plan is filmed in
-- one session with consistent video style — a single sweet spot per
-- batch. Different plans can use different timings as the practitioner's
-- style evolves.
--
-- Range guidance (UI-clamped, not DB-enforced):
--   crossfade_lead_ms : 100..800   (default 250)
--   crossfade_fade_ms : 50..600    (default 200)

ALTER TABLE plans
  ADD COLUMN IF NOT EXISTS crossfade_lead_ms smallint,
  ADD COLUMN IF NOT EXISTS crossfade_fade_ms smallint;

COMMENT ON COLUMN plans.crossfade_lead_ms IS
  'Wave 27: ms before loop seam to preroll the inactive video. NULL = surface default (250ms).';
COMMENT ON COLUMN plans.crossfade_fade_ms IS
  'Wave 27: opacity-transition duration for the dual-video crossfade. NULL = surface default (200ms).';
