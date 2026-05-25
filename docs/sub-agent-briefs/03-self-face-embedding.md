# Brief — PR #3: iOS native MobileFaceNet embedding compute + RPC wire-up

**Target branch:** `feat/self-face-embedding`
**Target merge:** `staging`
**Depends on:** PR #1 (`feat/self-trainer-schema`) merged
**Sensitive zone:** iOS native + new SECURITY DEFINER RPC

## Context

`docs/SELF_TRAINER_WAVE.md` § "Schema deltas" § 2 adds `practitioners.face_embedding vector(192)`. This PR wires the native compute path that populates it.

The Safe Mode v2 discriminator (PR sequence around 2026-05-22/23 per `docs/CHECKPOINT_2026-05-24.md`) already loads MobileFaceNet on-device via the existing `SafeModeProcessor` in `app/ios/Runner/VideoConverterChannel.swift`. This PR exposes that compute path through a new platform-channel method so Dart can request an embedding from a still image (the Public profile selfie) without going through the video pipeline.

## Acceptance criteria

1. **Native method** — `app/ios/Runner/HomefitFaceEmbeddingChannel.swift` (new file, mirrors the existing `HomefitHapticsChannel.swift` pattern). Single method `computeEmbeddingForImage(imagePath: String) -> [Float]` (192-dim). Loads MobileFaceNet via the same Core ML pathway `SafeModeProcessor` uses; runs face detection (Vision); takes the largest face's bounding box; crops + aligns; runs the embedding model; returns the 192-float vector. Throws a typed error if no face detected.

2. **Dart-side wrapper** — `app/lib/services/face_embedding_service.dart` (new file). Singleton with `Future<List<double>?> computeForImage(String path)`. Wraps the platform channel + handles the no-face error case (returns null, doesn't throw).

3. **RPC** — `register_self_face(p_embedding vector(192), p_consented_at timestamptz)` SECURITY DEFINER. Writes `practitioners.face_embedding` + timestamps. If `clients` row with `user_id = auth.uid()` doesn't exist in the user's personal practice, also creates it (`name='Me'`, `practice_id` derived from `practice_members` join). Idempotent — re-calling overwrites the embedding + timestamps. Returns the resolved `self_client_id`. Migration filename: `supabase/migrations/YYYYMMDDHHMMSS_register_self_face_rpc.sql`.

4. **API client wire** — `app/lib/services/api_client.dart` gains a new method `registerSelfFace(List<double> embedding, DateTime consentedAt) -> String` (returns the self-client id). Routes through the enumerated surface per `feedback_no_direct_db_access`.

5. **Test script** — `docs/test-scripts/2026-05-25-self-face-embedding.md` (markdown, GitHub-style checkboxes per `feedback_test_scripts_as_markdown`). 5-7 numbered items covering: (a) compute embedding from a known selfie returns 192 floats; (b) compute on an empty wall returns null; (c) RPC creates self-client first time; (d) RPC overwrites embedding on re-call; (e) verify partial unique index prevents duplicate self-clients.

## Hard rules

- **Repo-relative paths only** (per `feedback_agent_worktree_isolation`).
- **No direct DB access** — all reads/writes via `ApiClient` → RPCs (per `feedback_no_direct_db_access`).
- **No `flutter run`** — use `flutter build ios --debug --simulator` for testing.
- **R-10 N/A** — this is mobile-only (no web parity required).
- **Sensitive zone** — Carl will review the migration + RPC before merge.
- **No mobile deployment** (per `feedback_ask_before_mobile_deployment`) — do NOT run `install-device.sh` or `homefit-ship-to-phone`. Mac-side simulator verification only.
- **No emojis in files**.
- **Branch naming**: `feat/self-face-embedding` (per `feedback_branch_naming_discipline`).
