-- homefit.studio — Milestone T (Wave 9): Audit expansion — full event log with
-- filters + CSV export.
-- =============================================================================
-- Run via the linked CLI:
--   supabase db query --linked --file supabase/schema_milestone_t_audit_expansion.sql
-- Idempotent: every statement uses CREATE IF NOT EXISTS / OR REPLACE / guarded
-- inserts. Safe to re-run.
--
-- WHAT THIS MIGRATION DOES
--   1. Adds `audit_events` — a catchall table for practice-scoped mutations
--      that don't have a natural source row (member role changes, member
--      removals, practice renames, client restores, invite revocations, etc.).
--      RLS: SELECT scoped to `user_practice_ids()`; no INSERT/UPDATE/DELETE
--      grants — writes happen exclusively via `record_audit_event(...)` from
--      other SECURITY DEFINER RPCs.
--   2. Adds `record_audit_event(p_practice_id, p_kind, p_ref_id, p_meta,
--      p_actor_id)` — internal write helper. Not exposed to `authenticated`.
--   3. Adds `list_practice_audit(p_practice_id, p_offset, p_limit, p_kinds[],
--      p_actor, p_from, p_to)` — the primary read surface for the portal
--      /audit page. SECURITY DEFINER. Unions every natural source row
--      (plan_issuances, credit_ledger, referral_rebate_ledger, clients,
--      practice_members, practice_invite_codes) plus the audit_events catchall,
--      joins auth.users for identity, applies the filter triplet + pagination,
--      and emits a window COUNT(*) total so the portal can render
--      "Showing N–M of T" / pagination without a second round-trip.
--
-- SCHEMA NOTES (live DB, as of 2026-04-20)
--   * credit_ledger columns are (id, practice_id, delta, type, plan_id,
--     payfast_payment_id, notes, created_at) — there is no `trainer_id`
--     column on credit_ledger, so the unioned actor for credit rows is
--     NULL. The portal renders actor = "—" for credit rows. If/when an
--     actor column lands on credit_ledger, the branch of the union for
--     `kind LIKE 'credit.%'` can start populating it.
--   * plan_issuances uses `issued_at` (not `created_at`) and `version`
--     (not `plan_version`).
--   * referral_rebate_ledger uses `credits` (not `credits_delta`) and
--     `source_credit_ledger_id` (not `source_purchase_id`).
--   * practice_invite_codes columns are (code PK, practice_id, created_by,
--     created_at, claimed_by, claimed_at, revoked_at). `ref_id` for
--     invite.mint/claim/revoke is NULL — the code is the natural key, not
--     a uuid — so the portal surfaces the 7-char slug via the `title`
--     column instead.
--   * auth.users `full_name` is NOT populated today (the signup path is
--     email-only). We COALESCE to '' so the JSON shape is stable; the
--     portal falls back to email when full_name is empty.
--
-- RLS HELPER USAGE
--   `user_practice_ids()` is a SECURITY DEFINER set-returning function.
--   ALWAYS write `practice_id IN (SELECT public.user_practice_ids())` — never
--   `= ANY(public.user_practice_ids())`, which errors because Postgres can't
--   implicitly array-wrap a SETOF. Every prior wave (C recursion fix, E, G,
--   I, J, L) got bitten by this; the idiom is load-bearing.
-- =============================================================================

BEGIN;

-- ============================================================================
-- 1. audit_events — catchall for mutations without a natural source table
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.audit_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ts          timestamptz NOT NULL DEFAULT now(),
  practice_id uuid NOT NULL REFERENCES public.practices(id) ON DELETE CASCADE,
  -- Nullable so deleted users (FK CASCADE) or service-role writes still work.
  actor_id    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  -- Free-form kind — future callers add new kinds without schema migrations.
  -- Convention: dot-namespaced lower_snake (e.g. 'member.role_change',
  -- 'practice.rename', 'invite.revoke'). The portal's chip palette matches
  -- on string prefixes, so pick a sensible bucket when adding new kinds.
  kind        text NOT NULL,
  -- The uuid of the thing that changed (trainer_id, client_id, plan_id,
  -- whatever fits the kind). Nullable — some events have no natural target.
  ref_id      uuid,
  -- Free-form detail bag. Keep keys short + stable; the /audit page reads
  -- specific keys depending on the kind.
  meta        jsonb,
  CONSTRAINT audit_events_kind_nonempty CHECK (length(kind) > 0)
);

