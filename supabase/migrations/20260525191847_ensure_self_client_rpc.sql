-- ============================================================================
-- Self-trainer wave hotfix — ensure_self_client RPC
-- 2026-05-25 — fix/self-client-hide-and-jit-create
--
-- Idempotent JIT-heal helper for the Self-client row. Called from the
-- mobile FAB on My Workouts before minting a session, so the practitioner
-- never sees "Couldn't load your self profile. Try again in a moment."
-- when the Self-client is missing OR soft-deleted.
--
-- Background: PR #502 / PR #508 lazy-create the Self-client via
-- `register_self_face`, but if the row is later soft-deleted (e.g. via
-- `delete_client`) or never landed for whatever reason, the FAB read of
-- `getCachedSelfClient` returns null and the user is wedged with no
-- recovery path. This RPC is the recovery path.
--
-- Semantics:
--   * If a live Self-client (user_id = caller AND deleted_at IS NULL)
--     exists in the target practice, return its id. No-op.
--   * If a soft-deleted Self-client (user_id = caller AND deleted_at IS
--     NOT NULL) exists, undelete it (clear deleted_at + deleted_by_user_id,
--     bump updated_at) and return its id. Preserves the original uuid,
--     name, video_consent, face_embedding — everything the user had.
--   * If no Self-client exists at all, mint a fresh one ('Me', user_id =
--     caller, video_consent.analytics_allowed = false per R4-M1).
--
-- Idempotent — every call returns the same id once the row exists. The
-- partial unique index `clients_one_self_per_user_per_practice`
-- (practice_id, user_id) WHERE user_id IS NOT NULL AND deleted_at IS NULL
-- enforces "at most one live Self-client per (practice, user)" so a
-- concurrent caller cannot create a duplicate; on 23505 the caller
-- retries and the SELECT branch finds the winner's row.
--
-- Why a separate RPC instead of folding into register_self_face: the
-- latter requires p_embedding which the FAB doesn't have (face consent
-- may already be stamped; FAB just needs the row to exist). Splitting
-- keeps each RPC single-purpose and avoids re-doing the embedding
-- write on every FAB tap.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.ensure_self_client(p_practice_id uuid)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_is_member    boolean;
  v_self_client  uuid;
BEGIN
  -- Authentication gate.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'ensure_self_client requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'ensure_self_client: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- Membership gate — the caller must be a member of the target practice.
  -- Reuse the same pattern as `register_self_face` (which scans
  -- practice_members directly inside its SECURITY DEFINER body).
  SELECT EXISTS (
    SELECT 1 FROM public.practice_members
     WHERE practice_id = p_practice_id
       AND trainer_id  = v_caller
  ) INTO v_is_member;

  IF NOT v_is_member THEN
    RAISE EXCEPTION 'ensure_self_client: caller % is not a member of practice %',
                    v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  -- Branch 1 — live Self-client already exists. No-op, return id.
  SELECT id INTO v_self_client
    FROM public.clients
   WHERE practice_id = p_practice_id
     AND user_id     = v_caller
     AND deleted_at IS NULL
   LIMIT 1;

  IF v_self_client IS NOT NULL THEN
    RETURN v_self_client;
  END IF;

  -- Branch 2 — soft-deleted Self-client exists. Undelete in place so we
  -- preserve the original uuid (any plans/exercises pointing at it stay
  -- valid), name, video_consent, face_embedding, etc. The partial unique
  -- index ignores rows with deleted_at IS NOT NULL so undeleting cannot
  -- collide with any existing live row (which we already checked above
  -- and confirmed doesn't exist).
  UPDATE public.clients
     SET deleted_at         = NULL,
         deleted_by_user_id = NULL,
         updated_at         = now()
   WHERE practice_id = p_practice_id
     AND user_id     = v_caller
     AND deleted_at IS NOT NULL
   RETURNING id INTO v_self_client;

  IF v_self_client IS NOT NULL THEN
    RETURN v_self_client;
  END IF;

  -- Branch 3 — no Self-client at all. Mint a fresh one. R4-M1: explicitly
  -- default analytics_allowed=false on the Self-client video_consent —
  -- mirrors register_self_face's mint branch so the two stay in sync.
  INSERT INTO public.clients (
    id,
    practice_id,
    name,
    user_id,
    created_by_user_id,
    video_consent
  )
  VALUES (
    gen_random_uuid(),
    p_practice_id,
    'Me',
    v_caller,
    v_caller,
    jsonb_build_object(
      'line_drawing',      true,
      'grayscale',         false,
      'original',          false,
      'avatar',            false,
      'analytics_allowed', false
    )
  )
  RETURNING id INTO v_self_client;

  RETURN v_self_client;
END;
$function$;

-- Grants — same as register_self_face: authenticated callers only.
-- The function body's auth.uid() check + membership gate enforce the
-- per-call authorisation; the GRANT just controls EXECUTE visibility.
REVOKE ALL ON FUNCTION public.ensure_self_client(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_self_client(uuid) TO authenticated;

COMMENT ON FUNCTION public.ensure_self_client(uuid) IS
  'Self-trainer wave hotfix (2026-05-25). Idempotent JIT-heal for the '
  'Self-client row in the caller''s practice. Returns the live Self-client '
  'uuid, creating or undeleting as needed. Called by the mobile FAB on '
  'My Workouts before minting a session. See migration header for the '
  'three branches (live / undelete / mint).';

COMMIT;
