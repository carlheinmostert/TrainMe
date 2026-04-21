-- homefit.studio — Milestone U (Wave 14): Add practice member by email
-- =============================================================================
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_milestone_u_add_member_by_email.sql
-- Idempotent: every statement uses CREATE IF NOT EXISTS / OR REPLACE / DROP POLICY
-- IF EXISTS before CREATE POLICY. Safe to re-run.
--
-- SUPERSEDES Wave 5's invite-code flow (see schema_milestone_p_members.sql,
-- schema_fix_claim_invite_ambiguous.sql, schema_fix_list_members_srf.sql).
--
-- WHY WE'RE REPLACING THE INVITE-CODE FLOW
--   * Magic-link emails hit Supabase's built-in SMTP throttle (~4/hr
--     project-wide) — caused a live QA outage 2026-04-21.
--   * Testing needs fresh browser profiles because the invitee's session
--     collides with the owner's session in the same browser.
--   * Invitee-side confusion: "what's this 7-character code, where do I
--     paste it?" The mental model was heavy for a low-value flow.
--
-- NEW MODEL
--   * Owner types invitee's email on /members and clicks Add.
--   * If the email already has an auth.users row → the trainer is
--     inserted into practice_members immediately (role='practitioner').
--   * If not → a pending row is stashed in pending_practice_members.
--     When that email later signs up, a trigger on auth.users INSERT
--     drains the pending row into practice_members.
--   * The invitee never sees an invite link or code. Magic-link throttle
--     is no longer in the critical path.
--
-- WHAT THIS MIGRATION DOES
--   1. Drops Wave 5 surfaces: practice_invite_codes table, mint_ +
--      claim_ RPCs. Because list_practice_audit (Wave 9) has static
--      subqueries reading practice_invite_codes, we DROP that RPC first
--      (the table drop cannot cascade through without also dropping
--      that function, and we want a clean non-CASCADE drop).
--   2. Creates pending_practice_members table + RLS select-own policy.
--   3. Creates add_practice_member_by_email RPC — owner-only, returns
--      kind ('added' | 'already_member' | 'pending').
--   4. Creates remove_pending_practice_member RPC — owner-only; cancels
--      a pending entry before it drains.
--   5. Creates list_practice_members_and_pending RPC — UNIONs current
--      members (with profile) and pending entries; used by /members UI.
--      The existing list_practice_members_with_profile stays intact for
--      backward-compat callers (audit filter bar, mobile, etc.).
--   6. Creates claim_pending_practice_memberships() + AFTER INSERT
--      trigger on auth.users — drains pending rows on signup.
--   7. Recreates list_practice_audit() without the invite.mint /
--      invite.claim subqueries. The corresponding chip kinds stay in
--      the portal's AUDIT_EVENT_KINDS enum so any pre-migration
--      audit_events rows with invite.revoke still render; the two
--      natural-key subqueries simply no longer produce rows because
--      their source table is gone.
--
-- SCHEMA NOTES
--   * `citext` extension provides case-insensitive comparison on the
--     `email` column. Supabase ships the extension by default; the
--     CREATE EXTENSION IF NOT EXISTS is a harmless no-op when already
--     installed.
--   * The trigger is on auth.users (a Supabase-managed table). We don't
--     own the table; we can only attach triggers. Supabase docs
--     explicitly sanction this pattern (see the "handle_new_user"
--     boilerplate across their examples).
-- =============================================================================

BEGIN;

-- ============================================================================
-- 0. Extension — case-insensitive email matching.
-- ============================================================================
-- Supabase pre-installs this, but declare it explicitly so a fresh-instance
-- re-run is idempotent.

CREATE EXTENSION IF NOT EXISTS citext;

-- ============================================================================
-- 1. Drop Wave 5 invite-code surfaces.
-- ============================================================================
-- Order matters:
--   (a) list_practice_audit reads practice_invite_codes in two UNION ALL
--       branches. Dropping the table without CASCADE would fail; dropping
--       it WITH CASCADE would also drop the audit RPC, which we want to
--       recreate immediately below. Dropping the RPC first lets us drop
--       the table cleanly.
--   (b) mint_ + claim_ RPCs reference the table but have their own
--       existence; we drop them for explicitness rather than relying on
--       cascade semantics.

