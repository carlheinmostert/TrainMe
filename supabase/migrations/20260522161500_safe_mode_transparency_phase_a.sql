-- ============================================================================
-- Safe Mode Transparency — Phase A: identity gate
-- ============================================================================
-- Spec: docs/specs/2026-05-22-safe-mode-transparency.md
--
-- Phase A introduces the practitioner-identity layer that gates Safe Mode.
-- Before Safe Mode can transition to `active` (auto OR manual), the
-- six-point contract must hold:
--
--   Practitioner-controlled:
--     1. first_name set + non-empty
--     2. last_name set + non-empty
--     3. avatar_url set + face-detect verified at capture time
--   Practice-controlled (existing columns from Public Profile v2):
--     4. public_slug set on practices
--     5. public_blurb set + non-empty
--     6. public_profile_listed = true
--
-- New objects:
--   * practitioners      — one row per Supabase user; identity columns.
--   * practitioner_audit_log — append-only diff of identity changes.
--   * set_practitioner_profile — SECURITY DEFINER RPC that writes both.
--   * can_use_safe_mode  — returns (ok, missing[]) for the 6-point check.
--
-- Lockdown:
--   `practitioners` is RPC-write-only (mirrors credit_ledger). Clients
--   may SELECT but never INSERT/UPDATE/DELETE — the RPC owns all writes.
--   Audit log is INSERT-only; SELECT scoped to the trainer themselves +
--   any practice owner who shares membership with them.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. practitioners table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.practitioners (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  first_name text,
  last_name  text,
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practitioners_first_name_length') THEN
    ALTER TABLE public.practitioners
      ADD CONSTRAINT practitioners_first_name_length
        CHECK (first_name IS NULL OR length(btrim(first_name)) BETWEEN 1 AND 60);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practitioners_last_name_length') THEN
    ALTER TABLE public.practitioners
      ADD CONSTRAINT practitioners_last_name_length
        CHECK (last_name IS NULL OR length(btrim(last_name)) BETWEEN 1 AND 60);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'practitioners_avatar_url_shape') THEN
    ALTER TABLE public.practitioners
      ADD CONSTRAINT practitioners_avatar_url_shape
        CHECK (avatar_url IS NULL OR avatar_url ~ '^https://');
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS practitioners_user_idx ON public.practitioners (user_id);

-- ---------------------------------------------------------------------------
-- 2. practitioner_audit_log table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.practitioner_audit_log (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trainer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  field      text NOT NULL CHECK (field IN ('first_name', 'last_name', 'avatar_url')),
  old_value  text,
  new_value  text,
  changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS practitioner_audit_log_trainer_changed_idx
  ON public.practitioner_audit_log (trainer_id, changed_at DESC);

-- ---------------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.practitioners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.practitioner_audit_log ENABLE ROW LEVEL SECURITY;

-- practitioners: SELECT self + SELECT anyone in a shared practice (so a
-- practice owner can see their team's identity rows for the live page +
-- portal-side visibility once Phase B/C surface them).
DROP POLICY IF EXISTS practitioners_select_self ON public.practitioners;
CREATE POLICY practitioners_select_self
  ON public.practitioners
  FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1
        FROM public.practice_members pm_self
        JOIN public.practice_members pm_other
          ON pm_other.practice_id = pm_self.practice_id
       WHERE pm_self.trainer_id = auth.uid()
         AND pm_other.trainer_id = practitioners.user_id
    )
  );

-- No INSERT / UPDATE / DELETE policies — the RPC is the only writer.
-- (Policies missing = deny by default once RLS is on.)

-- practitioner_audit_log: SELECT for the trainer themselves + owners of
-- any practice the trainer belongs to.
DROP POLICY IF EXISTS practitioner_audit_log_select ON public.practitioner_audit_log;
CREATE POLICY practitioner_audit_log_select
  ON public.practitioner_audit_log
  FOR SELECT
  TO authenticated
  USING (
    trainer_id = auth.uid()
    OR EXISTS (
      SELECT 1
        FROM public.practice_members pm_owner
        JOIN public.practice_members pm_trainer
          ON pm_trainer.practice_id = pm_owner.practice_id
       WHERE pm_owner.trainer_id = auth.uid()
         AND pm_owner.role = 'owner'
         AND pm_trainer.trainer_id = practitioner_audit_log.trainer_id
    )
  );

-- ---------------------------------------------------------------------------
-- 4. Revoke direct writes — RPC-write-only lockdown.
-- ---------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON public.practitioners FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.practitioners FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.practitioner_audit_log FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.practitioner_audit_log FROM anon;

GRANT SELECT ON public.practitioners TO authenticated;
GRANT SELECT ON public.practitioner_audit_log TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. set_practitioner_profile RPC
--    Upserts the caller's row + appends one audit-log entry per
--    changed field. Empty-string inputs normalise to NULL so the
--    length CHECK constraints stay satisfied.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.set_practitioner_profile(text, text, text);

