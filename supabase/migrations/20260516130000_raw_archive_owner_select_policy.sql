-- 2026-05-16 — owner-scoped SELECT policy on raw-archive bucket
--
-- Companion fix to PR #358 (cb40c35) which flipped raw-archive uploads to
-- `upsert: true` to eliminate 409 Duplicate exceptions on re-publish.
-- Side effect surfaced 2026-05-16: Supabase Storage's upsert path needs
-- the row to be SELECT-readable so it can determine INSERT vs UPDATE.
-- The raw-archive bucket previously blocked SELECT entirely (privacy
-- model: signed URLs only). With no SELECT visibility, every upsert hit
-- RLS WITH CHECK denial (PG 42501 / "new row violates row-level security
-- policy" via ExecWithCheckOptions).
--
-- Evidence: zero raw-archive uploads landed on staging since 2026-05-15
-- 14:50 UTC (PR #358 merge time). Pre-merge: 155 uploads succeeded across
-- 3 days for the same user with the same RLS predicate.
--
-- This migration adds a SELECT policy scoped to `owner = auth.uid()`
-- so each authenticated user can see ONLY their own files in the
-- raw-archive bucket. No enumeration of others' files. No cross-user
-- read. Signed URLs (via sign_storage_url + get_plan_full) remain the
-- canonical path for the web player's shared reads.
--
-- Privacy model preserved:
--   * anon          → no SELECT (no policy applies → denied)
--   * authenticated → SELECT only OWN files (new policy)
--   * service_role  → bypasses RLS (unchanged)

BEGIN;

DO $outer$
BEGIN
  EXECUTE 'DROP POLICY IF EXISTS "Raw-archive owner select" ON storage.objects';

  EXECUTE $policy$
    CREATE POLICY "Raw-archive owner select"
      ON storage.objects FOR SELECT
      USING (
        bucket_id = 'raw-archive'
        AND owner = auth.uid()
      )
  $policy$;
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping raw-archive owner select policy creation (need service role).';
END
$outer$;

-- Verify the policy landed. The wrapper's EXCEPTION block above can
-- silently swallow `insufficient_privilege` (caught the 2026-05-15
-- recovery migration's same wrapper succeeding in our case, but a
-- future runner with a less-privileged role could regress). Fail loud
-- here so the migration doesn't claim success when the policy is
-- missing.
DO $check$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename  = 'objects'
      AND policyname = 'Raw-archive owner select'
  ) THEN
    RAISE EXCEPTION 'Raw-archive owner select policy was NOT created — re-run as supabase_storage_admin or postgres.';
  END IF;
END
$check$;

COMMIT;
