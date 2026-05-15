-- 2026-05-15 — re-apply storage bucket RLS policies dropped by pg_dump baseline
--
-- The 2026-05-11 baseline migration (20260511065443_baseline.sql) was generated
-- via `pg_dump --schema=public`, which silently omits storage.objects policies
-- because they live in the `storage` schema. Both the `media` and `raw-archive`
-- buckets had hand-applied policies (from schema_milestone_c.sql and
-- schema_milestone_g_three_treatment.sql respectively) that did NOT survive
-- the cutover.
--
-- Symptom on every DB cloned from baseline (i.e. the persistent staging branch
-- `vadjvkmldtoeyspyoqbx` and every per-PR DB preview):
--   Authenticated INSERT to storage.objects fails with 42501 RLS violation
--   on every bucket. Publish reports "0 of N uploaded" for every file.
--
-- This migration restores the historical policies verbatim from the archive
-- files. Idempotent: each policy is dropped-if-exists then re-created. Safe to
-- apply to any DB regardless of current policy state.
--
-- Source files:
--   supabase/archive/schema_milestone_c.sql:549-636      (media bucket)
--   supabase/archive/schema_milestone_g_three_treatment.sql:182-270
--                                                         (raw-archive bucket
--                                                          + bucket row)
--
-- Sensitive zone: storage RLS — requires Carl review before merge.
-- Reference: feedback_sensitive_code_review_before_merge.md.

BEGIN;

-- ============================================================================
-- 1. Ensure both buckets exist (defensive — bucket rows live in storage.buckets
--    which pg_dump --schema=public also misses).
-- ============================================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('media', 'media', true)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

INSERT INTO storage.buckets (id, name, public)
VALUES ('raw-archive', 'raw-archive', false)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

-- ============================================================================
-- 2. media bucket — public SELECT; INSERT/UPDATE/DELETE scoped to authed
--    trainers whose practice owns the plan referenced by the first path
--    segment (path convention: {session_id}/{exercise_id}.{ext}).
-- ============================================================================

DO $outer$
BEGIN
  -- Drop any earlier versions (covers legacy + current names).
  EXECUTE 'DROP POLICY IF EXISTS "Public read media"          ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Public upload media"        ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media read by path"         ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media upload"               ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media public read"          ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media trainer insert"       ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media trainer update"       ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media trainer delete"       ON storage.objects';

  -- Public SELECT — videos stream to anonymous clients over share links.
  EXECUTE $policy$
    CREATE POLICY "Media public read"
      ON storage.objects FOR SELECT
      USING (bucket_id = 'media')
  $policy$;

  -- INSERT: caller must be an authed trainer whose practice owns the plan
  -- referenced by the first path segment (session_id).
  EXECUTE $policy$
    CREATE POLICY "Media trainer insert"
      ON storage.objects FOR INSERT
      WITH CHECK (
        bucket_id = 'media'
        AND (storage.foldername(name))[1]::uuid IN (
          SELECT id FROM plans
           WHERE practice_id IN (
             SELECT practice_id FROM practice_members
              WHERE trainer_id = auth.uid()
           )
        )
      )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY "Media trainer update"
      ON storage.objects FOR UPDATE
      USING (
        bucket_id = 'media'
        AND (storage.foldername(name))[1]::uuid IN (
          SELECT id FROM plans
           WHERE practice_id IN (
             SELECT practice_id FROM practice_members
              WHERE trainer_id = auth.uid()
           )
        )
      )
      WITH CHECK (
        bucket_id = 'media'
        AND (storage.foldername(name))[1]::uuid IN (
          SELECT id FROM plans
           WHERE practice_id IN (
             SELECT practice_id FROM practice_members
              WHERE trainer_id = auth.uid()
           )
        )
      )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY "Media trainer delete"
      ON storage.objects FOR DELETE
      USING (
        bucket_id = 'media'
        AND (storage.foldername(name))[1]::uuid IN (
          SELECT id FROM plans
           WHERE practice_id IN (
             SELECT practice_id FROM practice_members
              WHERE trainer_id = auth.uid()
           )
        )
      )
  $policy$;
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping media bucket storage.objects policy changes (need service role).';
END
$outer$;

-- ============================================================================
-- 3. raw-archive bucket — PRIVATE (no SELECT for anon/authenticated; service
--    role + signed URLs only); INSERT/UPDATE/DELETE gated by the helper fn
--    public.can_write_to_raw_archive(name) which parses the first path segment
--    as practice_id and checks membership.
--
--    Path convention: {practice_id}/{plan_id}/{exercise_id}.mp4
-- ============================================================================

DO $outer$
BEGIN
  EXECUTE 'DROP POLICY IF EXISTS "Raw-archive select blocked"  ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Raw-archive trainer insert"  ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Raw-archive trainer update"  ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Raw-archive trainer delete"  ON storage.objects';

  -- SELECT: no explicit policy = denied for anon + authenticated. Service
  -- role bypasses RLS. Signed URLs generated server-side are how clients get
  -- playback access (see sign_storage_url + get_plan_full).
  -- (Deliberately no CREATE POLICY ... FOR SELECT here.)

  EXECUTE $policy$
    CREATE POLICY "Raw-archive trainer insert"
      ON storage.objects FOR INSERT
      WITH CHECK (
        bucket_id = 'raw-archive'
        AND public.can_write_to_raw_archive(name)
      )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY "Raw-archive trainer update"
      ON storage.objects FOR UPDATE
      USING (
        bucket_id = 'raw-archive'
        AND public.can_write_to_raw_archive(name)
      )
      WITH CHECK (
        bucket_id = 'raw-archive'
        AND public.can_write_to_raw_archive(name)
      )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY "Raw-archive trainer delete"
      ON storage.objects FOR DELETE
      USING (
        bucket_id = 'raw-archive'
        AND public.can_write_to_raw_archive(name)
      )
  $policy$;
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping raw-archive bucket storage.objects policy changes (need service role).';
END
$outer$;

COMMIT;

-- ============================================================================
-- Verification queries — run these after the migration applies to sanity-check
-- ============================================================================
--
-- A. Policy inventory: 4 media-bucket + 3 raw-archive policies (no raw-archive
--    SELECT policy by design).
--   SELECT policyname, cmd
--     FROM pg_policies
--    WHERE schemaname = 'storage'
--      AND tablename  = 'objects'
--    ORDER BY policyname;
--
-- B. Bucket row sanity: both buckets present, raw-archive private.
--   SELECT id, name, public FROM storage.buckets WHERE id IN ('media','raw-archive');
--
-- C. End-to-end (run as Carl post-merge): re-publish a 1-photo plan. Expect
--    every file to upload (no 42501). Sheet shows "All set"; credit consumed
--    (not refunded).
