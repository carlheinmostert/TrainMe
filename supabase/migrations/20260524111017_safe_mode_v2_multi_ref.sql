-- 2026-05-24 — Safe Mode v2: multi-reference face enrolment (Wave-A)
--
-- Spec: docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md
--
-- Replaces the single-embedding-per-client model from the 2026-05-23
-- spec. The discriminator algorithm itself (cosine similarity, blur
-- policy) is unchanged — only the reference shape and enrolment UX
-- change here. This migration is the schema half of Wave-A; native
-- channel signature + UI come in Wave-BC + Wave-D.
--
-- Why multi-reference: a single frontal embedding cannot span the
-- pose-and-lighting space the discriminator has to operate over. The
-- 2026-05-24 bench measured the subject's own cosSim against their
-- frontal avatar at 0.25 in a side-profile, while a passing bystander
-- scored 0.36 against the same avatar. No global threshold separates
-- those cases. Apple Face ID's solution — multiple references spanning
-- the pose space, match against max similarity — restores the gap.
--
-- Schema bump: new `client_face_embeddings` table (5-8 rows per fully-
-- enrolled client, PK on `(client_id, slot_index)`). The legacy
-- `clients.face_embedding` + `face_embedding_model_version` columns are
-- RETAINED for one release cycle (per spec) so a roll-back is possible;
-- a follow-up migration two waves out drops them.

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Table: client_face_embeddings
--
--    One row per (client, enrolment slot). 5-8 rows per fully-enrolled
--    client. embedding is 2048 bytes = 512 FP32 little-endian floats
--    (MobileFaceNet output), L2-normalised at the native layer.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.client_face_embeddings (
  client_id        uuid        NOT NULL REFERENCES public.clients(id) ON DELETE CASCADE,
  slot_index       smallint    NOT NULL,
  embedding        bytea       NOT NULL,
  model_version    smallint    NOT NULL,
  captured_at      timestamptz NOT NULL DEFAULT now(),
  pose_yaw         real,
  pose_pitch       real,
  is_frontal_pick  boolean     NOT NULL DEFAULT false,
  PRIMARY KEY (client_id, slot_index)
);

COMMENT ON TABLE public.client_face_embeddings IS
  'Safe Mode v2 multi-reference face enrolment (2026-05-24). 5-8 rows '
  'per fully-enrolled client spanning the subject''s pose space. Match-'
  'time semantics: for each detected face, cosine-similarity is computed '
  'against every row and the max is taken. Replaces the single-row '
  'clients.face_embedding column from the 2026-05-23 wave (retained for '
  'one release cycle).';

COMMENT ON COLUMN public.client_face_embeddings.embedding IS
  '512-byte MobileFaceNet output: 128 FP32 little-endian floats, '
  'L2-normalised at the native layer. Length is enforced at the RPC '
  'boundary (set_client_face_embeddings).';

COMMENT ON COLUMN public.client_face_embeddings.model_version IS
  'Generator version for the embedding. 1 = MobileFaceNet v1 (current). '
  'A future model upgrade bumps this so legacy rows can be detected and '
  're-enrolled.';

COMMENT ON COLUMN public.client_face_embeddings.is_frontal_pick IS
  'true on exactly one row per client — the most-frontal slot, used as '
  'the source for the avatar JPG so the avatar grid in /clients keeps '
  'showing a recognisable headshot.';


-- ----------------------------------------------------------------------------
-- 2. RLS: practice-scoped SELECT via user_practice_ids()
--
--    Writes go through set_client_face_embeddings RPC (SECURITY DEFINER);
--    direct INSERT/UPDATE/DELETE is revoked below.
-- ----------------------------------------------------------------------------

ALTER TABLE public.client_face_embeddings ENABLE ROW LEVEL SECURITY;

CREATE POLICY client_face_embeddings_select_own
  ON public.client_face_embeddings FOR SELECT
  TO authenticated
  USING (
    client_id IN (
      SELECT c.id FROM public.clients c
       WHERE c.practice_id IN (SELECT public.user_practice_ids())
    )
  );

REVOKE INSERT, UPDATE, DELETE ON public.client_face_embeddings FROM authenticated, anon;


-- ----------------------------------------------------------------------------
-- 3. One-shot backfill: existing single embeddings → slot_index 0
--
--    Every client with a non-null `clients.face_embedding` gets one row
--    in the new table at slot_index = 0, flagged as is_frontal_pick =
--    true (it came from the avatar — already the most-frontal frame
--    available). ON CONFLICT DO NOTHING keeps this idempotent against
--    migration re-runs.
--
--    Risk noted in the brief: this creates a row even for clients with
--    junk single embeddings (e.g. legacy enrolments where the avatar
--    photo was a bad angle). Acceptable — practitioners can re-enrol via
--    the new sweep flow, which replaces the slot set transactionally.
-- ----------------------------------------------------------------------------

