-- Revert the Mapbox satellite-snapshot infrastructure introduced in
-- 20260523111633_live_view_logo_and_snapshot.sql.
--
-- Architectural reversal (2026-05-23): the live transparency page is
-- moving from a Mapbox Static Images snapshot pipeline (edge function +
-- pg_net trigger + RPCs + storage policies) to the same Leaflet + Esri
-- World Imagery pattern already in use by the portal premises editor
-- (web-portal/src/components/PremisesPolygonEditor.tsx). That pattern is
-- free, key-less, and vendor-consistent with the rest of the surface.
--
-- This migration UNDOES:
--   1. practice_premises.snapshot_url column
--   2. get_live_sessions(text, text) — re-CREATEd without the
--      premises_snapshot_url tail column. EVERY other column is carried
--      forward unchanged (per the schema-migration column-preservation
--      rule). Notably practice_logo_url IS kept — item 16 (two-letter
--      initials / uploaded-logo header on the live page) still depends
--      on it.
--   3. regenerate_premises_snapshot(uuid) RPC
--   4. get_premises_for_snapshot(uuid) RPC
--   5. trg_premises_snapshot_on_polygon_change trigger + function
--   6. storage.objects policies for premises-snapshots paths
--
-- Carl will manually delete the edge function from staging Supabase
-- post-merge with:
--   supabase functions delete regen-premises-snapshot \
--     --project-ref vadjvkmldtoeyspyoqbx
--
-- All DROPs are guarded with IF EXISTS so this migration applies cleanly
-- on a fresh per-PR DB (where the snapshot infra may never have existed).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Drop the trigger BEFORE the trigger function (FK-ish dependency).
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_premises_snapshot_on_polygon_change
  ON public.practice_premises;

DROP FUNCTION IF EXISTS public.trg_premises_snapshot_on_polygon_change();

-- ---------------------------------------------------------------------------
-- 2. Drop the regen RPCs.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.regenerate_premises_snapshot(uuid);
DROP FUNCTION IF EXISTS public.get_premises_for_snapshot(uuid);

-- ---------------------------------------------------------------------------
-- 3. Re-CREATE get_live_sessions(text, text) WITHOUT premises_snapshot_url.
--    practice_logo_url stays — item 16 depends on it. Body otherwise
--    matches the pre-snapshot-infra version from
--    20260523085031_premises_public_slugs.sql, with the addition of
--    practice_logo_url on each returned row.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_live_sessions(text);
DROP FUNCTION IF EXISTS public.get_live_sessions(text, text);

CREATE FUNCTION public.get_live_sessions(
  p_practice_slug text,
  p_premises_slug text
)
 RETURNS TABLE (
   practice_id        uuid,
   practice_name      text,
   practice_slug      text,
   premises_id        uuid,
   premises_name      text,
   premises_slug      text,
   premises_polygon   jsonb,
   session_id         uuid,
   trainer_id         uuid,
   first_name         text,
   last_name          text,
   avatar_url         text,
   started_at         timestamptz,
   last_heartbeat_at  timestamptz,
   last_latitude      double precision,
   last_longitude     double precision,
   manual_mode        boolean,
   kind               text,
   practice_logo_url  text
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
        v_practice.public_logo_url AS practice_logo_url;
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
      v_practice.public_logo_url AS practice_logo_url
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
-- 4. Drop the storage.objects policies for premises-snapshots. These
--    were added by the previous migration; they no longer correspond to
--    any used path prefix.
-- ---------------------------------------------------------------------------
DO $outer$
BEGIN
  EXECUTE 'DROP POLICY IF EXISTS "Media premises-snapshots owner insert" ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media premises-snapshots owner update" ON storage.objects';
  EXECUTE 'DROP POLICY IF EXISTS "Media premises-snapshots owner delete" ON storage.objects';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'Skipping premises-snapshots storage.objects policy drops (need service role).';
END
$outer$;

-- ---------------------------------------------------------------------------
-- 5. Drop the snapshot_url column LAST — it's the schema-level evidence
--    of the snapshot pipeline. Guarded by IF EXISTS for fresh-DB safety.
-- ---------------------------------------------------------------------------
ALTER TABLE public.practice_premises
  DROP COLUMN IF EXISTS snapshot_url;

COMMIT;
