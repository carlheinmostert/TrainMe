-- ============================================================================
-- Wave 40.1 — audit feed: actor-never-NULL + dedicated Client column.
-- ============================================================================
--
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_wave40_1_audit_client_column.sql
--
-- Idempotent: every statement uses CREATE OR REPLACE. Safe to re-run.
--
-- WHY
--   Wave 39 surfaced two practitioner asks (audit QA item 9, reiterated by
--   Carl 2026-04-28):
--
--     "The actor is not always populated. I believe the actor should always
--      be populated. Even if it was a system-triggered issue or action, it
--      should ultimately be traceable back to the actor — one of the
--      practitioners. And then a dedicated client column so we understand
--      in the context of which client something is happening."
--
-- WHAT THIS MIGRATION DOES
--   1. list_practice_audit grows two new return columns:
--        - client_id   uuid  — the client this row is about (NULL when the
--                              event is purely practice-shaped, e.g.
--                              member.join, credit.purchase, referral.rebate).
--        - client_name text  — last-known clients.name when client_id is set;
--                              tombstoned clients still surface their name
--                              (the row is preserved with deleted_at). NULL
--                              when client_id is NULL.
--
--   2. plan-shaped rows (plan.publish, plan.opened) join through
--      plans.client_id to derive client_{id,name}.
--
--   3. client-shaped rows (client.create, client.delete) are themselves the
--      subject — client_id IS the row's ref_id; client_name IS row.title.
--
--   4. plan.opened actor: previously NULL (anon web player has no auth.uid).
--      Now derives the practitioner who LAST published the plan via
--      plan_issuances.trainer_id (issued_at DESC LIMIT 1). The "actor" thus
--      becomes "the practitioner whose plan was opened" — meaningful
--      traceability in the audit feed.
--
--   5. credit.consumption actor: when the credit_ledger row carries
--      cl.plan_id (publish-funded burns), derive the practitioner via the
--      same plan_issuances.trainer_id. Other credit.* kinds remain NULL
--      until the underlying tables grow a created_by column (see "what
--      this migration does NOT do" below).
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT backfill historical rows. Derivations are at-query time, so
--     historical plan.opened / credit.consumption rows pick up the
--     practitioner attribution automatically.
--   * Does NOT add an actor for credit.purchase / credit.refund /
--     credit.adjustment / credit.signup_bonus / credit.referral_signup_bonus
--     rows. credit_ledger has no trainer_id column; these are practice-
--     level / system events. A future migration could either (a) add
--     credit_ledger.trainer_id (preferred long-term) or (b) attribute to
--     practices.owner_trainer_id as a fallback. Out of scope for 40.1.
--   * Does NOT add an actor for referral.rebate or client.create /
--     client.delete (clients table has no created_by). Same reasoning.
--   * Does NOT add a Client filter to the audit filter bar. Out of scope
--     for 40.1; track separately if practitioners ask for it.
--   * Does NOT touch list_practice_audit's argument signature — only the
--     RETURNS TABLE shape grows. Existing callers see two new fields and
--     ignore them gracefully.
-- ============================================================================

BEGIN;

-- ============================================================================
-- list_practice_audit — extend RETURNS TABLE with client_id + client_name,
-- and resolve actor for plan.opened + credit.consumption rows.
-- ============================================================================

DROP FUNCTION IF EXISTS public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
);

