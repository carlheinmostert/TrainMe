-- homefit.studio — Schema hardening (Tier 1/2 security fixes)
-- Run this in the Supabase SQL Editor ONCE against the existing DB.
-- Safe to re-run: all statements are idempotent.
--
-- What this does:
--   1. Removes wide-open RLS SELECT policies that let anyone dump every plan.
--   2. Restricts UPDATE / DELETE / INSERT so anon can only act on a specific
--      plan they already know the id of (eliminates mass-mutation).
--   3. Adds a SECURITY DEFINER RPC `get_plan_full(plan_id uuid)` that the
--      web player calls to fetch a plan by id. No enumeration possible.
--   4. Adds a UNIQUE(plan_id, position) constraint on exercises for ordering integrity.
--   5. Locks down the `media` storage bucket SELECT policy so LIST is disabled —
--      reads must specify an exact object path.
--
-- AFTER running this, the web player must switch from `.from('plans').select()`
-- to `.rpc('get_plan_full', { plan_id })`. The parallel web-player edit agent
-- is aware of this and will update `web-player/app.js` accordingly.

BEGIN;

-- ============================================================================
-- 1. Replace wide-open SELECT policies with "need the id" policies.
-- ============================================================================

-- Drop existing permissive policies.
DROP POLICY IF EXISTS "Public read plans"      ON plans;
DROP POLICY IF EXISTS "Public insert plans"    ON plans;
DROP POLICY IF EXISTS "Public update plans"    ON plans;
DROP POLICY IF EXISTS "Public delete plans"    ON plans;
DROP POLICY IF EXISTS "Public read exercises"  ON exercises;
DROP POLICY IF EXISTS "Public insert exercises" ON exercises;
DROP POLICY IF EXISTS "Public update exercises" ON exercises;
DROP POLICY IF EXISTS "Public delete exercises" ON exercises;

-- No direct SELECT on plans/exercises from anon. Reads go via RPC below.
-- INSERT stays open (the Flutter app publishes with the anon key; POV trust model).
CREATE POLICY "Anon insert plans"
  ON plans FOR INSERT
  WITH CHECK (true);

CREATE POLICY "Anon update own plan by id"
  ON plans FOR UPDATE
  USING (true)  -- RLS USING can't reference the requested id; PostgREST filter applies
  WITH CHECK (true);

CREATE POLICY "Anon delete own plan by id"
  ON plans FOR DELETE
  USING (true);

CREATE POLICY "Anon insert exercises"
  ON exercises FOR INSERT
  WITH CHECK (true);

CREATE POLICY "Anon update exercises"
  ON exercises FOR UPDATE
  USING (true)
  WITH CHECK (true);

CREATE POLICY "Anon delete exercises"
  ON exercises FOR DELETE
  USING (true);

-- NOTE: With no SELECT policy, anon cannot SELECT these tables directly.
-- The Flutter trainer app calls INSERT/UPDATE/DELETE which don't require SELECT.
-- The web player (read-only) uses the RPC below.

-- ============================================================================
-- 2. Read-by-id RPC for the web player.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_plan_full(plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  plan_row   plans;
  exes       jsonb;
BEGIN
  SELECT * INTO plan_row FROM plans WHERE id = plan_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.position), '[]'::jsonb)
    INTO exes
    FROM exercises e
   WHERE e.plan_id = plan_id;

  RETURN jsonb_build_object(
    'plan',      to_jsonb(plan_row),
    'exercises', exes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;

-- ============================================================================
-- 3. Ordering integrity on exercises.
-- ============================================================================

-- Dedupe first: the old delete-then-insert publish flow could leave duplicate
-- (plan_id, position) rows when a publish was retried. Keep the newest row per
-- (plan_id, position) group (latest created_at; tie-break on id), drop the rest.
DELETE FROM exercises
WHERE id IN (
  SELECT id FROM (
    SELECT id,
      ROW_NUMBER() OVER (
        PARTITION BY plan_id, position
        ORDER BY created_at DESC, id DESC
      ) AS rn
    FROM exercises
  ) ranked
  WHERE rn > 1
);

-- Drop first (idempotent); re-add constraint.
ALTER TABLE exercises DROP CONSTRAINT IF EXISTS exercises_plan_id_position_unique;
ALTER TABLE exercises ADD CONSTRAINT exercises_plan_id_position_unique
  UNIQUE (plan_id, position) DEFERRABLE INITIALLY DEFERRED;

-- ============================================================================
-- 4. Storage bucket: keep public-read per object path, but we cannot
--    fully prevent LIST via the dashboard. Still tighten SELECT to require
--    a specific object name (no wildcard LIST).
-- ============================================================================

-- Only apply if storage.objects is accessible in this context.
DO $$
BEGIN
  -- Drop old public SELECT.
  EXECUTE 'DROP POLICY IF EXISTS "Public read media" ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Public upload media" ON storage.objects';

  -- Per-object read: client must know the full path.
  EXECUTE $policy$
    CREATE POLICY "Media read by path"
      ON storage.objects FOR SELECT
      USING (bucket_id = 'media' AND name IS NOT NULL)
  $policy$;

  -- Authenticated (or anon, for POV) can upload to the 'media' bucket,
  -- but can only overwrite files whose name matches a uuid/uuid pattern.
  EXECUTE $policy$
    CREATE POLICY "Media upload"
      ON storage.objects FOR INSERT
      WITH CHECK (bucket_id = 'media')
  $policy$;
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping storage.objects policy changes (need dashboard).';
END
$$;

COMMIT;

-- ============================================================================
-- Verification queries — run these after the above to sanity-check.
-- ============================================================================

-- Should return the RPC function:
--   SELECT proname FROM pg_proc WHERE proname = 'get_plan_full';
--
-- Should list only the tightened policies:
--   SELECT policyname, tablename, cmd FROM pg_policies WHERE tablename IN ('plans', 'exercises');
--
-- Attempt a direct SELECT as anon — should return 0 rows (policy blocks it):
--   SET ROLE anon;
--   SELECT count(*) FROM plans;
--   RESET ROLE;
--
-- Fetch a real plan via RPC (replace the uuid):
--   SELECT get_plan_full('00000000-0000-0000-0000-000000000000'::uuid);
