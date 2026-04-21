-- homefit.studio — Milestone P (Wave 5): Members area — identity, invites, role, remove, leave
-- =============================================================================
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_milestone_p_members.sql
-- Idempotent: every statement uses CREATE IF NOT EXISTS / OR REPLACE / DROP POLICY
-- IF EXISTS before CREATE POLICY. Safe to re-run.
--
-- NAMING NOTE: Carl's scheme labels this the "Members" milestone for Wave 5.
-- There's also a `schema_milestone_p_prep_seconds.sql` that shipped earlier
-- using the same letter. Letters have stopped being uniquely sequential —
-- we use `_members` and `_prep_seconds` qualifiers to disambiguate.
--
-- MODEL (locked 2026-04-20 per docs/CHECKPOINT_2026-04-20-late.md)
--   * Per-practitioner-per-practice invite codes — one opaque 7-char slug
--     per invited person, not per-practice group codes. Unambiguous alphabet
--     (ABCDEFGHJKLMNPQRSTUVWXYZ23456789, skip 0/O/I/1/l).
--   * No expiry — codes are valid until claimed or revoked.
--   * Auto-join on claim. claim_practice_invite inserts into practice_members
--     as role='practitioner' immediately.
--   * Owner-only mint.
--   * Member roster visible to all members (identity transparency).
--
-- WHAT THIS MIGRATION DOES
--   1. practice_invite_codes table — per-practitioner invite tokens.
--   2. RLS: SELECT scoped to user_practice_ids(); no INSERT/UPDATE/DELETE
--      policies (all mutations via SECURITY DEFINER RPCs below).
--   3. Six RPCs:
--        * list_practice_members_with_profile(p_practice_id)
--          — joins practice_members → auth.users; any member sees the roster.
--        * mint_practice_invite_code(p_practice_id)
--          — owner-only; returns the new 7-char code.
--        * claim_practice_invite(p_code)
--          — authenticated user claims an unused code; auto-joins as practitioner.
--        * set_practice_member_role(p_practice_id, p_trainer_id, p_new_role)
--          — owner-only; blocks last-owner demote + self-role-change.
--        * remove_practice_member(p_practice_id, p_trainer_id)
--          — owner-only; revokes unclaimed codes minted for the removed user.
--        * leave_practice(p_practice_id)
--          — any member; blocks last-owner-with-practitioners-remaining.
--   4. GRANT EXECUTE on all six to authenticated.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT change practice_members RLS — Milestone C + recursion_fix
--     already cover it correctly (SECURITY DEFINER helpers user_practice_ids
--     and user_is_practice_owner bypass RLS to avoid self-referential recursion).
--   * Does NOT implement undo for remove_practice_member — Wave 5 ships
--     remove as hard-delete with a success toast; undo is a follow-up wave.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. practice_invite_codes — per-practitioner invite tokens
-- ============================================================================
-- code is the natural PK so claim paths look up by the URL slug directly.
-- 7-char CHECK mirrors referral_codes; alphabet is validated at mint time.
-- claimed_by / claimed_at / revoked_at stay null until a code is used or
-- administratively invalidated.

CREATE TABLE IF NOT EXISTS public.practice_invite_codes (
  code          text PRIMARY KEY
                CHECK (length(code) = 7),
  practice_id   uuid NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
  created_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  claimed_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  claimed_at    timestamptz,
  revoked_at    timestamptz
);

CREATE INDEX IF NOT EXISTS idx_practice_invite_codes_practice
  ON public.practice_invite_codes(practice_id);

-- Partial index for fast "unused" lookups on claim (revoked_at IS NULL AND
-- claimed_at IS NULL) — covers the hot path inside claim_practice_invite.
CREATE INDEX IF NOT EXISTS idx_practice_invite_codes_unused
  ON public.practice_invite_codes(code)
  WHERE claimed_at IS NULL AND revoked_at IS NULL;

-- ============================================================================
-- 2. RLS: SELECT scoped to user's practices; all mutations via RPCs only.
-- ============================================================================

ALTER TABLE public.practice_invite_codes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS practice_invite_codes_select_own ON public.practice_invite_codes;
CREATE POLICY practice_invite_codes_select_own
  ON public.practice_invite_codes
  FOR SELECT
  TO authenticated
  USING (practice_id IN (SELECT public.user_practice_ids()));

