-- ============================================================================
-- list_practice_audit — union in capture_audit_events as capture.photo /
-- capture.video kinds. Carl's 2026-05-23 spec: one unified Audit view at
-- the portal that includes EVERY photo + video taken (alongside the
-- existing plan_issuances / credit_ledger / clients / members / audit_events
-- sources). The practice manager wants to audit the whole business from a
-- single feed at manage.homefit.studio/audit.
-- ============================================================================
--
-- Backward-additive change to the RPC return contract:
--   * No columns added / dropped / renamed. Existing rows render identically.
--   * Two new `kind` values appear in the output stream: 'capture.photo' and
--     'capture.video'. Portal kind-chip / label / description maps fall back
--     to a generic grey chip if the migration lands ahead of the portal
--     code, so no portal redeploy is required for correctness.
--
-- The unioned shape per capture-event row:
--   * ts            = capture_audit_events.started_at
--   * kind          = 'capture.photo' | 'capture.video'
--   * trainer_id    = the capturing practitioner
--   * email         = trainer's auth email
--   * full_name     = trainer's raw_user_meta_data.full_name (or '')
--   * title         = NULL (no per-row title for captures — meta carries detail)
--   * credits_delta = NULL (captures don't move credits)
--   * balance_after = NULL
--   * ref_id        = exercise_id from metadata (when present) — lets the
--                     portal optionally link back to the originating
--                     session in a future iteration. NULL for events with
--                     no exercise_id (defensive).
--   * meta          = {safe_mode_active, exercise_id, app_version,
--                     premises_id, premises_name} — passes through the
--                     metadata bag from the Dart writer and merges in
--                     the resolved premises_name (LEFT JOINed from
--                     practice_premises by ce.premises_id).
--   * client_id     = derived via exercises.plan_id → plans.client_id when
--                     metadata.exercise_id resolves; NULL otherwise (e.g.
--                     the exercise was later deleted, or the device wrote
--                     an event without exercise_id).
--   * client_name   = derived via the same chain → clients.name.
--
-- Filter behaviour: `p_kinds` array now accepts 'capture.photo' /
-- 'capture.video' to scope the feed to just captures. `p_actor` /
-- `p_from` / `p_to` apply identically to capture rows. Pagination is
-- preserved via the existing `total_count` window function.
--
-- RLS safety: capture_audit_events.SELECT is gated by
-- `practice_id = ANY user_practice_ids()` (see 20260523145446 migration);
-- the function-level membership check in list_practice_audit's first IF
-- block is therefore redundant but kept for defence in depth. The SECURITY
-- DEFINER context bypasses row RLS, so the WHERE clause on the new UNION
-- branch must scope by `ce.practice_id = p_practice_id` (already does).
--
-- Schema migration discipline (CLAUDE.md feedback_schema_migration_column_preservation):
-- this rewrite was sourced from the live staging definition via
-- `pg_get_functiondef`, NOT from supabase/*.sql files. Every existing
-- column in RETURNS TABLE is preserved verbatim; only the inner UNION
-- gains a new branch.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.list_practice_audit(
  p_practice_id uuid,
  p_offset integer DEFAULT 0,
  p_limit integer DEFAULT 50,
  p_kinds text[] DEFAULT NULL::text[],
  p_actor uuid DEFAULT NULL::uuid,
  p_from timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_to timestamp with time zone DEFAULT NULL::timestamp with time zone
)
 RETURNS TABLE(
   ts timestamp with time zone,
   kind text,
   trainer_id uuid,
   email text,
   full_name text,
   title text,
   credits_delta numeric,
   balance_after numeric,
   ref_id uuid,
   meta jsonb,
   client_id uuid,
   client_name text,
   total_count bigint
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_owner_id uuid;
BEGIN
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  -- Pre-fetch the practice owner for fallback attribution. One query
  -- instead of per-row lateral joins.
  SELECT pm.trainer_id INTO v_owner_id
    FROM practice_members pm
   WHERE pm.practice_id = p_practice_id
     AND pm.role = 'owner'
   LIMIT 1;

  RETURN QUERY
  WITH unioned AS (
    -- ------------------------------------------------------------------
    -- plan_issuances -> kind = 'plan.publish'
    -- ------------------------------------------------------------------
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
      jsonb_build_object(
        'version',           pi.version,
        'prepaid_unlock_at', pi.prepaid_unlock_at
      )                                               AS a_meta,
      p.client_id                                     AS a_client_id,
      cli.name::text                                  AS a_client_name
    FROM public.plan_issuances pi
    JOIN public.plans p ON p.id = pi.plan_id
    LEFT JOIN auth.users u ON u.id = pi.trainer_id
    LEFT JOIN public.clients cli ON cli.id = p.client_id
    WHERE pi.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- credit_ledger -> kind = 'credit.' || type
    -- Wave 40.5: full actor coverage.
    --   Priority: cl.trainer_id (stamped on new rows) ->
    --             plan_issuances (for consumption/refund with plan_id) ->
    --             practice owner (fallback for historical rows).
    -- ------------------------------------------------------------------
    SELECT
      cl.created_at                                   AS a_ts,
      ('credit.' || cl.type)::text                    AS a_kind,
      COALESCE(cl.trainer_id, derived_pi.trainer_id, v_owner_id) AS a_trainer_id,
      COALESCE(
        cl_u.email,
        derived_u.email,
        owner_u.email
      )::text                                         AS a_email,
      COALESCE(
        cl_u.raw_user_meta_data->>'full_name',
        derived_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
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
      END                                             AS a_meta,
      pl.client_id                                    AS a_client_id,
      cli.name::text                                  AS a_client_name
    FROM public.credit_ledger cl
    LEFT JOIN public.plans pl ON pl.id = cl.plan_id
    LEFT JOIN public.clients cli ON cli.id = pl.client_id
    -- Direct trainer_id lookup (Wave 40.5 rows)
    LEFT JOIN auth.users cl_u ON cl_u.id = cl.trainer_id
    -- Plan-based derivation (consumption/refund with plan_id, pre-40.5)
    LEFT JOIN LATERAL (
      SELECT pi.trainer_id
        FROM public.plan_issuances pi
       WHERE pi.plan_id = cl.plan_id
       ORDER BY pi.issued_at DESC
       LIMIT 1
    ) derived_pi ON cl.plan_id IS NOT NULL AND cl.trainer_id IS NULL
    LEFT JOIN auth.users derived_u ON derived_u.id = derived_pi.trainer_id
    -- Practice owner fallback (pre-40.5 rows without plan_id)
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id
      AND cl.trainer_id IS NULL
      AND derived_pi.trainer_id IS NULL
    WHERE cl.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- referral_rebate_ledger -> kind = 'referral.rebate'
    -- Wave 40.5: derive the referrer practice owner as the actor.
    -- ------------------------------------------------------------------
    SELECT
      rrl.created_at                                  AS a_ts,
      'referral.rebate'::text                         AS a_kind,
      owner_pm.trainer_id                             AS a_trainer_id,
      owner_u.email::text                             AS a_email,
      COALESCE(owner_u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      NULL::text                                      AS a_title,
      rrl.credits::numeric                            AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      rrl.referee_practice_id                         AS a_ref_id,
      jsonb_build_object(
        'referee_practice_id',     rrl.referee_practice_id,
        'source_credit_ledger_id', rrl.source_credit_ledger_id,
        'rebate_kind',             rrl.kind,
        'zar_amount',              rrl.zar_amount
      )                                               AS a_meta,
      NULL::uuid                                      AS a_client_id,
      NULL::text                                      AS a_client_name
    FROM public.referral_rebate_ledger rrl
    LEFT JOIN public.practice_members owner_pm
      ON owner_pm.practice_id = rrl.referrer_practice_id
     AND owner_pm.role = 'owner'
    LEFT JOIN auth.users owner_u ON owner_u.id = owner_pm.trainer_id
    WHERE rrl.referrer_practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- clients (created_at) -> kind = 'client.create'
    -- Wave 40.5: created_by_user_id as actor, fallback to practice owner.
    -- ------------------------------------------------------------------
    SELECT
      c.created_at                                    AS a_ts,
      'client.create'::text                           AS a_kind,
      COALESCE(c.created_by_user_id, v_owner_id)     AS a_trainer_id,
      COALESCE(creator_u.email, owner_u.email)::text  AS a_email,
      COALESCE(
        creator_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      c.id                                            AS a_client_id,
      c.name::text                                    AS a_client_name
    FROM public.clients c
    LEFT JOIN auth.users creator_u ON creator_u.id = c.created_by_user_id
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id AND c.created_by_user_id IS NULL
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NULL

    UNION ALL

    -- ------------------------------------------------------------------
    -- clients (deleted_at) -> kind = 'client.delete'
    -- Wave 40.5: deleted_by_user_id as actor, fallback to practice owner.
    -- ------------------------------------------------------------------
    SELECT
      c.deleted_at                                    AS a_ts,
      'client.delete'::text                           AS a_kind,
      COALESCE(c.deleted_by_user_id, v_owner_id)     AS a_trainer_id,
      COALESCE(deleter_u.email, owner_u.email)::text  AS a_email,
      COALESCE(
        deleter_u.raw_user_meta_data->>'full_name',
        owner_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      c.id                                            AS a_client_id,
      c.name::text                                    AS a_client_name
    FROM public.clients c
    LEFT JOIN auth.users deleter_u ON deleter_u.id = c.deleted_by_user_id
    LEFT JOIN auth.users owner_u
      ON owner_u.id = v_owner_id AND c.deleted_by_user_id IS NULL
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NOT NULL

    UNION ALL

    -- ------------------------------------------------------------------
    -- practice_members -> kind = 'member.join'
    -- ------------------------------------------------------------------
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
      NULL::jsonb                                     AS a_meta,
      NULL::uuid                                      AS a_client_id,
      NULL::text                                      AS a_client_name
    FROM public.practice_members pm
    LEFT JOIN auth.users u ON u.id = pm.trainer_id
    WHERE pm.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- audit_events catchall (member.role_change / member.remove /
    -- practice.rename / client.restore / plan.opened / ...)
    --
    -- plan.opened: derive actor from latest plan_issuance (Wave 40.1).
    -- All other audit_events carry actor_id directly.
    -- ------------------------------------------------------------------
    SELECT
      ae.ts                                           AS a_ts,
      ae.kind                                         AS a_kind,
      COALESCE(ae.actor_id, derived_open_pi.trainer_id) AS a_trainer_id,
      COALESCE(u.email, derived_open_u.email)::text   AS a_email,
      COALESCE(
        u.raw_user_meta_data->>'full_name',
        derived_open_u.raw_user_meta_data->>'full_name',
        ''
      )::text                                         AS a_full_name,
      NULL::text                                      AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      ae.ref_id                                       AS a_ref_id,
      ae.meta                                         AS a_meta,
      CASE
        WHEN ae.kind LIKE 'plan.%' THEN plan_for_ae.client_id
        WHEN ae.kind LIKE 'client.%' THEN ae.ref_id
        ELSE NULL
      END                                             AS a_client_id,
      CASE
        WHEN ae.kind LIKE 'plan.%' THEN cli_for_plan.name::text
        WHEN ae.kind LIKE 'client.%' THEN cli_for_ae.name::text
        ELSE NULL
      END                                             AS a_client_name
    FROM public.audit_events ae
    LEFT JOIN auth.users u ON u.id = ae.actor_id
    LEFT JOIN public.plans plan_for_ae
      ON ae.kind LIKE 'plan.%' AND plan_for_ae.id = ae.ref_id
    LEFT JOIN public.clients cli_for_plan
      ON cli_for_plan.id = plan_for_ae.client_id
    LEFT JOIN public.clients cli_for_ae
      ON ae.kind LIKE 'client.%' AND cli_for_ae.id = ae.ref_id
    LEFT JOIN LATERAL (
      SELECT pi.trainer_id
        FROM public.plan_issuances pi
       WHERE pi.plan_id = ae.ref_id
       ORDER BY pi.issued_at DESC
       LIMIT 1
    ) derived_open_pi
      ON ae.kind = 'plan.opened' AND ae.actor_id IS NULL
    LEFT JOIN auth.users derived_open_u
      ON derived_open_u.id = derived_open_pi.trainer_id
    WHERE ae.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- capture_audit_events -> kind = 'capture.photo' | 'capture.video'
    -- 2026-05-24 — Carl's spec: every photo/video taken in the practice
    -- surfaces in the unified audit feed.
    --
    -- ref_id ← metadata.exercise_id (when present, valid uuid) so the
    -- portal can hyperlink back to the originating session in a future
    -- iteration. NULL when the Dart writer omitted exercise_id.
    --
    -- client_id / client_name ← exercises.plan_id → plans.client_id →
    -- clients.name. LEFT JOINs throughout so a tombstoned exercise / plan
    -- / client doesn't drop the audit row.
    --
    -- meta is the practitioner's metadata bag (safe_mode_active,
    -- exercise_id, app_version) merged with {premises_id, premises_name}
    -- resolved from practice_premises. Premises name is the human-
    -- readable label the practitioner saw at capture time; nullable when
    -- premises_id is NULL (captured outside any polygon) or the premises
    -- was later hard-deleted.
    -- ------------------------------------------------------------------
    SELECT
      ce.started_at                                   AS a_ts,
      ('capture.' || ce.kind)::text                   AS a_kind,
      ce.trainer_id                                   AS a_trainer_id,
      ce_u.email::text                                AS a_email,
      COALESCE(ce_u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      NULL::text                                      AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      CASE
        WHEN ce.metadata ? 'exercise_id'
         AND (ce.metadata->>'exercise_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          THEN (ce.metadata->>'exercise_id')::uuid
        ELSE NULL
      END                                             AS a_ref_id,
      COALESCE(ce.metadata, '{}'::jsonb)
        || jsonb_build_object(
             'premises_id',   ce.premises_id,
             'premises_name', pp.name,
             'ended_at',      ce.ended_at
           )                                          AS a_meta,
      pl_for_ex.client_id                             AS a_client_id,
      cli_for_ex.name::text                           AS a_client_name
    FROM public.capture_audit_events ce
    LEFT JOIN auth.users ce_u ON ce_u.id = ce.trainer_id
    LEFT JOIN public.practice_premises pp ON pp.id = ce.premises_id
    LEFT JOIN public.exercises ex
      ON ce.metadata ? 'exercise_id'
     AND (ce.metadata->>'exercise_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     AND ex.id = (ce.metadata->>'exercise_id')::uuid
    LEFT JOIN public.plans pl_for_ex ON pl_for_ex.id = ex.plan_id
    LEFT JOIN public.clients cli_for_ex ON cli_for_ex.id = pl_for_ex.client_id
    WHERE ce.practice_id = p_practice_id
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
    f.a_client_id     AS client_id,
    f.a_client_name   AS client_name,
    COUNT(*) OVER ()::bigint AS total_count
  FROM filtered f
  ORDER BY f.a_ts DESC
  OFFSET GREATEST(p_offset, 0)
  LIMIT  GREATEST(p_limit, 1);
END;
$function$;

COMMIT;