INSERT INTO public.client_face_embeddings
  (client_id, slot_index, embedding, model_version, is_frontal_pick)
SELECT
  id,
  0::smallint,
  face_embedding,
  COALESCE(face_embedding_model_version, 1)::smallint,
  true
FROM public.clients
WHERE face_embedding IS NOT NULL
ON CONFLICT (client_id, slot_index) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 4. RPC: set_client_face_embeddings (plural)
--
--    Transactionally DELETE every existing row for the client and INSERT
--    the new slot set in one shot. Practice-scoped via user_practice_ids().
--    Refuses to persist below 1 slot or above 8.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_client_face_embeddings(
  p_client_id            uuid,
  p_embeddings           bytea[],
  p_model_version        smallint,
  p_frontal_pick_slot    smallint,
  p_poses_yaw            real[],
  p_poses_pitch          real[]
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_deleted_at   timestamptz;
  v_slot_count   int;
  v_yaw_count    int;
  v_pitch_count  int;
  v_i            int;
  v_emb          bytea;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_face_embeddings requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_face_embeddings: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_embeddings IS NULL THEN
    RAISE EXCEPTION 'set_client_face_embeddings: p_embeddings is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_model_version IS NULL OR p_model_version < 1 THEN
    RAISE EXCEPTION 'set_client_face_embeddings: p_model_version must be >= 1'
      USING ERRCODE = '22023';
  END IF;

  v_slot_count := array_length(p_embeddings, 1);
  IF v_slot_count IS NULL OR v_slot_count < 1 OR v_slot_count > 8 THEN
    RAISE EXCEPTION 'set_client_face_embeddings: expected 1-8 slots, got %', COALESCE(v_slot_count, 0)
      USING ERRCODE = '22023';
  END IF;

  IF p_frontal_pick_slot IS NULL OR p_frontal_pick_slot < 0 OR p_frontal_pick_slot >= v_slot_count THEN
    RAISE EXCEPTION 'set_client_face_embeddings: p_frontal_pick_slot % out of range [0,%)',
      COALESCE(p_frontal_pick_slot, -1), v_slot_count
      USING ERRCODE = '22023';
  END IF;

  -- Pose arrays must match the slot count (NULLs allowed as elements,
  -- but the array length must align so the per-row insert below stays
  -- in lockstep). Pass empty arrays {} of matching length if poses are
  -- unknown for some slots.
  v_yaw_count   := COALESCE(array_length(p_poses_yaw, 1),   0);
  v_pitch_count := COALESCE(array_length(p_poses_pitch, 1), 0);
  IF v_yaw_count <> v_slot_count OR v_pitch_count <> v_slot_count THEN
    RAISE EXCEPTION 'set_client_face_embeddings: pose arrays length mismatch (yaw=%, pitch=%, slots=%)',
      v_yaw_count, v_pitch_count, v_slot_count
      USING ERRCODE = '22023';
  END IF;

  -- Each slot embedding must be exactly 2048 bytes (= 512 FP32 floats,
  -- MobileFaceNet output).
  FOR v_i IN 1..v_slot_count LOOP
    v_emb := p_embeddings[v_i];
    IF v_emb IS NULL THEN
      RAISE EXCEPTION 'set_client_face_embeddings: slot % embedding is NULL', v_i - 1
        USING ERRCODE = '22023';
    END IF;
    IF length(v_emb) <> 2048 THEN
      RAISE EXCEPTION 'set_client_face_embeddings: slot % expected 2048-byte embedding, got % bytes',
        v_i - 1, length(v_emb)
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  SELECT practice_id, deleted_at
    INTO v_practice_id, v_deleted_at
    FROM public.clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_face_embeddings: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_face_embeddings: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids())
     AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_face_embeddings: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Transactional replace. Whole fn runs in a single SQL transaction so
  -- a mid-flight failure leaves the prior slot set intact.
  DELETE FROM public.client_face_embeddings WHERE client_id = p_client_id;

  FOR v_i IN 1..v_slot_count LOOP
    INSERT INTO public.client_face_embeddings (
      client_id,
      slot_index,
      embedding,
      model_version,
      pose_yaw,
      pose_pitch,
      is_frontal_pick
    ) VALUES (
      p_client_id,
      (v_i - 1)::smallint,
      p_embeddings[v_i],
      p_model_version,
      p_poses_yaw[v_i],
      p_poses_pitch[v_i],
      (v_i - 1) = p_frontal_pick_slot
    );
  END LOOP;

  -- Mirror the frontal-pick slot into the legacy single-embedding
  -- columns so the 2026-05-23 native code path (still in production
  -- during the backward-compat window) finds a usable reference. The
  -- column drop happens in a follow-up wave once all enrolment paths
  -- write through this RPC.
  UPDATE public.clients
     SET face_embedding               = p_embeddings[p_frontal_pick_slot + 1],
         face_embedding_model_version = p_model_version
   WHERE id = p_client_id;

  -- No audit_events row — consistent with set_client_face_embedding
  -- (singular) from the 2026-05-23 spec. The embedding is biometric data
  -- but enrolment is part of capture, not a consent toggle. Consent
  -- flips emit client.consent.update via set_client_safe_mode_consent.
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.set_client_face_embeddings(uuid, bytea[], smallint, smallint, real[], real[]) FROM public;
GRANT  EXECUTE ON FUNCTION public.set_client_face_embeddings(uuid, bytea[], smallint, smallint, real[], real[]) TO authenticated;


