-- Branding storage policies for the `media` bucket.
--
-- Fix S-C1 (synthesis 2026-05-21): the existing INSERT/UPDATE/DELETE policies
-- in `20260515135502_storage_bucket_policies_recovery.sql` cast
-- `(storage.foldername(name))[1]::uuid` and look the uuid up in `plans`. That
-- predicate fails with PG error `22P02` (invalid input syntax for type uuid)
-- on any path beginning with the literal `branding/`, which is exactly where
-- `LogoUploader.tsx` writes practice logos for Public Profile v2.
--
-- These policies scope writes to `branding/{practice_id}/...` to practice
-- *owners* (matching `set_practice_public_profile` which is owner-only) and
-- enforce a server-side MIME allow-list of PNG + JPEG. Dropping SVG at the
-- storage layer doubles as the S-M1 mitigation (XSS via SVG `<script>`).
--
-- The existing "Media trainer insert/update/delete" policies still match
-- non-branding paths (plan media keyed by session uuid) because Postgres OR's
-- INSERT policies — any matching predicate authorises the row.

BEGIN;

DROP POLICY IF EXISTS "Media branding owner insert" ON storage.objects;
DROP POLICY IF EXISTS "Media branding owner update" ON storage.objects;
DROP POLICY IF EXISTS "Media branding owner delete" ON storage.objects;

CREATE POLICY "Media branding owner insert"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = 'branding'
    AND (storage.foldername(name))[2]::uuid IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid() AND role = 'owner'
    )
    AND coalesce(metadata->>'mimetype', '') IN ('image/png', 'image/jpeg')
  );

CREATE POLICY "Media branding owner update"
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = 'branding'
    AND (storage.foldername(name))[2]::uuid IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid() AND role = 'owner'
    )
  )
  WITH CHECK (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = 'branding'
    AND (storage.foldername(name))[2]::uuid IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid() AND role = 'owner'
    )
    AND coalesce(metadata->>'mimetype', '') IN ('image/png', 'image/jpeg')
  );

CREATE POLICY "Media branding owner delete"
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1] = 'branding'
    AND (storage.foldername(name))[2]::uuid IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid() AND role = 'owner'
    )
  );

COMMIT;
