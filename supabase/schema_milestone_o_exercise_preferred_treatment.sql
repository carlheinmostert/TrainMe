-- Milestone O — per-exercise sticky treatment preference.
--
-- The practitioner can cycle an exercise's treatment (Line / B&W /
-- Original) in the Studio _MediaViewer (vertical swipe), in the plan
-- preview (segmented-control tap), and from the Studio exercise card's
-- tile row. That choice now STICKS — every exercise has its own
-- preferred treatment and renders with that treatment by default on
-- the next open.
--
-- Semantics:
--
--   * preferred_treatment IS NULL → no explicit choice, render as Line
--     (the de-identifying default and the pre-feature behaviour for
--     every existing row).
--   * 'line' / 'grayscale' / 'original' → the practitioner's explicit
--     choice. Next open of the plan renders this treatment on this
--     specific exercise. Moving to the neighbour exercise does NOT
--     carry it over — each exercise reads ITS OWN preference.
--
-- Scope:
--
-- This column mirrors the mobile SQLite `exercises.preferred_treatment`
-- (schema v18, see app/lib/services/local_storage_service.dart). The
-- two columns share a string vocabulary so publish + sync can round-
-- trip the field without any translation layer.
--
-- Consent gating is NOT enforced at the column — if a client later
-- revokes consent for B&W / Original, the playback surface silently
-- falls back to Line (see `_effectiveTreatmentFor` in studio_mode_
-- screen.dart + the analogous seed in plan_preview_screen.dart). The
-- stored preference is preserved so that re-granting consent restores
-- the practitioner's prior choice without re-entry.

-- ---------------------------------------------------------------------------
-- 1. Column add — nullable TEXT with a CHECK constraint restricting
--    values to the allowed vocabulary.
-- ---------------------------------------------------------------------------

ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS preferred_treatment TEXT
    CHECK (preferred_treatment IS NULL OR preferred_treatment IN ('line', 'grayscale', 'original'));

-- Preserving the NULL default covers the existing-row migration — every
-- exercise inserted before this migration keeps NULL and therefore
-- continues to render as Line on the next open, matching the pre-
-- feature behaviour.

COMMENT ON COLUMN public.exercises.preferred_treatment IS
  'Practitioner-sticky preferred treatment for this specific exercise. '
  'NULL = render as Line (the de-identifying default). '
  'Non-null values: line | grayscale | original. '
  'Written by the Flutter Studio viewer / plan preview / card tiles; '
  'mirrors the mobile SQLite exercises.preferred_treatment column.';

-- ---------------------------------------------------------------------------
-- 2. RLS — no new policy needed. The existing exercises-table RLS
--    scopes reads + writes by practice membership via the plan's
--    practice_id. preferred_treatment inherits those policies
--    transparently.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. Smoke test (run manually after apply):
--
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_name = 'exercises'
--      AND column_name = 'preferred_treatment';
--
--   -- Expect 1 row: preferred_treatment | text | YES
--
--   -- Check constraint is in place:
--   SELECT conname, pg_get_constraintdef(oid) AS def
--     FROM pg_constraint
--    WHERE conrelid = 'public.exercises'::regclass
--      AND conname LIKE '%preferred_treatment%';
-- ---------------------------------------------------------------------------