-- ----------------------------------------------------------------------------
-- 5. RPC: get_client_face_embeddings
--
--    Returns the multi-slot embedding set for a client. Practice-scoped
--    via user_practice_ids() — caller distinguishes empty (unenrolled) /
--    single-slot (legacy backfill) / full-enrolment (new sweep) by row
--    count on the client side.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_client_face_embeddings(
  p_client_id uuid
)
 RETURNS TABLE(
   slot_index      smallint,
   embedding       bytea,
   model_version   smallint,
   is_frontal_pick boolean
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_practice_id uuid;
  v_deleted_at  timestamptz;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_face_embeddings requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'get_client_face_embeddings: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at
    INTO v_practice_id, v_deleted_at
    FROM public.clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'get_client_face_embeddings: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'get_client_face_embeddings: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids())
     AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'get_client_face_embeddings: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT cfe.slot_index,
         cfe.embedding,
         cfe.model_version,
         cfe.is_frontal_pick
    FROM public.client_face_embeddings cfe
   WHERE cfe.client_id = p_client_id
   ORDER BY cfe.slot_index ASC;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_client_face_embeddings(uuid) FROM public;
GRANT  EXECUTE ON FUNCTION public.get_client_face_embeddings(uuid) TO authenticated;


-- ----------------------------------------------------------------------------
-- 6. set_client_safe_mode_consent — extend to clear multi-ref slots
--
--    The 2026-05-23 RPC zeroes clients.face_embedding +
--    face_embedding_model_version on consent withdrawal. With Wave-A
--    landing a separate multi-row table, the withdrawal also needs to
--    DELETE every client_face_embeddings row for the client so
--    "withdrawing consent is a full data deletion" stays true.
--
--    Every other behaviour is carried forward verbatim from
--    20260523102954_safe_mode_v2.sql per the column-preservation gotcha
--    (feedback_schema_migration_column_preservation).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_client_safe_mode_consent(
  p_client_id uuid,
  p_consent   boolean
)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_practice_id  uuid;
  v_deleted_at   timestamptz;
  v_prev_consent jsonb;
  v_new_consent  jsonb;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: p_client_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF p_consent IS NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: p_consent is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT practice_id, deleted_at, video_consent
    INTO v_practice_id, v_deleted_at, v_prev_consent
    FROM public.clients WHERE id = p_client_id LIMIT 1;

  IF v_practice_id IS NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: client % not found', p_client_id
      USING ERRCODE = '22023';
  END IF;

  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: client has been deleted'
      USING ERRCODE = '22023';
  END IF;

  IF v_practice_id NOT IN (SELECT public.user_practice_ids())
     AND NOT public.user_is_practice_owner(v_practice_id) THEN
    RAISE EXCEPTION 'set_client_safe_mode_consent: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  v_new_consent := jsonb_set(
    COALESCE(v_prev_consent, '{}'::jsonb),
    '{safe_mode_face_recognition}',
    to_jsonb(p_consent),
    true
  );

  IF p_consent = false THEN
    -- Privacy: withdrawing consent erases all biometric data — both the
    -- legacy single-embedding columns AND every row in the new multi-
    -- ref table. The practitioner can re-enrol on the next capture if
    -- the client changes their mind.
    UPDATE public.clients
       SET video_consent                = v_new_consent,
           face_embedding               = NULL,
           face_embedding_model_version = NULL
     WHERE id = p_client_id;
    DELETE FROM public.client_face_embeddings WHERE client_id = p_client_id;
  ELSE
    UPDATE public.clients
       SET video_consent = v_new_consent
     WHERE id = p_client_id;
  END IF;

  IF v_prev_consent IS DISTINCT FROM v_new_consent THEN
    INSERT INTO public.audit_events (
      practice_id,
      actor_id,
      kind,
      ref_id,
      meta
    ) VALUES (
      v_practice_id,
      v_caller,
      'client.consent.update',
      p_client_id,
      jsonb_build_object(
        'from', v_prev_consent,
        'to',   v_new_consent
      )
    );
  END IF;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.set_client_safe_mode_consent(uuid, boolean) FROM public;
GRANT  EXECUTE ON FUNCTION public.set_client_safe_mode_consent(uuid, boolean) TO authenticated;

COMMIT;
