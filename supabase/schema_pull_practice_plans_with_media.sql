-- ============================================================================
-- list_practice_plans — add `line_drawing_url` to per-exercise payload
-- ============================================================================
-- Extends the cloud→mobile pull RPC introduced in
-- `schema_pull_practice_plans.sql` so the SyncService can lazy-download the
-- line-drawing video when Studio opens a cloud-only session. The existing
-- `media_url` column on `exercises` already stores the public line-drawing
-- URL for video + photo captures (see `app/lib/services/upload_service.dart`,
-- `mediaUrls[exercise.id] = _api.publicMediaUrl(path: storagePath)`), but
-- the per-exercise payload only re-exposes it as `media_url` — semantically
-- ambiguous for the prefetch surface. Mirroring `get_plan_full`'s shape, we
-- add an explicit `line_drawing_url` field that always carries the public
-- line-drawing URL (NULL for rest exercises and rows that were never
-- published). Strict additive change — every existing field still ships.
--
-- Sourced from live DB via `pg_get_functiondef('public.list_practice_plans
-- (uuid)'::regproc)` per the schema-migration discipline rule
-- (feedback_schema_migration_column_preservation.md). Diff vs the live body
-- is one line: the new `'line_drawing_url'` key on the per-exercise jsonb.
--
-- B&W and Original treatments live in `raw-archive` and need signed URLs;
-- those stay on the existing on-treatment-switch download path. This RPC
-- extension covers ONLY the line-drawing default-view file.
--
-- Idempotent — CREATE OR REPLACE only.
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
    SELECT
      e.plan_id,
      jsonb_agg(
        jsonb_build_object(
          'id',                  e.id,
          'position',            e.position,
          'name',                e.name,
          'media_url',           e.media_url,
          -- Wave: lazy line-drawing prefetch on Studio open. `media_url`
          -- already carries the public line-drawing URL for video + photo
          -- captures; we re-export it under an explicit name so the
          -- mobile MediaPrefetchService doesn't have to guess. NULL for
          -- rest exercises and rows that never published — the service
          -- skips those.
          'line_drawing_url',    CASE
                                   WHEN e.media_type = 'rest' THEN NULL
                                   ELSE e.media_url
                                 END,
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
  'jsonb { plans: [{...plan_cols, exercises: [{...ex_cols, line_drawing_url, sets: [{...}]}]}] } '
  'scoped by practice membership. Per-exercise line_drawing_url is the public '
  'media-bucket URL for the line-drawing treatment (NULL on rest rows and '
  'never-published rows); the mobile MediaPrefetchService downloads it on '
  'Studio session open so cloud-pulled cards play locally.';
