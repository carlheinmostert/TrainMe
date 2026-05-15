-- 2026-05-15 — re-apply the auth.users INSERT trigger dropped by pg_dump baseline
--
-- Companion to 20260515135502_storage_bucket_policies_recovery.sql (PR #354).
-- Same root cause: the 2026-05-11 baseline migration was generated via
-- `pg_dump --schema=public`, which silently omits any trigger whose target
-- table lives outside the public schema.
--
-- Specifically missing: claim_pending_practice_memberships_trigger on
-- auth.users. The function public.claim_pending_practice_memberships() DID
-- make it into the baseline (line 716, since CREATE OR REPLACE FUNCTION
-- targets public.*), but the AFTER INSERT ON auth.users trigger that
-- invokes it did NOT.
--
-- Symptom on every DB cloned from baseline (persistent staging branch
-- vadjvkmldtoeyspyoqbx + every per-PR DB preview): owners can invite
-- practitioners by email (rows land in public.pending_practice_members),
-- but when the invitee signs up the trigger never fires, the pending row
-- never drains into public.practice_members, and the invitee lands
-- without their expected practice membership. Production has the trigger
-- (it was applied directly when milestone U shipped) so this only bites
-- on staging + previews.
--
-- This migration restores the trigger verbatim from the archive file.
-- Idempotent: DROP TRIGGER IF EXISTS then CREATE TRIGGER, wrapped in a
-- DO block with exception handling because some hosted Postgres
-- environments require service_role to touch auth.* triggers.
--
-- Source file:
--   supabase/archive/schema_milestone_u_add_member_by_email.sql:450-455
--
-- Sensitive zone: auth-schema trigger — requires Carl review before merge.
-- Reference: feedback_sensitive_code_review_before_merge.md.

BEGIN;

-- ============================================================================
-- Pre-flight: confirm the trigger function exists in public.
-- The baseline includes the function body but not the trigger that calls it.
-- If the function is missing for any reason, fail fast rather than create a
-- trigger that points at nothing.
-- ============================================================================
DO $check$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'claim_pending_practice_memberships'
  ) THEN
    RAISE EXCEPTION
      'public.claim_pending_practice_memberships() is missing — apply the baseline migration first';
  END IF;
END
$check$;

-- ============================================================================
-- Restore the trigger. AFTER INSERT ON auth.users — fires for every new
-- signup. Drains every public.pending_practice_members row whose email
-- matches NEW.email (citext) into public.practice_members, then deletes
-- the pending row.
-- ============================================================================
DO $outer$
BEGIN
  EXECUTE 'DROP TRIGGER IF EXISTS claim_pending_practice_memberships_trigger ON auth.users';
  EXECUTE $trg$
    CREATE TRIGGER claim_pending_practice_memberships_trigger
      AFTER INSERT ON auth.users
      FOR EACH ROW
      EXECUTE FUNCTION public.claim_pending_practice_memberships()
  $trg$;
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping auth.users trigger creation (need service role).';
END
$outer$;

COMMIT;
