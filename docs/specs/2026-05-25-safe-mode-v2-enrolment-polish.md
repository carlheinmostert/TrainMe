# Safe Mode v2 — Multi-Reference Enrolment Polish

A polish wave on the multi-reference face enrolment editor that landed in Wave-D (PR #479) earlier today. Bundles five concerns that all share the enrolment screen, all surfaced during device QA with Carl:

1. **Camera selection** — today the screen assumes selfie. Real-world use is the practitioner enrolling a client across a desk; rear camera is the correct default.
2. **Real-time pose-gated capture** — today the sweep timer-snaps N frames regardless of whether the head is actually moving. Should behave like Face ID: only accept frames at meaningfully different poses, prompt the user toward missing pose buckets.
3. **Per-embedding quality scoring** — today every frame the timer fires gets accepted as a slot. Should compute a composite quality score (face confidence, sharpness, lighting, pose uniqueness, embedding norm) and reject anything below threshold.
4. **Manual avatar selection** — today the most-frontal slot is silently promoted to the avatar JPG. Practitioner should be able to manually pick which captured frame becomes the avatar from a post-sweep grid.
5. **Consent-aware UI behaviour** — today the editor implicitly assumes both face-rec AND avatar consent are on. The two consents are independent (see the Consent matrix section); the editor should adapt to whichever combination the client granted.

Branch this implements against: `feat/safe-mode-v2-enrolment-polish`
Target: `staging` (per the staging-promotion rule).

## Table of Contents

1. [Summary](#1-summary)
2. [Current behaviour](#2-current-behaviour)
3. [Consent matrix](#3-consent-matrix)
4. [The five polish concerns](#4-the-five-polish-concerns)
5. [Acceptance criteria](#5-acceptance-criteria)
6. [Implementation guidance](#6-implementation-guidance)
7. [Edge cases](#7-edge-cases)
8. [Testing](#8-testing)
9. [Out of scope](#9-out-of-scope)
10. [Open questions](#10-open-questions)
11. [Appendix A — Agent brief](#11-appendix-a--agent-brief)

## 1. Summary

The Wave-D editor works but feels overwhelming and imprecise. It snaps a lot of photos regardless of whether the head moves, can't be steered (no rear-camera option, no quality gating), and silently picks the avatar without the practitioner getting a say. This wave converts the editor from "passive snapshotter" to "actively guided capture with quality feedback + practitioner control."

It also closes a real consent gap: today the editor assumes both face-rec consent AND avatar consent are on. The two consents are genuinely independent (see section 3); the editor should adapt to whichever combination the client granted, NOT force-couple them.

## 2. Current behaviour

When the practitioner taps the avatar circle on the client detail screen (or the "Set face" CTA in the capture banner), today's flow:

1. **Camera mounts in selfie mode.** No toggle available.
2. **Practitioner taps "Start."** A 10–15 second sweep begins.
3. **Native `generateFaceEmbeddingsFromFrames`** runs frame extraction on a timer + greedy farthest-point pose pick post-hoc. Output: 3–8 embeddings, each tagged with yaw/pitch.
4. **Frontal pick is silently promoted** to the avatar JPG. Saved to the raw-archive bucket.
5. **Slots persist to the cloud** `client_face_embeddings` table via `set_client_face_embeddings`.
6. **Screen pops.** Practitioner returns to client detail with the new avatar shown.

There's NO real-time feedback during the sweep — no indication of which poses have been captured, no quality scoring, no way to retry a bad sweep. The user gets one outcome and the editor's confidence in it is opaque.

## 3. Consent matrix

The client's `video_consent` jsonb carries two relevant flags:

- **`safe_mode_face_recognition`** — permission to compute and store a 2048-byte biometric face embedding and use it at capture time to discriminate client from bystanders. Gates the EMBEDDINGS.
- **`avatar`** — permission to persistently store a small face photo and display it in practitioner-facing surfaces (Studio cards, client list, peek, web portal). Gates the AVATAR JPG.

These are independent in principle and should be independent in practice. The enrolment editor must adapt:

| face-rec consent | avatar consent | Editor behaviour |
|---|---|---|
| ON | ON | Full multi-ref sweep. Post-sweep grid for manual avatar selection. Both artifacts persist. |
| ON | OFF | Multi-ref sweep runs. No avatar selection grid shown. Embeddings persist; no avatar JPG written to the raw-archive bucket. |
| OFF | ON | Simple-mode single capture. No sweep, no embedding generation. Single tap shutter → frame saved as avatar JPG. Acts as the legacy avatar-capture flow. |
| OFF | OFF | Editor doesn't open at all. The avatar-tap intercept (or "Set face" CTA) shows a SnackBar: "Toggle face recognition OR avatar consent first." Tap navigates to the consent sheet. |

This matrix lives in code as a `_EnrolmentMode` enum derived once at screen mount from the current cached-client snapshot. The UI conditionally renders subcomponents based on the mode.

Consent withdrawal AFTER enrolment is independent for each artifact:

- Avatar consent withdrawn → server zeros the avatar_path column AND deletes the avatar JPG from the raw-archive bucket. Embeddings stay.
- Face-rec consent withdrawn → server zeros the face_embedding column AND empties the client_face_embeddings slots. Avatar JPG stays.

Existing RPCs (`set_client_video_consent`) handle the zeroing; verify both paths still work correctly with the per-artifact cleanup. No new RPC needed for withdrawal — just confirm the existing flow.

## 4. The five polish concerns

### 4a. Camera selection

Add a flip toggle to the enrolment screen, positioned in the top-right corner of the viewfinder (small icon button, white-on-dark). Tapping flips between front (selfie) and rear cameras.

Default camera based on use case:
- Practitioner enrolling themselves → selfie. Detectable by checking whether the active practice membership's user.id matches the client.id-via-user-link (rare; only the Carl-sentinel-claim case).
- Practitioner enrolling a client → rear. Default in 99% of real-world use.

Heuristic: default to rear UNLESS the cached client row is the practitioner themselves. Persist last-used-camera per-device in SharedPreferences so the toggle is sticky across sessions.

### 4b. Real-time pose-gated capture

Replace the timer-driven sweep with a real-time pose validation loop. Each Vision detection cycle:

1. Compute current face pose (yaw, pitch) via `VNFaceLandmarksRequest`.
2. Compare against the set of already-captured slot poses. If the new pose is "meaningfully different" (yaw or pitch differs by ≥ N degrees from every existing slot's pose), it becomes a candidate.
3. If the candidate ALSO passes the quality score gate (section 4c), accept it as a new slot. Otherwise, hold pending until the user moves AND the lighting/sharpness improve.

UI:
- Guidance ring (Face-ID-style circle) surrounding the viewfinder. Divided into N segments mapped to pose buckets (e.g. 8 segments: front, front-left, left, back-left, etc.). Captured-pose segments light up coral; missing segments stay dim.
- Real-time hint text below the ring: "Turn slightly to your left" — derived from which missing segment is closest to the current pose.
- Live slot counter: "3 of 6 captured."
- Sweep ends when every pose bucket has at least one slot, OR when N seconds elapse with no further progress (timeout), OR when the practitioner taps "Done."

The greedy farthest-point post-hoc pick from the Wave-D implementation can be removed — pose diversity is now enforced at acceptance time.

### 4c. Per-embedding quality scoring

Compute a composite 0–100 quality score for each candidate frame BEFORE accepting it as a slot. Components:

| Metric | Source | Weight |
|---|---|---|
| Face detection confidence | `VNFaceObservation.confidence` (Vision returns this for free) | 30 |
| Sharpness | Laplacian variance of the face crop, normalised to a 0–1 baseline | 25 |
| Lighting quality | Contrast + dynamic range in the face region | 20 |
| Pose uniqueness | Cosine distance in pose-space (yaw, pitch) vs already-captured slots | 15 |
| Embedding norm | L2 norm of the generated embedding — should be exactly 1.0 if properly normalised; deviations indicate degenerate output | 10 |

Composite = weighted sum, clamped to 0..100. Threshold: 60. Anything below is rejected.

UI:
- Show the score live during the sweep next to the slot counter ("Slot 3: 87").
- Show a brief quality histogram at the end (small bar chart of all accepted slots' scores) so the practitioner can see the spread.
- If the average accepted score is < 70, show a "retake" suggestion: "Quality is low — try better lighting or get closer."

### 4d. Manual avatar selection

After the sweep completes (and ONLY when avatar consent is ON — see section 3 matrix), show a confirmation screen:

- Grid of all N captured face crops (3–8 cells).
- Each cell shows the face crop + its quality score + a pose-label badge (e.g. "front-left, 0° pitch").
- The frontal-pick is highlighted as the default choice.
- Tap a cell to select it as the avatar.
- "Confirm" button at the bottom — persists the chosen frame as the avatar JPG, persists all embeddings as slots, pops the screen.
- "Retake" button — discards everything, restarts the sweep.

If avatar consent is OFF, this screen is skipped — embeddings persist immediately, no avatar JPG written, screen pops on sweep completion.

### 4e. Consent-aware UI behaviour

Per the section 3 matrix. Implementation lives in the enrolment screen's `initState`:

```dart
final cached = SyncService.instance.storage.getCachedClientById(clientId);
final mode = _resolveMode(cached);
// mode is one of:
//   _EnrolmentMode.full       (both consents on)
//   _EnrolmentMode.embeddingOnly (face-rec on, avatar off)
//   _EnrolmentMode.avatarOnly    (avatar on, face-rec off — simple-mode capture)
//   _EnrolmentMode.disabled      (both off — show SnackBar, pop immediately)
```

Each mode renders a different subset of the UI:
- `full` — full sweep + quality scoring + grid + avatar persist.
- `embeddingOnly` — full sweep + quality scoring, no grid, no avatar persist.
- `avatarOnly` — single-tap shutter, no sweep, no embedding generation, only the avatar JPG persists. Quality scoring optional (sharpness + lighting still useful as a "good photo" gate).
- `disabled` — screen doesn't open; SnackBar from the entry-point widget directs to the consent sheet.

The avatar-tap intercept on client detail AND the "Set face" CTA on the capture banner both consult the mode and route accordingly.

## 5. Acceptance criteria

1. **Camera flip toggle present and functional.** Top-right of viewfinder. Defaults to rear when enrolling a client, selfie when enrolling the practitioner themselves. Last-used selection persists across sessions.

2. **Real-time pose gating works.** Sweep doesn't accept a frame unless its pose differs from every existing slot by ≥ N degrees AND its quality score ≥ 60. Guidance ring lights up captured segments; hint text directs the user toward missing segments.

3. **Quality score visible during sweep.** Per-slot score shown live ("Slot 3: 87"). Slots below 60 are visibly rejected (a brief X flash, no slot counter increment).

4. **Manual avatar selection grid shown post-sweep** when avatar consent is ON. Practitioner can tap any captured frame to override the default frontal pick. "Confirm" persists; "Retake" restarts the sweep.

5. **Consent matrix respected.** All four combinations behave per section 3 table. Verified by toggling consents and re-opening the editor.

6. **Avatar consent OFF → no avatar JPG persisted.** The chosen frame data is discarded after the embedding is generated. The raw-archive bucket does NOT receive a new file.

7. **Face-rec consent OFF + avatar consent ON → simple single-shot capture.** No sweep, no embedding generation, just one tap → frame saved as avatar JPG.

8. **Both consents OFF → editor doesn't open.** Avatar-tap intercept / "Set face" CTA shows the SnackBar with consent-toggle navigation.

9. **Consent withdrawal cleanup independent.** Withdrawing avatar consent zeros the avatar_path AND deletes the JPG from raw-archive — but leaves the embeddings intact. Withdrawing face-rec consent zeros embeddings — but leaves the avatar JPG. Verified by manual QA against the existing `set_client_video_consent` RPC.

10. **No native iOS code changes.** All five concerns live in Dart + Flutter UI. The native `generateFaceEmbeddingsFromFrames` and `generateFaceEmbedding` channel methods are reused as-is. Pose-gating happens in Dart by polling the camera's preview frames through Vision via the existing channel.

## 6. Implementation guidance

### Files likely to change

- `app/lib/screens/face_enrolment_screen.dart` — major rework: add camera toggle, replace timer sweep with pose-gated loop, add quality scoring, add manual avatar selection grid, add consent-mode branching.
- `app/lib/services/face_enrolment_service.dart` — refactor the sweep state machine to support pose-gated accept + quality scoring. Add a `mode` parameter that selects between `full` / `embeddingOnly` / `avatarOnly`.
- `app/lib/screens/client_sessions_screen.dart` (or wherever the client detail screen lives) — update the avatar-tap intercept to consult the mode and either open the editor or show the SnackBar.
- `app/lib/screens/capture_mode_screen.dart` — update the Safe Mode banner's "Set face" CTA similarly.
- `app/lib/services/api_client.dart` — verify `set_client_video_consent` triggers per-artifact cleanup correctly. May need a small migration on the existing RPC if it doesn't already handle both cleanup paths (see open question 3).
- New test file `app/test/services/face_enrolment_service_test.dart` — unit tests for pose gating + quality scoring + mode resolution.
- New test wave file `docs/test-scripts/YYYY-MM-DD-safe-mode-v2-enrolment-polish.md`.
- New mockup file `docs/design/mockups/safe-mode-v2-enrolment-polish.html` — wireframe of the new sweep UI with guidance ring + quality score + post-sweep grid. (Author this BEFORE implementation per the mockup-first convention; Carl signs off on the visual before any code is written.)

### Sequencing (recommended)

This wave is big enough that splitting into two PRs makes sense:

**Phase 1 (small, fast — 1 day):**
- Camera flip toggle (4a)
- Consent-aware mode resolution (4e) — the mode enum + the four UI branches as scaffolding
- Avatar-tap intercept consent gating + SnackBar path

**Phase 2 (substantive — 3-5 days):**
- Real-time pose gating (4b) — replaces the sweep loop
- Quality scoring (4c) — integrates with the pose-gated accept
- Manual avatar selection grid (4d) — replaces the silent frontal-pick
- Mockup signoff before any code lands

Phase 1 ships first; phase 2 builds on the consent-aware scaffolding.

### Pose gating math

Vision provides `yaw`, `pitch`, `roll` per face observation. Use yaw + pitch only (roll varies with how the user holds the device and isn't useful for enrolment diversity). Pose-distance metric:

```dart
double poseDistance(({double yaw, double pitch}) a, ({double yaw, double pitch}) b) {
  // Manhattan distance in degrees.
  return (a.yaw - b.yaw).abs() + (a.pitch - b.pitch).abs();
}
```

Accept threshold: 25 degrees (sum). Recommend tuning during phase 2 implementation against real device captures.

### Quality scoring math

```dart
double scoreCandidate({
  required double visionConfidence,    // 0..1 from VNFaceObservation
  required double sharpness,           // Laplacian variance, normalised
  required double lighting,            // contrast + dynamic range
  required double poseUniqueness,      // 0..1 cosine distance vs existing
  required double embeddingNorm,       // closeness to 1.0
}) {
  final score = 30 * visionConfidence
              + 25 * sharpness
              + 20 * lighting
              + 15 * poseUniqueness
              + 10 * (1 - (embeddingNorm - 1.0).abs());
  return score.clamp(0, 100);
}
```

All component values normalised to 0..1 before weighting. Implement in `face_enrolment_service.dart` as a static `_QualityScorer`.

## 7. Edge cases

- **Practitioner is the client.** Self-enrolment (Carl-sentinel-claim case). Selfie camera default. Works through the same editor; mode is `full` (both consents implicitly granted for self-enrolment).
- **Existing single-slot legacy client.** Already has an avatar + a legacy face_embedding from the pre-Wave-D path. Tapping the avatar opens the editor in `full` mode (assuming both consents on); the existing slots get REPLACED by the new sweep. Document this clearly in the editor's pre-sweep screen: "This will replace the existing face fingerprint."
- **Sweep timeout with insufficient slots.** If the user fails to cover enough pose buckets in N seconds AND has captured < 3 slots, the sweep is abandoned (no partial save). UI: "Not enough variety captured — try again with better lighting / more head movement." If they have ≥ 3 slots, the sweep can complete with what's captured (down from the target 6–8).
- **Camera permission denied.** Existing camera-permission UX applies; editor surfaces the standard "Camera access needed" sheet and pops.
- **Network down during persistence.** Phase-2 PR should verify the existing offline-first queue handles the multi-ref slot save correctly via `pending_ops`. Carl asked about this during Wave-D QA; verify the same queue used for `upsert_client` covers the new slot save RPC.

## 8. Testing

### Manual test wave on iPhone (per `homefit-ship-to-phone`)

New test script under `docs/test-scripts/YYYY-MM-DD-safe-mode-v2-enrolment-polish.md`. Numbered checkboxes covering:

**Phase 1 items (consent matrix + camera):**
1. Both consents ON → tap avatar → editor opens in full mode, defaults to rear camera. Toggle camera; flip persists across editor re-opens.
2. Face-rec ON, avatar OFF → editor opens, sweep runs, post-sweep grid is HIDDEN, no avatar JPG visible in client list afterward.
3. Avatar ON, face-rec OFF → editor opens in simple-mode (single shutter button, no sweep), single tap saves avatar.
4. Both OFF → tap avatar → SnackBar appears with "Toggle consent first" — tap navigates to consent sheet.
5. Selfie default for self-enrolment (Carl-sentinel-claim client) → camera mounts in selfie.

**Phase 2 items (pose gating + quality + grid):**
6. Sweep with stationary head → no slots captured (pose gating rejects everything).
7. Sweep with active head rotation → slots accepted as pose changes; guidance ring lights up segments; hint text directs toward missing buckets.
8. Sweep in low light → quality score visibly low; some frames rejected with X flash; final retake-suggestion shown if average < 70.
9. Sweep in good light + good rotation → 6 slots captured with scores ≥ 80; post-sweep grid shows them.
10. In grid, tap a non-frontal slot → that becomes the avatar; confirm; client list shows the chosen frame.
11. Retake from grid → all slots discarded; sweep restarts.
12. Sweep timeout with 2 slots captured → "not enough variety" message; no partial save.

### Unit tests

In `app/test/services/face_enrolment_service_test.dart`:
- Mode resolution (4 combinations of consent → correct enum value).
- Pose-distance math (known input pairs → expected degree values).
- Quality scoring (known component values → expected composite).
- Pose-gating accept/reject (mock current pose + existing slot poses → accept/reject decision).

## 9. Out of scope

- Native iOS code changes — pose-gating happens in Dart via the existing Vision channel; quality scoring is pure Dart.
- Reworking the `client_face_embeddings` schema or the `set_client_face_embeddings` RPC.
- Changing the embedding model (still MobileFaceNet, still 2048 bytes per slot).
- Changing the consent sheet UI itself (the toggle locations + labels are fine as-is).
- Pre-sweep tutorial / first-run video — out of scope; the editor's UI guidance handles discoverability.
- Multi-face-in-frame detection during sweep (e.g. rejecting frames where TWO faces are visible). Punt to a future PR; today the editor just picks the largest bbox if multiple faces appear.

## 10. Open questions

1. **Pose-bucket count.** 8 segments around the guidance ring? 6? More? Recommend 6 (front, front-left, front-right, left, right, slight-up) — covers the meaningful angles without over-constraining. Carl picks during mockup signoff.
2. **Quality threshold value.** Recommend 60 (out of 100). Could be tuned higher (80) for stricter enrolment quality at the cost of sweep length. Empirically tune during phase-2 device QA.
3. **Consent withdrawal cleanup verification.** Verify the existing `set_client_video_consent` RPC handles per-artifact cleanup correctly. If it doesn't (e.g. it zeros both columns regardless of which consent was withdrawn), a small migration is needed to split the cleanup paths. Implementing agent confirms with a SQL inspection of the RPC body before writing any migration.
4. **Pose-distance threshold.** 25 degrees Manhattan sum recommended. Tune in phase-2.
5. **Manual avatar selection — preserve in offline mode?** If the practitioner is offline during the sweep, the slots queue via `pending_ops`. The chosen avatar JPG also needs to queue. Verify this works through the existing queue mechanism in phase-2 implementation.

## 11. Appendix A — Agent brief

Use the following as the agent brief when implementing PHASE 1 (the small, fast wave). Phase 2 gets its own brief once mockups are signed off.

```markdown
# Task: Safe Mode v2 enrolment polish — Phase 1 (camera + consent-aware UI)

## Context

The multi-reference face enrolment editor that landed in Wave-D (PR #479) earlier today has rough edges. This is Phase 1 of a two-phase polish wave:
- Camera flip toggle (rear vs selfie, sensible default per use case)
- Consent-aware UI scaffolding (the four-mode matrix from section 3 of the spec)
- Avatar-tap intercept SnackBar path for the "both consents off" case

Phase 2 (real-time pose gating + quality scoring + manual avatar selection) is a separate PR that depends on this scaffolding.

The full spec lives at `docs/specs/2026-05-25-safe-mode-v2-enrolment-polish.md` on main. READ THAT FIRST. Phase 1 covers sections 4a + 4e of the spec. Phase 2 sections 4b/4c/4d are explicitly OUT OF SCOPE for this PR.

## Constraints (HARD RULES)

- REPO-RELATIVE paths only in tool calls.
- No emojis anywhere — code, comments, commits, PR body.
- Branch: `feat/safe-mode-v2-enrolment-polish-phase1` off `staging`.
- PR target: `staging` (NOT `main`). Draft, prefixed `[QA-blocked]`.
- After any `.dart` edit, run `dart_analyze` via the dart MCP.
- NO PHONE INSTALL. The `feedback_ask_before_mobile_deployment` rule is binding.
- No native iOS code changes.
- No schema migrations.

## Acceptance criteria

Phase-1 subset of section 5 of the spec: items 1, 5, 6, 7, 8, 10. (Items 2, 3, 4 — pose gating / quality / manual grid — are Phase 2.)

## Files likely to change

- `app/lib/screens/face_enrolment_screen.dart` (camera toggle + mode branching scaffolding)
- `app/lib/services/face_enrolment_service.dart` (mode parameter)
- `app/lib/screens/client_sessions_screen.dart` (avatar-tap intercept consent gating)
- `app/lib/screens/capture_mode_screen.dart` ("Set face" CTA consent gating)
- `app/test/services/face_enrolment_service_test.dart` (new — mode resolution tests only; pose/quality tests are Phase 2)
- `docs/test-scripts/YYYY-MM-DD-safe-mode-v2-enrolment-polish-phase1.md` (new — items 1-5 of section 8 of the spec)
- `docs/test-scripts/index.md` (entry at top of Active wave)

## Deliverable

- PR title: `feat(safe-mode-v2): enrolment polish phase 1 — camera toggle + consent-aware mode scaffolding`
- PR body references this spec.
- Conventional Commits.
- Draft, prefixed `[QA-blocked]`.

## Out of scope (Phase 2)

Real-time pose gating, quality scoring, manual avatar selection grid, mockup file authoring. Those land in a follow-up PR after Carl signs off on the Phase-2 mockups.
```
