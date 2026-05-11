-- homefit.studio — Milestone G: three-treatment video model
-- =============================================================================
-- Run in Supabase SQL Editor or via `supabase db query --linked --file ...`.
-- Safe to re-run (every statement is idempotent).
--
-- PRE-REQS
--   * Milestone A, B, C applied (practices, practice_members, plans,
--     user_practice_ids(), user_is_practice_owner(pid) all exist).
--   * Milestone C_recursion_fix applied (helper fns are SECURITY DEFINER).
--
-- WHAT THIS MIGRATION DOES
--   1. Creates `public.clients` table — practice-scoped client roster with
--      per-client `video_consent` jsonb ({line_drawing, grayscale, original}).
--      `line_drawing` is always true (can't be withdrawn; it de-identifies).
--   2. Adds `plans.client_id uuid` FK → clients(id) ON DELETE SET NULL + index.
--   3. Backfills `clients` from distinct (plans.practice_id, plans.client_name)
--      pairs; links plan rows to their new client_id. Idempotent DO block.
--   4. Creates PRIVATE storage bucket `raw-archive` for grayscale / original
--      treatment MP4s. Path shape: {practice_id}/{plan_id}/{exercise_id}.mp4.
--   5. RLS on storage.objects for raw-archive: SELECT blocked for anon +
--      authenticated (service role only, or signed URLs via RPC). INSERT /
--      UPDATE / DELETE allowed for practice members of the first path segment.
--   6. Enables `pgjwt` extension and declares a `public.sign_storage_url(...)`
--      helper that generates 30-min signed URLs from SQL. Reads the JWT secret
--      and Supabase URL from `vault.secrets` (named `supabase_jwt_secret`,
--      `supabase_url`). Returns NULL if the secrets aren't populated — callers
--      must tolerate NULL and fall back to line-drawing only. Populating the
--      vault secrets flips raw-archive signing on without further migrations.
--   7. Extends `public.get_plan_full(p_plan_id uuid)` to return per-exercise:
--        - line_drawing_url (public `media` bucket, unchanged) — always present
--        - grayscale_url    (signed raw-archive URL) — NULL unless consent
--        - original_url     (signed raw-archive URL) — NULL unless consent
--      Consent is resolved via plan → client → video_consent jsonb.
--      Plans without a client_id use the default consent shape
--      `{line_drawing:true, grayscale:false, original:false}` — so legacy
--      plans remain strictly line-drawing-only.
--   8. Adds client-management RPCs (all SECURITY DEFINER, practice-scoped):
--        - upsert_client(p_practice_id, p_name)           -> uuid
--        - set_client_video_consent(p_client_id, ...)     -> void
--        - get_client_by_id(p_client_id)                  -> (id, name, video_consent)
--        - list_practice_clients(p_practice_id)           -> setof rows with last_plan_at
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT require `plans.client_id` to be NOT NULL — legacy plans stay
--     happy; new publishes populate it via upsert_client + link.
--   * Does NOT upload any files to raw-archive. A sister Flutter agent wires
--     the upload; this migration only establishes the bucket + policies.
--   * Does NOT break `get_plan_full` return shape for existing keys
--     (plan, exercises[]) — new fields are additive on each exercise dict.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. Clients table + RLS
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.clients (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  practice_id    uuid NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
  name           text NOT NULL,
  video_consent  jsonb NOT NULL DEFAULT
                 '{"line_drawing": true, "grayscale": false, "original": false}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT clients_practice_name_unique UNIQUE (practice_id, name)
);

CREATE INDEX IF NOT EXISTS idx_clients_practice ON public.clients (practice_id);

-- Bump updated_at on every UPDATE.
CREATE OR REPLACE FUNCTION public._clients_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_clients_touch_updated_at ON public.clients;
CREATE TRIGGER trg_clients_touch_updated_at
  BEFORE UPDATE ON public.clients
  FOR EACH ROW
  EXECUTE FUNCTION public._clients_touch_updated_at();

ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;

-- Drop any prior attempt at these policies (idempotent).
DROP POLICY IF EXISTS clients_select_member ON public.clients;
DROP POLICY IF EXISTS clients_insert_member ON public.clients;
DROP POLICY IF EXISTS clients_update_member ON public.clients;
DROP POLICY IF EXISTS clients_delete_member ON public.clients;

-- Practice members can see + edit their practice's clients. Owners have the
-- same write access via user_is_practice_owner; we OR both helpers together
-- so a non-owner member can still CRUD their own practice's clients
-- (matches the rest of the schema's posture on practice-scoped data).
CREATE POLICY clients_select_member ON public.clients
  FOR SELECT USING (
    practice_id IN (SELECT public.user_practice_ids())
    OR public.user_is_practice_owner(practice_id)
  );

CREATE POLICY clients_insert_member ON public.clients
  FOR INSERT WITH CHECK (
    practice_id IN (SELECT public.user_practice_ids())
    OR public.user_is_practice_owner(practice_id)
  );

CREATE POLICY clients_update_member ON public.clients
  FOR UPDATE
  USING (
    practice_id IN (SELECT public.user_practice_ids())
    OR public.user_is_practice_owner(practice_id)
  )
  WITH CHECK (
    practice_id IN (SELECT public.user_practice_ids())
    OR public.user_is_practice_owner(practice_id)
  );

CREATE POLICY clients_delete_member ON public.clients
  FOR DELETE USING (
    practice_id IN (SELECT public.user_practice_ids())
    OR public.user_is_practice_owner(practice_id)
  );

-- ============================================================================
-- 2. plans.client_id column + index
-- ============================================================================
ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS client_id uuid
    REFERENCES public.clients(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_plans_client ON public.plans (client_id);

-- ============================================================================
-- 3. Backfill — distinct (practice_id, client_name) → clients, then link plans
-- ============================================================================
-- Idempotent: only inserts clients that don't exist yet, only links plans
-- whose client_id is still NULL. Re-running is a no-op once everything's
-- linked. Plans with NULL/empty client_name are skipped (no client record).
DO $$
DECLARE
  v_inserted  integer := 0;
  v_linked    integer := 0;
BEGIN
  WITH ins AS (
    INSERT INTO public.clients (practice_id, name)
    SELECT DISTINCT p.practice_id, p.client_name
      FROM public.plans p
     WHERE p.practice_id IS NOT NULL
       AND p.client_name IS NOT NULL
       AND length(trim(p.client_name)) > 0
    ON CONFLICT (practice_id, name) DO NOTHING
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_inserted FROM ins;

  WITH upd AS (
    UPDATE public.plans p
       SET client_id = c.id
      FROM public.clients c
     WHERE p.practice_id = c.practice_id
       AND p.client_name = c.name
       AND p.client_id IS NULL
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_linked FROM upd;

  RAISE NOTICE 'Backfill: inserted % new clients, linked % plans.',
    v_inserted, v_linked;
END
$$;

-- ============================================================================
-- 4. raw-archive bucket (PRIVATE) + storage RLS
-- ============================================================================
-- Bucket: public=false. Service-role reads; signed URLs for everyone else.
-- Path convention: {practice_id}/{plan_id}/{exercise_id}.mp4
-- First segment is the tenancy anchor — all policies key off it.
INSERT INTO storage.buckets (id, name, public)
VALUES ('raw-archive', 'raw-archive', false)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

-- Helper fn to decide if the calling user can write to a given raw-archive path.
-- Parses the first path segment as a practice_id; returns true iff caller is
-- a member (or owner) of that practice.
CREATE OR REPLACE FUNCTION public.can_write_to_raw_archive(p_path text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_practice_id uuid;
BEGIN
  IF p_path IS NULL OR length(p_path) = 0 THEN
    RETURN false;
  END IF;

  -- storage.foldername returns each directory component; first is practice_id.
  BEGIN
    v_practice_id := ((storage.foldername(p_path))[1])::uuid;
  EXCEPTION WHEN others THEN
    RETURN false; -- malformed path / non-uuid first segment
  END;

  IF v_practice_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_practice_id IN (SELECT public.user_practice_ids())
      OR public.user_is_practice_owner(v_practice_id);
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.can_write_to_raw_archive(text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.can_write_to_raw_archive(text) FROM anon, public;

-- Storage policies for raw-archive. Wrapped in DO block to survive hosted
-- environments where storage.objects policy changes require service role.
DO $$
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
    RAISE NOTICE 'Skipping storage.objects policy changes (need service role).';
END
$$;

-- ============================================================================
-- 5. Signed URL helper (pgjwt + vault.secrets)
-- ============================================================================
-- Supabase Storage signed URLs are HS256 JWTs over {url, iat, exp} signed
-- with the project's JWT secret. Format:
--   {supabase_url}/storage/v1/object/sign/{bucket}/{path}?token={jwt}
--
-- We read the JWT secret and Supabase URL from vault.secrets to keep them
-- out of function definitions. Secret names:
--   - supabase_jwt_secret   (the HS256 signing key)
--   - supabase_url          (e.g. https://yrwcofhovrcydootivjx.supabase.co)
--
-- If either secret is missing/empty, sign_storage_url returns NULL — callers
-- must tolerate this and degrade gracefully to line-drawing-only playback.
-- This keeps the migration a one-shot: flip signing on later by populating
-- the vault secrets, no further DDL required.
CREATE EXTENSION IF NOT EXISTS pgjwt WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.sign_storage_url(
  p_bucket      text,
  p_path        text,
  p_expires_in  integer DEFAULT 1800  -- 30 min
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $fn$
DECLARE
  v_jwt_secret  text;
  v_base_url    text;
  v_token       text;
  v_payload     jsonb;
BEGIN
  IF p_bucket IS NULL OR p_path IS NULL THEN
    RETURN NULL;
  END IF;

  -- Pull the JWT secret + base URL from vault. Use a safe SELECT so a missing
  -- row just returns NULL (instead of erroring).
  SELECT decrypted_secret INTO v_jwt_secret
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_jwt_secret'
   LIMIT 1;

  SELECT decrypted_secret INTO v_base_url
    FROM vault.decrypted_secrets
   WHERE name = 'supabase_url'
   LIMIT 1;

  IF v_jwt_secret IS NULL OR length(v_jwt_secret) = 0
     OR v_base_url IS NULL OR length(v_base_url) = 0 THEN
    RETURN NULL;
  END IF;

  v_payload := jsonb_build_object(
    'url', p_bucket || '/' || p_path,
    'iat', extract(epoch from now())::bigint,
    'exp', extract(epoch from now())::bigint + COALESCE(p_expires_in, 1800)
  );

  -- extensions.sign takes json (not jsonb). Cast explicitly so the right
  -- overload resolves.
  v_token := extensions.sign(v_payload::json, v_jwt_secret, 'HS256');

  RETURN rtrim(v_base_url, '/')
      || '/storage/v1/object/sign/'
      || p_bucket
      || '/'
      || p_path
      || '?token='
      || v_token;
EXCEPTION
  WHEN others THEN
    -- Never propagate signing failures out of the SELECT path; degrade to NULL.
    RETURN NULL;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.sign_storage_url(text, text, integer) TO authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.sign_storage_url(text, text, integer) FROM public;

-- ============================================================================
-- 6. get_plan_full — extended with treatment URLs
-- ============================================================================
-- Backward-compatible: the returned JSON still has {plan, exercises}. Each
-- exercise dict now additionally carries:
--   line_drawing_url  text      always present (existing media_url)
--   grayscale_url     text|null signed raw-archive URL, gated by consent
--   original_url      text|null signed raw-archive URL, gated by consent
-- Consent resolution:
--   * plan.client_id IS NULL → default {line_drawing:true, grayscale:false,
--     original:false}. Only line_drawing_url populated.
--   * Otherwise: load clients.video_consent and honour flags.
CREATE OR REPLACE FUNCTION public.get_plan_full(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  plan_row    plans;
  v_consent   jsonb;
  v_gray_ok   boolean;
  v_orig_ok   boolean;
  exes        jsonb;
BEGIN
  -- Stamp first_opened_at atomically on first fetch.
  UPDATE plans
     SET first_opened_at = now()
   WHERE id = p_plan_id
     AND first_opened_at IS NULL
  RETURNING * INTO plan_row;

  IF plan_row IS NULL THEN
    SELECT * INTO plan_row FROM plans WHERE id = p_plan_id LIMIT 1;
  END IF;

  IF plan_row IS NULL THEN
    RETURN NULL;
  END IF;

  -- Resolve consent. Default = line-drawing only.
  IF plan_row.client_id IS NOT NULL THEN
    SELECT video_consent INTO v_consent
      FROM clients WHERE id = plan_row.client_id LIMIT 1;
  END IF;

  IF v_consent IS NULL THEN
    v_consent := '{"line_drawing": true, "grayscale": false, "original": false}'::jsonb;
  END IF;

  v_gray_ok := COALESCE((v_consent ->> 'grayscale')::boolean, false);
  v_orig_ok := COALESCE((v_consent ->> 'original')::boolean, false);

  -- Assemble exercises. We only generate signed URLs for video rows where the
  -- raw-archive object could plausibly exist — media_type='video'. The path
  -- shape is {practice_id}/{plan_id}/{exercise_id}.mp4 (see upload contract).
  SELECT COALESCE(
           jsonb_agg(
             to_jsonb(e)
               || jsonb_build_object(
                    'line_drawing_url', e.media_url,
                    'grayscale_url',
                      CASE
                        WHEN v_gray_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mp4',
                               1800)
                        ELSE NULL
                      END,
                    'original_url',
                      CASE
                        WHEN v_orig_ok AND e.media_type = 'video' AND plan_row.practice_id IS NOT NULL
                        THEN public.sign_storage_url(
                               'raw-archive',
                               plan_row.practice_id::text || '/' ||
                               plan_row.id::text          || '/' ||
                               e.id::text                 || '.mp4',
                               1800)
                        ELSE NULL
                      END
                  )
               ORDER BY e.position
           ),
           '[]'::jsonb
         )
    INTO exes
    FROM exercises e
   WHERE e.plan_id = p_plan_id;

  RETURN jsonb_build_object(
    'plan',      to_jsonb(plan_row),
    'exercises', exes
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.get_plan_full(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_plan_full(uuid) FROM public;

-- ============================================================================
-- 7. Client-management RPCs
-- ============================================================================

-- 7a. upsert_client — idempotent; returns id of existing or newly-inserted row
CREATE OR REPLACE FUNCTION public.upsert_client(
  p_practice_id uuid,
  p_name        text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller uuid := auth.uid();
  v_id     uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'upsert_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'upsert_client: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_name IS NULL OR length(trim(p_name)) = 0 THEN
    RAISE EXCEPTION 'upsert_client: p_name must be non-empty'
      USING ERRCODE = '22023';
  END IF;

  -- Membership check (SECURITY DEFINER bypasses RLS).
  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = p_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'upsert_client: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Look up by unique (practice_id, name). Insert if missing.
  SELECT id INTO v_id
    FROM clients
   WHERE practice_id = p_practice_id AND name = trim(p_name)
   LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO clients (practice_id, name)
  VALUES (p_practice_id, trim(p_name))
  ON CONFLICT (practice_id, name) DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.upsert_client(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.upsert_client(uuid, text) FROM anon, public;

-- 7b. set_client_video_consent — update the jsonb atomically.
-- line_drawing always stays true; attempting to pass false raises a validation
-- error. grayscale and original are free to toggle.
CREATE OR REPLACE FUNCTION public.set_client_video_consent(
  p_client_id     uuid,
  p_line_drawing  boolean,
  p_grayscale     boolean,
  p_original      boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_line_drawing IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'set_client_video_consent: line_drawing consent cannot be withdrawn (must be true)'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id INTO v_practice_id
    FROM clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_video_consent: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members
     WHERE practice_id = v_practice_id AND trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_video_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  UPDATE clients
     SET video_consent = jsonb_build_object(
           'line_drawing', true,
           'grayscale',    COALESCE(p_grayscale, false),
           'original',     COALESCE(p_original, false)
         )
   WHERE id = p_client_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_client_video_consent(uuid, boolean, boolean, boolean) FROM anon, public;

-- 7c. get_client_by_id — practice-scoped read.
CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
RETURNS TABLE (
  id             uuid,
  name           text,
  video_consent  jsonb
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

  SELECT c.practice_id INTO v_practice_id
    FROM clients c WHERE c.id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;  -- empty set; client doesn't exist
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = v_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RETURN;  -- empty set; caller isn't a member
  END IF;

  RETURN QUERY
  SELECT c.id, c.name, c.video_consent
    FROM clients c
   WHERE c.id = p_client_id;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.get_client_by_id(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_client_by_id(uuid) FROM anon, public;

-- 7d. list_practice_clients — ordered by most-recent-plan activity.
CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
RETURNS TABLE (
  id             uuid,
  name           text,
  video_consent  jsonb,
  last_plan_at   timestamptz
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

COMMIT;

-- ============================================================================
-- Verification queries — run via `supabase db query --linked` after apply
-- ============================================================================
--
-- 1. Table exists and has the right shape:
--   SELECT table_name FROM information_schema.tables
--    WHERE table_schema='public' AND table_name='clients';
--   SELECT column_name, data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='clients'
--    ORDER BY ordinal_position;
--
-- 2. plans.client_id column + FK:
--   SELECT column_name, data_type, is_nullable FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='plans' AND column_name='client_id';
--   SELECT conname, pg_get_constraintdef(oid)
--     FROM pg_constraint
--    WHERE conrelid = 'public.plans'::regclass
--      AND conname LIKE '%client%';
--
-- 3. Backfill counts:
--   SELECT COUNT(*) AS clients_total FROM public.clients;
--   SELECT COUNT(*) FILTER (WHERE client_id IS NOT NULL) AS linked,
--          COUNT(*) FILTER (WHERE client_id IS NULL)     AS unlinked,
--          COUNT(*)                                      AS total
--     FROM public.plans;
--
-- 4. Bucket + storage policies:
--   SELECT id, name, public FROM storage.buckets WHERE id='raw-archive';
--   SELECT policyname FROM pg_policies
--    WHERE schemaname='storage' AND tablename='objects'
--      AND policyname ILIKE 'Raw-archive%';
--
-- 5. Functions in place:
--   SELECT proname, pg_get_function_identity_arguments(p.oid) AS args
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public'
--      AND proname IN ('get_plan_full','upsert_client',
--                      'set_client_video_consent','get_client_by_id',
--                      'list_practice_clients','sign_storage_url',
--                      'can_write_to_raw_archive')
--    ORDER BY proname;
--
-- 6. Sample RPC call on a real plan id (replace <uuid>):
--   SELECT jsonb_pretty(public.get_plan_full('<plan-uuid>'::uuid));
--
-- 7. Enabling signing end-to-end: populate vault and call again.
--   SELECT vault.create_secret(
--     '<PROJECT JWT SECRET>', 'supabase_jwt_secret',
--     'HS256 secret for Supabase Storage signed URLs');
--   SELECT vault.create_secret(
--     'https://yrwcofhovrcydootivjx.supabase.co', 'supabase_url',
--     'Supabase project base URL (for signed URL assembly)');
