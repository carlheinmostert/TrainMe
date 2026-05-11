-- homefit.studio — Milestone R: sticky per-client exercise defaults (Wave 8)
-- =============================================================================
-- Run via `supabase db query --linked --file supabase/schema_milestone_r_sticky_defaults.sql`.
-- Safe to re-run (every statement is idempotent).
--
-- PRE-REQS
--   * Milestone G applied (clients table, video_consent jsonb, user_practice_ids()).
--
-- WHAT THIS MIGRATION DOES
--   1. Adds `clients.client_exercise_defaults` JSONB with default `{}` — holds
--      the practitioner's most-recent edit of the seven sticky fields on a
--      per-client basis. Forward-only propagation: next capture for that
--      client pre-fills from this map; overrides update the map.
--   2. Ships `public.set_client_exercise_default(p_client_id, p_field, p_value)`
--      SECURITY DEFINER RPC. One-key-at-a-time upsert via jsonb_set so the
--      client doesn't need a read-modify-write round trip. Practice-membership
--      checked inside the fn.
--   3. Extends `list_practice_clients` + `get_client_by_id` to RETURN the new
--      jsonb so the Flutter app can seed its cache without a second round
--      trip. Additive — existing row-shape columns keep their names.
--
-- SEVEN STICKY FIELDS (UI enforces; DB stays schemaless for future additions)
--   reps                      (integer)
--   sets                      (integer)
--   hold_seconds              (integer)
--   include_audio             (boolean)      ← "muted" is UI-inverted
--   preferred_treatment       ('line'|'grayscale'|'original')
--   prep_seconds              (integer)
--   custom_duration_seconds   (integer, nullable — absence means "auto")
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT touch existing captures. Propagation is forward-only; past
--     sessions stay exactly as captured.
--   * Does NOT enforce field names at the DB layer. If a client adds a
--     typo'd key, the value simply never gets read. Keeps the column
--     flexible for Wave N+ additions without a schema migration.
-- =============================================================================

BEGIN;

-- 1. Column on clients ---------------------------------------------------------
ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS client_exercise_defaults JSONB NOT NULL DEFAULT '{}'::jsonb;

-- 2. set_client_exercise_default RPC ------------------------------------------
-- Writes ONE key at a time so mobile doesn't need a read-modify-write round
-- trip (otherwise two simultaneous edits would race). jsonb_set with the
-- create_if_missing flag upserts the field.
CREATE OR REPLACE FUNCTION public.set_client_exercise_default(
  p_client_id UUID,
  p_field     TEXT,
  p_value     JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller   UUID := auth.uid();
  v_practice UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_field IS NULL OR length(trim(p_field)) = 0 THEN
    RAISE EXCEPTION 'set_client_exercise_default: p_field must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id INTO v_practice
    FROM public.clients
   WHERE id = p_client_id
   LIMIT 1;

  IF v_practice IS NULL THEN
    RAISE EXCEPTION 'set_client_exercise_default: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  -- Membership check (SECURITY DEFINER bypasses RLS).
  IF NOT (v_practice = ANY (public.user_practice_ids())) THEN
    RAISE EXCEPTION 'set_client_exercise_default: caller % is not a member of practice %',
      v_caller, v_practice
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.clients
     SET client_exercise_defaults = jsonb_set(
           COALESCE(client_exercise_defaults, '{}'::jsonb),
           ARRAY[p_field],
           COALESCE(p_value, 'null'::jsonb),
           true
         )
   WHERE id = p_client_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.set_client_exercise_default(UUID, TEXT, JSONB) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_client_exercise_default(UUID, TEXT, JSONB) FROM anon, public;

-- 3. Extend list_practice_clients to include defaults -------------------------
-- Postgres disallows changing the OUT / returns-table shape via CREATE OR
-- REPLACE, so drop the existing fn first. DROP IF EXISTS makes the migration
-- idempotent — a fresh DB (or re-run) just starts from nothing.
DROP FUNCTION IF EXISTS public.list_practice_clients(uuid);

CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
RETURNS TABLE (
  id                        uuid,
  name                      text,
  video_consent             jsonb,
  client_exercise_defaults  jsonb,
  last_plan_at              timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = p_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_practice_clients: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults,
         (SELECT MAX(COALESCE(p.sent_at, p.created_at))
            FROM plans p
           WHERE p.client_id = c.id) AS last_plan_at
    FROM clients c
   WHERE c.practice_id = p_practice_id
   ORDER BY last_plan_at DESC NULLS LAST, c.name ASC;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.list_practice_clients(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.list_practice_clients(uuid) FROM anon, public;

-- 4. Extend get_client_by_id to include defaults ------------------------------
-- Same DROP-first dance as list_practice_clients.
DROP FUNCTION IF EXISTS public.get_client_by_id(uuid);

CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
RETURNS TABLE (
  id                        uuid,
  name                      text,
  video_consent             jsonb,
  client_exercise_defaults  jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_by_id requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'get_client_by_id: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM public.clients c
   WHERE c.id = p_client_id
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id = ANY (public.user_practice_ids())) THEN
    RAISE EXCEPTION 'get_client_by_id: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults
    FROM public.clients c
   WHERE c.id = p_client_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.get_client_by_id(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_client_by_id(uuid) FROM anon, public;

COMMIT;

-- ============================================================================
-- Verification queries — run via `supabase db query --linked` after apply
-- ============================================================================
--
-- 1. Column present:
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='clients'
--      AND column_name='client_exercise_defaults';
--
-- 2. Function signatures:
--   SELECT proname, pg_get_function_identity_arguments(p.oid) AS args
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public'
--      AND proname IN ('set_client_exercise_default',
--                      'list_practice_clients',
--                      'get_client_by_id');
--
-- 3. Round-trip test (replace UUIDs with real ones):
--   SELECT public.set_client_exercise_default(
--     '00000000-0000-0000-0000-000000000000'::uuid,
--     'reps', '12'::jsonb
--   );
--   SELECT client_exercise_defaults
--     FROM public.clients
--    WHERE id = '00000000-0000-0000-0000-000000000000'::uuid;
