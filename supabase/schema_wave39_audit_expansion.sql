-- ============================================================================
-- Wave 39 — audit-feed expansion: surface unlock ↔ publish prepayment + log
-- plan opens.
-- ============================================================================
--
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_wave39_audit_expansion.sql
--
-- Idempotent: every statement uses CREATE IF NOT EXISTS / OR REPLACE / guarded
-- inserts. Safe to re-run.
--
-- WHAT THIS MIGRATION DOES
--   1. plan_issuances.prepaid_unlock_at — nullable timestamptz column. Stamped
--      by `consume_credit` whenever the prepaid-unlock fast path fires (i.e.
--      `plans.unlock_credit_prepaid_at` was non-NULL at the moment of the
--      consume). NULL on regular publishes. The audit page joins this onto
--      the matching `plan.publish` row to render a "Prepaid via unlock at
--      {date}" subtitle and the unlock row's "Used at {date}" subtitle.
--
--   2. consume_credit — when the prepaid-unlock branch fires, also INSERT
--      a `plan_issuances` row that records `prepaid_unlock_at = the cleared
--      flag value`. Today the publish flow itself writes the plan_issuances
--      row (see upload_service.dart `recordPublishIssuance`); this RPC ALSO
--      stamps the column directly on that row when consume_credit hits the
--      fast path. We do this by surfacing the timestamp in the JSONB return
--      so the Dart upload path can stamp the audit row it inserts.
--      (The DB-only alternative — having consume_credit insert the issuance —
--      would skip the trainer_id binding and version bump. Cleaner to keep
--      that on Dart and just thread the marker.)
--
--   3. record_plan_opened — extend to ALSO insert an `audit_events` row
--      with `kind='plan.opened'` on every call. Volume is small (one per
--      plan-open from the web player). The audit page lists these as a
--      sage-toned client-engagement event; actor is NULL because the web
--      player calls anon.
--
--   4. list_practice_audit — extend the `plan.publish` and `plan.opened`
--      branches to surface the new prepaid_unlock_at field via the `meta`
--      jsonb.
--
-- WHAT THIS MIGRATION DOES *NOT* DO
--   * Does NOT backfill plan_issuances.prepaid_unlock_at on existing rows —
--     historic unlock→publish pairs stay un-linked. New unlocks from the
--     point this migration lands forward will be marked correctly.
--   * Does NOT enforce a foreign-key constraint between plan_issuances and
--     credit_ledger. The unlock→publish link is timestamp-based (the
--     publish stamps the unlock's `created_at`) and resilient to manual
--     ledger fixups.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. plan_issuances.prepaid_unlock_at
-- ============================================================================

ALTER TABLE public.plan_issuances
  ADD COLUMN IF NOT EXISTS prepaid_unlock_at timestamptz;

COMMENT ON COLUMN public.plan_issuances.prepaid_unlock_at IS
  'Wave 39. NULL on regular publishes. Set to the timestamp of the matching '
  'credit_ledger.unlock_plan_for_edit row when this publish was prepaid via '
  'unlock — i.e. consume_credit took the prepaid-unlock fast path and did '
  'NOT charge a fresh credit. Used by the audit page to render the '
  '"Prepaid via unlock at {date}" subtitle on the publish row and the '
  '"Used at {publish date}" subtitle on the unlock row.';

CREATE INDEX IF NOT EXISTS idx_plan_issuances_prepaid_unlock
  ON public.plan_issuances (plan_id, prepaid_unlock_at)
  WHERE prepaid_unlock_at IS NOT NULL;

-- ============================================================================
-- 2. consume_credit — already returns `prepaid_unlock_at` in the JSONB on
-- the fast path (see schema_wave29_unlock_plan.sql). No change needed here;
-- the Dart publish flow reads that field and threads it onto the
-- plan_issuances row it already inserts via the existing direct-INSERT
-- path (RLS allows authenticated practice members to write the audit row).
--
-- A SECURITY DEFINER `record_plan_issuance` RPC was considered for forward
-- compatibility (in case `plan_issuances` writes ever get RPC-only-locked-
-- down à la `credit_ledger`). Removed to keep the surface lean; revisit
-- only when we actually move that lockdown.
-- ============================================================================

-- ============================================================================
-- 3. record_plan_opened — extend to also drop an audit_events row per call.
--
-- The base behaviour (idempotent stamp on first_opened_at + last_opened_at)
-- is preserved. The audit_events insert is unconditional — every plan-open
-- counts as one engagement signal. Actor is NULL because the web player
-- runs anon.
--
-- Volume: low. Each unique client open ≈ one row. The portal renders
-- these as `plan.opened` chips (sage tone — engagement). Operators can
-- prune old rows with a GC job if it ever grows.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.record_plan_opened(p_plan_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_practice_id uuid;
BEGIN
  IF p_plan_id IS NULL THEN
    -- No-op on null; the web player can call this defensively.
    RETURN;
  END IF;

  -- Stamp first_opened_at / last_opened_at and capture the practice for the
  -- audit insert in one round-trip.
  UPDATE plans
     SET first_opened_at = COALESCE(first_opened_at, now()),
         last_opened_at  = now()
   WHERE id = p_plan_id
  RETURNING practice_id INTO v_practice_id;

  -- Plan not found → don't fabricate an audit row.
  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  -- Drop a `plan.opened` audit_events row. Actor NULL — the anon web player
  -- has no auth.uid(). The audit page renders actor IS NULL as the literal
  -- "Client" label.
  INSERT INTO public.audit_events (practice_id, actor_id, kind, ref_id, meta)
  VALUES (
    v_practice_id,
    NULL,
    'plan.opened',
    p_plan_id,
    NULL
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.record_plan_opened(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.record_plan_opened(uuid) FROM public;

-- ============================================================================
-- 4. list_practice_audit — surface prepaid_unlock_at on plan.publish rows
--    and treat plan.opened as a first-class kind.
--
-- audit_events already passes through verbatim, so plan.opened rows surface
-- naturally via the catchall branch — no per-kind UNION needed. We only
-- need to extend the plan.publish branch's meta jsonb to include
-- prepaid_unlock_at.
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
    -- plan_issuances → kind = 'plan.publish'
    -- Wave 39: meta now also carries `prepaid_unlock_at` (NULL on regular
    -- publishes; ISO timestamp when this publish consumed a prepaid unlock).
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
      )                                               AS a_meta
    FROM public.plan_issuances pi
    JOIN public.plans p ON p.id = pi.plan_id
    LEFT JOIN auth.users u ON u.id = pi.trainer_id
    WHERE pi.practice_id = p_practice_id

    UNION ALL

    -- credit_ledger → kind = 'credit.' || type
    SELECT
      cl.created_at                                   AS a_ts,
      ('credit.' || cl.type)::text                    AS a_kind,
      NULL::uuid                                      AS a_trainer_id,
      NULL::text                                      AS a_email,
      NULL::text                                      AS a_full_name,
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
      END                                             AS a_meta
    FROM public.credit_ledger cl
    WHERE cl.practice_id = p_practice_id

    UNION ALL

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
      )                                               AS a_meta
    FROM public.referral_rebate_ledger rrl
    WHERE rrl.referrer_practice_id = p_practice_id

    UNION ALL

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
      NULL::jsonb                                     AS a_meta
    FROM public.clients c
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NULL

    UNION ALL

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
      NULL::jsonb                                     AS a_meta
    FROM public.clients c
    WHERE c.practice_id = p_practice_id
      AND c.deleted_at IS NOT NULL

    UNION ALL

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
      NULL::jsonb                                     AS a_meta
    FROM public.practice_members pm
    LEFT JOIN auth.users u ON u.id = pm.trainer_id
    WHERE pm.practice_id = p_practice_id

    UNION ALL

    -- Wave 14 retired the `practice_invite_codes` table; the legacy
    -- `invite.mint` / `invite.claim` UNION ALL branches were dropped in
    -- `schema_milestone_u_add_member_by_email.sql` and MUST stay dropped
    -- here. Re-introducing them caused a regression in the in-flight Wave
    -- 39 commit: the RPC compiled (plpgsql is lazy on table refs) but
    -- threw `42P01: relation "public.practice_invite_codes" does not
    -- exist` on every call, and the portal silently rendered an empty
    -- audit page (see fix in `web-portal/src/lib/supabase/api.ts`).

    -- audit_events catchall (member.role_change / member.remove /
    -- practice.rename / client.restore / invite.revoke / plan.opened / ...)
    SELECT
      ae.ts                                           AS a_ts,
      ae.kind                                         AS a_kind,
      ae.actor_id                                     AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      NULL::text                                      AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      ae.ref_id                                       AS a_ref_id,
      ae.meta                                         AS a_meta
    FROM public.audit_events ae
    LEFT JOIN auth.users u ON u.id = ae.actor_id
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
-- A. Column exists:
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'plan_issuances' AND column_name = 'prepaid_unlock_at';
--
-- B. record_plan_opened drops an audit row:
--   SELECT public.record_plan_opened('<plan-uuid>'::uuid);
--   SELECT id, kind, ref_id, ts FROM public.audit_events
--    WHERE kind = 'plan.opened' AND ref_id = '<plan-uuid>'::uuid
--    ORDER BY ts DESC LIMIT 5;
--
-- C. list_practice_audit surfaces plan.publish meta.prepaid_unlock_at:
--   SELECT kind, meta FROM public.list_practice_audit(
--     '<practice-uuid>'::uuid, 0, 50, NULL, NULL, NULL, NULL
--   ) WHERE kind = 'plan.publish' LIMIT 5;
--   -- Expect: meta keys include `version` + `prepaid_unlock_at`.
--
-- D. list_practice_audit does NOT reference retired tables:
--   SELECT proname FROM pg_proc
--    WHERE proname = 'list_practice_audit'
--      AND prosrc LIKE '%practice_invite_codes%';
--   -- Expect: zero rows. The Wave 14 lockdown must hold.
-- ============================================================================
