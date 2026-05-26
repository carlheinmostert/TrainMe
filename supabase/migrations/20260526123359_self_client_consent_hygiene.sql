-- ============================================================================
-- M23 — Self-client video_consent jsonb hygiene
-- 2026-05-26 — fix/settings-reshape-and-self-face-home
--
-- Three deficiencies in the existing Self-client flow that this migration
-- fixes:
--
--   1. `ensure_self_client` mint branch (PR #513) writes only 5 jsonb
--      keys: line_drawing / grayscale / original / avatar / analytics_allowed.
--      Missing: `safe_mode_face_recognition`. Result — a fresh Self-client
--      cannot be discriminated by face-rec on capture until something
--      else flips the key.
--
--   2. `register_self_face` mint branch (migration 20260525114912) has
--      the same missing key. Practitioners enrolling via the consent
--      sheet got a Self-client without face-rec consent — even though
--      THEY JUST CONSENTED TO FACE-REC by tapping Yes. The consent
--      stamp lands on `practitioners.face_embedding_consented_at` but
--      the per-client jsonb doesn't reflect it.
--
--   3. Both mint branches use conservative defaults (avatar=false)
--      that ignore actual practitioner state. If the practitioner has
--      already saved an avatar (`practitioners.avatar_url IS NOT NULL`)
--      when the Self-client lands, the consent should reflect that —
--      a practitioner sharing their avatar publicly on the venue
--      transparency page hasn't somehow withdrawn avatar consent for
--      their OWN self-captures.
--
-- Fix:
--
--   * Both RPCs now write a COMPLETE 6-key video_consent jsonb that
--     derives avatar + safe_mode_face_recognition from live
--     `practitioners` row state at insert time. Other keys keep their
--     conservative defaults (Self-client analytics_allowed=false per
--     R4-M1; grayscale/original=false because the practitioner controls
--     treatment per-publish, not per-client).
--
--   * One-off `jsonb_set` backfill merges the two missing keys into
--     existing Self-client rows WITHOUT overwriting any value that's
--     already present. Idempotent — re-running is a no-op.
--
-- Pre-flight: pg_get_functiondef pulled both RPCs from live staging
-- (project vadjvkmldtoeyspyoqbx) so the new bodies preserve every
-- existing branch. Per feedback_schema_migration_column_preservation —
-- both functions go through CREATE OR REPLACE with the same
-- (parameters, RETURNS, LANGUAGE, SECURITY, search_path) shape so the
-- ACL grant doesn't drift.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Section 1 — ensure_self_client (PR #513) updated mint branch.
-- ----------------------------------------------------------------------------

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
  v_has_avatar   boolean;
  v_has_face_emb boolean;
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

  -- Branch 2 — soft-deleted Self-client exists. Undelete in place so
  -- existing plans/exercises that point at it stay valid.
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

  -- Branch 3 — no Self-client at all. Mint a fresh one.
  --
  -- M23 (2026-05-26): video_consent now includes ALL 6 keys explicitly,
  -- with avatar + safe_mode_face_recognition derived from live
  -- practitioner state. Falls back to false when no practitioners row
  -- exists yet (a user can land here before they've ever saved a
  -- Public profile — the row gets created lazily by set_practitioner_profile).
  SELECT
    avatar_url IS NOT NULL AND avatar_url <> '',
    face_embedding IS NOT NULL
  INTO v_has_avatar, v_has_face_emb
  FROM public.practitioners
  WHERE user_id = v_caller;

  v_has_avatar   := COALESCE(v_has_avatar, false);
  v_has_face_emb := COALESCE(v_has_face_emb, false);

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
      'line_drawing',                true,
      'grayscale',                   false,
      'original',                    false,
      'avatar',                      v_has_avatar,
      'analytics_allowed',           false,
      'safe_mode_face_recognition',  v_has_face_emb
    )
  )
  RETURNING id INTO v_self_client;

  RETURN v_self_client;
END;
$function$;

