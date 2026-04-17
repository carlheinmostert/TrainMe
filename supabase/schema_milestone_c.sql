-- homefit.studio — Milestone C: trainer-scoped RLS + atomic credit consumption
-- =============================================================================
-- Run in Supabase SQL Editor. Safe to re-run (every statement is idempotent).
--
-- PRE-REQS
--   * Milestone A has run (practices, practice_members, credit_ledger,
--     plan_issuances all exist; plans has practice_id + first_opened_at).
--   * Milestone B has run (Supabase Auth + Google Sign-In live; auth.uid()
--     returns a real user id; practice_members.trainer_id rows carry real
--     auth UUIDs, not the sentinel 00000...001).
--
-- WHAT THIS MIGRATION DOES
--   1. Drops every permissive `pov_all` / "Anon …" policy on plans, exercises,
--      practices, practice_members, credit_ledger, plan_issuances.
--   2. Installs trainer-scoped RLS policies keyed on auth.uid() ∈ practice_members.
--   3. Keeps the web player working by relying on `get_plan_full(uuid)` — a
--      SECURITY DEFINER RPC that bypasses RLS. Re-declared here to be safe.
--   4. Adds `practice_has_credits(practice_id, cost)` helper.
--   5. Adds `consume_credit(practice_id, plan_id, credits)` — atomic, row-
--      locked consumption used by the D1 upload_service.
--   6. Tightens storage.objects policies on the `media` bucket so INSERT /
--      UPDATE / DELETE are scoped to the authed trainer's practice, while
--      SELECT stays public (clients stream videos over share links).
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT flip plans.practice_id to NOT NULL yet — deferred until we are
--     certain every code path stamps it on insert. (Target: Milestone D.)
--   * Does NOT change `practice_credit_balance` (SECURITY DEFINER from A).
--     See gotchas below.
--   * Does NOT wire PayFast — purchase-type ledger rows will still be inserted
--     by a service-role webhook in D4 and bypass RLS naturally.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. Drop every legacy permissive policy
-- ============================================================================
-- Covers both flavours of "let everyone through": the original
-- `"Public ..."` / `"Anon ..."` policies from schema_hardening.sql, and the
-- `pov_all` policies from Milestone A.

-- plans
DROP POLICY IF EXISTS pov_all                         ON plans;
DROP POLICY IF EXISTS "Public read plans"             ON plans;
DROP POLICY IF EXISTS "Public insert plans"           ON plans;
DROP POLICY IF EXISTS "Public update plans"           ON plans;
DROP POLICY IF EXISTS "Public delete plans"           ON plans;
DROP POLICY IF EXISTS "Anon insert plans"             ON plans;
DROP POLICY IF EXISTS "Anon update own plan by id"    ON plans;
DROP POLICY IF EXISTS "Anon delete own plan by id"    ON plans;

-- exercises
DROP POLICY IF EXISTS pov_all                         ON exercises;
DROP POLICY IF EXISTS "Public read exercises"         ON exercises;
DROP POLICY IF EXISTS "Public insert exercises"       ON exercises;
DROP POLICY IF EXISTS "Public update exercises"       ON exercises;
DROP POLICY IF EXISTS "Public delete exercises"       ON exercises;
DROP POLICY IF EXISTS "Anon insert exercises"         ON exercises;
DROP POLICY IF EXISTS "Anon update exercises"         ON exercises;
DROP POLICY IF EXISTS "Anon delete exercises"         ON exercises;

-- practices / practice_members / credit_ledger / plan_issuances
DROP POLICY IF EXISTS pov_all ON practices;
DROP POLICY IF EXISTS pov_all ON practice_members;
DROP POLICY IF EXISTS pov_all ON credit_ledger;
DROP POLICY IF EXISTS pov_all ON plan_issuances;

-- Also drop any Milestone C policies we might be re-applying on a re-run.
DROP POLICY IF EXISTS plans_select_own              ON plans;
DROP POLICY IF EXISTS plans_insert_own              ON plans;
DROP POLICY IF EXISTS plans_update_own              ON plans;
DROP POLICY IF EXISTS plans_delete_own              ON plans;

DROP POLICY IF EXISTS exercises_select_own          ON exercises;
DROP POLICY IF EXISTS exercises_insert_own          ON exercises;
DROP POLICY IF EXISTS exercises_update_own          ON exercises;
DROP POLICY IF EXISTS exercises_delete_own          ON exercises;

DROP POLICY IF EXISTS practices_select_member       ON practices;
DROP POLICY IF EXISTS practices_insert_authed       ON practices;
DROP POLICY IF EXISTS practices_update_owner        ON practices;
DROP POLICY IF EXISTS practices_delete_owner        ON practices;