CREATE INDEX IF NOT EXISTS idx_audit_events_practice_ts
  ON public.audit_events (practice_id, ts DESC);

CREATE INDEX IF NOT EXISTS idx_audit_events_actor
  ON public.audit_events (actor_id);

ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

-- SELECT: any practice member sees every event for the practice.
-- Transparency is intentional per CLAUDE.md; no role gating.
DROP POLICY IF EXISTS audit_events_select_own ON public.audit_events;
CREATE POLICY audit_events_select_own ON public.audit_events
  FOR SELECT TO authenticated
  USING (practice_id IN (SELECT public.user_practice_ids()));

-- No INSERT/UPDATE/DELETE policies. Writes happen exclusively through
-- `record_audit_event(...)` (SECURITY DEFINER), which bypasses RLS.

-- ============================================================================
-- 2. record_audit_event — internal write helper
-- ============================================================================
-- Called from other SECURITY DEFINER RPCs (future: remove_practice_member,
-- set_practice_member_role, etc.) to drop a row into audit_events with the
-- caller's auth.uid() as the actor. Not exposed to `authenticated` — the
-- only way to write is from trusted server-side code.

CREATE OR REPLACE FUNCTION public.record_audit_event(
  p_practice_id uuid,
  p_kind        text,
  p_ref_id      uuid  DEFAULT NULL,
  p_meta        jsonb DEFAULT NULL,
  p_actor_id    uuid  DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO public.audit_events (practice_id, actor_id, kind, ref_id, meta)
  VALUES (
    p_practice_id,
    COALESCE(p_actor_id, auth.uid()),
    p_kind,
    p_ref_id,
    p_meta
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.record_audit_event(uuid, text, uuid, jsonb, uuid) FROM PUBLIC;
-- Deliberately NOT granted to authenticated. Only other SECURITY DEFINER
-- RPCs call this; they execute as the function owner and have access.

-- ============================================================================
-- 3. list_practice_audit — primary read surface for /audit
-- ============================================================================
-- Drop first in case the return-shape changes across revisions. Prior waves
-- learned the hard way that `CREATE OR REPLACE FUNCTION` refuses to widen
-- or shrink the RETURNS TABLE signature without a DROP first.

DROP FUNCTION IF EXISTS public.list_practice_audit(
  uuid, int, int, text[], uuid, timestamptz, timestamptz
);

CREATE OR REPLACE FUNCTION public.list_practice_audit(
  p_practice_id uuid,
  p_offset      int         DEFAULT 0,
  p_limit       int         DEFAULT 50,
  -- Optional filter: include only events whose kind matches exactly. Frontend
  -- can still group by chip-colour by passing all kinds in a colour group.
  p_kinds       text[]      DEFAULT NULL,
  -- Optional filter: single actor (auth.uid of the practitioner).
  p_actor       uuid        DEFAULT NULL,
  -- Optional filter: ts >= p_from.
  p_from        timestamptz DEFAULT NULL,
  -- Optional filter: ts <= p_to.
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
  -- Same value on every returned row (window count). Frontend takes
  -- rows[0].total_count for pagination. If the page is empty, the frontend
  -- calls again with offset=0 to discover the real count.
  total_count    bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Gate: caller must belong to the practice. 42501 so the portal can map
  -- the error to a nice "not authorised" surface instead of a generic 500.
  IF NOT (p_practice_id IN (SELECT public.user_practice_ids())) THEN
    RAISE EXCEPTION 'not a member of this practice'
      USING ERRCODE = '42501';
  END IF;

  -- NOTE ON COLUMN ALIASING: we deliberately rename every column inside the
  -- `unioned` CTE to `a_<name>` (audit-qualified) so they don't collide with
  -- the RETURNS TABLE out-columns. PL/pgSQL raises 42702 (ambiguous column
  -- reference) if any CTE selects a name identical to a RETURNS TABLE out-
  -- column — the out-column binding shadows the CTE column inside the
  -- function body. The `filtered` CTE then references `u.a_kind` / `u.a_ts`
  -- unambiguously, and the final SELECT re-maps back to the public shape.
  RETURN QUERY
  WITH unioned AS (
    -- plan_issuances → kind = 'plan.publish'
    -- plan_issuances has `issued_at` (ts) and `version` (not plan_version).
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
      jsonb_build_object('version', pi.version)       AS a_meta
    FROM public.plan_issuances pi
    JOIN public.plans p ON p.id = pi.plan_id
    LEFT JOIN auth.users u ON u.id = pi.trainer_id
    WHERE pi.practice_id = p_practice_id

    UNION ALL

    -- credit_ledger → kind = 'credit.' || type (e.g. 'credit.consumption',
    -- 'credit.purchase', 'credit.refund', 'credit.adjustment',
    -- 'credit.signup_bonus', 'credit.referral_signup_bonus').
    -- NOTE: credit_ledger has NO trainer_id column in the live schema, so
    -- actor identity is NULL here. The portal renders the Actor column as
    -- "—" for credit rows.
    -- `balance_after` is synthesised with a window SUM over the practice's
    -- ledger ordered by created_at — mirrors what you'd see scrolling the
    -- credit wallet.
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

    -- referral_rebate_ledger → kind = 'referral.rebate'
    -- Table uses `credits` (not credits_delta) and `source_credit_ledger_id`
    -- (not source_purchase_id).
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

    -- clients.created_at → kind = 'client.create'
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

    -- clients.deleted_at → kind = 'client.delete'
    -- Deleted-then-restored rows (deleted_at cleared by restore_client) fall
    -- out of this branch naturally because deleted_at IS NULL after restore.
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

    -- practice_members.joined_at → kind = 'member.join'
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

    -- practice_invite_codes.created_at → kind = 'invite.mint'
    -- `code` is the natural key (no uuid), so it lands in `title` for the
    -- portal to render; ref_id stays NULL.
    SELECT
      pic.created_at                                  AS a_ts,
      'invite.mint'::text                             AS a_kind,
      pic.created_by                                  AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      pic.code::text                                  AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      NULL::uuid                                      AS a_ref_id,
      NULL::jsonb                                     AS a_meta
    FROM public.practice_invite_codes pic
    LEFT JOIN auth.users u ON u.id = pic.created_by
    WHERE pic.practice_id = p_practice_id

    UNION ALL

    -- practice_invite_codes.claimed_at → kind = 'invite.claim'
    SELECT
      pic.claimed_at                                  AS a_ts,
      'invite.claim'::text                            AS a_kind,
      pic.claimed_by                                  AS a_trainer_id,
      u.email::text                                   AS a_email,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::text AS a_full_name,
      pic.code::text                                  AS a_title,
      NULL::numeric                                   AS a_credits_delta,
      NULL::numeric                                   AS a_balance_after,
      NULL::uuid                                      AS a_ref_id,
      NULL::jsonb                                     AS a_meta
    FROM public.practice_invite_codes pic
    LEFT JOIN auth.users u ON u.id = pic.claimed_by
    WHERE pic.practice_id = p_practice_id
      AND pic.claimed_at IS NOT NULL

    UNION ALL

    -- audit_events (catchall for member.role_change / member.remove /
    -- practice.rename / client.restore / invite.revoke / etc.)
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
-- A. Objects exist:
--      SELECT to_regclass('public.audit_events');
--      -- expect: public.audit_events
--      SELECT to_regprocedure(
--        'public.list_practice_audit(uuid,int,int,text[],uuid,timestamptz,timestamptz)'
--      );
--      -- expect: a non-NULL regprocedure oid
--      SELECT to_regprocedure('public.record_audit_event(uuid,text,uuid,jsonb,uuid)');
--      -- expect: a non-NULL regprocedure oid
--
-- B. Sample call (run as a signed-in user who's a member of the practice):
--      SELECT * FROM public.list_practice_audit(
--        '00000000-0000-0000-0000-0000000ca71e'::uuid,
--        0, 10, NULL, NULL, NULL, NULL
--      );
--      -- expect: up to 10 rows ordered by ts DESC with total_count repeated.
--
-- C. RLS denial for non-members:
--      -- signed in as a user who is NOT in the practice:
--      SELECT * FROM public.list_practice_audit(
--        '00000000-0000-0000-0000-0000000ca71e'::uuid,
--        0, 10, NULL, NULL, NULL, NULL
--      );
--      -- expect: 42501 "not a member of this practice"
