-- ============================================================================
-- sign_practice_raw_archive_url — practitioner-scoped signed URL for raw-archive
-- ============================================================================
-- Wraps the low-level public.sign_storage_url helper (which is restricted to
-- postgres + service_role) so authenticated practitioners can pull a raw
-- archive object for any plan in a practice they're a member of.
--
-- Why this exists:
--   * sign_storage_url is granted to postgres + service_role only; the
--     anon path uses it indirectly via get_plan_full (SECURITY DEFINER),
--     which gates its output by client-level video_consent.
--   * The mobile practitioner pull (PR #190 + the cloud-only-session lazy
--     archive download) needs a signed URL without requiring a plan-id +
--     consent dance — the practitioner is inside their own tenant. Membership
--     in practice_members is the right boundary.
--
-- Path is constructed as `{practice_id}/{plan_id}/{exercise_id}.{p_extension}`,
-- mirroring the upload paths UploadService writes to and the paths
-- get_plan_full signs:
--   * videos → `.mp4` (default)
--   * photos → `.jpg`
--
-- Returns NULL when:
--   * The caller is not authenticated.
--   * The caller is not a member of p_practice_id.
--   * sign_storage_url itself returns NULL (vault secret missing).
--
-- Idempotent — CREATE OR REPLACE only.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sign_practice_raw_archive_url(
  p_practice_id  uuid,
  p_plan_id      uuid,
  p_exercise_id  uuid,
  p_expires_in   integer DEFAULT 1800,
  p_extension    text    DEFAULT 'mp4'
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $fn$
DECLARE
  v_caller    uuid    := auth.uid();
  v_is_owner  boolean := public.user_is_practice_owner(p_practice_id);
  v_is_member boolean := p_practice_id = ANY(ARRAY(SELECT public.user_practice_ids()));
  v_ext       text;
  v_path      text;
  v_url       text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'sign_practice_raw_archive_url requires authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL OR p_plan_id IS NULL OR p_exercise_id IS NULL THEN
    RAISE EXCEPTION 'sign_practice_raw_archive_url: all uuid args are required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT v_is_owner AND NOT v_is_member THEN
    RAISE EXCEPTION 'sign_practice_raw_archive_url: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Whitelist the extension to a small known set. The bucket layout only
  -- ever has mp4 (videos) and jpg (photos); anything else is a bug.
  -- Strip a leading dot for tolerance (caller can pass `.mp4` or `mp4`).
  v_ext := lower(coalesce(nullif(p_extension, ''), 'mp4'));
  IF left(v_ext, 1) = '.' THEN
    v_ext := substr(v_ext, 2);
  END IF;
  IF v_ext NOT IN ('mp4', 'jpg') THEN
    RAISE EXCEPTION 'sign_practice_raw_archive_url: unsupported extension %', v_ext
      USING ERRCODE = '22023';
  END IF;

  v_path := p_practice_id::text || '/' || p_plan_id::text || '/' ||
            p_exercise_id::text || '.' || v_ext;

  v_url := public.sign_storage_url(
    p_bucket      => 'raw-archive',
    p_path        => v_path,
    p_expires_in  => p_expires_in
  );

  RETURN v_url;
END;
$fn$;

REVOKE ALL ON FUNCTION public.sign_practice_raw_archive_url(uuid, uuid, uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sign_practice_raw_archive_url(uuid, uuid, uuid, integer, text) TO authenticated;

-- Drop the old 4-arg signature so PostgREST resolves the new 5-arg version
-- unambiguously when the client passes p_extension.
DROP FUNCTION IF EXISTS public.sign_practice_raw_archive_url(uuid, uuid, uuid, integer);

COMMENT ON FUNCTION public.sign_practice_raw_archive_url(uuid, uuid, uuid, integer, text) IS
  'Practitioner-scoped signed URL for raw-archive bucket. Membership-checked. '
  'Used by the mobile lazy-archive prefetch when treatment switching needs '
  'the raw mp4 (videos) or jpg (photos) on a cloud-only session.';
