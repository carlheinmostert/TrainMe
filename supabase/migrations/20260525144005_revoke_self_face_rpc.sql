-- ============================================================================
-- Self-trainer wave — revoke_self_face RPC (PR #4 of 11)
-- 2026-05-25 — feat/self-trainer-consent
--
-- Spec: docs/sub-agent-briefs/04-self-trainer-consent.md
--       docs/SELF_TRAINER_WAVE.md § "POPIA compliance" § 3 "Decoupled deletion"
-- ADR:  docs/adr/0020-self-trainer-as-practitioner-with-self-as-client.md
--
-- Brand new function — no prior signature to preserve (per
-- feedback_schema_migration_column_preservation).
--
-- POPIA Q14.3 — "Decoupled deletion". The Settings → Public profile flow
-- gains a "Stop using face verification" affordance. Tap → calls this
-- RPC, which:
--
--   1. Clears `practitioners.face_embedding` + the two timestamps
--      (`face_embedding_consented_at`, `face_embedding_computed_at`)
--      back to NULL. The selfie + name remain so the Safe Mode
--      transparency surface keeps working — only the
--      self-verification purpose is revoked.
--
--   2. Soft-deletes the Self-client row (`clients.user_id = auth.uid()`
--      AND `deleted_at IS NULL` in the caller's personal practice) by
--      stamping `deleted_at = now()` + `deleted_by_user_id = auth.uid()`.
--      The partial unique index `clients_one_self_per_user_per_practice`
--      filters on `deleted_at IS NULL`, so soft-deletion frees the slot
--      for a future re-registration via `register_self_face`.
--
-- Idempotent — re-calling on an already-revoked practitioner is a no-op
-- (UPDATE matches zero rows; soft-delete is filtered by `deleted_at IS NULL`).
--
-- Returns a record indicating what changed:
--   embedding_cleared   boolean — true iff face_embedding was non-NULL pre-call
--   self_client_deleted uuid    — the soft-deleted Self-client id, or NULL
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.revoke_self_face()
 RETURNS TABLE (
   embedding_cleared   boolean,
   self_client_deleted uuid
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_had_embed    boolean := false;
  v_self_client  uuid;
BEGIN
  -- Authentication gate.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'revoke_self_face requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  -- Clear the embedding + consent + computed timestamps on the
  -- practitioners row. We only flip `embedding_cleared` true if there
  -- was actually an embedding to clear — lets the caller distinguish
  -- "we revoked something" from "you weren't a self-trainer to begin
  -- with" for the SnackBar copy.
  UPDATE public.practitioners
     SET face_embedding              = NULL,
         face_embedding_consented_at = NULL,
         face_embedding_computed_at  = NULL,
         updated_at                  = now()
   WHERE user_id = v_caller
     AND face_embedding IS NOT NULL
  RETURNING true INTO v_had_embed;

  IF v_had_embed IS NULL THEN
    v_had_embed := false;
  END IF;

  -- Soft-delete the Self-client row, if present. The partial unique
  -- index filters on deleted_at IS NULL so this frees the slot for a
  -- future re-registration via register_self_face.
  UPDATE public.clients
     SET deleted_at         = now(),
         deleted_by_user_id = v_caller
   WHERE practice_id IN (
           SELECT practice_id
             FROM public.practice_members
            WHERE trainer_id = v_caller
         )
     AND user_id     = v_caller
     AND deleted_at IS NULL
  RETURNING id INTO v_self_client;

  embedding_cleared   := v_had_embed;
  self_client_deleted := v_self_client;
  RETURN NEXT;
END;
$function$;

-- Lock down: only authenticated callers may execute; service_role for
-- server-side jobs; anon explicitly denied.
REVOKE EXECUTE ON FUNCTION public.revoke_self_face()
  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.revoke_self_face()
  TO authenticated;
GRANT  EXECUTE ON FUNCTION public.revoke_self_face()
  TO service_role;

COMMENT ON FUNCTION public.revoke_self_face() IS
  'Self-trainer wave PR #4 — POPIA Q14.3 decoupled deletion. Clears '
  'practitioners.face_embedding + consent/computed timestamps and '
  'soft-deletes the Self-client row. Selfie + name remain on the '
  'practitioners row so Safe Mode transparency keeps working. '
  'Idempotent. See docs/SELF_TRAINER_WAVE.md § POPIA compliance.';

COMMIT;
