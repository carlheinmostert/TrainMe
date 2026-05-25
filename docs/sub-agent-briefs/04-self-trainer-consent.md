# Brief — PR #4: Public profile consent UI + lazy backfill + Self-client creation

**Target branch:** `feat/self-trainer-consent`
**Target merge:** `staging`
**Depends on:** PR #1 (`feat/self-trainer-schema`), PR #3 (`feat/self-face-embedding`)
**Sensitive zone:** POPIA-sensitive UX

## Context

`docs/SELF_TRAINER_WAVE.md` § "Persona onboarding" + § "POPIA compliance" + § "Migration plan" § "Lazy backfill".

This PR wires the user-facing consent dialog + the lazy backfill that converts existing Public profile selfie users into self-trainers on next launch. The consent prompt is POPIA-sensitive — the wording matters legally.

## Acceptance criteria

1. **Consent dialog** — new widget `app/lib/widgets/self_face_consent_sheet.dart`. Bottom sheet (NOT a modal — per R-01). Copy template (refine with Carl on review):
   > **Use your photo for self-verification too?**
   > This lets us recognise you in your own captures so they're free to publish. Your face data stays on this device and in your homefit.studio account; you can delete it anytime in Settings.
   > [ Not now ]    [ Yes, use it ]
   On "Yes": invokes `FaceEmbeddingService.computeForImage(selfie_path)` → `ApiClient.registerSelfFace(embedding, now())`. On "Not now": dismisses; no embedding, no Self-client; the existing selfie keeps powering Safe Mode transparency only.

2. **Lazy backfill trigger** — in `app/lib/services/auth_service.dart` (or a new `app/lib/services/self_trainer_bootstrap.dart`), after first successful authenticated bootstrap, check `practitioners.face_embedding IS NULL` AND `practitioners.avatar_url IS NOT NULL` AND `practitioners.face_embedding_consented_at IS NULL`. If all three: surface the consent sheet on the next time Home renders (post-frame callback). One-time per user — stamp a `SharedPreferences` flag so re-prompts don't fire on every launch.

3. **Inline-on-FAB-tap prompt** — separate trigger: when user taps "New Session" FAB on My Workouts AND has no self-client yet, surface the same consent sheet inline first (before navigating to Session shell). On Yes: register face, then proceed to create session. On Not now: dismiss sheet, do NOT create session, user stays on My Workouts.

4. **Settings → Public profile addition** — `app/lib/screens/public_profile_screen.dart` gains a section below the selfie:
   - If `face_embedding_consented_at IS NOT NULL`: section reads "Face verification: ON · captures of you are free to publish · [ Stop using face verification ]". Tap "Stop" → calls a new RPC `revoke_self_face()` which deletes the embedding + soft-deletes the self-client. Undoable via SnackBar (per R-01).
   - If consent missing but selfie present: section reads "Face verification: OFF · turn it on to make captures of yourself free · [ Turn on ]". Tap "Turn on" → opens the consent sheet.

5. **API client extensions** — `app/lib/services/api_client.dart` gains `revokeSelfFace()` method. Routes through new SECURITY DEFINER RPC `revoke_self_face()` (migration: `YYYYMMDDHHMMSS_revoke_self_face_rpc.sql`).

6. **POPIA copy** — final wording for the consent dialog is **Carl-review-required**. Do NOT merge without explicit copy approval. The brief above is a starting draft.

7. **Test script** — `docs/test-scripts/2026-05-25-self-trainer-consent.md`. Items: (a) cold launch with no selfie: no prompt; (b) launch with existing selfie + no consent: prompt appears once; (c) "Not now" dismisses and doesn't re-prompt; (d) "Yes" creates self-client + embedding; (e) Settings → "Stop using face verification" deletes embedding + self-client + reverts state; (f) FAB tap without self-client surfaces inline consent.

## Hard rules

- **Repo-relative paths only**.
- **No direct DB access** — all via `ApiClient`.
- **R-10 N/A** — mobile-only.
- **POPIA copy review required before merge.**
- **No mobile deployment.**
- **No emojis.**
- **Branch**: `feat/self-trainer-consent`.
