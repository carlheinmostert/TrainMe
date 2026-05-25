-- ============================================================================
-- Self-trainer wave — schema deltas (PR #1 of 11)
-- 2026-05-25 — feat/self-trainer-schema
--
-- Spec: docs/SELF_TRAINER_WAVE.md § Schema deltas
-- ADRs:
--   * docs/adr/0020-self-trainer-as-practitioner-with-self-as-client.md
--   * docs/adr/0021-safe-mode-subscription-credit-denominated.md
--   * docs/adr/0022-plan-artifacts-abstraction-before-reel.md
--
-- Additive only. No drops, no renames, no breaking changes. Every column add
-- is IF NOT EXISTS; every index and table CREATE is IF NOT EXISTS. Safe to
-- re-apply.
--
-- Six deltas:
--   1. clients.user_id              — Self-client identification
--   2. practitioners.face_embedding — pgvector, plus consent + computed
--                                     timestamps
--   3. plan_artifacts table         — Plan URL kind only at v1, backfill
--                                     existing plans
--   4. credit_ledger index          — Safe Mode subscription lookup
--                                     (gated on credit_ledger.type, not
--                                     `kind` — see deviation note below)
--   5. practice_members.safe_mode_grandfathered + backfill
--   6. exercises.self_verified      — populated by PR #5
--
-- Deviations from spec (documented for review):
--   * Spec § 4 says `credit_ledger.kind`; actual column is `credit_ledger.type`.
--     The CHECK constraint on `type` does NOT currently allow
--     'safe_mode_month' / 'safe_mode_month_trial' values. This migration
--     does NOT extend the CHECK constraint (that would be a follow-on PR;
--     extending CHECKs is non-trivial and Carl should sign off explicitly).
--     The lookup index is built on `type` for future-proofing; once a later
--     PR widens the CHECK to include the new kinds, inserts can land and
--     the index will serve them. The index condition uses the new kinds so
--     it's a no-op on today's data.
--   * Spec § 5 backfill references `exercises.session_id`; actual column is
--     `exercises.plan_id`. Corrected. Also simplified the join — `plans` has
--     its own `practice_id` column, so the join through `clients` is
--     unnecessary.
--   * Spec § 3 plan_artifacts RLS says join through clients; `plans` has its
--     own `practice_id` already (matches the `plan_issuances` RLS pattern),
--     so the policy uses `p.practice_id` directly for a simpler / faster
--     check.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. pgvector extension (required for practitioners.face_embedding)
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------------
-- 1. clients.user_id — Self-client identification
-- ---------------------------------------------------------------------------
-- Nullable; populated only for self-client rows. ON DELETE SET NULL so a
-- user account deletion leaves the historical client row intact (orphaned
-- from auth.users, soft-deletable separately).
ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- Partial unique index enforces "at most one self-client per user per
-- practice". With the personal-practice-only rule (Q4.3 revised) this
-- effectively means exactly one self-client per user across the system.
-- The WHERE clause excludes soft-deleted rows so a user can recreate after
-- deletion.
CREATE UNIQUE INDEX IF NOT EXISTS clients_one_self_per_user_per_practice
  ON public.clients (practice_id, user_id)
  WHERE user_id IS NOT NULL AND deleted_at IS NULL;

COMMENT ON COLUMN public.clients.user_id IS
  'Self-client linkage — when non-NULL, this clients row IS the practitioner '
  'themselves. NULL for regular clients. Backed by partial unique index '
  '(practice_id, user_id) WHERE NOT NULL AND NOT deleted. Populated by '
  'register_self_face RPC (PR #4). See docs/SELF_TRAINER_WAVE.md.';

-- ---------------------------------------------------------------------------
-- 2. practitioners.face_embedding — pgvector + consent + computed timestamps
-- ---------------------------------------------------------------------------
-- Note: vector(192) here is for MobileFaceNet's standard 192-dim embedding
-- (the spec choice). This is distinct from the existing
-- clients.face_embedding (bytea, 512 FP32) added by Safe Mode v2 — that
-- column is per-client identification for bystander discrimination. This
-- column is per-practitioner self-verification. Two different purposes,
-- two different tables, two different formats. Do not conflate.
ALTER TABLE public.practitioners
  ADD COLUMN IF NOT EXISTS face_embedding              vector(192),
  ADD COLUMN IF NOT EXISTS face_embedding_consented_at timestamptz,
  ADD COLUMN IF NOT EXISTS face_embedding_computed_at  timestamptz;

COMMENT ON COLUMN public.practitioners.face_embedding IS
  'Self-trainer self-verification — 192-dim MobileFaceNet embedding of the '
  'practitioner''s own face. NULL until they consent + the on-device '
  'embedding computes successfully. Distinct from clients.face_embedding '
  '(which is for client identification in Safe Mode v2). Population path: '
  'register_self_face RPC (PR #4).';

COMMENT ON COLUMN public.practitioners.face_embedding_consented_at IS
  'Self-trainer POPIA consent stamp — moment the user explicitly opted into '
  '"use this face for self-verification". Different purpose from the '
  'Public profile selfie display consent (Q14.1). NULL = no consent yet, '
  'embedding is NOT populated.';

COMMENT ON COLUMN public.practitioners.face_embedding_computed_at IS
  'Self-trainer embedding generation timestamp — used for staleness '
  'diagnostics + future model-version migrations.';

-- ---------------------------------------------------------------------------
-- 3. plan_artifacts table — Plan URL kind only at v1, prepared for Reel
-- ---------------------------------------------------------------------------
-- Per ADR-0022, abstract the per-Plan "what we ship" concept now so the Reel
-- artifact (and any future kind) becomes a pure additive change.
CREATE TABLE IF NOT EXISTS public.plan_artifacts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id       uuid NOT NULL REFERENCES public.plans(id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('plan_url')),
  status        text NOT NULL DEFAULT 'ready'
                  CHECK (status IN ('pending', 'generating', 'ready', 'failed')),
  output_url    text,
  generated_at  timestamptz NOT NULL DEFAULT now(),
  error_message text,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- Partial unique index: one ready/pending/generating row per (plan, kind);
-- failed rows allowed to coexist with retries. Mirrors the spec's
-- (plan_id, kind) UNIQUE intent but tolerates retry rows.
-- (Per spec text: "UNIQUE (plan_id, kind)" — implementing as a plain unique
-- constraint to match the spec literally.)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'plan_artifacts_plan_kind_unique'
  ) THEN
    ALTER TABLE public.plan_artifacts
      ADD CONSTRAINT plan_artifacts_plan_kind_unique UNIQUE (plan_id, kind);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS plan_artifacts_plan_id ON public.plan_artifacts (plan_id);

