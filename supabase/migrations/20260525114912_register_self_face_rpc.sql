-- ============================================================================
-- Self-trainer wave — register_self_face RPC (PR #3 of 11)
-- 2026-05-25 — feat/self-face-embedding
--
-- Spec: docs/sub-agent-briefs/03-self-face-embedding.md
--       docs/SELF_TRAINER_WAVE.md § "Schema deltas" § 2
--       docs/SELF_TRAINER_WAVE.md § "Capture-entry path from My Workouts" § 5
-- ADR:  docs/adr/0020-self-trainer-as-practitioner-with-self-as-client.md
--
-- This migration does two things:
--
--   1. Amends the column added by PR #1 (`practitioners.face_embedding`)
--      from vector(192) → vector(512), because the bundled
--      MobileFaceNet.mlmodel emits a 512-d output (see
--      `app/ios/Runner/MobileFaceNetEmbedder.swift`, `embeddingDimension`).
--      The spec called for 192-d but the on-device model is fixed at
--      512-d (the InsightFace / ArcFace canonical head); re-training to
--      a 192-d head is out of scope for this wave. Safe to alter — the
--      column is NULL on every existing row (PR #1 only added it, never
--      populated it).
--
--   2. Introduces `register_self_face(p_embedding vector(512),
--      p_consented_at timestamptz)` SECURITY DEFINER. Writes the
--      practitioner's self-verification embedding + timestamps and
--      lazily creates the Self-client row in the user's personal
--      practice (per ADR-0020: self-trainer is a practitioner whose only
--      client is themselves, addressed via My Workouts; the Self-client
--      is created at the moment Public profile + face-verification
--      consent are recorded together).
--
-- Idempotency: re-calling overwrites the embedding + consent timestamp
-- and the computed-at timestamp. The partial unique index
-- `clients_one_self_per_user_per_practice` (from PR #1) guarantees the
-- second call reuses the existing Self-client row instead of creating
-- a duplicate.
--
-- Returns: the resolved Self-client uuid (always non-null on success).
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Amend practitioners.face_embedding to vector(512)
--
-- The column was added by PR #1 as vector(192). The on-device model is
-- 512-d (see MobileFaceNetEmbedder.swift, embeddingDimension = 512).
-- Three options were considered (per spec deviation review):
--   (a) Retrain MobileFaceNet to a 192-d head — out of scope; the
--       PyTorch state-dict ships with a 512-d head and re-training
--       would add weeks.
--   (b) Truncate the 512-d embedding to its first 192 dimensions —
--       degrades cosine similarity quality significantly; rejected per
--       feedback_no_silent_fallbacks.
--   (c) Match the column to the model — chosen. Same dimension as the
--       existing clients.face_embedding bytea (also 512-d / 2048 bytes).
--
-- ALTER TYPE on a pgvector column with all-NULL data is a no-op write;
-- pgvector accepts the change because there's no existing data to
-- re-cast.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  IF EXISTS (
    SELECT 1
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'practitioners'
       AND column_name  = 'face_embedding'
  ) THEN
    ALTER TABLE public.practitioners
      ALTER COLUMN face_embedding TYPE vector(512)
      USING NULL::vector(512);
  END IF;
END $$;

COMMENT ON COLUMN public.practitioners.face_embedding IS
  'Self-trainer self-verification — 512-dim MobileFaceNet embedding of '
  'the practitioner''s own face (changed from 192 to 512 by PR #3 to '
  'match the bundled mlmodel''s actual output dimension). NULL until the '
  'user consents + the on-device embedding computes successfully. '
  'Distinct from clients.face_embedding (which is for client '
  'identification in Safe Mode v2 and also 512-d but stored as bytea). '
  'Population path: register_self_face RPC.';

-- ---------------------------------------------------------------------------
-- 2. register_self_face RPC
--
-- Brand new function — no prior signature to preserve (per
-- feedback_schema_migration_column_preservation).
--
-- Resolves the user's "personal practice" as the FIRST practice where
-- they hold the 'owner' role (per ADR-0020 + bootstrap_practice_for_user
-- ordering). If multiple owner practices exist, the first by created_at
-- is chosen — deterministic but ambiguous for legacy multi-practice
-- owners; the self-trainer onboarding flow is designed for users who
-- have exactly one practice (the one created at signup), so the
-- ambiguity is bounded in practice.
--
-- Writes:
--   - practitioners.face_embedding              ← p_embedding
--   - practitioners.face_embedding_consented_at ← p_consented_at
--   - practitioners.face_embedding_computed_at  ← now()
--   - clients (id=gen_random_uuid(), practice_id=<personal>,
--              user_id=auth.uid(), name='Me') if not already present
--
-- The clients row is inserted with `ON CONFLICT DO NOTHING` keyed on the
-- partial unique index (practice_id, user_id) WHERE user_id IS NOT NULL
-- AND deleted_at IS NULL. A pre-existing self-client (re-registration)
-- is returned as-is.
--
-- Returns the Self-client uuid.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_self_face(
  p_embedding    vector(512),
  p_consented_at timestamptz
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_self_client  uuid;
BEGIN
  -- Authentication gate.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'register_self_face requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Argument validation.
  IF p_embedding IS NULL THEN
    RAISE EXCEPTION 'register_self_face: p_embedding is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_consented_at IS NULL THEN
    RAISE EXCEPTION 'register_self_face: p_consented_at is required'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve the user's personal practice. Prefer the owned practice
  -- (the one bootstrap_practice_for_user creates at signup). Fall back
  -- to any practice the user belongs to if for some reason no owned
  -- practice exists (defensive — bootstrap always creates one).
  SELECT practice_id INTO v_practice_id
    FROM public.practice_members
   WHERE trainer_id = v_caller
     AND role = 'owner'
   ORDER BY joined_at ASC NULLS LAST
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    SELECT practice_id INTO v_practice_id
      FROM public.practice_members
     WHERE trainer_id = v_caller
     ORDER BY joined_at ASC NULLS LAST
     LIMIT 1;
  END IF;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'register_self_face: caller % has no practice membership; '
                    'call bootstrap_practice_for_user first',
                    v_caller
      USING ERRCODE = '42501';
  END IF;

  -- Upsert the practitioners row. The base row may or may not already
  -- exist (set_practitioner_profile creates it on first profile save;
  -- a user may opt into face-verification before saving a name).
  INSERT INTO public.practitioners (
    user_id,
    face_embedding,
    face_embedding_consented_at,
    face_embedding_computed_at,
    updated_at
  )
  VALUES (
    v_caller,
    p_embedding,
    p_consented_at,
    now(),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE
     SET face_embedding              = EXCLUDED.face_embedding,
         face_embedding_consented_at = EXCLUDED.face_embedding_consented_at,
         face_embedding_computed_at  = EXCLUDED.face_embedding_computed_at,
         updated_at                  = now();

  -- Resolve or create the Self-client row. The partial unique index
  -- `clients_one_self_per_user_per_practice` (PR #1) guarantees at
  -- most one non-deleted self-client per (practice, user) pair, so the
  -- SELECT-then-INSERT race is bounded — the index will reject any
  -- concurrent second insert with 23505 and the caller can retry.
  SELECT id INTO v_self_client
    FROM public.clients
   WHERE practice_id = v_practice_id
     AND user_id     = v_caller
     AND deleted_at IS NULL
   LIMIT 1;

  IF v_self_client IS NULL THEN
    -- Insert a fresh Self-client row. Name defaults to 'Me' per ADR-0020;
    -- the Self-client is never surfaced in the Clients tab — only
    -- addressed via the My Workouts surface — so the name is for audit
    -- + future-proofing only.
    INSERT INTO public.clients (
      id,
      practice_id,
      name,
      user_id,
      created_by_user_id
    )
    VALUES (
      gen_random_uuid(),
      v_practice_id,
      'Me',
      v_caller,
      v_caller
    )
    RETURNING id INTO v_self_client;
  END IF;

  RETURN v_self_client;
END;
$function$;

-- Lock down: only authenticated callers may execute; service_role for
-- server-side jobs; anon explicitly denied.
REVOKE EXECUTE ON FUNCTION public.register_self_face(vector, timestamptz)
  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.register_self_face(vector, timestamptz)
  TO authenticated;
GRANT  EXECUTE ON FUNCTION public.register_self_face(vector, timestamptz)
  TO service_role;

COMMENT ON FUNCTION public.register_self_face(vector, timestamptz) IS
  'Self-trainer onboarding — writes practitioners.face_embedding + '
  'lazily creates the Self-client row in the user''s personal practice. '
  'Idempotent: re-calling overwrites the embedding + timestamps and '
  'reuses the existing Self-client. Embedding dim = 512 (MobileFaceNet '
  'on-device model output). See docs/SELF_TRAINER_WAVE.md + ADR-0020.';

COMMIT;