DROP FUNCTION IF EXISTS public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
);

DROP FUNCTION IF EXISTS public.mint_practice_invite_code(uuid);
DROP FUNCTION IF EXISTS public.claim_practice_invite(text);
DROP TABLE    IF EXISTS public.practice_invite_codes;

-- ============================================================================
-- 2. pending_practice_members — parking lot for not-yet-signed-up invitees.
-- ============================================================================
-- PK is (email, practice_id) — one pending row per email per practice.
-- Re-adding the same email is idempotent via ON CONFLICT DO UPDATE in
-- the add RPC, refreshing added_by + added_at to the latest owner push.
--
-- FK on practice_id CASCADE: if a practice is deleted, its pending
-- invites vanish with it (matches the practice_members ON DELETE
-- CASCADE behaviour).
--
-- added_by → auth.users ON DELETE SET NULL so an owner leaving /
-- being deleted doesn't blow away outstanding pending rows; the
-- audit crumb simply loses its actor.

CREATE TABLE IF NOT EXISTS public.pending_practice_members (
  email         CITEXT NOT NULL,
  practice_id   uuid   NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
  added_by      uuid            REFERENCES auth.users(id)       ON DELETE SET NULL,
  added_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (email, practice_id)
);

-- Secondary index on email so the auth.users trigger's SELECT (by the
-- new signup's email) is O(1) regardless of practice_id.
CREATE INDEX IF NOT EXISTS idx_pending_practice_members_email
  ON public.pending_practice_members (email);

ALTER TABLE public.pending_practice_members ENABLE ROW LEVEL SECURITY;

-- SELECT: any practice member can see pending rows for their practice
-- (so the /members table can list them). Writes gated through RPCs only.
DROP POLICY IF EXISTS pending_practice_members_select_own
  ON public.pending_practice_members;
CREATE POLICY pending_practice_members_select_own
  ON public.pending_practice_members
  FOR SELECT
  TO authenticated
  USING (practice_id IN (SELECT public.user_practice_ids()));

-- Belt-and-suspenders: revoke default CRUD grants so a PostgREST
-- misconfig can't accidentally let clients write.
REVOKE INSERT, UPDATE, DELETE
  ON public.pending_practice_members FROM anon, authenticated;

-- ============================================================================
-- 3. add_practice_member_by_email — owner-only, two-path add.
-- ============================================================================
-- Owner clicks Add on /members:
--   * If an auth.users row exists for the email, add the user to
--     practice_members as practitioner immediately. If already a
--     member, return kind='already_member' with their current role.
--   * If no auth.users row, upsert into pending_practice_members and
--     return kind='pending'. The trigger will drain it on signup.
--
-- Returns a single-row TABLE so the portal's RPC wrapper can pick up
-- the kind + identity columns in one round trip and surface them in
-- a toast ("Added foo@bar.com" vs. "Saved — will join automatically").
--
-- SQLSTATE choices mirror Milestone P:
--   * 28000 — no authenticated caller.
--   * 42501 — caller is not the practice owner.
--   * 22023 — email missing / malformed.

