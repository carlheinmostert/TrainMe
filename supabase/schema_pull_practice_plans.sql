-- ============================================================================
-- list_practice_plans — full cloud→mobile session pull
-- ============================================================================
-- After the bundle-ID rebrand on 2026-04-28 the iOS app sandbox was wiped, so
-- a fresh `install-device.sh` rendered the clients list with zero session
-- counts. Root cause: SyncService.pullAll never had a cloud→local sessions
-- branch — sessions only entered SQLite via on-device capture + saveSession.
-- This RPC is the missing pull surface.
--
-- Returns the practice's plans with embedded exercises + per-set rows in a
-- single round-trip jsonb payload. The mobile sync layer hydrates SQLite
-- (sessions / exercises / exercise_sets) for any plan id it doesn't yet
-- have locally; existing local rows are NOT clobbered (local-wins on
-- collisions per the offline-first contract).
--
-- Visibility:
--   * Practice owner  → all non-deleted plans in the practice.
--   * Practitioner    → plans the trainer published OR plans they created
--                       (we track authorship via plan_issuances; if a plan
--                       has no issuance row the practitioner can still see
--                       it as long as they're a member — this matches the
--                       Studio "your draft" experience and avoids the false
--                       negative where a not-yet-published plan is hidden
--                       from its own author).
--   * Non-member      → 42501 insufficient_privilege.
--
-- The mobile shell relies on Supabase storage URLs only at re-download
-- time (which is deferred). We therefore return raw `media_url` /
-- `thumbnail_url` strings as-is; no signing happens here. Practitioners
-- play media from the local raw_file_path / converted_file_path; if those
-- files are missing (fresh install with no cloud-side raw archive
-- available yet), the open path tolerates it via PathResolver.
--
-- Idempotent — CREATE OR REPLACE only, no table writes.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.list_practice_plans(
  p_practice_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $fn$
DECLARE
  v_caller    uuid    := auth.uid();
  v_is_owner  boolean := public.user_is_practice_owner(p_practice_id);
  v_is_member boolean := p_practice_id = ANY(ARRAY(SELECT public.user_practice_ids()));
  v_plans     jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_plans requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_plans: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT v_is_member AND NOT v_is_owner THEN
    RAISE EXCEPTION 'list_practice_plans: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  WITH visible_plans AS (
    -- Plans this caller is allowed to see in this practice. Owners see
    -- everything; practitioners see plans they authored (latest issuance)
    -- and unpublished drafts (no issuance row at all). A subsequent
    -- iteration can tighten this if cross-trainer leakage becomes a
    -- concern, but for MVP we mirror the Studio mental model where the
    -- author owns their drafts.
    SELECT p.*
      FROM plans p
     WHERE p.practice_id = p_practice_id
       AND p.deleted_at IS NULL
       AND (
         v_is_owner
         OR NOT EXISTS (
              SELECT 1 FROM plan_issuances pi
               WHERE pi.plan_id = p.id
            )
         OR EXISTS (
              SELECT 1 FROM plan_issuances pi
               WHERE pi.plan_id    = p.id
                 AND pi.trainer_id = v_caller
            )
       )
  ),
  plan_exercises AS (
    -- One row per plan: the JSON-aggregated exercises + their nested
    -- sets array. Mirrors the structure get_plan_full emits (so the
    -- client-side hydrator can reuse the same parsing path) but
    -- without the consent-gated signed URLs (practitioner pull is
    -- inside-the-tenant; storage paths flow back unsigned).
    SELECT
      e.plan_id,
      jsonb_agg(
        jsonb_build_object(
          'id',                  e.id,
          'position',            e.position,
          'name',                e.name,
          'media_url',           e.media_url,
          'thumbnail_url',       e.thumbnail_url,
          'media_type',          e.media_type,
          'notes',               e.notes,
          'circuit_id',          e.circuit_id,
          'include_audio',       e.include_audio,
          'created_at',          e.created_at,
          'preferred_treatment', e.preferred_treatment,
          'prep_seconds',        e.prep_seconds,
          'start_offset_ms',     e.start_offset_ms,
          'end_offset_ms',       e.end_offset_ms,
          'video_reps_per_loop', e.video_reps_per_loop,
          'aspect_ratio',        e.aspect_ratio,
          'rotation_quarters',   e.rotation_quarters,
          'body_focus',          e.body_focus,
          'rest_seconds',        e.rest_seconds,
          'sets',                COALESCE(
                                   (SELECT jsonb_agg(
                                             jsonb_build_object(
                                               'position',                s.position,
                                               'reps',                    s.reps,
                                               'hold_seconds',            s.hold_seconds,
                                               'weight_kg',               s.weight_kg,
                                               'breather_seconds_after',  s.breather_seconds_after
                                             )
                                             ORDER BY s.position
                                           )
                                      FROM public.exercise_sets s
                                     WHERE s.exercise_id = e.id),
                                   '[]'::jsonb
                                 )
        )
        ORDER BY e.position
      ) AS exercises
    FROM exercises e
    JOIN visible_plans vp ON vp.id = e.plan_id
    GROUP BY e.plan_id
  ),
  latest_issuance AS (
    SELECT DISTINCT ON (pi.plan_id)
           pi.plan_id,
           pi.trainer_id  AS last_trainer_id,
           pi.issued_at   AS last_issued_at
      FROM plan_issuances pi
      JOIN visible_plans vp ON vp.id = pi.plan_id
     ORDER BY pi.plan_id, pi.issued_at DESC
  )
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id',                              vp.id,
               'practice_id',                     vp.practice_id,
               'client_id',                       vp.client_id,
               'client_name',                     COALESCE(c.name, vp.client_name),
               'title',                           vp.title,
               'circuit_cycles',                  vp.circuit_cycles,
               'preferred_rest_interval_seconds', vp.preferred_rest_interval_seconds,
               'created_at',                      vp.created_at,
               'sent_at',                         vp.sent_at,
               'version',                         vp.version,
               'first_opened_at',                 vp.first_opened_at,
               'last_opened_at',                  vp.last_opened_at,
               'deleted_at',                      vp.deleted_at,
               'crossfade_lead_ms',               vp.crossfade_lead_ms,
               'crossfade_fade_ms',               vp.crossfade_fade_ms,
               'unlock_credit_prepaid_at',        vp.unlock_credit_prepaid_at,
               'last_published_at',               li.last_issued_at,
               'last_trainer_id',                 li.last_trainer_id,
               'exercises',                       COALESCE(pe.exercises, '[]'::jsonb)
             )
             ORDER BY COALESCE(li.last_issued_at, vp.created_at) DESC NULLS LAST, vp.id
           ),
           '[]'::jsonb
         )
    INTO v_plans
    FROM visible_plans vp
    LEFT JOIN clients          c  ON c.id     = vp.client_id
    LEFT JOIN latest_issuance  li ON li.plan_id = vp.id
    LEFT JOIN plan_exercises   pe ON pe.plan_id = vp.id;

  RETURN jsonb_build_object('plans', v_plans);
END;
$fn$;

REVOKE ALL ON FUNCTION public.list_practice_plans(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_practice_plans(uuid) TO authenticated;

COMMENT ON FUNCTION public.list_practice_plans(uuid) IS
  'SECURITY DEFINER pull-all-plans RPC for the mobile SyncService. Returns '
  'jsonb { plans: [{...plan_cols, exercises: [{...ex_cols, sets: [{...}]}]}] } '
  'scoped by practice membership. No storage URL signing — practitioner UX '
  'plays from local files. Single round-trip; no anon access.';

-- ============================================================================
-- Verification
-- ============================================================================
--
--   -- Function present:
--   SELECT proname, pg_get_function_arguments(oid)
--     FROM pg_proc
--    WHERE proname = 'list_practice_plans'
--      AND pronamespace = 'public'::regnamespace;
--
--   -- Smoke test (replace with a real practice id you're a member of):
--   SELECT jsonb_pretty(public.list_practice_plans(
--     '00000000-0000-0000-0000-0000000ca71e'::uuid
--   ));