DROP POLICY IF EXISTS members_select_own_practices  ON practice_members;
DROP POLICY IF EXISTS members_insert_self_or_owner  ON practice_members;
DROP POLICY IF EXISTS members_update_owner          ON practice_members;
DROP POLICY IF EXISTS members_delete_owner          ON practice_members;

DROP POLICY IF EXISTS credit_ledger_select_own      ON credit_ledger;
DROP POLICY IF EXISTS credit_ledger_insert_own      ON credit_ledger;

DROP POLICY IF EXISTS plan_issuances_select_own     ON plan_issuances;
DROP POLICY IF EXISTS plan_issuances_insert_own     ON plan_issuances;

-- Make sure RLS is on for every table we care about.
ALTER TABLE plans             ENABLE ROW LEVEL SECURITY;
ALTER TABLE exercises         ENABLE ROW LEVEL SECURITY;
ALTER TABLE practices         ENABLE ROW LEVEL SECURITY;
ALTER TABLE practice_members  ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_ledger     ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_issuances    ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 2. plans — trainer-scoped policies
-- ============================================================================
-- Web player does NOT read plans directly anymore — it calls get_plan_full()
-- which runs SECURITY DEFINER and bypasses RLS. So "no anon SELECT" is fine.

CREATE POLICY plans_select_own
  ON plans FOR SELECT
  USING (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

CREATE POLICY plans_insert_own
  ON plans FOR INSERT
  WITH CHECK (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

CREATE POLICY plans_update_own
  ON plans FOR UPDATE
  USING (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  )
  WITH CHECK (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

CREATE POLICY plans_delete_own
  ON plans FOR DELETE
  USING (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

-- ============================================================================
-- 3. exercises — scoped via join to plans
-- ============================================================================
-- Milestone A already created idx_exercises_plan, which this subquery uses.

CREATE POLICY exercises_select_own
  ON exercises FOR SELECT
  USING (
    plan_id IN (
      SELECT id FROM plans
       WHERE practice_id IN (
         SELECT practice_id FROM practice_members
          WHERE trainer_id = auth.uid()
       )
    )
  );

CREATE POLICY exercises_insert_own
  ON exercises FOR INSERT
  WITH CHECK (
    plan_id IN (
      SELECT id FROM plans
       WHERE practice_id IN (
         SELECT practice_id FROM practice_members
          WHERE trainer_id = auth.uid()
       )
    )
  );

CREATE POLICY exercises_update_own
  ON exercises FOR UPDATE
  USING (
    plan_id IN (
      SELECT id FROM plans
       WHERE practice_id IN (
         SELECT practice_id FROM practice_members
          WHERE trainer_id = auth.uid()
       )
    )
  )
  WITH CHECK (
    plan_id IN (
      SELECT id FROM plans
       WHERE practice_id IN (
         SELECT practice_id FROM practice_members
          WHERE trainer_id = auth.uid()
       )
    )
  );

CREATE POLICY exercises_delete_own
  ON exercises FOR DELETE
  USING (
    plan_id IN (
      SELECT id FROM plans
       WHERE practice_id IN (
         SELECT practice_id FROM practice_members
          WHERE trainer_id = auth.uid()
       )
    )
  );

-- Idempotency belt-and-braces: the Milestone A index should already exist.
CREATE INDEX IF NOT EXISTS idx_exercises_plan ON exercises (plan_id);

-- ============================================================================
-- 4. practices — member-visible, owner-mutable, any-authed-create
-- ============================================================================

CREATE POLICY practices_select_member
  ON practices FOR SELECT
  USING (
    id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

-- Any authed user can create a new practice. The AuthService layer is
-- responsible for inserting the matching `practice_members` row with role=owner
-- in the same transaction. Members_insert_self_or_owner (below) enforces that.
CREATE POLICY practices_insert_authed
  ON practices FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY practices_update_owner
  ON practices FOR UPDATE
  USING (
    id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
         AND role = 'owner'
    )
  )
  WITH CHECK (
    id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
         AND role = 'owner'
    )
  );

CREATE POLICY practices_delete_owner
  ON practices FOR DELETE
  USING (
    id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
         AND role = 'owner'
    )
  );

-- ============================================================================
-- 5. practice_members — see fellow members; bootstrap self as owner; owners manage
-- ============================================================================
-- SELECT uses an aliased self-join (pm) so PostgreSQL doesn't mistake the
-- subquery's practice_members for the outer table's RLS-filtered view.

CREATE POLICY members_select_own_practices
  ON practice_members FOR SELECT
  USING (
    practice_id IN (
      SELECT pm.practice_id
        FROM practice_members pm
       WHERE pm.trainer_id = auth.uid()
    )
  );

-- INSERT allows two cases:
--   (a) self-bootstrap as owner: trainer_id = auth.uid() AND role = 'owner'.
--       Used when AuthService creates a fresh practice + owner row in one
--       round-trip (the row being inserted points at a practice with no
--       existing members yet).
--   (b) existing owner invites someone: the authed user is already an owner
--       of the target practice.
CREATE POLICY members_insert_self_or_owner
  ON practice_members FOR INSERT
  WITH CHECK (
    (role = 'owner' AND trainer_id = auth.uid())
    OR EXISTS (
      SELECT 1 FROM practice_members pm
       WHERE pm.practice_id = practice_members.practice_id
         AND pm.trainer_id  = auth.uid()
         AND pm.role        = 'owner'
    )
  );

-- Only owners can change roles.
CREATE POLICY members_update_owner
  ON practice_members FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM practice_members pm
       WHERE pm.practice_id = practice_members.practice_id
         AND pm.trainer_id  = auth.uid()
         AND pm.role        = 'owner'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM practice_members pm
       WHERE pm.practice_id = practice_members.practice_id
         AND pm.trainer_id  = auth.uid()
         AND pm.role        = 'owner'
    )
  );