-- No INSERT/UPDATE/DELETE policies for authenticated — RPCs only.
-- REVOKE default privileges belt-and-braces so a PostgREST misconfig
-- can't accidentally grant write access.
REVOKE INSERT, UPDATE, DELETE ON public.practice_invite_codes FROM anon, authenticated;

-- ============================================================================
-- 3. list_practice_members_with_profile — roster with email + full_name
-- ============================================================================
-- Any practice member can read the roster (transparency intentional per
-- Wave 5 design). auth.users is schema-qualified; raw_user_meta_data carries
-- the display name practitioners set at signup (full_name or name).

CREATE OR REPLACE FUNCTION public.list_practice_members_with_profile(
  p_practice_id uuid
)
RETURNS TABLE (
  trainer_id      uuid,
  email           text,
  full_name       text,
  role            text,
  joined_at       timestamptz,
  is_current_user boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  -- Any practice member can see fellow members. Use the helper fn rather
  -- than a direct subquery on practice_members (avoids RLS recursion).
  IF NOT (p_practice_id = ANY (public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      pm.trainer_id,
      u.email::text,
      COALESCE(
        (u.raw_user_meta_data->>'full_name'),
        (u.raw_user_meta_data->>'name'),
        ''
      )::text AS full_name,
      pm.role,
      pm.joined_at,
      (pm.trainer_id = auth.uid()) AS is_current_user
    FROM public.practice_members pm
    JOIN auth.users u ON u.id = pm.trainer_id
    WHERE pm.practice_id = p_practice_id
    ORDER BY pm.joined_at;
END;
$$;

-- ============================================================================
-- 4. mint_practice_invite_code — owner-only, 7-char opaque slug
-- ============================================================================
-- Alphabet mirrors the referral-codes convention (unambiguous glyphs only);
-- 32 chars → 32^7 ≈ 34B combinations. Collisions retry by catching the
-- unique_violation. Owner-only, enforced via the SECURITY DEFINER helper.

CREATE OR REPLACE FUNCTION public.mint_practice_invite_code(
  p_practice_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code      text;
  v_alphabet  text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_caller    uuid := auth.uid();
  i           int;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  -- Collision-tolerant mint loop. 32^7 ≈ 34B, collisions should be
  -- vanishingly rare at MVP scale; the retry is defensive.
  LOOP
    v_code := '';
    FOR i IN 1..7 LOOP
      v_code := v_code || substr(
        v_alphabet,
        1 + floor(random() * length(v_alphabet))::int,
        1
      );
    END LOOP;

    BEGIN
      INSERT INTO public.practice_invite_codes (code, practice_id, created_by)
      VALUES (v_code, p_practice_id, v_caller);
      RETURN v_code;
    EXCEPTION
      WHEN unique_violation THEN
        -- Collision — regenerate and try again.
        CONTINUE;
    END;
  END LOOP;
END;
$$;

-- ============================================================================
-- 5. claim_practice_invite — authenticated user claims an unused code
-- ============================================================================
-- Looks up an unclaimed, un-revoked code; auto-joins the caller into the
-- practice as role='practitioner'. Idempotent: if the caller is already a
-- member of the target practice, the code is still marked claimed (by this
-- user) and the practice id/name returned. Concurrent claims race on the
-- FOR UPDATE lock — the second wins back the "already-used" error.

CREATE OR REPLACE FUNCTION public.claim_practice_invite(
  p_code text
)
RETURNS TABLE (
  practice_id   uuid,
  practice_name text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_practice_id   uuid;
  v_practice_name text;
  v_caller        uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF p_code IS NULL OR length(p_code) <> 7 THEN
    RAISE EXCEPTION 'invalid code' USING ERRCODE = '22023';
  END IF;

  -- Lock the row so two concurrent claims can't both succeed.
  SELECT pic.practice_id
    INTO v_practice_id
    FROM public.practice_invite_codes pic
   WHERE pic.code = upper(p_code)
     AND pic.claimed_at IS NULL
     AND pic.revoked_at IS NULL
   FOR UPDATE;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'invalid or already-used code' USING ERRCODE = 'P0002';
  END IF;

  -- Idempotency: if the caller is already a member, skip the insert but
  -- still stamp the code as claimed by this user. (Avoids the "already a
  -- member" UX dead-end — the common case is a practitioner re-clicking
  -- their invite link after the first successful claim.)
  IF NOT EXISTS (
    SELECT 1
      FROM public.practice_members
     WHERE practice_id = v_practice_id
       AND trainer_id  = v_caller
  ) THEN
    INSERT INTO public.practice_members (practice_id, trainer_id, role, joined_at)
    VALUES (v_practice_id, v_caller, 'practitioner', now());
  END IF;

  UPDATE public.practice_invite_codes
     SET claimed_by = v_caller,
         claimed_at = now()
   WHERE code = upper(p_code);

  SELECT p.name
    INTO v_practice_name
    FROM public.practices p
   WHERE p.id = v_practice_id;

  RETURN QUERY SELECT v_practice_id, v_practice_name;
END;
$$;

-- ============================================================================
-- 6. set_practice_member_role — owner-only, guards last-owner + self
-- ============================================================================
-- Blocks:
--   (a) can't change your own role (prevents accidental lockout).
--   (b) can't demote the last owner (would leave the practice ownerless).
-- The new role value is validated against the role check the table already
-- enforces (owner | practitioner) — invalid values surface as 22023.

CREATE OR REPLACE FUNCTION public.set_practice_member_role(
  p_practice_id uuid,
  p_trainer_id  uuid,
  p_new_role    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_old_role   text;
  v_owner_count int;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  IF p_trainer_id = v_caller THEN
    RAISE EXCEPTION 'cannot change your own role'
      USING ERRCODE = '22023';
  END IF;

  IF p_new_role NOT IN ('owner', 'practitioner') THEN
    RAISE EXCEPTION 'invalid role: %', p_new_role
      USING ERRCODE = '22023';
  END IF;

  -- Lock the target row so a concurrent update can't race the last-owner
  -- check. If the row doesn't exist, P0002 bubbles up.
  SELECT pm.role
    INTO v_old_role
    FROM public.practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.trainer_id  = p_trainer_id
   FOR UPDATE;

  IF v_old_role IS NULL THEN
    RAISE EXCEPTION 'member not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_old_role = p_new_role THEN
    -- No-op: role already matches. Return without writing.
    RETURN;
  END IF;

  -- Demotion check: if we're demoting the target from 'owner' to
  -- 'practitioner', make sure at least one OTHER owner exists.
  IF v_old_role = 'owner' AND p_new_role <> 'owner' THEN
    SELECT COUNT(*)
      INTO v_owner_count
      FROM public.practice_members
     WHERE practice_id = p_practice_id
       AND role = 'owner'
       AND trainer_id <> p_trainer_id;

    IF v_owner_count = 0 THEN
      RAISE EXCEPTION 'cannot demote the last owner'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  UPDATE public.practice_members
     SET role = p_new_role
   WHERE practice_id = p_practice_id
     AND trainer_id  = p_trainer_id;
END;
$$;

-- ============================================================================
-- 7. remove_practice_member — owner-only hard delete + code cleanup
-- ============================================================================
-- Owner-only. Refuses to remove yourself (use leave_practice for that).
-- Refuses to remove the last owner (same rationale as role demote). Also
-- revokes any unclaimed invite codes minted FOR this user (created_by =
-- target), so their invite links stop working.

CREATE OR REPLACE FUNCTION public.remove_practice_member(
  p_practice_id uuid,
  p_trainer_id  uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller     uuid := auth.uid();
  v_role       text;
  v_owner_count int;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  IF NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'owner-only' USING ERRCODE = '42501';
  END IF;

  IF p_trainer_id = v_caller THEN
    RAISE EXCEPTION 'use leave_practice to remove yourself'
      USING ERRCODE = '22023';
  END IF;

  -- Lock the target row. P0002 if they're not a member.
  SELECT pm.role
    INTO v_role
    FROM public.practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.trainer_id  = p_trainer_id
   FOR UPDATE;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'member not found' USING ERRCODE = 'P0002';
  END IF;

  -- Last-owner guard.
  IF v_role = 'owner' THEN
    SELECT COUNT(*)
      INTO v_owner_count
      FROM public.practice_members
     WHERE practice_id = p_practice_id
       AND role = 'owner'
       AND trainer_id <> p_trainer_id;

    IF v_owner_count = 0 THEN
      RAISE EXCEPTION 'cannot remove the last owner'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Revoke any unclaimed invite codes this user created. Their codes
  -- lose effect the moment they lose access.
  UPDATE public.practice_invite_codes
     SET revoked_at = now()
   WHERE practice_id = p_practice_id
     AND created_by  = p_trainer_id
     AND claimed_at IS NULL
     AND revoked_at IS NULL;

  DELETE FROM public.practice_members
   WHERE practice_id = p_practice_id
     AND trainer_id  = p_trainer_id;
END;
$$;

-- ============================================================================
-- 8. leave_practice — self-service departure, guards last-owner + last-member
-- ============================================================================
-- Any member can leave their own practice. Blocks:
--   (a) you're the last owner AND there are practitioners remaining — must
--       promote someone first (UI hint surfaces this).
--   (b) you're the ONLY member — destructive-delete flow out of scope for
--       Wave 5 (UI suggests contacting support).

CREATE OR REPLACE FUNCTION public.leave_practice(
  p_practice_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller        uuid := auth.uid();
  v_role          text;
  v_owner_count   int;
  v_member_count  int;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'auth required' USING ERRCODE = '28000';
  END IF;

  -- Lock the caller's row. P0002 if they're not a member.
  SELECT pm.role
    INTO v_role
    FROM public.practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.trainer_id  = v_caller
   FOR UPDATE;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  -- Count TOTAL members (including self) to detect the solo-member case.
  SELECT COUNT(*)
    INTO v_member_count
    FROM public.practice_members
   WHERE practice_id = p_practice_id;

  IF v_member_count <= 1 THEN
    RAISE EXCEPTION 'cannot leave a practice where you are the only member'
      USING ERRCODE = '22023';
  END IF;

  -- Last-owner guard: if you're an owner, make sure at least one OTHER
  -- owner would remain after you leave.
  IF v_role = 'owner' THEN
    SELECT COUNT(*)
      INTO v_owner_count
      FROM public.practice_members
     WHERE practice_id = p_practice_id
       AND role = 'owner'
       AND trainer_id <> v_caller;

    IF v_owner_count = 0 THEN
      RAISE EXCEPTION 'promote another owner before leaving'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  DELETE FROM public.practice_members
   WHERE practice_id = p_practice_id
     AND trainer_id  = v_caller;
END;
$$;

-- ============================================================================
-- 9. Grants — all six RPCs are executable by authenticated users
-- ============================================================================
-- Internal membership / owner checks inside each function gate the actual
-- mutations; grants here just let a signed-in session reach them. anon is
-- never granted — these surfaces are all signed-in-only.

GRANT EXECUTE ON FUNCTION public.list_practice_members_with_profile(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.mint_practice_invite_code(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_practice_invite(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_practice_member_role(uuid, uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_practice_member(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_practice(uuid)
  TO authenticated;

REVOKE EXECUTE ON FUNCTION public.list_practice_members_with_profile(uuid)
  FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.mint_practice_invite_code(uuid)
  FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.claim_practice_invite(text)
  FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.set_practice_member_role(uuid, uuid, text)
  FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.remove_practice_member(uuid, uuid)
  FROM public, anon;
REVOKE EXECUTE ON FUNCTION public.leave_practice(uuid)
  FROM public, anon;

COMMIT;

-- ============================================================================
-- Verification queries — run these after the migration for sanity checks
-- ============================================================================
--
-- A. Table exists:
--   SELECT column_name, data_type FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='practice_invite_codes'
--    ORDER BY ordinal_position;
--
-- B. RLS policy installed:
--   SELECT policyname, cmd FROM pg_policies
--    WHERE schemaname='public' AND tablename='practice_invite_codes';
--
-- C. RPCs visible to authenticated:
--   SELECT proname FROM pg_proc p
--     JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND proname IN ('list_practice_members_with_profile',
--                      'mint_practice_invite_code',
--                      'claim_practice_invite',
--                      'set_practice_member_role',
--                      'remove_practice_member',
--                      'leave_practice')
--    ORDER BY proname;
--
-- D. Mint + claim round-trip (run as two different authed sessions):
--   -- as owner:
--   SELECT public.mint_practice_invite_code('<practice-uuid>');  -- returns 7-char
--   -- as target user:
--   SELECT * FROM public.claim_practice_invite('<code>');        -- returns practice_id + name
