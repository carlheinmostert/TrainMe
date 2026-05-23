# 2026-05-23 — Safe Mode v2: face-recognition subject discriminator

**Status:** signed off by Carl 2026-05-23. Implementation wave to follow immediately.
**Supersedes:** the segmentation-only anchor-box approach in PR #423 / PR #427 / PR #430 (broken) and the segmentation flood-fill approach in PR #437 (backlogged).
**Algorithm version stamp:** `safe_mode_algorithm_version = 2`.

## Table of Contents

- [Problem statement](#problem-statement)
- [Design summary](#design-summary)
- [The 16 decisions](#the-16-decisions)
- [Algorithm pseudocode](#algorithm-pseudocode)
- [Schema additions](#schema-additions)
- [New RPCs](#new-rpcs)
- [Native iOS surface](#native-ios-surface)
- [Dart surface](#dart-surface)
- [UI changes](#ui-changes)
- [Privacy posture](#privacy-posture)
- [Out of scope for v2](#out-of-scope-for-v2)
- [Implementation order](#implementation-order)
- [Open risks](#open-risks)

## Problem statement

Safe Mode v1 (PR #423 → PR #427 → PR #430) used face-bbox-derived "anchor boxes" to classify pixels in a person-segmentation mask as subject vs bystander. The algorithm was conceptually wrong: real bodies extend past axis-aligned anchor rectangles, so even a single-subject capture got body pixels marked as bystander → blurred along with everything else. Three rounds of fixes (crash, coordinate frame, intended-to-be-flood-fill) did not address the fundamental flaw.

The actual product use case is a SOLO practitioner self-recording in a semi-public gym, where bystanders walk through the background. Safe Mode's job is to obscure bystanders' identifying features (faces) without blurring the practitioner, the scenery, or bystanders' non-identifying body silhouettes.

## Design summary

**Per-client persistent face embedding, derived from the existing avatar JPG via an on-device MobileFaceNet CoreML model.** At capture time, Safe Mode detects all faces in the frame, embeds each, and identifies the subject by cosine similarity to the stored embedding for the session's `client_id`. Non-subject faces (and their associated body silhouettes when the subject IS identified in frame) are Gaussian-blurred. Scenery — anything that isn't a person silhouette or a face — stays sharp.

**Single subject per session, permanently.** "Classes" is a recorded-course-as-product concept, not a multi-subject capture concept (per [project_classes_means_recorded_courses](../../memory/project_classes_means_recorded_courses.md) — irrelevant to schema).

**Two operating modes at runtime, depending on whether the subject's face is detected in this particular capture:**

- **Subject identified mode:** the subject face is in frame. Aggressive privacy — subject silhouette stays sharp; every other silhouette (whether faced or un-faced) gets blurred; non-subject face bboxes also blurred defensively.
- **No subject mode:** no face in frame matches the subject embedding. Conservative — only the visible non-subject FACE bboxes get blurred. All silhouettes (including the assumed-subject, body-only-no-face) stay sharp. This permits solo back-view self-recording: the practitioner sets up the tripod and walks into frame, with their body facing away from the camera.

## The 16 decisions

| # | Decision | Locked value |
|---|---|---|
| Q1 | Reference selfie storage shape | Per-client persistent |
| Q2 | Face-rec model | MobileFaceNet (CoreML, ~5MB, MIT) |
| Q3 | Where embedding lives | `clients.face_embedding bytea` + `clients.face_embedding_model_version smallint` |
| Q4 | Reference concept | Avatar IS the reference. No separate "reference selfie." |
| Q5 | Bystander handling when subject identified | Blur face bboxes (head-expanded) + blur silhouettes with non-subject faces + blur un-faced silhouettes |
| Q6 | When embedding is generated | On avatar upload (going forward) + lazy backfill on Safe Mode first-use for existing clients |
| Q7 | Subjects per session | One. Always. `session.client_id` stays scalar. |
| Q8 | Behaviour when no subject face is in frame | Blur visible non-subject faces; keep all silhouettes sharp |
| Q9 | Client has no avatar | Inline capture flow at Safe Mode first-engage. Selfie becomes the avatar. |
| Q10 | Video Safe Mode | Phased: v1 photos only (video suppressed inside Safe Mode polygons); v2 video with keyframe-embed + track |
| Q11 | Model bundling | Bundled in the iOS app binary |
| Q12 | Broken-capture recovery | Per-card long-press "Re-process Safe Mode" affordance |
| Q13 | Blur visual | Head-expanded face region + Gaussian blur |
| Q14 | POPIA consent | Explicit `safe_mode_face_recognition` boolean in `clients.video_consent` jsonb |
| Q15 | Algorithm version stamp | `exercises.safe_mode_algorithm_version smallint` |
| Q16 | Operational defaults | Threshold 0.6, BLOCK capture during embed gen, HARD-FAIL on model load failure |

## Algorithm pseudocode

```
inputs:
  - rawImagePixelBuffer (BGRA, upright, top-left origin, display dimensions)
  - subjectEmbedding (128-d FP32 vector from the session client's avatar)
  - subjectThreshold = 0.6
  - kHeadExpansionFactor = 2.0 width / 1.5 height around face centre
  - kGaussianBlurRadius = 35.0 at 1080p, scaled by min(width, height) / 1080

steps:

  1. Detect all faces via VNDetectFaceRectanglesRequest with orientation: .up.
     If zero faces → no subject mode (skip to step 6).

  2. For each detected face:
       a. Crop the face region to a 160x160 chip (MobileFaceNet input size).
       b. Run MobileFaceNet → 128-d L2-normalized embedding.
       c. Compute cosine similarity vs subjectEmbedding.

  3. Find the face with max similarity. If max >= subjectThreshold:
       → subject identified mode. The face with max similarity is the subject face.
     Else:
       → no subject mode.

  4. Run VNGeneratePersonSegmentationRequest with qualityLevel = .accurate.
     Returns a Planar8 mask, upright, same dimensions as the source buffer.

  5. Subject identified mode:
       a. Compute connected components of the binary mask (threshold at 128).
       b. The component containing the subject face centre = subject silhouette.
       c. Build keepSourceMask:
            - Subject silhouette pixels: 255 (keep sharp).
            - All other mask-positive pixels (other silhouettes, faced or un-faced): 0 (blur).
            - Background (mask < 128): 255 (keep sharp).
       d. For each non-subject face: paint 0s into keepSourceMask at the
          face's head-expanded bbox (defensive — covers the case where the
          silhouette undershoots near the head).
       e. Skip to step 7.

  6. No subject mode (also reached by step 1's zero-faces fallback):
       a. Initialize keepSourceMask = all 255 (keep everything sharp).
       b. For each detected face (zero or more): paint 0s into keepSourceMask
          at the face's head-expanded bbox.
       c. Note: silhouettes are not blurred in this mode; the practitioner's
          own body (assumed to be in frame as the un-faced subject) stays sharp.

  7. Composite via CIBlendWithMask:
       output = source where keepSourceMask is 255,
                blurred where keepSourceMask is 0.
     Blur = CIGaussianBlur(source, radius=kGaussianBlurRadius), cropped to source extent.

  8. Encode the output buffer to JPG at destPath.

  9. Stamp exercises.safe_mode_algorithm_version = 2 on the captured row.

failure modes:
  - MobileFaceNet model fails to load → return failure. UI shows hard error.
  - Vision face detection throws → no subject mode (step 6 path).
  - PersonSegmentation throws → fall back to step 6 path (no silhouette work).
  - subjectEmbedding is nil → block capture until embedding is generated.
```

## Schema additions

Three migrations land together as a single timestamped file:

```sql
-- supabase/migrations/20260523HHMMSS_safe_mode_v2.sql

-- 1. Persistent face embedding per client
ALTER TABLE clients
  ADD COLUMN face_embedding bytea,                           -- 512-byte vector (128 FP32)
  ADD COLUMN face_embedding_model_version smallint;          -- 1 = MobileFaceNet v1

-- 2. Algorithm version stamp on every captured exercise
ALTER TABLE exercises
  ADD COLUMN safe_mode_algorithm_version smallint;
COMMENT ON COLUMN exercises.safe_mode_algorithm_version IS
  '1 = anchor-box (broken; never shipped to prod). 2 = face-rec MobileFaceNet (Safe Mode v2, 2026-05-23). Nullable for non-Safe-Mode captures.';

-- 3. Consent extension: jsonb update default for new clients
-- Existing clients' video_consent jsonb gets the new key on next consent update
-- via the upsert pattern; no batch migration needed.
```

SQLite mirror (`app/lib/services/local_db.dart`): bump `_dbVersion` to capture the new columns on `cached_clients` (`face_embedding BLOB`, `face_embedding_model_version INTEGER`) and `exercises` (`safe_mode_algorithm_version INTEGER`).

## New RPCs

Two new SECURITY DEFINER functions, owned by `postgres`, with practice-membership checks:

```sql
-- Set the face embedding for a client. Called by the mobile app after
-- on-device MobileFaceNet inference. Caller passes the raw 512-byte
-- vector + the model version that produced it. Practice-scoped.
CREATE OR REPLACE FUNCTION set_client_face_embedding(
  p_client_id uuid,
  p_embedding bytea,
  p_model_version smallint
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$ ... $$;

-- Set the explicit safe_mode_face_recognition consent toggle on a
-- client. Updates clients.video_consent jsonb and emits an audit
-- event with {from, to} diff. Practice-scoped.
CREATE OR REPLACE FUNCTION set_client_safe_mode_consent(
  p_client_id uuid,
  p_consent boolean
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$ ... $$;
```

Existing `set_client_video_consent` is NOT modified — it continues to handle the original avatar / line_drawing / grayscale / original consent keys. The new `safe_mode_face_recognition` key is managed by its own RPC so the audit trail is clean and the privacy review is auditable in isolation.

## Native iOS surface

The platform channel gains two methods + one bundled asset:

```swift
// MobileFaceNet model file, MIT-licensed weights converted to .mlmodel.
// Bundled in the Xcode project as a resource. Compiled to .mlmodelc at
// build time. Loaded lazily on first use via MLModel(contentsOf:).
// Hard-failing if the file is missing or corrupt — per feedback_no_silent_fallbacks.
app/ios/Runner/MobileFaceNet.mlmodel

// Generate the embedding for the supplied JPG (avatar / reference selfie).
// Returns a 512-byte Data blob (128 FP32 little-endian floats).
// Throws FlutterError if the JPG has zero faces, multiple ambiguous faces,
// or if MobileFaceNet fails to load.
generateFaceEmbeddingFromJpg(srcPath: String) -> Data

// Apply Safe Mode v2 to a single captured JPG. Caller supplies the
// pre-computed subject embedding from the SQLite row. Returns success
// metrics; output JPG is written to destPath.
applySafeModeV2ToPhoto(
    srcPath: String,
    destPath: String,
    subjectEmbedding: Data,           // required; pre-blocked by Dart if not yet generated
    threshold: Double                  // 0.6 default
) -> SafeModePhotoOutcome
```

The existing `applySafeModeToPhoto` (Safe Mode v1) is **removed in this wave** — superseded entirely. Algorithm version 1 captures continue to display their existing safe-variant JPG (per `feedback_no_original_display_safe_mode`); the v1 algorithm code is no longer reachable from any callsite.

PersonSegmenter is reused as-is; the segmentation mask is consumed by the new pipeline.

MobileFaceNet sourcing: starting candidate is the `nfacer/mobilefacenet-coreml` GitHub repo or a fresh PyTorch → ONNX → CoreML conversion of the canonical MobileFaceNet weights. Implementation agent validates the model produces sensible embeddings on a known-good face pair before bundling.

## Dart surface

New service: `app/lib/services/face_embedding_service.dart`. Wraps the native channel; owns the "is this client's embedding ready" state; provides the inline-capture-flow primitive.

Modifications:
- `client_edit_screen.dart`: new consent row "Face recognition for Safe Mode" with descriptive subtext. Toggling on triggers embedding generation (if not present) or no-op (if present). Toggling off zeros the embedding column.
- `capture_mode_screen.dart`: pre-capture gate when Safe Mode polygon engaged. If subject embedding missing for the active client → inline capture flow (Q9). If embedding is generating → block with spinner (Q16).
- `safe_mode_service.dart`: new `subjectEmbedding` ValueListenable exposing the current session's subject embedding state (null / loading / ready / error).
- `exercise_card.dart`: long-press → "Re-process Safe Mode" menu item (Q12). Greyed if raw original past 90-day retention.
- Algorithm version awareness: `kSafeModeAlgorithmVersion = 2` constant in `safe_mode_service.dart`. The re-process button enables iff the stored capture version is lower than this constant.

`sync_service.dart` extends `_pullClients` to also pull `face_embedding` + `face_embedding_model_version`. New `_pullX` branch per `feedback_offline_first_pull_branches`.

## UI changes

- **Client consent accordion (client edit screen):** new row "Face recognition for Safe Mode." Subtext: "Stores a biometric fingerprint derived from this client's avatar so we can recognise them in Safe Mode captures. Required to use Safe Mode with this client." Default off; toggling on triggers embedding gen (~30ms).
- **Capture mode banner (inside Safe Mode polygon, missing embedding):** "Preparing Safe Mode…" with a spinner, or "Set face for Safe Mode" inline-capture CTA.
- **Capture mode hard-failure banner (model load error):** "Safe Mode unavailable — please reinstall the app or contact support." Capture buttons disabled.
- **Exercise card long-press menu (algorithm version older than runtime):** "Re-process Safe Mode" item. Tappable; triggers a one-shot re-run against the raw archive.
- **Privacy policy (manage.homefit.studio/privacy):** new section "Biometric data" with the face-rec narrative. Owned by Carl + lawyer red-pen, can be a follow-up PR.

## Privacy posture

- Face embeddings are derived from already-consented avatar JPGs.
- Storage is per-client, mirrored in cloud (Supabase `clients.face_embedding`) and offline-first (SQLite cache).
- Per-client opt-out: toggling `safe_mode_face_recognition` off zeros the embedding column on next sync. Safe Mode then refuses to operate for that client (UI shows the hard-failure banner with a "re-enable consent" CTA).
- Embeddings are not exported, not used for analytics, not shared cross-practice. RLS scope is `user_practice_ids()` — same as the rest of the client data.
- Embedding format (128 FP32 vector) is not reversible to a face image (the inverse problem is computationally hard). This is a defensible privacy claim in the policy text.

## Out of scope for v2

- **Video Safe Mode.** Suppressed inside Safe Mode polygons in v2. Long-press-to-record gesture disabled; banner: "Safe Mode: video coming soon." Tracked for v3.
- **Multi-subject capture.** Not a real product use case (per [project_classes_means_recorded_courses](../../memory/project_classes_means_recorded_courses.md)).
- **Re-process button for video.** Only photos in v2.
- **Server-side embedding generation.** All embedding work happens on-device.
- **Cross-practice face matching.** Each practice's clients have their own embedding space.

## Implementation order

The wave is best parallelised into independent agents with a single integration step:

1. **Schema + RPCs** (one agent): write the timestamped migration, add the two new RPCs, generate fresh TypeScript types for the portal, SQLite mirror migration in `local_db.dart` (bump `_dbVersion`).
2. **Native iOS** (one agent): source / convert MobileFaceNet to `.mlmodel`, bundle in Xcode project, write the new `generateFaceEmbeddingFromJpg` + `applySafeModeV2ToPhoto` methods, remove Safe Mode v1 code paths. Run `flutter build ios --debug --simulator` + simulator smoke test.
3. **Dart wiring** (one agent): consent toggle UI, inline capture flow, re-process button, sync_service extension, algorithm version constant, capture-mode gate. Runs in parallel with (2) — the platform-channel method names are agreed up front; the Dart side scaffolds against the contract.
4. **Integration + device QA** (main agent): merge, install, run the test wave Carl walks.

Each agent commits to its own `feat/safe-mode-v2-*` branch targeting `staging`. The three branches merge in order (schema → native → Dart) so the Dart branch can build against the native + RPC contracts.

## Open risks

- **MobileFaceNet model sourcing.** No Apple-blessed face-rec model exists. We're relying on an external MIT-licensed conversion. Risk: weights produce poor accuracy in practice (e.g. trained on a non-diverse dataset). Mitigation: validate on a small known-good face-pair test before bundling; if accuracy is poor, consider ArcFace conversion (larger model, better accuracy).
- **POPIA edge case: client cannot or will not provide an avatar.** No avatar = no Safe Mode for that client. Acceptable for v2 — practitioner is told upfront, in the inline-capture-flow prompt.
- **Twins / very similar faces.** MobileFaceNet at threshold 0.6 will likely confuse identical twins. Mitigation: lowConfidence flag (the two top matches are within 0.05 of each other) surfaces a post-capture warning; practitioner can manually re-process or recapture. Not a v2 ship-blocker.
- **Lighting drift between avatar and capture.** Avatar taken at session-setup time, capture taken hours/days later under different lighting. MobileFaceNet is reasonably robust but not perfect. Mitigation: practitioner can replace the avatar at any time → embedding regenerates.
- **Model file corruption in the wild.** Bundled in the app binary so this should be impossible. If it happens (filesystem rot on a specific iPhone), the hard-failure banner per Q16 surfaces the issue to the user.
- **Cosine threshold 0.6 may need tuning.** Ship with the default and a dev-mode tuner; revisit after Carl has real device captures.
