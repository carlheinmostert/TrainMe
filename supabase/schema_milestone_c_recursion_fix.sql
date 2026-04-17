-- Fix infinite-recursion in Milestone C RLS.
-- All policies that subquery `practice_members` are rewritten to go through
-- the `user_practice_ids()` SECURITY DEFINER helper, which bypasses RLS
-- (it runs as the function owner, not the caller). This breaks the recursion
-- loop where `practice_members` SELECT policy would re-enter itself.

BEGIN;

-- ========================================================================
-- practice_members — the critical recursion root
-- ========================================================================

DROP POLICY IF EXISTS "members_select_own_practices" ON practice_members;
DROP POLICY IF EXISTS "members_insert_self_or_owner" ON practice_members;
DROP POLICY IF EXISTS "members_update_owner" ON practice_members;
DROP POLICY IF EXISTS "members_delete_owner" ON practice_members;

-- SELECT: any member of any practice I'm in. Uses helper → no recursion.
CREATE POLICY "members_select_own_practices"
  ON practice_members FOR SELECT
  USING (practice_id IN (SELECT user_practice_ids()));

-- INSERT: self-bootstrap as owner, OR you're an owner inviting someone else.
-- The owner check is done via a SECURITY DEFINER helper too.
CREATE OR REPLACE FUNCTION public.user_is_practice_owner(pid uuid)
  RETURNS boolean
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
  SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM practice_members
    WHERE practice_id = pid AND trainer_id = auth.uid() AND role = 'owner'
  );
$$;
GRANT EXECUTE ON FUNCTION public.user_is_practice_owner(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.user_is_practice_owner(uuid) FROM anon, public;

CREATE POLICY "members_insert_self_or_owner"
  ON practice_members FOR INSERT
  WITH CHECK (
    (role = 'owner' AND trainer_id = auth.uid())
    OR user_is_practice_owner(practice_id)
  );

CREATE POLICY "members_update_owner"
  ON practice_members FOR UPDATE
  USING (user_is_practice_owner(practice_id))
  WITH CHECK (user_is_practice_owner(practice_id));

CREATE POLICY "members_delete_owner"
  ON practice_members FOR DELETE
  USING (user_is_practice_owner(practice_id));

-- ========================================================================
-- practices
-- ========================================================================

DROP POLICY IF EXISTS "practices_select_member" ON practices;
DROP POLICY IF EXISTS "practices_insert_authed" ON practices;
DROP POLICY IF EXISTS "practices_update_owner" ON practices;
DROP POLICY IF EXISTS "practices_delete_owner" ON practices;

CREATE POLICY "practices_select_member"
  ON practices FOR SELECT
  USING (id IN (SELECT user_practice_ids()));

CREATE POLICY "practices_insert_authed"
  ON practices FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "practices_update_owner"
  ON practices FOR UPDATE
  USING (user_is_practice_owner(id))
  WITH CHECK (user_is_practice_owner(id));

CREATE POLICY "practices_delete_owner"
  ON practices FOR DELETE
  USING (user_is_practice_owner(id));

-- ========================================================================
-- plans
-- ========================================================================

DROP POLICY IF EXISTS "plans_select_own" ON plans;
DROP POLICY IF EXISTS "plans_insert_own" ON plans;
DROP POLICY IF EXISTS "plans_update_own" ON plans;
DROP POLICY IF EXISTS "plans_delete_own" ON plans;

CREATE POLICY "plans_select_own"
  ON plans FOR SELECT
  USING (practice_id IN (SELECT user_practice_ids()));

CREATE POLICY "plans_insert_own"
  ON plans FOR INSERT
  WITH CHECK (practice_id IN (SELECT user_practice_ids()));

CREATE POLICY "plans_update_own"
  ON plans FOR UPDATE
  USING (practice_id IN (SELECT user_practice_ids()))
  WITH CHECK (practice_id IN (SELECT user_practice_ids()));

CREATE POLICY "plans_delete_own"
  ON plans FOR DELETE
  USING (practice_id IN (SELECT user_practice_ids()));

-- ========================================================================
-- exercises (scoped via plans)
-- ========================================================================

DROP POLICY IF EXISTS "exercises_select_own" ON exercises;
DROP POLICY IF EXISTS "exercises_insert_own" ON exercises;
DROP POLICY IF EXISTS "exercises_update_own" ON exercises;
DROP POLICY IF EXISTS "exercises_delete_own" ON exercises;

CREATE POLICY "exercises_select_own"
  ON exercises FOR SELECT
  USING (plan_id IN (SELECT id FROM plans WHERE practice_id IN (SELECT user_practice_ids())));

CREATE POLICY "exercises_insert_own"
  ON exercises FOR INSERT
  WITH CHECK (plan_id IN (SELECT id FROM plans WHERE practice_id IN (SELECT user_practice_ids())));

CREATE POLICY "exercises_update_own"
  ON exercises FOR UPDATE
  USING (plan_id IN (SELECT id FROM plans WHERE practice_id IN (SELECT user_practice_ids())))
  WITH CHECK (plan_id IN (SELECT id FROM plans WHERE practice_id IN (SELECT user_practice_ids())));

CREATE POLICY "exercises_delete_own"
  ON exercises FOR DELETE
  USING (plan_id IN (SELECT id FROM plans WHERE practice_id IN (SELECT user_practice_ids())));

-- ========================================================================
-- credit_ledger
-- ========================================================================

DROP POLICY IF EXISTS "credit_ledger_select_own" ON credit_ledger;
DROP POLICY IF EXISTS "credit_ledger_insert_own" ON credit_ledger;

CREATE POLICY "credit_ledger_select_own"
  ON credit_ledger FOR SELECT
  USING (practice_id IN (SELECT user_practice_ids()));

CREATE POLICY "credit_ledger_insert_own"
  ON credit_ledger FOR INSERT
  WITH CHECK (practice_id IN (SELECT user_practice_ids()));

-- ========================================================================
-- plan_issuances
-- ========================================================================

DROP POLICY IF EXISTS "plan_issuances_select_own" ON plan_issuances;
DROP POLICY IF EXISTS "plan_issuances_insert_own" ON plan_issuances;

CREATE POLICY "plan_issuances_select_own"
  ON plan_issuances FOR SELECT
  USING (practice_id IN (SELECT user_practice_ids()));

CREATE POLICY "plan_issuances_insert_own"
  ON plan_issuances FOR INSERT
  WITH CHECK (practice_id IN (SELECT user_practice_ids()));

-- ========================================================================
-- storage.objects (media bucket)
-- ========================================================================

DROP POLICY IF EXISTS "Media upload" ON storage.objects;
DROP POLICY IF EXISTS "Media update" ON storage.objects;
DROP POLICY IF EXISTS "Media delete" ON storage.objects;

CREATE POLICY "Media upload"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'media'
    AND (storage.foldername(name))[1]::uuid IN (
      SELECT id FROM plans WHERE practice_id IN (SELECT user_practice_ids())
    )
  );

CREATE POLICY "Media update"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1]::uuid IN (
      SELECT id FROM plans WHERE practice_id IN (SELECT user_practice_ids())
    )
  );

CREATE POLICY "Media delete"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'media'
    AND (storage.foldername(name))[1]::uuid IN (
      SELECT id FROM plans WHERE practice_id IN (SELECT user_practice_ids())
    )
  );

COMMIT;