CREATE OR REPLACE FUNCTION public.list_practice_audit(
  p_practice_id uuid,
  p_offset      int         DEFAULT 0,
  p_limit       int         DEFAULT 50,
  p_kinds       text[]      DEFAULT NULL,
  p_actor       uuid        DEFAULT NULL,
  p_from        timestamptz DEFAULT NULL,
  p_to          timestamptz DEFAULT NULL
)
RETURNS TABLE (
  ts             timestamptz,
  kind           text,
  trainer_id     uuid,
  email          text,
  full_name      text,
  title          text,
  credits_delta  numeric,
  balance_after  numeric,
  ref_id         uuid,
  meta           jsonb,
  client_id      uuid,
  client_name    text,
  total_count    bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH unioned AS (
    -- ------------------------------------------------------------------
    -- plan_issuances → kind = 'plan.publish'
    -- Wave 40.1: client_{id,name} derived via plans.client_id → clients.
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
    -- credit_ledger → kind = 'credit.' || type
    -- Wave 40.1: when cl.plan_id is set (publish-funded consumption /
    -- refund), derive trainer_id + email via the latest plan_issuance for
    -- that plan. Other rows (purchase / adjustment / system bonuses) stay
    -- NULL — credit_ledger has no created_by column; a future migration
    -- can extend that.
    -- ------------------------------------------------------------------
    SELECT
      cl.created_at                                   AS a_ts,
      ('credit.' || cl.type)::text                    AS a_kind,
      derived_pi.trainer_id                           AS a_trainer_id,
      derived_u.email::text                           AS a_email,
      COALESCE(derived_u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
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
    LEFT JOIN LATERAL (
      SELECT pi.trainer_id
        FROM public.plan_issuances pi
       WHERE pi.plan_id = cl.plan_id
       ORDER BY pi.issued_at DESC
       LIMIT 1
    ) derived_pi ON cl.plan_id IS NOT NULL
    LEFT JOIN auth.users derived_u ON derived_u.id = derived_pi.trainer_id
    WHERE cl.practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- referral_rebate_ledger → kind = 'referral.rebate'
    -- Practice-shaped (no client context). Actor stays NULL — system-
    -- issued; no per-row practitioner attribution available.
    -- ------------------------------------------------------------------
    SELECT
      rrl.created_at                                  AS a_ts,
      'referral.rebate'::text                         AS a_kind,
      NULL::uuid                                      AS a_trainer_id,
      NULL::text                                      AS a_email,
      NULL::text                                      AS a_full_name,
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
    WHERE rrl.referrer_practice_id = p_practice_id

    UNION ALL

    -- ------------------------------------------------------------------
    -- clients (created_at) → kind = 'client.create'
    -- Wave 40.1: client_{id,name} = the row's own id + name.
    -- ------------------------------------------------------------------
    SELECT
      c.created_at                                    AS a_ts,
      'client.create'::text                           AS a_kind,
      NULL::uuid                                      AS a_trainer_id,
      NULL::text                                      AS a_email,
      NULL::text                                      AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      c.id                                            AS a_client_id,
      c.name::text                                    AS a_client_name
    FROM public.clients c
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NULL

    UNION ALL

    -- ------------------------------------------------------------------
    -- clients (deleted_at) → kind = 'client.delete'
    -- Wave 40.1: client_{id,name} = the row's own id + name (last-known).
    -- ------------------------------------------------------------------
    SELECT
      c.deleted_at                                    AS a_ts,
      'client.delete'::text                           AS a_kind,
      NULL::uuid                                      AS a_trainer_id,
      NULL::text                                      AS a_email,
      NULL::text                                      AS a_full_name,
      c.name::text                                    AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      c.id                                            AS a_ref_id,
      NULL::jsonb                                     AS a_meta,
      c.id                                            AS a_client_id,
      c.name::text                                    AS a_client_name
    FROM public.clients c
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NOT NULL

    UNION ALL

    -- ------------------------------------------------------------------
    -- practice_members → kind = 'member.join'
    -- Practice-shaped (no client context).
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
    -- Wave 40.1:
    --   * For plan.opened (anon web player → ae.actor_id IS NULL), derive
    --     the practitioner via the latest plan_issuances row for the
    --     same plan. The "actor" semantically becomes "the practitioner
    --     whose published plan the client opened" — meaningful
    --     traceability instead of NULL → "Client" magic-string.
    --   * For plan.* rows where ae.ref_id points at a plan, also derive
    --     client_{id,name} via plans.client_id → clients.
    --   * For client.* rows where ae.ref_id points at a client, surface
    --     the client_{id,name} directly.
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
      -- client_id resolution: plan.* rows → plans.client_id;
      --                       client.* rows → ae.ref_id IS the client_id;
      --                       everything else → NULL.
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
    -- plan.* derivation: ae.ref_id points at the plan.
    LEFT JOIN public.plans plan_for_ae
      ON ae.kind LIKE 'plan.%' AND plan_for_ae.id = ae.ref_id
    LEFT JOIN public.clients cli_for_plan
      ON cli_for_plan.id = plan_for_ae.client_id
    -- client.* derivation: ae.ref_id IS the client_id.
    LEFT JOIN public.clients cli_for_ae
      ON ae.kind LIKE 'client.%' AND cli_for_ae.id = ae.ref_id
    -- plan.opened actor backfill: latest plan_issuance for the plan.
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
$$;

REVOKE ALL ON FUNCTION public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
) TO authenticated;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
--
-- A. Returns shape includes client_id + client_name:
--   SELECT pg_typeof(client_id), pg_typeof(client_name)
--     FROM public.list_practice_audit(
--       '<practice-uuid>'::uuid, 0, 1, NULL, NULL, NULL, NULL
--     )
--    LIMIT 1;
--   -- Expect: uuid, text
--
-- B. plan.opened rows now carry a non-NULL trainer_id + email when a prior
-- plan_issuance exists:
--   SELECT kind, email, client_name FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, ARRAY['plan.opened'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: email = the publisher of the plan; client_name = the plan's client.
--
-- C. credit.consumption rows now carry a non-NULL trainer_id + email:
--   SELECT kind, email FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, ARRAY['credit.consumption'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: email = the publisher of the corresponding plan.
--
-- D. Practice-shaped rows still NULL on client_{id,name}:
--   SELECT kind, client_id FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, ARRAY['member.join','referral.rebate'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: client_id IS NULL
--
-- E. Tombstoned client rows still surface their last-known name:
--   SELECT kind, client_name FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, ARRAY['client.delete'], NULL, NULL, NULL
--   ) LIMIT 5;
--   -- Expect: client_name = the soft-deleted client's name (not NULL).
-- ============================================================================
