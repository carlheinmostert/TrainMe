-- Live view: logo + satellite snapshot (item 19 + items 15/16 plumbing)
--
-- Spec carry-forward: docs/specs/2026-05-22-safe-mode-transparency.md +
-- docs/test-scripts/2026-05-23-stack.md items 15-19.
--
-- 1. Adds `practice_premises.snapshot_url text` — public URL (or NULL) of
--    a Mapbox satellite-tile snapshot regenerated whenever the polygon
--    changes. Web player renders it as the map background; falls back to
--    the polygon-only SVG when NULL (e.g. Mapbox secret not set, or
--    polygon hasn't transitioned to non-NULL yet).
--
-- 2. Extends `get_live_sessions(p_practice_slug, p_premises_slug)` to
--    return two more columns on every row:
--      - practice_logo_url    text   — practices.public_logo_url, used
--                                       for the live header logo when
--                                       present (else two-letter initials).
--      - premises_snapshot_url text  — practice_premises.snapshot_url.
--    Per the column-preservation rule (feedback_schema_migration_column_preservation),
--    EVERY existing column from the prior RETURNS TABLE is carried forward
--    unchanged — only two columns are added at the tail.
--
-- 3. Adds `regenerate_premises_snapshot(p_premises_id)` SECURITY DEFINER
--    RPC. Owner-only. Best-effort calls the `regen-premises-snapshot`
--    Edge Function via pg_net so the snapshot is refreshed asynchronously.
--    Wired to the portal's "Regenerate satellite snapshot" button on the
--    premises editor and called from upsert_premises whenever the polygon
--    transitions from NULL → non-NULL or coordinates change.
--
-- 4. Adds storage policies for `media/premises-snapshots/{practice_id}/...`
--    so the Edge Function (service role) can upload + so public SELECT
--    works (the existing `Media public read` already covers SELECT for the
--    entire `media` bucket; nothing extra needed there).
--
-- The snapshot regen is best-effort: if MAPBOX_TOKEN secret is missing
-- or the edge function errors, the column stays NULL and the live page
-- gracefully falls back to the polygon-only SVG that ships today.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Schema: practice_premises.snapshot_url
-- ---------------------------------------------------------------------------
ALTER TABLE public.practice_premises
  ADD COLUMN IF NOT EXISTS snapshot_url text;

COMMENT ON COLUMN public.practice_premises.snapshot_url IS
  'Public URL of the Mapbox satellite-tile snapshot for this premises (populated by regen-premises-snapshot edge function). Stable per (practice_id, premises_id) — service worker caches naturally. NULL until the polygon is first set or the regen flow runs.';

-- ---------------------------------------------------------------------------
-- 2. get_live_sessions — extended with practice_logo_url +
--    premises_snapshot_url. Carries forward every prior column.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_live_sessions(text);
DROP FUNCTION IF EXISTS public.get_live_sessions(text, text);

CREATE FUNCTION public.get_live_sessions(
  p_practice_slug text,
  p_premises_slug text
)
 RETURNS TABLE (
   practice_id            uuid,
   practice_name          text,
   practice_slug          text,
   premises_id            uuid,
   premises_name          text,
   premises_slug          text,
   premises_polygon       jsonb,
   session_id             uuid,
   trainer_id             uuid,
   first_name             text,
   last_name              text,
   avatar_url             text,
   started_at             timestamptz,
   last_heartbeat_at      timestamptz,
   last_latitude          double precision,
   last_longitude         double precision,
   manual_mode            boolean,
   kind                   text,
   practice_logo_url      text,
   premises_snapshot_url  text
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', extensions
AS $function$
DECLARE
  v_practice_slug text := nullif(btrim(lower(coalesce(p_practice_slug, ''))), '');
  v_premises_slug text := nullif(btrim(lower(coalesce(p_premises_slug, ''))), '');
  v_practice      public.practices%ROWTYPE;
  v_premises      public.practice_premises%ROWTYPE;
BEGIN
  IF v_practice_slug IS NULL OR v_premises_slug IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_practice
    FROM public.practices p
   WHERE p.public_slug = v_practice_slug
     AND coalesce(p.public_profile_listed, false) = true
   LIMIT 1;

  IF v_practice.id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_premises
    FROM public.practice_premises pp
   WHERE pp.practice_id = v_practice.id
     AND pp.public_slug = v_premises_slug
     AND pp.deleted_at IS NULL
   LIMIT 1;

  IF v_premises.id IS NULL THEN
    RETURN;
  END IF;

  -- One 'premises' row for the polygon — only emitted when Safe Mode is
  -- enforced.
  IF coalesce(v_premises.safe_mode_enforced, false) AND v_premises.polygon IS NOT NULL THEN
    RETURN QUERY
      SELECT
        v_practice.id            AS practice_id,
        v_practice.name          AS practice_name,
        v_practice.public_slug   AS practice_slug,
        v_premises.id            AS premises_id,
        v_premises.name          AS premises_name,
        v_premises.public_slug   AS premises_slug,
        to_jsonb(
          ARRAY(
            SELECT jsonb_build_array(extensions.ST_X(pt), extensions.ST_Y(pt))
              FROM extensions.ST_DumpPoints(v_premises.polygon) AS d(path, pt)
             ORDER BY (d.path)[2]
          )
        )                        AS premises_polygon,
        NULL::uuid               AS session_id,
        NULL::uuid               AS trainer_id,
        NULL::text               AS first_name,
        NULL::text               AS last_name,
        NULL::text               AS avatar_url,
        NULL::timestamptz        AS started_at,
        NULL::timestamptz        AS last_heartbeat_at,
        NULL::double precision   AS last_latitude,
        NULL::double precision   AS last_longitude,
        NULL::boolean            AS manual_mode,
        'premises'::text         AS kind,
        v_practice.public_logo_url AS practice_logo_url,
        v_premises.snapshot_url  AS premises_snapshot_url;
  END IF;

  -- Active sessions at THIS premises (heartbeat < 60s ago).
  RETURN QUERY
    SELECT
      v_practice.id            AS practice_id,
      v_practice.name          AS practice_name,
      v_practice.public_slug   AS practice_slug,
      v_premises.id            AS premises_id,
      v_premises.name          AS premises_name,
      v_premises.public_slug   AS premises_slug,
      NULL::jsonb              AS premises_polygon,
      acs.id                   AS session_id,
      acs.trainer_id           AS trainer_id,
      prac.first_name          AS first_name,
      prac.last_name           AS last_name,
      prac.avatar_url          AS avatar_url,
      acs.started_at           AS started_at,
      acs.last_heartbeat_at    AS last_heartbeat_at,
      acs.last_latitude        AS last_latitude,
      acs.last_longitude       AS last_longitude,
      acs.manual_mode          AS manual_mode,
      'session'::text          AS kind,
      v_practice.public_logo_url AS practice_logo_url,
      v_premises.snapshot_url  AS premises_snapshot_url
    FROM public.active_capture_sessions acs
    LEFT JOIN public.practitioners prac
      ON prac.user_id = acs.trainer_id
   WHERE acs.practice_id = v_practice.id
     AND acs.premises_id = v_premises.id
     AND acs.ended_at IS NULL
     AND acs.last_heartbeat_at >= now() - interval '60 seconds';
END;
$function$;

REVOKE ALL ON FUNCTION public.get_live_sessions(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_live_sessions(text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. regenerate_premises_snapshot — owner-only RPC that fires the
--    regen-premises-snapshot edge function via pg_net. Idempotent;
--    the edge function uploads to a stable path and updates the column.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.regenerate_premises_snapshot(uuid);

CREATE FUNCTION public.regenerate_premises_snapshot(
  p_premises_id uuid
)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller        uuid := auth.uid();
  v_practice_id   uuid;
  v_has_polygon   boolean;
  v_base_url      text;
  v_service_key   text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'regenerate_premises_snapshot requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_premises_id IS NULL THEN
    RAISE EXCEPTION 'regenerate_premises_snapshot: p_premises_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT pp.practice_id, pp.polygon IS NOT NULL
    INTO v_practice_id, v_has_polygon
    FROM public.practice_premises pp
   WHERE pp.id = p_premises_id
     AND pp.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'regenerate_premises_snapshot: premises not found'
      USING ERRCODE = 'P0002';
  END IF;

  -- Owners only — the regen action is a publicly-visible artifact and
  -- consumes a Mapbox quota call; restrict to owners.
  IF NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'regenerate_premises_snapshot: caller % is not an owner of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Skip if no polygon yet — nothing to snapshot.
  IF NOT v_has_polygon THEN
    RETURN false;
  END IF;

  -- Best-effort fire the edge function. Same pattern as report_session
  -- (20260523065018_safe_mode_report_vault_secrets.sql): if either
  -- vault secret is missing OR pg_net errors, this no-ops.
  BEGIN
    SELECT decrypted_secret INTO v_base_url
      FROM vault.decrypted_secrets
     WHERE name = 'supabase_url'
     LIMIT 1;

    SELECT decrypted_secret INTO v_service_key
      FROM vault.decrypted_secrets
     WHERE name = 'supabase_service_role_key'
     LIMIT 1;

    IF v_base_url IS NOT NULL AND v_service_key IS NOT NULL THEN
      PERFORM net.http_post(
        url := v_base_url || '/functions/v1/regen-premises-snapshot',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_service_key
        ),
        body := jsonb_build_object(
          'premises_id', p_premises_id,
          'practice_id', v_practice_id
        )
      );
      RETURN true;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Swallow — caller treats false as "nothing fired" and surfaces a
    -- graceful "snapshot will refresh shortly" message.
    NULL;
  END;

  RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION public.regenerate_premises_snapshot(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.regenerate_premises_snapshot(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.regenerate_premises_snapshot(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3a. AFTER INSERT/UPDATE trigger on practice_premises — fires regen when
--     the polygon transitions NULL→non-NULL or its coordinates change.
--     Name-only / address-only / safe_mode_enforced edits do NOT trigger
--     regen (per the brief: "Regenerate ONLY when polygon transitions
--     from NULL → non-NULL or when polygon coordinates change. Skip on
--     name-only edits").
--
--     Trigger fires the edge function via pg_net the same way as
--     regenerate_premises_snapshot — best-effort, swallows errors.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_premises_snapshot_on_polygon_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_should_regen boolean := false;
  v_base_url     text;
  v_service_key  text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_should_regen := NEW.polygon IS NOT NULL;
  ELSIF TG_OP = 'UPDATE' THEN
    -- Coords-equal check uses ST_Equals which is order-insensitive.
    -- ST_Equals on two non-NULL geoms; either side NULL → not equal.
    IF NEW.polygon IS NOT NULL
       AND (OLD.polygon IS NULL OR NOT extensions.ST_Equals(NEW.polygon, OLD.polygon)) THEN
      v_should_regen := true;
    END IF;
  END IF;

  IF NOT v_should_regen THEN
    RETURN NEW;
  END IF;

  BEGIN
    SELECT decrypted_secret INTO v_base_url
      FROM vault.decrypted_secrets WHERE name = 'supabase_url' LIMIT 1;
    SELECT decrypted_secret INTO v_service_key
      FROM vault.decrypted_secrets WHERE name = 'supabase_service_role_key' LIMIT 1;

    IF v_base_url IS NOT NULL AND v_service_key IS NOT NULL THEN
      PERFORM net.http_post(
        url := v_base_url || '/functions/v1/regen-premises-snapshot',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_service_key
        ),
        body := jsonb_build_object(
          'premises_id', NEW.id,
          'practice_id', NEW.practice_id
        )
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Never block the underlying INSERT/UPDATE on regen failure.
    NULL;
  END;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_premises_snapshot_on_polygon_change ON public.practice_premises;
CREATE TRIGGER trg_premises_snapshot_on_polygon_change
  AFTER INSERT OR UPDATE OF polygon ON public.practice_premises
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_premises_snapshot_on_polygon_change();

-- ---------------------------------------------------------------------------
-- 3b. get_premises_for_snapshot — service-role-only helper used by the
--     regen-premises-snapshot edge function. Returns the polygon as
--     GeoJSON plus practice_id, with NO membership gate (the edge
--     function is service-role-authed via SUPABASE_SERVICE_ROLE_KEY).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_premises_for_snapshot(uuid);

CREATE FUNCTION public.get_premises_for_snapshot(
  p_premises_id uuid
)
 RETURNS TABLE (
   id                uuid,
   practice_id       uuid,
   polygon_geojson   text
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', extensions
AS $function$
BEGIN
  RETURN QUERY
    SELECT
      pp.id,
      pp.practice_id,
      CASE WHEN pp.polygon IS NULL THEN NULL::text
           ELSE extensions.ST_AsGeoJSON(pp.polygon)::text END
    FROM public.practice_premises AS pp
   WHERE pp.id = p_premises_id
     AND pp.deleted_at IS NULL
   LIMIT 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_premises_for_snapshot(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_premises_for_snapshot(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Storage policies for `media/premises-snapshots/{practice_id}/...`.
--    The Edge Function uploads with service_role which bypasses RLS, but
--    we add owner-scoped INSERT/UPDATE/DELETE policies so a future
--    authenticated path (e.g. portal-side direct upload) Just Works
--    without another migration. SELECT is already covered by the
--    "Media public read" policy (entire media bucket is public SELECT).
-- ---------------------------------------------------------------------------
DO $outer$
BEGIN
  EXECUTE 'DROP POLICY IF EXISTS "Media premises-snapshots owner insert" ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media premises-snapshots owner update" ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media premises-snapshots owner delete" ON storage.objects';

  EXECUTE $policy$
    CREATE POLICY "Media premises-snapshots owner insert"
      ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (
        bucket_id = 'media'
        AND (storage.foldername(name))[1] = 'premises-snapshots'
        AND (storage.foldername(name))[2]::uuid IN (
          SELECT practice_id FROM practice_members
           WHERE trainer_id = auth.uid() AND role = 'owner'
        )
        AND coalesce(metadata->>'mimetype', '') IN ('image/png', 'image/jpeg')
      )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY "Media premises-snapshots owner update"
      ON storage.objects FOR UPDATE TO authenticated
      USING (
        bucket_id = 'media'
        AND (storage.foldername(name))[1] = 'premises-snapshots'
        AND (storage.foldername(name))[2]::uuid IN (
          SELECT practice_id FROM practice_members
           WHERE trainer_id = auth.uid() AND role = 'owner'
        )
      )
      WITH CHECK (
        bucket_id = 'media'
        AND (storage.foldername(name))[1] = 'premises-snapshots'
        AND (storage.foldername(name))[2]::uuid IN (
          SELECT practice_id FROM practice_members
           WHERE trainer_id = auth.uid() AND role = 'owner'
        )
        AND coalesce(metadata->>'mimetype', '') IN ('image/png', 'image/jpeg')
      )
  $policy$;

  EXECUTE $policy$
    CREATE POLICY "Media premises-snapshots owner delete"
      ON storage.objects FOR DELETE TO authenticated
      USING (
        bucket_id = 'media'
        AND (storage.foldername(name))[1] = 'premises-snapshots'
        AND (storage.foldername(name))[2]::uuid IN (
          SELECT practice_id FROM practice_members
           WHERE trainer_id = auth.uid() AND role = 'owner'
        )
      )
  $policy$;
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping premises-snapshots storage.objects policy changes (need service role).';
END
$outer$;

COMMIT;