ALTER TABLE public.plan_artifacts ENABLE ROW LEVEL SECURITY;

-- SELECT: scoped via plans.practice_id (matches plan_issuances RLS pattern).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'plan_artifacts'
      AND policyname = 'plan_artifacts_select_via_plan'
  ) THEN
    CREATE POLICY plan_artifacts_select_via_plan ON public.plan_artifacts
      FOR SELECT
      USING (
        plan_id IN (
          SELECT p.id FROM public.plans p
          WHERE p.practice_id IN (SELECT public.user_practice_ids())
        )
      );
  END IF;
END $$;

-- Lockdown: RPC-write-only. Mirrors credit_ledger / capture_audit_events
-- pattern. Writes only via the publish-flow RPC (PR #7).
REVOKE INSERT, UPDATE, DELETE ON public.plan_artifacts FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.plan_artifacts FROM anon;

COMMENT ON TABLE public.plan_artifacts IS
  'Per-Plan durable outputs — one row per (plan_id, kind). v1 ships '
  '"plan_url" only; "reel" + others land in future PRs. Written by the '
  'publish flow (PR #7). See ADR-0022 + docs/SELF_TRAINER_WAVE.md.';

-- Backfill existing plans with one plan_url artifact each. Skips deleted
-- plans. Uses ON CONFLICT to make the migration idempotent if re-applied.
INSERT INTO public.plan_artifacts (plan_id, kind, status, generated_at)
SELECT
  id,
  'plan_url',
  'ready',
  COALESCE(last_published_at, sent_at, created_at, now())
FROM public.plans
WHERE deleted_at IS NULL
ON CONFLICT (plan_id, kind) DO NOTHING;
-- Note: spec referenced last_published_at + updated_at; this baseline of
-- plans has neither column. Substituted sent_at + created_at (both exist
-- per baseline DDL) as the temporal fallback chain.

-- ---------------------------------------------------------------------------
-- 4. credit_ledger Safe Mode subscription lookup index
-- ---------------------------------------------------------------------------
-- Spec § 4 names this index for the `is_in_active_safe_mode_sub` gating
-- query (lands in PR #8). Deviation: spec says column is `kind` but actual
-- column is `type`; also uses `trainer_id` rather than `user_id` per the
-- legacy practitioner column naming flagged in CLAUDE.md.
--
-- WHERE clause uses the future kinds — index is empty today, populated when
-- PR #8 widens the CHECK constraint + starts writing those rows.
CREATE INDEX IF NOT EXISTS credit_ledger_safe_mode_lookup
  ON public.credit_ledger (trainer_id, type, created_at DESC)
  WHERE type IN ('safe_mode_month', 'safe_mode_month_trial');

COMMENT ON INDEX public.credit_ledger_safe_mode_lookup IS
  'Lookup index for is_in_active_safe_mode_sub(p_user_id) — Safe Mode '
  'subscription gating fn. Filters on type IN (safe_mode_month, '
  'safe_mode_month_trial). Index is empty until PR #8 widens the type '
  'CHECK constraint to allow those kinds. See docs/SELF_TRAINER_WAVE.md.';

-- ---------------------------------------------------------------------------
-- 5. practice_members.safe_mode_grandfathered + backfill
-- ---------------------------------------------------------------------------
ALTER TABLE public.practice_members
  ADD COLUMN IF NOT EXISTS safe_mode_grandfathered boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.practice_members.safe_mode_grandfathered IS
  'Self-trainer wave — perpetual-free Safe Mode flag for early adopters '
  '(anyone who captured with safe_mode_active=true before the subscription '
  'gate landed). Read by is_in_active_safe_mode_sub. Set by this '
  'migration''s one-time backfill below.';

-- Backfill: any practitioner who has captured a safe_mode_active=true
-- exercise in any of their practices is grandfathered. Joins exercises to
-- plans (plans.practice_id, not via clients) for the simplest query path.
-- Idempotent: re-running this UPDATE is a no-op.
UPDATE public.practice_members pm
SET safe_mode_grandfathered = true
WHERE NOT safe_mode_grandfathered
  AND EXISTS (
    SELECT 1
    FROM public.exercises e
    JOIN public.plans p ON p.id = e.plan_id
    WHERE p.practice_id = pm.practice_id
      AND e.safe_mode_active = true
  );

-- ---------------------------------------------------------------------------
-- 6. exercises.self_verified — populated by PR #5
-- ---------------------------------------------------------------------------
-- NULL = not yet checked (legacy rows + pre-PR-#5 captures). true/false =
-- result of MobileFaceNet vs practitioners.face_embedding comparison at
-- capture time. The publish-cost logic (PR #6) treats NULL conservatively
-- as "unverified".
ALTER TABLE public.exercises
  ADD COLUMN IF NOT EXISTS self_verified boolean;

COMMENT ON COLUMN public.exercises.self_verified IS
  'Self-trainer self-verification result — NULL = not checked (legacy or '
  'pre-PR-#5). true = capture-time face matched practitioners.face_embedding. '
  'false = no match (capture still saved per Q2.4; only the publish cost '
  'differs). Aggregated in preview_publish_cost (PR #6).';

COMMIT;