CREATE OR REPLACE FUNCTION public.add_practice_member_by_email(
  p_practice_id uuid,
  p_email       text
)
RETURNS TABLE (
  kind         text,       -- 'added' | 'already_member' | 'pending'
  trainer_id   uuid,
  email        text,
  full_name    text,
  role         text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- PL/pgSQL 42702 trap: RETURNS TABLE OUT columns are visible as variables
-- inside the function body, and collide with real table columns of the
-- same name inside INSERT / ON CONFLICT / UPDATE targets
-- (pending_practice_members.email, practice_members.role, etc.).
-- `#variable_conflict use_column` tells the parser to resolve ambiguous
-- names to the TABLE column first. Same class of bug the delete_client
-- hotfix hit (Milestone L).
#variable_conflict use_column
DECLARE
  v_caller uuid := auth.uid();
  v_clean  citext;
  v_user   auth.users%rowtype;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  -- Normalise: trim + lower + citext-cast. Reject obvious garbage
  -- before the auth.users probe so callers get a clean "invalid email"
  -- instead of a lookup miss masked as "pending".
  v_clean := lower(trim(COALESCE(p_email, '')))::citext;
  IF position('@' in v_clean::text) = 0
     OR length(v_clean::text) < 5 THEN
    RAISE EXCEPTION 'invalid email' USING ERRCODE = '22023';
  END IF;

  -- Live lookup against auth.users. Email column is citext on Supabase.
  SELECT *
    INTO v_user
    FROM auth.users u
   WHERE u.email::citext = v_clean
   LIMIT 1;

  IF v_user.id IS NOT NULL THEN
    -- Account exists. Already a member?
    IF EXISTS (
      SELECT 1 FROM public.practice_members pm
       WHERE pm.practice_id = p_practice_id
         AND pm.trainer_id  = v_user.id
    ) THEN
      RETURN QUERY
        SELECT
          'already_member'::text                              AS kind,
          v_user.id                                           AS trainer_id,
          v_user.email::text                                  AS email,
          COALESCE(
            (v_user.raw_user_meta_data->>'full_name'),
            (v_user.raw_user_meta_data->>'name'),
            ''
          )::text                                             AS full_name,
          (
            SELECT pm.role
              FROM public.practice_members pm
             WHERE pm.practice_id = p_practice_id
               AND pm.trainer_id  = v_user.id
          )::text                                             AS role;
      RETURN;
    END IF;

    -- Not a member yet — insert and return 'added'.
    INSERT INTO public.practice_members (practice_id, trainer_id, role, joined_at)
    VALUES (p_practice_id, v_user.id, 'practitioner', now());

    RETURN QUERY
      SELECT
        'added'::text                                         AS kind,
        v_user.id                                             AS trainer_id,
        v_user.email::text                                    AS email,
        COALESCE(
          (v_user.raw_user_meta_data->>'full_name'),
          (v_user.raw_user_meta_data->>'name'),
          ''
        )::text                                               AS full_name,
        'practitioner'::text                                  AS role;
    RETURN;
  END IF;

  -- No auth.users row yet. Stash pending. Idempotent via the PK:
  -- re-adding the same email refreshes added_by + added_at so the
  -- /members page always shows the most recent nudge.
  INSERT INTO public.pending_practice_members (email, practice_id, added_by)
  VALUES (v_clean, p_practice_id, v_caller)
  ON CONFLICT (email, practice_id) DO UPDATE
     SET added_by = EXCLUDED.added_by,
         added_at = now();

  RETURN QUERY
    SELECT
      'pending'::text                                         AS kind,
      NULL::uuid                                              AS trainer_id,
      v_clean::text                                           AS email,
      ''::text                                                AS full_name,
      'practitioner'::text                                    AS role;
END;
$$;

REVOKE ALL ON FUNCTION public.add_practice_member_by_email(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_practice_member_by_email(uuid, text)
  TO authenticated;

-- ============================================================================
-- 4. remove_pending_practice_member — owner-only cancel-before-drain.
-- ============================================================================
-- Owner can revoke a pending add before the user signs up.

CREATE OR REPLACE FUNCTION public.remove_pending_practice_member(
  p_practice_id uuid,
  p_email       text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.pending_practice_members
   WHERE email       = lower(trim(COALESCE(p_email, '')))::citext
     AND practice_id = p_practice_id;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_pending_practice_member(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_pending_practice_member(uuid, text)
  TO authenticated;

-- ============================================================================
-- 5. list_practice_members_and_pending — one call, both sections.
-- ============================================================================
-- Keeping list_practice_members_with_profile intact for backward-compat
-- callers (audit filter, mobile). This new sibling UNIONs the current
-- roster with pending rows, tagged so the portal can split the two
-- sections cleanly.
--
-- Column layout mirrors list_practice_members_with_profile with three
-- extra columns:
--   * is_pending  — true when the row is a pending entry (no auth.users
--     row yet; trainer_id is NULL).
--   * added_by    — actor who staged the pending row (practitioner uuid).
--   * added_at    — when the pending row was staged.
-- For current-member rows these extras are NULL.

CREATE OR REPLACE FUNCTION public.list_practice_members_and_pending(
  p_practice_id uuid
)
RETURNS TABLE (
  trainer_id      uuid,
  email           text,
  full_name       text,
  role            text,
  joined_at       timestamptz,
  is_current_user boolean,
  is_pending      boolean,
  added_by        uuid,
  added_at        timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- Same 42702 guard as add_practice_member_by_email — OUT column names
-- collide with real table columns inside the UNION body (pm.role,
-- ppm.email, etc.). See the comment there for detail.
#variable_conflict use_column
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  -- Any practice member can see the roster + pending. Transparency is
  -- the Wave 5 design choice; we keep it for Wave 14.
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    pm.trainer_id                                  AS trainer_id,
    u.email::text                                  AS email,
    COALESCE(
      (u.raw_user_meta_data->>'full_name'),
      (u.raw_user_meta_data->>'name'),
      ''
    )::text                                        AS full_name,
    pm.role                                        AS role,
    pm.joined_at                                   AS joined_at,
    (pm.trainer_id = auth.uid())                   AS is_current_user,
    FALSE                                          AS is_pending,
    NULL::uuid                                     AS added_by,
    NULL::timestamptz                              AS added_at
  FROM public.practice_members pm
  JOIN auth.users u ON u.id = pm.trainer_id
  WHERE pm.practice_id = p_practice_id

  UNION ALL

  SELECT
    NULL::uuid                                     AS trainer_id,
    ppm.email::text                                AS email,
    ''::text                                       AS full_name,
    'practitioner'::text                           AS role,
    NULL::timestamptz                              AS joined_at,
    FALSE                                          AS is_current_user,
    TRUE                                           AS is_pending,
    ppm.added_by                                   AS added_by,
    ppm.added_at                                   AS added_at
  FROM public.pending_practice_members ppm
  WHERE ppm.practice_id = p_practice_id

  ORDER BY is_pending ASC, joined_at ASC NULLS LAST, added_at ASC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.list_practice_members_and_pending(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_practice_members_and_pending(uuid)
  TO authenticated;

-- ============================================================================
-- 6. claim_pending_practice_memberships — auth.users INSERT trigger.
-- ============================================================================
-- When a new auth.users row is inserted, drain every pending_practice_members
-- row with a matching email into practice_members, then delete those
-- pending rows. Idempotent via the NOT EXISTS guard so a racey drain won't
-- duplicate practice_members rows.
--
-- The function is owned by the postgres role (SECURITY DEFINER) so it can
-- write to practice_members regardless of the (new) user's RLS context.

CREATE OR REPLACE FUNCTION public.claim_pending_practice_memberships()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.email IS NULL THEN
    RETURN NEW;
  END IF;

  -- Drain: insert every pending row's practice into practice_members.
  -- The NOT EXISTS guard protects against a race where the user is
  -- already a member (e.g. created_by trigger order quirks, defensive
  -- replay). joined_at = now() so the roster shows the effective
  -- join timestamp, not the original invite time.
  INSERT INTO public.practice_members (practice_id, trainer_id, role, joined_at)
  SELECT ppm.practice_id, NEW.id, 'practitioner', now()
    FROM public.pending_practice_members ppm
   WHERE ppm.email = NEW.email::citext
     AND NOT EXISTS (
       SELECT 1 FROM public.practice_members pm
        WHERE pm.practice_id = ppm.practice_id
          AND pm.trainer_id  = NEW.id
     );

  -- Clear out the pending rows for this email regardless of how many
  -- inserts happened above (some may have been skipped by the
  -- idempotency guard). The pending row's job is done either way.
  DELETE FROM public.pending_practice_members
   WHERE email = NEW.email::citext;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS claim_pending_practice_memberships_trigger
  ON auth.users;
CREATE TRIGGER claim_pending_practice_memberships_trigger
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.claim_pending_practice_memberships();

-- ============================================================================
-- 7. Recreate list_practice_audit — same shape, minus invite-code branches.
-- ============================================================================
-- The Wave 9 RPC joined practice_invite_codes in two UNION ALL arms
-- (invite.mint + invite.claim). Wave 14 removes those arms since the
-- source table is gone. invite.revoke audit_events rows (if any were
-- ever recorded via record_audit_event) continue to surface through the
-- audit_events catchall branch — their meta is table-independent.
--
-- Signature + column layout are byte-for-byte identical to the Wave 9
-- revision so the portal's types / row mappers don't shift.

CREATE OR REPLACE FUNCTION public.list_practice_audit(
  p_practice_id uuid,
  p_offset      int         DEFAULT 0,
  p_limit       int         DEFAULT 50,
  p_kinds       text[]      DEFAULT NULL,
  p_actor       uuid        DEFAULT NULL,
  p_from        timestamptz DEFAULT NULL,
  p_to          timestamptz DEFAULT NULL
)
RETURNS TABLE (
  ts             timestamptz,
  kind           text,
  trainer_id     uuid,
  email          text,
  full_name      text,
  title          text,
  credits_delta  numeric,
  balance_after  numeric,
  ref_id         uuid,
  meta           jsonb,
  total_count    bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH unioned AS (
    -- plan_issuances → kind = 'plan.publish'
    SELECT
      pi.issued_at                                    AS a_ts,
      'plan.publish'::text                            AS a_kind,
      pi.trainer_id                                   AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      p.title::text                                   AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      pi.plan_id                                      AS a_ref_id,
      jsonb_build_object('version', pi.version)       AS a_meta
    FROM public.plan_issuances pi
    JOIN public.plans p ON p.id = pi.plan_id
    LEFT JOIN auth.users u ON u.id = pi.trainer_id
    WHERE pi.practice_id = p_practice_id

    UNION ALL

    -- credit_ledger → kind = 'credit.' || type
    SELECT
      cl.created_at                                   AS a_ts,
      ('credit.' || cl.type)::text                    AS a_kind,
      NULL::uuid                                      AS a_trainer_id,
      NULL::text                                      AS a_email,
      NULL::text                                      AS a_full_name,
      cl.notes::text                                  AS a_title,
      cl.delta::numeric                               AS a_credits_delta,
      (SUM(cl.delta) OVER (
        ORDER BY cl.created_at, cl.id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ))::numeric                                     AS a_balance_after,
      cl.plan_id                                      AS a_ref_id,
      CASE
        WHEN cl.payfast_payment_id IS NOT NULL
          THEN jsonb_build_object('payfast_payment_id', cl.payfast_payment_id)
        ELSE NULL
      END                                             AS a_meta
    FROM public.credit_ledger cl
    WHERE cl.practice_id = p_practice_id

    UNION ALL

    -- referral_rebate_ledger → kind = 'referral.rebate'
    SELECT
      rrl.created_at                                  AS a_ts,
      'referral.rebate'::text                         AS a_kind,
      NULL::uuid                                      AS a_trainer_id,
      NULL::text                                      AS a_email,
      NULL::text                                      AS a_full_name,
      NULL::text                                      AS a_title,
      rrl.credits::numeric                            AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      rrl.referee_practice_id                         AS a_ref_id,
      jsonb_build_object(
        'referee_practice_id',     rrl.referee_practice_id,
        'source_credit_ledger_id', rrl.source_credit_ledger_id,
        'rebate_kind',             rrl.kind,
        'zar_amount',              rrl.zar_amount
      )                                               AS a_meta
    FROM public.referral_rebate_ledger rrl
    WHERE rrl.referrer_practice_id = p_practice_id

    UNION ALL

    -- clients.created_at → kind = 'client.create'
    SELECT
      c.created_at                                    AS a_ts,
      'client.create'::text                           AS a_kind,
      NULL::uuid                                      AS a_trainer_id,
      NULL::text                                      AS a_email,
      NULL::text                                      AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta
    FROM public.clients c
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NULL

    UNION ALL

    -- clients.deleted_at → kind = 'client.delete'
    SELECT
      c.deleted_at                                    AS a_ts,
      'client.delete'::text                           AS a_kind,
      NULL::uuid                                      AS a_trainer_id,
      NULL::text                                      AS a_email,
      NULL::text                                      AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta
    FROM public.clients c
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NOT NULL

    UNION ALL

    -- practice_members.joined_at → kind = 'member.join'
    SELECT
      pm.joined_at                                    AS a_ts,
      'member.join'::text                             AS a_kind,
      pm.trainer_id                                   AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      pm.role::text                                   AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      pm.trainer_id                                   AS a_ref_id,
      NULL::jsonb                                     AS a_meta
    FROM public.practice_members pm
    LEFT JOIN auth.users u ON u.id = pm.trainer_id
    WHERE pm.practice_id = p_practice_id

    UNION ALL

    -- audit_events (catchall for member.role_change / member.remove /
    -- practice.rename / client.restore / etc.)
    SELECT
      ae.ts                                           AS a_ts,
      ae.kind                                         AS a_kind,
      ae.actor_id                                     AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      NULL::text                                      AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      ae.ref_id                                       AS a_ref_id,
      ae.meta                                         AS a_meta
    FROM public.audit_events ae
    LEFT JOIN auth.users u ON u.id = ae.actor_id
    WHERE ae.practice_id = p_practice_id
  ),
  filtered AS (
    SELECT *
      FROM unioned un
     WHERE (p_kinds IS NULL OR un.a_kind        = ANY (p_kinds))
       AND (p_actor IS NULL OR un.a_trainer_id  = p_actor)
       AND (p_from  IS NULL OR un.a_ts         >= p_from)
       AND (p_to    IS NULL OR un.a_ts         <= p_to)
  )
  SELECT
    f.a_ts            AS ts,
    f.a_kind          AS kind,
    f.a_trainer_id    AS trainer_id,
    f.a_email         AS email,
    f.a_full_name     AS full_name,
    f.a_title         AS title,
    f.a_credits_delta AS credits_delta,
    f.a_balance_after AS balance_after,
    f.a_ref_id        AS ref_id,
    f.a_meta          AS meta,
    COUNT(*) OVER ()::bigint AS total_count
  FROM filtered f
  ORDER BY f.a_ts DESC
  OFFSET GREATEST(p_offset, 0)
  LIMIT  GREATEST(p_limit, 1);
END;
$$;

REVOKE ALL ON FUNCTION public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
) TO authenticated;

COMMIT;

-- =============================================================================
-- Verification queries — run after migration for sanity checks
-- =============================================================================
--
-- A. Old invite-code surfaces gone:
--   SELECT to_regclass('public.practice_invite_codes');        -- → null
--   SELECT proname FROM pg_proc WHERE proname IN
--     ('mint_practice_invite_code','claim_practice_invite');   -- → 0 rows
--
-- B. Pending table + policy live:
--   SELECT column_name, data_type FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='pending_practice_members'
--    ORDER BY ordinal_position;
--   SELECT policyname, cmd FROM pg_policies
--    WHERE schemaname='public' AND tablename='pending_practice_members';
--
-- C. Three new functions visible:
--   SELECT proname FROM pg_proc p
--     JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public'
--      AND proname IN (
--        'add_practice_member_by_email',
--        'remove_pending_practice_member',
--        'list_practice_members_and_pending')
--    ORDER BY proname;
--
-- D. Auth trigger installed:
--   SELECT tgname FROM pg_trigger
--    WHERE tgname = 'claim_pending_practice_memberships_trigger';
--
-- E. Audit RPC still works after invite-branch removal:
--   SELECT COUNT(*) FROM public.list_practice_audit('<practice-uuid>');