-- Only owners can remove members (including kicking themselves — front-end
-- should guard against the last-owner case).
CREATE POLICY members_delete_owner
  ON practice_members FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM practice_members pm
       WHERE pm.practice_id = practice_members.practice_id
         AND pm.trainer_id  = auth.uid()
         AND pm.role        = 'owner'
    )
  );

-- ============================================================================
-- 6. credit_ledger — append-only, trainer-scoped
-- ============================================================================
-- No UPDATE / DELETE policies exist → RLS denies them outright. That gives us
-- the append-only guarantee at the DB level, on top of the app discipline.

CREATE POLICY credit_ledger_select_own
  ON credit_ledger FOR SELECT
  USING (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

-- Authenticated trainers can insert consumption / adjustment rows for their
-- own practice. Purchase rows are inserted by the PayFast webhook using the
-- service role, which bypasses RLS — so this policy doesn't need to allow them.
CREATE POLICY credit_ledger_insert_own
  ON credit_ledger FOR INSERT
  WITH CHECK (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

-- ============================================================================
-- 7. plan_issuances — append-only, trainer-scoped
-- ============================================================================

CREATE POLICY plan_issuances_select_own
  ON plan_issuances FOR SELECT
  USING (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

CREATE POLICY plan_issuances_insert_own
  ON plan_issuances FOR INSERT
  WITH CHECK (
    practice_id IN (
      SELECT practice_id FROM practice_members
       WHERE trainer_id = auth.uid()
    )
  );

-- No UPDATE / DELETE policies → append-only by construction.

-- ============================================================================
-- 8. get_plan_full — unchanged shape, re-declared to be safe
-- ============================================================================
-- The web player is anon and depends on this RPC. SECURITY DEFINER bypasses
-- RLS. Milestone A already added the first_opened_at stamping; we just make
-- sure the grants haven't drifted.

CREATE OR REPLACE FUNCTION public.get_plan_full(plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  plan_row  plans;
  exes      jsonb;
BEGIN
  UPDATE plans
     SET first_opened_at = now()
   WHERE id = plan_id
     AND first_opened_at IS NULL
  RETURNING * INTO plan_row;

  IF plan_row IS NULL THEN
    SELECT * INTO plan_row FROM plans WHERE id = plan_id LIMIT 1;
  END IF;

  IF plan_row IS NULL THEN
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
-- 9. practice_has_credits — convenience wrapper around the Milestone A balance
-- ============================================================================
-- Used by upload_service (D1) to short-circuit a publish attempt before we
-- bother doing the work. NOT authoritative — the atomic consume_credit()
-- call below is the source of truth.

CREATE OR REPLACE FUNCTION public.practice_has_credits(p_practice_id uuid, p_cost integer)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.practice_credit_balance(p_practice_id) >= COALESCE(p_cost, 0);
$$;

GRANT EXECUTE ON FUNCTION public.practice_has_credits(uuid, integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.practice_has_credits(uuid, integer) FROM public, anon;

-- ============================================================================
-- 10. consume_credit — atomic, race-safe credit burn for publish (D1)
-- ============================================================================
-- Contract:
--   * caller must be an authed trainer (auth.uid() not null).
--   * caller must be a member of p_practice_id — enforced explicitly inside
--     the function because SECURITY DEFINER bypasses RLS.
--   * p_credits must be > 0.
--   * Acquires a ROW SHARE lock on the practice row via SELECT ... FOR UPDATE
--     to serialise concurrent publishes within the same practice.
--   * Re-computes balance under the lock. If insufficient, returns
--     {ok:false, reason:'insufficient_credits', balance:N} without writing
--     anything.
--   * Otherwise inserts a 'consumption' ledger row with delta = -p_credits
--     and returns {ok:true, new_balance:N}.
-- Returns jsonb so callers can switch on .ok cheaply.

CREATE OR REPLACE FUNCTION public.consume_credit(
  p_practice_id uuid,
  p_plan_id     uuid,
  p_credits     integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_balance      integer;
  v_new_balance  integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'consume_credit requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'consume_credit: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_credits IS NULL OR p_credits <= 0 THEN
    RAISE EXCEPTION 'consume_credit: p_credits must be positive (got %)', p_credits
      USING ERRCODE = '22023';
  END IF;

  -- Membership check. Must be done explicitly since SECURITY DEFINER bypasses RLS.
  SELECT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'consume_credit: caller % is not a member of practice %', v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Serialise concurrent publishes for the same practice by locking the
  -- practice row. Other publishes for the same practice wait here; publishes
  -- for other practices are unaffected.
  PERFORM 1 FROM practices WHERE id = p_practice_id FOR UPDATE;

  -- Recompute balance under the lock.
  SELECT COALESCE(SUM(delta), 0)::integer
    INTO v_balance
    FROM credit_ledger
   WHERE practice_id = p_practice_id;

  IF v_balance < p_credits THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'reason',  'insufficient_credits',
      'balance', v_balance
    );
  END IF;

  INSERT INTO credit_ledger (practice_id, delta, type, plan_id, notes)
  VALUES (
    p_practice_id,
    -p_credits,
    'consumption',
    p_plan_id,
    'consume_credit(' || p_credits::text || ')'
  );

  v_new_balance := v_balance - p_credits;

  RETURN jsonb_build_object(
    'ok',          true,
    'new_balance', v_new_balance
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.consume_credit(uuid, uuid, integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.consume_credit(uuid, uuid, integer) FROM public, anon;

-- ============================================================================
-- 11. storage.objects — tighten the media bucket
-- ============================================================================
-- Keep SELECT public (web player + WhatsApp link previews need it).
-- Scope INSERT / UPDATE / DELETE to authed trainers of the owning practice.
-- Object path convention: `{session_id}/{exercise_id}.{ext}` inside the `media`
-- bucket. storage.foldername(name)[1] gives us the session uuid.

DO $$
BEGIN
  -- Drop any earlier versions.
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
    RAISE NOTICE 'Skipping storage.objects policy changes (need Supabase dashboard / service role).';
END
$$;

COMMIT;

-- ============================================================================
-- Verification queries — run these after the migration to sanity-check
-- ============================================================================
--
-- A. Policy inventory: one trainer-scoped policy set per table, no pov_all left.
--   SELECT tablename, policyname, cmd
--     FROM pg_policies
--    WHERE schemaname = 'public'
--      AND tablename IN ('plans','exercises','practices','practice_members',
--                        'credit_ledger','plan_issuances')
--    ORDER BY tablename, cmd, policyname;
--
-- B. Anon is locked out of plans (web player uses get_plan_full RPC, not table).
--   SET ROLE anon;
--   SELECT count(*) FROM plans;        -- expect 0
--   SELECT count(*) FROM exercises;    -- expect 0
--   SELECT count(*) FROM credit_ledger; -- expect 0
--   RESET ROLE;
--
-- C. RPC still works for anon (unguessable-UUID model preserved).
--   SELECT public.get_plan_full('<known-plan-uuid>'::uuid);
--
-- D. Bad consume_credit calls fail cleanly (run these AS YOURSELF when authed):
--   SELECT public.consume_credit(NULL, NULL, 1);               -- raises 22023
--   SELECT public.consume_credit(
--     '00000000-0000-0000-0000-0000000ca71e'::uuid, NULL, 0);  -- raises 22023
--   SELECT public.consume_credit(
--     '00000000-0000-0000-0000-0000000ca71e'::uuid, NULL, 1);  -- {ok:true, new_balance:999}
--
-- E. Non-member gets 42501 insufficient_privilege (run from a different auth user):
--   SELECT public.consume_credit(
--     '00000000-0000-0000-0000-0000000ca71e'::uuid, NULL, 1);  -- raises 42501
--
-- F. Storage policies visible:
--   SELECT policyname FROM pg_policies
--    WHERE schemaname = 'storage' AND tablename = 'objects';