CREATE FUNCTION public.set_practitioner_profile(
  p_first_name text,
  p_last_name  text,
  p_avatar_url text
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller   uuid := auth.uid();
  v_first    text := nullif(btrim(coalesce(p_first_name, '')), '');
  v_last     text := nullif(btrim(coalesce(p_last_name, '')),  '');
  v_avatar   text := nullif(btrim(coalesce(p_avatar_url, '')), '');
  v_existing public.practitioners%ROWTYPE;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_practitioner_profile requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF v_first IS NOT NULL AND length(v_first) > 60 THEN
    RAISE EXCEPTION 'set_practitioner_profile: first_name too long (max 60)'
      USING ERRCODE = '22023';
  END IF;
  IF v_last IS NOT NULL AND length(v_last) > 60 THEN
    RAISE EXCEPTION 'set_practitioner_profile: last_name too long (max 60)'
      USING ERRCODE = '22023';
  END IF;
  IF v_avatar IS NOT NULL AND v_avatar !~ '^https://' THEN
    RAISE EXCEPTION 'set_practitioner_profile: avatar_url must be https://'
      USING ERRCODE = '22023';
  END IF;

  -- Capture old values for the diff.
  SELECT * INTO v_existing FROM public.practitioners WHERE user_id = v_caller;

  INSERT INTO public.practitioners (user_id, first_name, last_name, avatar_url, updated_at)
  VALUES (v_caller, v_first, v_last, v_avatar, now())
  ON CONFLICT (user_id) DO UPDATE
     SET first_name = EXCLUDED.first_name,
         last_name  = EXCLUDED.last_name,
         avatar_url = EXCLUDED.avatar_url,
         updated_at = now();

  -- Per-field audit entries — only when the value actually changed.
  IF v_existing.first_name IS DISTINCT FROM v_first THEN
    INSERT INTO public.practitioner_audit_log (trainer_id, field, old_value, new_value)
    VALUES (v_caller, 'first_name', v_existing.first_name, v_first);
  END IF;
  IF v_existing.last_name IS DISTINCT FROM v_last THEN
    INSERT INTO public.practitioner_audit_log (trainer_id, field, old_value, new_value)
    VALUES (v_caller, 'last_name', v_existing.last_name, v_last);
  END IF;
  IF v_existing.avatar_url IS DISTINCT FROM v_avatar THEN
    INSERT INTO public.practitioner_audit_log (trainer_id, field, old_value, new_value)
    VALUES (v_caller, 'avatar_url', v_existing.avatar_url, v_avatar);
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_practitioner_profile(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_practitioner_profile(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_practitioner_profile(text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. can_use_safe_mode RPC
--    Returns (ok boolean, missing text[]) — empty missing[] when ok=true.
--    Caller passes trainer + practice; the RPC checks all 6 points and
--    returns the list of missing requirements (stable identifier strings
--    the client renders into the gate UI).
--
--    Missing identifiers (stable; client maps these to copy):
--      'first_name', 'last_name', 'avatar_url'   — practitioner-controlled
--      'public_slug', 'public_blurb', 'public_profile_listed'
--                                                — practice-controlled
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.can_use_safe_mode(uuid, uuid);

CREATE FUNCTION public.can_use_safe_mode(
  p_trainer_id  uuid,
  p_practice_id uuid
)
 RETURNS TABLE (ok boolean, missing text[])
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller   uuid := auth.uid();
  v_prac     public.practitioners%ROWTYPE;
  v_practice public.practices%ROWTYPE;
  v_missing  text[] := ARRAY[]::text[];
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'can_use_safe_mode requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Allow self-query OR practice-member query (so a practice owner could
  -- ask "is my team-member eligible?"). Anyone outside the shared
  -- membership gets a hard 403-shape error.
  IF p_trainer_id IS NULL OR p_practice_id IS NULL THEN
    RAISE EXCEPTION 'can_use_safe_mode: trainer_id and practice_id required'
      USING ERRCODE = '22023';
  END IF;

  IF p_trainer_id <> v_caller
     AND NOT (p_practice_id = ANY(SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'can_use_safe_mode: not authorised for this practice'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_prac FROM public.practitioners WHERE user_id = p_trainer_id;
  SELECT * INTO v_practice FROM public.practices WHERE id = p_practice_id;

  IF v_practice.id IS NULL THEN
    RAISE EXCEPTION 'can_use_safe_mode: practice not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Practitioner-level checks
  IF v_prac.first_name IS NULL OR btrim(v_prac.first_name) = '' THEN
    v_missing := v_missing || 'first_name';
  END IF;
  IF v_prac.last_name IS NULL OR btrim(v_prac.last_name) = '' THEN
    v_missing := v_missing || 'last_name';
  END IF;
  IF v_prac.avatar_url IS NULL OR btrim(v_prac.avatar_url) = '' THEN
    v_missing := v_missing || 'avatar_url';
  END IF;

  -- Practice-level checks
  IF v_practice.public_slug IS NULL OR btrim(v_practice.public_slug) = '' THEN
    v_missing := v_missing || 'public_slug';
  END IF;
  IF v_practice.public_blurb IS NULL OR btrim(v_practice.public_blurb) = '' THEN
    v_missing := v_missing || 'public_blurb';
  END IF;
  IF NOT coalesce(v_practice.public_profile_listed, false) THEN
    v_missing := v_missing || 'public_profile_listed';
  END IF;

  ok := (array_length(v_missing, 1) IS NULL);
  missing := v_missing;
  RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.can_use_safe_mode(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_use_safe_mode(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_use_safe_mode(uuid, uuid) TO service_role;

COMMIT;