REVOKE ALL ON FUNCTION public.ensure_self_client(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_self_client(uuid) TO authenticated;

COMMENT ON FUNCTION public.ensure_self_client(uuid) IS
  'Self-trainer wave hotfix (2026-05-25). M23 (2026-05-26) — mint branch '
  'now writes a complete 6-key video_consent jsonb including '
  'safe_mode_face_recognition + avatar derived from live practitioner '
  'state. Idempotent JIT-heal for the Self-client row in the caller''s '
  'practice. Returns the live Self-client uuid, creating or undeleting '
  'as needed. See migration header for the three branches (live / '
  'undelete / mint).';

-- ----------------------------------------------------------------------------
-- Section 2 — register_self_face (migration 20260525114912) updated mint
-- branch.
--
-- Preserves every existing line of the previous body verbatim per
-- feedback_schema_migration_column_preservation. Only the
-- jsonb_build_object call in the mint branch grows from 5 keys to 6 +
-- adds `safe_mode_face_recognition: true` (the user has just consented
-- to face-rec by calling this RPC, so the per-client flag should
-- reflect that immediately).
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.register_self_face(
  p_embedding    vector,
  p_consented_at timestamp with time zone
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
  v_consented_at timestamptz := now();
  v_has_avatar   boolean;
BEGIN
  -- Authentication gate.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'register_self_face requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Argument validation. p_consented_at is intentionally ignored — see
  -- R4-L2 above — but we still accept it for API stability. p_embedding
  -- remains required.
  IF p_embedding IS NULL THEN
    RAISE EXCEPTION 'register_self_face: p_embedding is required'
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
    v_consented_at,
    now(),
    now()
  )
  ON CONFLICT (user_id) DO UPDATE
     SET face_embedding              = EXCLUDED.face_embedding,
         face_embedding_consented_at = EXCLUDED.face_embedding_consented_at,
         face_embedding_computed_at  = EXCLUDED.face_embedding_computed_at,
         updated_at                  = now();

  -- Resolve or create the Self-client row.
  SELECT id INTO v_self_client
    FROM public.clients
   WHERE practice_id = v_practice_id
     AND user_id     = v_caller
     AND deleted_at IS NULL
   LIMIT 1;

  IF v_self_client IS NULL THEN
    -- M23 (2026-05-26) — video_consent now includes ALL 6 keys explicitly.
    -- safe_mode_face_recognition=true because the user has just consented
    -- to face-rec by calling this RPC. avatar derived from live
    -- practitioner state (row may or may not exist yet — UPSERT above
    -- guarantees the user_id row but not the avatar_url column).
    SELECT avatar_url IS NOT NULL AND avatar_url <> '' INTO v_has_avatar
      FROM public.practitioners
      WHERE user_id = v_caller;
    v_has_avatar := COALESCE(v_has_avatar, false);

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
      v_practice_id,
      'Me',
      v_caller,
      v_caller,
      jsonb_build_object(
        'line_drawing',                true,
        'grayscale',                   false,
        'original',                    false,
        'avatar',                      v_has_avatar,
        'analytics_allowed',           false,
        'safe_mode_face_recognition',  true
      )
    )
    RETURNING id INTO v_self_client;
  END IF;

  -- CB-9: audit-event write for face-consent grant. The audit_events
  -- table is the existing per-practice audit feed (kind/meta/actor_id/
  -- practice_id/ref_id schema). Practitioner face consent is closest
  -- to a profile-level event, NOT a capture event, so it does not
  -- belong in capture_audit_events (which is per-capture and carries
  -- a SHA-256 file fingerprint).
  INSERT INTO public.audit_events (
    practice_id,
    actor_id,
    kind,
    ref_id,
    meta
  ) VALUES (
    v_practice_id,
    v_caller,
    'practitioner.face_consent.granted',
    v_self_client,
    jsonb_build_object(
      'consented_at',  v_consented_at,
      'embedding_dim', 512
    )
  );

  RETURN v_self_client;
END;
$function$;

REVOKE ALL ON FUNCTION public.register_self_face(vector, timestamp with time zone) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_self_face(vector, timestamp with time zone) TO authenticated;

-- ----------------------------------------------------------------------------
-- Section 3 — One-off backfill of existing Self-client rows.
--
-- Merges the two missing keys into every live Self-client jsonb without
-- overwriting any value that's already present. Idempotent — re-running
-- is a no-op because `||` right-side wins on duplicate keys but the
-- subquery only feeds NEW key/value pairs filtered through `?` checks.
--
-- Strategy:
--   * `safe_mode_face_recognition`: append `true` if the practitioner
--     has a face_embedding (they've already enrolled), otherwise `false`.
--     The key is only ADDED if missing (preserves any explicit
--     true/false the user has set elsewhere).
--   * `avatar`: same — derive `true` from practitioners.avatar_url
--     presence, only fill if missing.
--
-- The `?` operator checks for key existence in jsonb; we use NOT (jsonb
-- ? 'key') as the filter so a row that already has the key (even with
-- value false) is left alone. POPIA-friendly — we never silently flip
-- a user-set false back to true.
-- ----------------------------------------------------------------------------

UPDATE public.clients c
   SET video_consent = c.video_consent
       || jsonb_build_object(
            'safe_mode_face_recognition',
            (p.face_embedding IS NOT NULL)
          )
  FROM public.practitioners p
 WHERE c.user_id = p.user_id
   AND c.user_id IS NOT NULL
   AND c.deleted_at IS NULL
   AND NOT (c.video_consent ? 'safe_mode_face_recognition');

UPDATE public.clients c
   SET video_consent = c.video_consent
       || jsonb_build_object(
            'avatar',
            (p.avatar_url IS NOT NULL AND p.avatar_url <> '')
          )
  FROM public.practitioners p
 WHERE c.user_id = p.user_id
   AND c.user_id IS NOT NULL
   AND c.deleted_at IS NULL
   AND NOT (c.video_consent ? 'avatar');

-- Defensive backfill for the 4 keys that should ALWAYS exist on every
-- video_consent jsonb (line_drawing / grayscale / original /
-- analytics_allowed). Same pattern — only add if missing. Conservative
-- defaults: line_drawing=true (always-on per design — line drawings
-- de-identify, can't be withdrawn); other three false.
UPDATE public.clients
   SET video_consent = video_consent || jsonb_build_object('line_drawing', true)
 WHERE user_id IS NOT NULL
   AND deleted_at IS NULL
   AND NOT (video_consent ? 'line_drawing');

UPDATE public.clients
   SET video_consent = video_consent || jsonb_build_object('grayscale', false)
 WHERE user_id IS NOT NULL
   AND deleted_at IS NULL
   AND NOT (video_consent ? 'grayscale');

UPDATE public.clients
   SET video_consent = video_consent || jsonb_build_object('original', false)
 WHERE user_id IS NOT NULL
   AND deleted_at IS NULL
   AND NOT (video_consent ? 'original');

UPDATE public.clients
   SET video_consent = video_consent
       || jsonb_build_object('analytics_allowed', false)
 WHERE user_id IS NOT NULL
   AND deleted_at IS NULL
   AND NOT (video_consent ? 'analytics_allowed');

COMMIT;
