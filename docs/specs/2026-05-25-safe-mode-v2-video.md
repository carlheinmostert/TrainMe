# 2026-05-25 — Safe Mode v2: video (face-recognition subject discriminator)

**Status:** draft, awaiting Carl signoff. Extends Safe Mode v2 (face-recognition discriminator) from photos to videos.
**Builds on:** `docs/specs/2026-05-23-safe-mode-face-rec.md` (algorithm + threshold), `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md` (per-client embedding rows), `docs/specs/2026-05-25-safe-mode-accept-zero-detection.md` (fail-closed rule + telemetry).
**Algorithm version stamp:** `safe_mode_algorithm_version = 2` (no bump — same algorithm, new media type).

## Table of Contents

1. [Summary](#1-summary)
2. [Current behaviour](#2-current-behaviour)
3. [Problem](#3-problem)
4. [Performance constraint](#4-performance-constraint)
5. [Architecture options](#5-architecture-options)
6. [Other architectural decisions](#6-other-architectural-decisions)
7. [Acceptance criteria](#7-acceptance-criteria)
8. [Implementation guidance](#8-implementation-guidance)
9. [Edge cases preserved](#9-edge-cases-preserved)
10. [Testing](#10-testing)
11. [Out of scope](#11-out-of-scope)
12. [Open questions](#12-open-questions)
13. [Appendix A — Agent brief](#13-appendix-a--agent-brief)

## 1. Summary

Safe Mode v2 photo capture uses MobileFaceNet to embed every detected face in the frame, compares each embedding against the bound client's multi-reference embedding slots, and treats the highest cosine similarity as the subject. Everyone else is painted coral (in the per-frame composite, or blurred per the active visual policy in `applySafeModeV2ToPhoto`).

The video Safe Mode path still runs Safe Mode v1 — the older "largest detected human bbox = client" anchor-box heuristic. This is the original known-broken-but-shipping algorithm. When a bystander walks closer to the camera than the subject, v1 mis-identifies them as the subject, leaves their face sharp, and paints the actual subject coral. This is a privacy regression compared to v2 photos and a UX failure (the practitioner sees themselves obscured).

This spec extends the v2 face-recognition discriminator to videos. The dominant constraint is performance: a naive per-frame face-rec implementation would push a 30-second clip to 90+ seconds of pure inference time, breaking the practitioner's near-real-time conversion expectation. The spec recommends a **hybrid architecture** — first-frame identify, Vision single-object tracker between samples, sparse re-confirm via face-rec every N seconds plus on tracker-confidence drop — that holds the worst case under 2x real-time while preserving v2's accuracy guarantees in the cases that matter.

The native pipeline gains one new entry point (`applySafeModeV2ToVideo`) and one helper class (`SafeModeV2VideoProcessor`); the existing v1 `SafeModeProcessor` is removed in the same wave. The Dart surface routes video conversions through the new method when Safe Mode is active and the bound client has at least one embedding slot populated. The fail-closed semantics from the just-merged zero-detection spec carry forward unchanged: 100% miss is accepted as no-PII, 5%–100% miss is rejected.

## 2. Current behaviour

When a Safe Mode video is captured inside an enforcing premises polygon today:

1. Capture stamps the exercise row with `safe_mode_active = true` and `captured_in_premises_id`.
2. Native conversion runs the v1 `SafeModeProcessor` over every decoded frame.
3. Per frame: Vision detects all human bounding boxes; the largest bbox is assumed to be the subject; every pixel covered by a non-largest bbox is painted coral; the result is written to the safe variant `{exerciseId}_safe.mp4`.
4. The mask-miss-rate counter ticks each frame where Vision detected zero humans. The native channel surfaces this as `safeFramesMissedRate`.
5. `app/lib/services/conversion_service.dart` evaluates the result against the unified rule (per the zero-detection spec, just-merged): accept if miss rate is 0%–5% or 100%, reject if 5%–100%.
6. On acceptance, the safe variant uploads to `raw-archive/{practice_id}/{plan_id}/{exercise_id}.mp4` in place of the original via `_uploadRawArchives` swap logic.

What works today:

- Frame-by-frame composite via `CIBlendWithMask` is mature, fast (~5–10 ms per frame), and visually stable.
- The colorspace setup (NSNull workingColorSpace, DeviceRGB output) is known-stable after multiple regressions on the photo path.
- The fail-closed miss-rate check catches catastrophic detection failures.
- The audit-stamp + upload-swap paths are agnostic to the algorithm under the hood.

What doesn't work today (the gap this spec closes):

- Subject identification is purely spatial. Any time a bystander occupies more pixels than the subject (passes closer to the camera, sits in foreground, leans into frame), v1 swaps them. The actual subject's face stays unobscured in the safe variant only if they happen to be the bbox-largest human in every frame they appear in — which is the practitioner-self-recording case the product is built for, but breaks the moment a real bystander enters.
- There is no per-frame continuity check. v1 can flip the "who is the subject" assignment frame-to-frame as bystanders move past, producing visible jitter (subject sharp at t=0.5s, blurred at t=0.7s when a passer-by gets closer, sharp again at t=0.9s).

## 3. Problem

Concrete failure scenarios on v1 video today:

- **Gym aisle.** Practitioner self-records on a mat. A second member walks down the aisle behind them, closer to the camera. v1: bystander becomes the bbox-largest for the seconds they're in frame, gets the sharp treatment, the actual practitioner gets painted coral for those seconds.
- **Group class background.** Practitioner demos a movement; a class is finishing on the next mat over. v1: whichever member of the next-mat group happens to be in the largest bbox per frame gets selected as the subject; assignment flips between several bystanders across the video; the actual practitioner is intermittently obscured.
- **Camera close to floor, subject in background.** Practitioner sets the phone on a bench to film a standing exercise. A passing client crouches near the camera to tie a shoelace. v1: the close-up shoelace-tier is bbox-largest; the standing practitioner is painted coral.
- **Practitioner kneels.** Practitioner kneels for a floor demo while a bystander walks past upright. v1: standing bystander momentarily has the larger bbox; subject swap.

v2 face-rec resolves all four because each face is independently matched against the client's enrolled embedding slots and a bystander cannot beat the subject regardless of pixel area. The constraint is doing this on every video frame inside the conversion budget.

## 4. Performance constraint

Per-frame inference cost on iPhone 13 / iPhone 15 class hardware (rough measurements, Vision + CoreML):

| Stage | Cost per frame | Notes |
|---|---|---|
| `VNDetectFaceRectanglesRequest` | 30–50 ms | Once per frame regardless of face count |
| MobileFaceNet (per detected face) | ~50 ms | 160x160 input, on Neural Engine |
| `VNGeneratePersonSegmentationRequest` (`.accurate`) | 50–100 ms | Already in v1 path |
| `CIBlendWithMask` composite | 5–10 ms | Existing v1 cost |

A 30-second 30fps clip = 900 frames. Naive per-frame face-rec with one face in frame: 900 × (40 + 50 + 75 + 8) = ~155 seconds — about 5x real-time. Two faces in frame would push past 200 seconds. The conversion service today processes a 30-second v1 video in roughly real-time; a 5x regression would break Carl's "publish in seconds" UX promise.

**Target wall-clock budget for a 30-second 1080p video on iPhone 13 or newer: ≤ 60 seconds (2x real-time).** This is the hard ceiling; the recommended architecture should hit closer to 1.2x–1.5x real-time on a typical solo-subject capture.

The architecture must therefore amortise face-rec inference across many frames. The candidates below all share the same end-state pipeline (subject mask → composite → safe variant) and differ only in how the per-frame "which silhouette is the subject" decision is made.

## 5. Architecture options

### Option A — First-frame identify + Vision single-object tracker

**Mechanism.** Run face detection + MobileFaceNet on the first N frames (say N=3) to lock subject identity. Convert the matched face bbox into the seed for a `VNTrackObjectRequest`. From frame N+1 onward, hand the tracker the previous frame's output and the current frame; the tracker returns the updated bbox + a confidence score. As long as confidence stays above a threshold (say 0.5), trust the tracker — the silhouette containing the tracked bbox's centre is the subject. If confidence drops or the tracker loses the object, fall back to fresh face-rec on the current frame.

**Inference cost on a 30s/900-frame clip, solo subject, no tracker loss.** Face-rec on 3 seed frames: 3 × (40 + 50) = ~270 ms. Tracker per frame: ~5–10 ms × 897 = ~5–9 seconds. Segmentation + composite still ~75 + 8 per frame = ~75 seconds. **Total ~80–85 seconds, around 2.7x real-time.** Segmentation dominates the budget.

**Pros.**
- Apple-blessed primitive. `VNTrackObjectRequest` is purpose-built for this exact problem (single-object tracking through a video), well-documented, low-failure-mode in the Apple ecosystem.
- Strong continuity: the tracker's bbox moves smoothly between frames, no jitter from re-identification flickering.
- Predictable inference cost — tracker latency is bounded and known.
- Tracker confidence is a useful signal in its own right (drop = subject occluded, turned away, or left frame).

**Cons.**
- Tracker drift on long clips. If the subject moves rapidly, occludes briefly, or the camera shakes, the tracker can drift onto a similar-coloured background region. Confidence-threshold fallback mitigates this but only catches gross failures, not slow drift.
- If the first 3 frames don't contain the subject's face (subject's back is to camera at t=0), the tracker never seeds. Requires a tail-end re-confirm strategy.
- VNTrackObjectRequest is bbox-only — it doesn't give us the silhouette, just where the subject's face is. We still need segmentation per frame to determine which silhouette to keep sharp.

### Option B — Sparse face-rec sampling + spatial continuity

**Mechanism.** Run face detection + MobileFaceNet every Nth frame (say N=10, 3 Hz at 30fps). On the sampled frames, identify the subject the v2 way (max cosSim against the client's slots). Between sampled frames, use spatial continuity: the silhouette closest to the most-recently-identified subject bbox is the subject for this frame. Compute "closest" as Euclidean distance between silhouette centroids and the last-known subject centroid.

**Inference cost on a 30s/900-frame clip, solo subject.** Face-rec on 90 sampled frames: 90 × (40 + 50) = ~8.1 seconds. Centroid-distance check on 810 non-sampled frames: ~1 ms × 810 = ~0.8 seconds. Segmentation + composite ~75 + 8 = ~75 seconds. **Total ~85 seconds, around 2.8x real-time.** Similar bottom line to Option A because segmentation dominates.

**Pros.**
- Simpler than tracker integration; doesn't depend on Vision's tracker behaviour.
- Self-correcting: every Nth frame re-identifies from scratch, so a misassignment at frame 47 self-heals at frame 50.
- Handles tracker-loss cases trivially — there's no tracker to lose.

**Cons.**
- Spatial continuity is fragile when multiple silhouettes overlap or pass through each other. If the subject and a bystander cross paths, the centroid-closest rule can flip assignment.
- The 10-frame gap between re-identifications means a single misassigned identification frame propagates for up to 9 frames before the next sample corrects it. That's 300 ms of wrong-subject blur on a 30 fps clip — visible.
- Centroid distance ignores depth and silhouette area; a bystander walking right behind the subject can have a closer centroid than the subject's own moved-since-last-frame centroid.

### Option C — Hybrid: first-frame identify + tracker + sparse re-confirm (RECOMMENDED)

**Mechanism.** Combine the strengths of A and B and the fail-closed sanity of frequent re-confirmation.

1. First N frames (N=3): full face-rec on every face. Pick the subject the v2 way (max cosSim ≥ threshold).
2. If a subject was identified, seed a `VNTrackObjectRequest` from that face's bbox. From frame N+1 onward, drive the tracker. The silhouette containing the tracker's bbox centre is the subject.
3. Every M seconds (M = 2, i.e. every 60 frames at 30 fps), re-run face-rec on the current frame's detected faces. If the highest-cosSim face is within R pixels of the tracker's current bbox centre (R ~= 0.2 × frame height), confirm and continue. If it's elsewhere, re-seed the tracker on the re-identified face — the subject moved out of the tracker's lock or the tracker drifted.
4. If tracker confidence drops below 0.5 OR the tracker reports "lost", run fresh face-rec on the current frame immediately. If a subject is re-identified, re-seed and continue. If not (subject not in frame), enter no-subject mode for this frame and the next M seconds, then re-attempt face-rec.
5. If the first 3 frames yield no subject identification (subject's back to camera, occluded), enter no-subject mode and re-attempt face-rec every M seconds until a subject is identified or the video ends.

**Inference cost on a 30s/900-frame clip, solo subject, no tracker loss.** Face-rec on 3 seed + ~15 re-confirm frames = 18 × (40 + 50) = ~1.6 seconds. Tracker on ~882 frames = ~7 seconds. Segmentation + composite = ~75 seconds. **Total ~83–85 seconds, around 2.8x real-time on iPhone 13 — close to the 2x ceiling on iPhone 15.** Segmentation remains dominant; the inference savings vs naive are ~70 seconds.

**Pros.**
- Strongest accuracy on the hardest cases (subject-bystander crossover, lighting drift, brief occlusion) because periodic re-confirmation catches tracker drift before it propagates.
- Graceful failure shape: tracker loss → immediate face-rec retry rather than silent misassignment.
- First-frame-fail case has a recovery path (re-attempt face-rec every M seconds) rather than committing to v1 fallback for the whole video.
- Re-confirm cadence (2 seconds) gives a measurable upper bound on wrong-subject duration: at most 2 seconds of misassignment before the next sample either confirms or re-seeds.

**Cons.**
- More moving parts → harder to reason about. Explicit state machine: `seeding`, `tracking`, `re-confirming`, `lost`, `no-subject`.
- Re-confirmation cadence is a tunable that affects both accuracy and inference cost — Carl will want to tune it after device QA.
- Slight risk that re-confirmation finds a bystander whose face moved closer to the tracker centre during a brief subject occlusion. Mitigated by requiring the re-confirmed face to clear the cosSim threshold against the client's slots, not just the spatial proximity check.

### Recommendation: Option C (Hybrid)

The first-frame-identify + Vision tracker spine is the right primitive for video subject continuity; sparse re-confirmation is the cheap insurance against tracker drift; the immediate-fallback-on-tracker-loss path covers the cases where the tracker just gives up. Option A alone is fragile on long or busy clips; Option B alone has unbounded misassignment windows. The hybrid combines both with one explicit state machine, keeps the inference budget close to the 2x-real-time ceiling, and matches the v2 photo accuracy guarantee in the steady state.

Segmentation dominates the budget in all three options. The implementing agent should profile whether running segmentation at a lower cadence (every other frame, interpolating the mask between) would push the budget below 2x. That's a tunable for the post-merge optimisation pass, not a v2.0 ship blocker.

## 6. Other architectural decisions

### 6a. Mask continuity across frames

Per-frame mask painting in v1 today has visible jitter — the coral region edges shift slightly between frames because Vision's segmentation output is naturally noisy at sub-pixel scale. With the hybrid architecture, the **subject silhouette assignment** is now continuous (the tracker provides spatial continuity between samples), so the worst jitter source — flipping which silhouette is "subject" between frames — disappears. What remains is the per-frame segmentation boundary noise.

**Recommendation: punt mask-edge smoothing to a follow-up.** Document the open question. The two candidate strategies:

- **Temporal mask averaging.** Average the binary mask over a sliding 3-frame window before binarising at 128. Removes high-frequency boundary noise. Cost: trivial (1 ms per frame). Risk: 1-frame latency in mask transitions when the subject moves rapidly (acceptable for typical exercise capture).
- **Motion-compensated keyframe interpolation.** Compute optical flow between consecutive masks, warp the previous mask forward, blend with the new. Cost: ~10 ms per frame for optical flow. Risk: more complex; gains over simple averaging may not justify the cost.

Track as `safe_mode_v2_video_mask_smoothing` in the BACKLOG for a follow-up wave once Carl has eyeballed actual v2-video output on device and decided whether the jitter is bothersome.

### 6b. Fail-closed semantics for video (carrying forward the zero-detection rule)

The just-merged zero-detection spec (`docs/specs/2026-05-25-safe-mode-accept-zero-detection.md`) defines the unified accept/reject rule:

| Miss rate | Outcome |
|---|---|
| 0% ≤ miss ≤ 5% | Accept with safe variant |
| 5% < miss < 100% | Reject (Vision is struggling — partial detection failure) |
| 100% (exactly) | Accept as no-PII (no humans in any frame) |

This rule transfers to v2 video verbatim. The definition of "miss" requires translation:

- v1 video defined a "miss frame" as one where **Vision face/person detection returned zero detections**. The accept/reject decision was downstream of detection alone.
- v2 video adds the face-recognition step on top. A frame can have a successful Vision face detection but NO face matching the subject (because every detected face is a bystander, OR because the practitioner is back-to-camera and Vision detected only a back-of-head silhouette with no face).

**Decision: "miss" stays defined as "Vision detected zero humans in the frame".** Frames where Vision found humans but no face matched the subject are NOT misses — they correctly produce no-subject-mode output (all detected non-matching faces blurred, scenery sharp, per the v2 photo rule on no-subject frames). This matches the v2 photo definition and preserves the existing fail-closed semantics: the rule catches catastrophic detection failures, not subject-absence cases.

A 30-second video of an empty room (or a video where the practitioner is permanently back-to-camera) hits 100% miss and is accepted as no-PII. A 30-second video where Vision intermittently loses the subject (heavy backlighting, occlusion) hits the middle band and is rejected with the same "couldn't track everyone — try a different angle" copy from the zero-detection spec.

### 6c. First-frame identification fail

The bound client has at least one embedding slot populated (capture is blocked otherwise — same gate as v2 photo via `SafeModeService` subject-embedding ValueListenable). But the subject's face may not be detectable in the first 3 frames: they're back-to-camera setting up the shot, looking at the floor for the rep count, hooded against bright light, etc.

**Decision: enter no-subject mode after the seeding window expires, keep periodic re-attempts running.**

Specifically:
- First 3 frames: attempt face-rec on every detected face. If no face clears the cosSim threshold against any client slot, the seed window expires without a tracker lock.
- Frames 4 through end-of-video: process each frame in no-subject mode (no-subject mode = blur every detected face's bbox; silhouettes stay sharp — matches the v2 photo no-subject branch from the 2026-05-23 spec).
- Every M seconds (M = 2), re-run face-rec on the current frame in case the subject turned around or moved into better light. If a subject is identified, seed the tracker and switch to subject-identified mode for the remainder (or until the next tracker loss).

This preserves the "solo back-view self-recording" use case the v2 photo spec carved out and naturally degrades to v2 photo's no-subject behaviour for sections of the video where the subject isn't face-visible.

**Decision NOT TO fall back to v1 anchor-box.** v1 is removed in this wave; falling back would require keeping v1 code paths alive and creates an "is my safe variant v1 or v2" ambiguity even within a single video. The no-subject mode is a clean degradation; v1 fallback is not.

### 6d. Tracker loss mid-video

Tracker confidence drops below 0.5 OR `VNTrackObjectRequest` reports the observation as lost (no observations returned, or the observation has zero confidence).

**Decision: immediate fresh face-rec on the current frame. Three outcomes:**

1. **A face matches the subject AND it's near the tracker's last-known bbox centre.** Tracker drifted onto something else but the subject is still in frame and close to where we last saw them. Re-seed the tracker on the re-identified face. Resume tracking.
2. **A face matches the subject but it's elsewhere in the frame.** Subject moved out of the tracker's lock area while the tracker was confused. Re-seed at the new location.
3. **No face matches.** Subject is occluded, turned away, or left frame. Enter no-subject mode for this frame and the next M seconds; re-attempt face-rec at the next M-cadence boundary or on any subsequent tracker confidence event.

**No "skip the rest of the video" or "stitch through last-known position" path.** Stitching forward from a stale position would risk painting a bystander who walked through that region with the sharp treatment. The no-subject fallback is safer.

### 6e. Multi-face frames mid-video

A new face enters the frame at t=15s (passing bystander, second client walks past). Vision now detects 2 faces where there was 1.

**Decision: trust the tracker on the existing subject; treat any new face as bystander automatically.**

Specifically:
- The tracker continues following the existing subject through frame 15s and beyond. No interruption.
- The new face is rendered through the v2 photo no-subject-mode policy for THAT face: blur its bbox region in the composite. (Treat it the same way v2 photo treats any non-subject face in subject-identified mode.)
- At the next M-cadence re-confirmation, face-rec re-runs across all detected faces in frame. If the cosSim ranking still says the existing tracked face is the subject (highest match against any client slot), continue. If somehow the new face scores higher (which would only happen if the tracker has drifted onto a non-subject face during the 2-second window), re-seed on the new winner — but this should be vanishingly rare for two reasons: (a) the tracker is on the original face's bbox, which means the face under the bbox is still the subject's; (b) MobileFaceNet's embedding for a bystander, even one who happens to look similar, should not beat the subject's own multiple enrolled slots.

**No special "recognise this new face as a known bystander" feature.** v2 video has one job: identify the subject and obscure everyone else. Bystander faces are blurred without regard to whether we've seen them before. This matches v2 photo.

### 6f. Performance budget

**Target: 30-second 1080p video processes in ≤ 60 seconds wall-clock on iPhone 13 or newer (2x real-time ceiling).**

Typical solo-subject capture should hit closer to 1.2x–1.5x real-time on iPhone 15 class hardware. The 2x ceiling is for worst-case (multi-face frames throughout, frequent tracker loss requiring re-seeding).

**Progress UX during conversion.** Today's v1 video conversion shows an indeterminate spinner on the exercise card. With the 2x ceiling and a 30-second cap on capture, the worst-case wait is 60 seconds — long enough to need progress indication.

**Decision: surface a determinate progress bar on the exercise card while v2 video conversion is running.** The native `applySafeModeV2ToVideo` already needs to report progress for AVAssetWriter framing; expose this as a `Stream<double>` via a new "in-flight" event in `ConversionService`. The card's existing "converting…" pill becomes a thin coral progress bar. Implementation detail, but flag it here so the implementing agent doesn't get surprised.

**Decision: no in-app cancellation.** A user-cancelled video is half-converted and the safe variant doesn't exist. The publish path would fall back to the raw original — exactly the privacy leak Safe Mode prevents. Capture-to-conversion is atomic from the practitioner's perspective.

## 7. Acceptance criteria

1. **v2 video produces safe variant correctly for a solo subject.** Practitioner self-records inside an enforcing polygon, no bystanders. Result: subject stays sharp throughout, no coral painting, mp4 plays cleanly.
2. **v2 video correctly obscures a bystander that's bbox-larger than the subject.** Practitioner kneels for a floor demo while a standing bystander walks past at the same depth. Result: practitioner stays sharp (face-rec wins over largest-bbox), bystander painted coral.
3. **v2 video correctly obscures a bystander that walks closer to the camera.** Practitioner records on a mat; passing client walks within 1m of the camera lens for a few seconds. Result: practitioner stays sharp, bystander painted coral for the duration of their pass.
4. **v2 video handles subject crossing paths with a bystander.** Practitioner walks across frame; a bystander walks the opposite direction across frame; their silhouettes overlap briefly. Result: practitioner stays sharp throughout, bystander painted coral throughout, no assignment flicker at the crossover frame.
5. **No-subject mode kicks in for back-to-camera sections.** Practitioner records front-then-turns-around-then-front-again. Result: front sections produce subject-identified output (practitioner sharp); back-turned section produces no-subject output (no faces blurred because no faces detected; silhouettes stay sharp); face-rec re-attempts every 2 seconds correctly re-identify the subject when they turn back around.
6. **First-frame fail recovers within 2 seconds.** Subject is back-to-camera at t=0, turns around at t=4. Result: first 4 seconds run in no-subject mode; tracker seeds at the M-cadence re-attempt after subject turns around; remainder of video runs in subject-identified mode.
7. **Tracker loss recovers immediately.** Subject is briefly fully-occluded mid-video (walks behind a piece of equipment for ~1 second). Result: tracker confidence drops, no-subject mode for the occluded frames, subject re-identified the moment they reappear.
8. **Fail-closed rule preserved.** Heavily backlit video where Vision can't detect faces in 30% of frames → rejected with the same "couldn't track everyone — try a different angle" toast as v1 today. Empty-room video (100% miss) → accepted as no-PII, no safe variant produced, audit event written.
9. **Performance budget honoured.** 30-second 1080p capture on iPhone 13 or newer converts in ≤ 60 seconds wall-clock. Measured by the conversion service's existing timing instrumentation.
10. **Algorithm version stamped.** Every video exercise captured under v2 has `safe_mode_algorithm_version = 2` written to the cloud `exercises` row. v1 video captures retain their existing `safe_mode_algorithm_version = 1` (or NULL for pre-v2 rows).
11. **v1 video code paths removed.** No callsite in the codebase invokes the v1 video pipeline. The `SafeModeProcessor` class is deleted along with `applySafeModeToVideo` / `processSafeModeVideo` channel methods. Compile-time enforcement that v1 video is gone.
12. **Existing v1 video safe variants continue to display.** Captures stamped `safe_mode_algorithm_version = 1` still render their stored safe variant on every surface (per `feedback_no_original_display_safe_mode`). The "Re-process Safe Mode" long-press affordance (from the v2 photo spec) extends to videos — tapping it on a v1 video capture re-runs v2 against the raw archive (if still within 90-day retention).
13. **Progress UX visible during conversion.** The exercise card shows a determinate progress bar while v2 video conversion is in flight. No more indeterminate spinner for v2 video.

## 8. Implementation guidance

### Files likely to change

- `app/ios/Runner/VideoConverterChannel.swift` — new `SafeModeV2VideoProcessor` class, new `applySafeModeV2ToVideo` platform-channel method, remove `SafeModeProcessor` (v1) class and `applySafeModeToVideo` / `processSafeModeVideo` channel method, route the v1 dead-code removal through a single cleanup commit so the diff is easy to review.
- `app/lib/services/conversion_service.dart` — switch the video Safe Mode invocation from the old method to `applySafeModeV2ToVideo`. The fail-closed evaluation block (already updated by the zero-detection spec) needs no changes — it operates on `safeMissRate` which keeps the same semantics. Add the progress-stream wiring for the card UI.
- `app/lib/services/safe_mode_service.dart` — subject-embedding ValueListenable already gates capture for v2 photo; verify it also gates video capture (it should — the capture flow doesn't differentiate by media type at this gate). No code change expected, just confirm.
- `app/lib/screens/capture_mode_screen.dart` — the existing v2-photo banner ("Set face for Safe Mode" / "Preparing Safe Mode…") gates both photo AND video capture today. Verify; no code change expected.
- `app/lib/screens/studio_mode_screen.dart` (or the exercise-card widget — file location may differ) — surface the new progress stream as a determinate coral progress bar on the card during conversion.
- `app/lib/services/api_client.dart` — no new RPC. Existing `replace_plan_exercises` already accepts `safe_mode_algorithm_version` per the v2 photo spec.
- Migration: none. v2 video reuses the v2 photo schema (`client_face_embeddings`, `exercises.safe_mode_algorithm_version`). No new columns, no new RPCs.
- `docs/test-scripts/2026-MM-DD-safe-mode-v2-video.md` — new manual test wave (see section 10).
- `docs/test-scripts/index.md` — add the new wave at the top of "Active wave".

### Native channel signature

```swift
// New method on the platform channel.
// Caller blocks the Dart-side capture flow until embeddings are loaded
// (same gate as v2 photo).
applySafeModeV2ToVideo(
    srcPath: String,                  // raw captured mp4
    destPath: String,                 // safe variant output path
    subjectEmbeddingSlots: [Data],    // client's enrolled embedding rows (5–8 slots, 128 FP32 each)
    threshold: Double,                // cosine threshold, default 0.55–0.60 per the multi-ref spec
    onProgress: (Double) -> Void      // 0.0–1.0 progress callback for the card UI
) -> SafeModeVideoOutcome
```

`SafeModeVideoOutcome` mirrors the existing v1 outcome shape: `success: Bool, safeMissRate: Double, framesProcessed: Int, durationMs: Int`. No new fields needed — Dart's existing `_ConvertResult` consumption already handles these.

### State machine for the hybrid pipeline

```
enum State {
  case seeding       // first N frames, full face-rec on every face
  case tracking      // tracker driving subject bbox per frame
  case reConfirming  // periodic face-rec sample to verify tracker is still on subject
  case lost          // tracker confidence dropped, immediate face-rec retry
  case noSubject     // no subject in frame (seed-fail or post-loss); face-rec retries every M seconds
}

const seedingFramesN = 3
const reConfirmIntervalSec = 2.0
const trackerConfidenceFloor = 0.5
const reSeedProximityRadiusFrac = 0.2  // 20% of frame height
```

Per-frame loop (pseudocode):

```
state = .seeding
frameIdx = 0
lastReConfirmFrameIdx = 0
subjectBbox: CGRect? = nil
tracker: VNTrackObjectRequest? = nil

for frame in video.frames {
  let segmentationMask = segmenter.generateMask(for: frame.pixelBuffer)
  let detectedFaces = visionDetectFaces(in: frame)

  switch state {
    case .seeding:
      let match = pickSubjectViaFaceRec(detectedFaces, subjectEmbeddingSlots, threshold)
      if match != nil {
        subjectBbox = match.faceBbox
        tracker = seedTracker(at: match.faceBbox)
        state = .tracking
      } else if frameIdx >= seedingFramesN - 1 {
        state = .noSubject
      }

    case .tracking:
      let trackResult = tracker.track(in: frame)
      if trackResult.confidence < trackerConfidenceFloor || trackResult.lost {
        state = .lost
        subjectBbox = nil
      } else {
        subjectBbox = trackResult.bbox
        if frameIdx - lastReConfirmFrameIdx >= reConfirmIntervalSec * fps {
          state = .reConfirming
        }
      }

    case .reConfirming:
      let match = pickSubjectViaFaceRec(detectedFaces, subjectEmbeddingSlots, threshold)
      lastReConfirmFrameIdx = frameIdx
      if match != nil {
        if distanceBetween(match.faceBbox.center, subjectBbox.center) < reSeedProximityRadiusFrac * frame.height {
          // confirmed; keep tracking
        } else {
          // tracker drifted; re-seed
          tracker = seedTracker(at: match.faceBbox)
          subjectBbox = match.faceBbox
        }
        state = .tracking
      } else {
        state = .noSubject
        subjectBbox = nil
      }

    case .lost:
      let match = pickSubjectViaFaceRec(detectedFaces, subjectEmbeddingSlots, threshold)
      if match != nil {
        tracker = seedTracker(at: match.faceBbox)
        subjectBbox = match.faceBbox
        state = .tracking
      } else {
        state = .noSubject
      }
      lastReConfirmFrameIdx = frameIdx

    case .noSubject:
      if frameIdx - lastReConfirmFrameIdx >= reConfirmIntervalSec * fps {
        let match = pickSubjectViaFaceRec(detectedFaces, subjectEmbeddingSlots, threshold)
        lastReConfirmFrameIdx = frameIdx
        if match != nil {
          tracker = seedTracker(at: match.faceBbox)
          subjectBbox = match.faceBbox
          state = .tracking
        }
      }
  }

  // Build keepSourceMask using the v2 photo composite rule:
  //   - If subjectBbox != nil: subject silhouette sharp, every other silhouette blurred, non-subject faces blurred defensively.
  //   - If subjectBbox == nil: all silhouettes sharp, only detected non-subject face bboxes blurred (this matches the v2 photo no-subject branch).
  let keepSourceMask = buildKeepSourceMask(segmentationMask, subjectBbox, detectedFaces)
  composite(frame, mask: keepSourceMask, blurRadius: kGaussianBlurRadius, output: outputFrame)
  videoWriter.append(outputFrame)

  if detectedFaces.isEmpty {
    missFrameCount += 1
  }
  totalFrames += 1
  frameIdx += 1
  onProgress(Double(frameIdx) / Double(totalFrameCount))
}

let safeMissRate = Double(missFrameCount) / Double(totalFrames)
return SafeModeVideoOutcome(success: true, safeMissRate: safeMissRate, framesProcessed: totalFrames, durationMs: ...)
```

### Composite rule reuse

The per-frame composite (`buildKeepSourceMask` + `CIBlendWithMask`) reuses the v2 photo logic. Carl's load-bearing colorspace setup (NSNull workingColorSpace, DeviceRGB output) MUST be preserved per `feedback_no_silent_fallbacks` and the prior regressions on the photo path. Factor the composite into a private helper on `SafeModeV2VideoProcessor` that calls the same `CIBlendWithMask` configuration as the photo path.

### Pick-subject helper reuse

`pickSubjectViaFaceRec` is the exact same hybrid pick-highest rule from the v2 photo path: solo-floor for 1 face (single face must clear the cosSim threshold against any client slot), multi-relative for 2+ faces (highest cosSim wins iff it clears the threshold). Factor into a shared helper that both photo and video call into. If this lives on `MobileFaceNetEmbedder.shared` as a method `pickSubject(faces:slots:threshold:)`, both sites get the same behaviour.

### Removing v1 video paths

Single cleanup commit. Search for: `SafeModeProcessor`, `applySafeModeToVideo`, `processSafeModeVideo`, any v1-specific constants in `VideoConverterChannel.swift`. Delete the class definition, the platform-channel method registration, and the Dart-side `MethodChannel` invocation in `conversion_service.dart`. Confirm zero references remain via `git grep`.

Note: the v1 photo path (`applySafeModeToPhoto`) was already removed in the v2 photo wave per the 2026-05-23 spec. v1 video is the last remaining v1 surface; removing it closes Safe Mode v1 entirely from the codebase.

### Profiling instrumentation

Add `os_log` markers around each major stage of the per-frame loop:
- Face detection time per frame
- MobileFaceNet time per face crop
- Tracker time per frame
- Segmentation time per frame
- Composite time per frame
- Re-confirmation / re-seed events with timestamps

Visible in Console.app filtered by the `homefit-safe-mode-v2-video` subsystem. Used to validate the performance budget on real device captures.

## 9. Edge cases preserved

- **Subject's enrolled embeddings haven't been generated yet.** Capture is blocked by the same `SafeModeService.subjectEmbedding` ValueListenable gate as v2 photo. The capture screen surfaces "Preparing Safe Mode…" or "Set face for Safe Mode" — no behavioural difference for video.
- **Client has no embedding slots populated (no enrolment yet).** Same gate as above — the inline-capture-flow CTA fires on first Safe Mode engage regardless of media type.
- **Subject's face is enrolled but they're permanently back-to-camera throughout the video.** No-subject mode for the entire video. Result is the same as v2 photo in no-subject mode: silhouettes stay sharp, no faces to blur because no faces detected. Practitioner sees their own silhouette unobscured (correct — the privacy threat is faces, and the subject's face is not in frame to expose).
- **Subject's enrolled at threshold edge.** Slots stored, but every slot scores 0.40–0.55 cosSim against the subject's own face in this lighting. Multi-reference picking helps but at the edge, the subject could be misidentified as bystander. Mitigation: the enrolment screen's confirm step (per the multi-ref spec) lets the practitioner re-sweep if the bench doesn't look right. This is a v2 photo gap too, not a v2 video regression.
- **Identical twins or near-identical faces in frame.** v2 photo defers this to future work (see the 2026-05-23 spec's open risks); v2 video inherits the same risk. Mitigation: tracker continuity reduces the in-video impact — once the subject is locked, the tracker follows them; a similar-looking bystander appearing later doesn't re-seed unless the tracker is lost.
- **Heavily occluded subject (camera tilts, subject walks behind equipment).** Tracker loss → immediate face-rec retry on every subsequent frame until M-cadence expires → no-subject mode until re-identification. Worst case: a few frames of no-subject mode where the subject was actually still in frame but face-hidden. Acceptable.
- **Frame rate variation.** AVAssetReader emits frames at the source clip's rate. The state machine's "every M seconds" cadence is computed from `frameIdx / fps`, so it adapts. 60 fps slow-mo captures get sampled less frequently in absolute frame terms.
- **Audio passthrough.** AVAssetWriter audio track copy stays identical to v1. The visual pipeline change has no audio impact.
- **AVAssetWriter multi-track drain deadlock.** Known gotcha from the audio-on-Line treatment work (per the architecture notes). Use the same concurrent drain pattern via separate dispatch queues with `DispatchGroup` gating `finishWriting`. The implementing agent should literally copy the proven pattern, not redesign.

## 10. Testing

### Manual test wave on iPhone (per `homefit-ship-to-phone`)

New test script at `docs/test-scripts/YYYY-MM-DD-safe-mode-v2-video.md`. Numbered checkboxes:

1. **Solo subject video, no bystanders, inside enforcing polygon.** Capture a 15-second video of just the practitioner. Result: safe variant produced, practitioner sharp throughout, no coral, no rejection toast.
2. **Solo subject video with one bystander walking past.** Practitioner sits/kneels, bystander walks across frame. Result: practitioner sharp, bystander painted coral for their pass duration, no flicker at the moment the bystander enters/exits.
3. **Solo subject video with bystander closer to camera than subject.** Practitioner records from a fixed-distance mat; bystander walks within 1m of the camera. Result: practitioner stays sharp (face-rec beats v1's bbox-largest heuristic); bystander painted coral.
4. **Subject crosses paths with bystander.** Practitioner walks one direction, bystander walks the opposite; their silhouettes overlap briefly. Result: no assignment flicker at the crossover; practitioner stays sharp throughout.
5. **First-frame fail recovery.** Set up the shot with practitioner's back to camera; start recording; turn around after 4 seconds; record 10 more seconds. Result: first 4 seconds in no-subject mode (silhouettes sharp), then practitioner is identified within ~2 seconds of turning around, sharp for the rest.
6. **Mid-video occlusion.** Practitioner records, walks behind a piece of equipment for ~1 second, emerges and continues. Result: occluded frames in no-subject mode briefly, practitioner re-identified on emergence, no visible re-identification artifact.
7. **Empty room video inside enforcing polygon.** Record 10 seconds of an empty room. Result: 100% miss rate, accepted as no-PII per the zero-detection rule, no safe variant produced, audit event `safe_mode.accepted_empty` visible in portal feed.
8. **Heavily backlit video.** Record practitioner against a bright window; Vision will intermittently lose face detection. Result: middle-band miss rate, capture rejected with the "couldn't track everyone" toast, no orphan exercise card in Studio (orphan fix from the zero-detection spec must still hold for video).
9. **30-second video conversion time.** Capture a 30-second clip with one or two faces visible throughout. Measure wall-clock conversion time on Carl's iPhone (use the existing conversion-time instrumentation visible in Console.app). Assert ≤ 60 seconds.
10. **Progress bar visible during conversion.** While item 9 is converting, observe the exercise card. Assert a determinate coral progress bar advances smoothly (not jumpy, not stuck).
11. **Re-process Safe Mode on a v1 video.** Find an existing v1 video capture (or capture one on a previous build); long-press the exercise card; tap "Re-process Safe Mode." Result: v2 re-runs against the raw archive, replacing the v1 safe variant. Algorithm version stamp updates to 2 on next publish.
12. **v1 video safe variant still displays untouched.** Open a v1 video capture in Studio + workout preview without tapping re-process. Result: the existing v1 safe variant renders normally on every surface (Studio card, editor sheet, web player after publish).
13. **Algorithm version stamp.** After items 1–6 are captured and published, check the cloud `exercises` table for `safe_mode_algorithm_version = 2` on those rows. Items 7 (accepted empty) should also stamp 2 (the algorithm was v2; it just didn't produce a safe variant).

Add the test script entry at the top of `docs/test-scripts/index.md`'s "Active wave" list per `feedback_test_wave_discipline`.

### Bench tool extension

The Safe Mode bench (`/Users/chm/Desktop/Safe Mode Bench Report.html` per `feedback_safe_mode_bench_report`) currently shows photo originals + bench-produced safe variants side by side. Extend the bench to support videos:

- Input: 3–5 short clips (5–15 seconds each) covering the test scenarios above (solo, bystander pass, crossover, occlusion, first-frame fail).
- Output: for each input clip, render the safe variant and embed both originals + safe variants side by side as `<video>` elements in the HTML report, with stats (avg face count per frame, miss rate, conversion time).
- Stats inline below each video pair: subject identification rate (% of frames where a subject was locked), tracker-loss event count, re-seed event count, avg cosSim of identified subject.

This is the visual proof of correctness that the bench-only numbers can't provide (per the bench-report rule). The implementing agent extends the bench BEFORE running any device install — the bench is what makes the deployment approvable.

### Unit-level (in-PR, not optional)

`app/test/services/conversion_service_v2_video_test.dart`:

- Mock `_ConvertResult` with various `safeMissRate` values; assert the fail-closed rule still applies identically to v2 video.
- Mock the progress stream emission; assert Studio's card observer receives the values.

Native unit tests for the state machine logic are nice-to-have but not blocking — the state machine is small enough that the manual test wave covers the cases.

## 11. Out of scope

- Web player playback changes — videos play the safe variant from the `raw-archive` bucket exactly as v1 video does today. No new web player work.
- Photo path changes. v2 photo is already shipped and stable.
- Mask-edge temporal smoothing (sliding-window averaging, optical-flow interpolation) — see section 6a; punted to a follow-up after device QA reveals whether jitter is bothersome.
- Cancellable conversion — see section 6f; deliberately not added.
- Re-enrolment UX changes — handled by the multi-reference enrolment spec.
- Server-side processing — all v2 video work stays on-device, same as v2 photo.
- Multi-subject capture — not a real product use case per `project_classes_means_recorded_courses`.
- Recording in landscape mode — orthogonal feature, separately tracked.
- Lowering segmentation cadence (running every other frame, interpolating between) — flagged in section 5 recommendation as a post-merge optimisation, not v2.0 scope.

## 12. Open questions

1. **Re-confirmation cadence M.** Recommended 2 seconds. Faster (1 second) = better accuracy, more inference; slower (4 seconds) = cheaper, longer windows for misassignment. Carl to confirm or tune after device QA.
2. **Seeding window N frames.** Recommended 3 frames (100 ms at 30 fps). If face-rec on frames 0–2 all yield no match, enter no-subject mode. Could be tuned up to 5–10 frames if first-frame fail is common in practice.
3. **Tracker confidence floor.** Recommended 0.5. Apple's `VNTrackObjectRequest` confidence is loosely documented; the right floor needs device-bench tuning. Surface in the bench report.
4. **Cosine threshold.** Recommended 0.55–0.60 inherited from the multi-reference spec (which targets this range against the multi-slot setup). Same threshold for video; no v2-video-specific override.
5. **Progress UX styling.** Determinate coral progress bar on the exercise card during conversion — exact pixel design is a Carl call. Mockup not in scope for this spec; reasonable interpretation by the implementing agent unless Carl pre-specifies.
6. **Bench tool extension scope.** Whether the bench HTML report should include the full multi-clip side-by-side, or a single representative clip per scenario, is up to the implementing agent's judgment based on how long the report takes to render and view.

## 13. Appendix A — Agent brief

Use the following as the agent brief when implementation kicks off. Composed in the homefit-agent-brief style.

```markdown
# Task: Safe Mode v2 — extend face-rec discriminator from photos to videos

## Context

Safe Mode v2 (face-recognition discriminator) currently runs on photos only. Videos still use the v1 anchor-box heuristic ("largest bbox = client"), which mis-identifies bystanders as subject whenever they're bbox-larger than the actual client. This wave extends v2 to videos using a hybrid first-frame-identify + Vision-tracker + sparse-re-confirm architecture that holds the conversion budget under 2x real-time.

Read the full spec FIRST: `docs/specs/2026-05-25-safe-mode-v2-video.md`. Read it completely before touching any code.

Related specs (read for full context):
- `docs/specs/2026-05-23-safe-mode-face-rec.md` — v2 photo algorithm + threshold + composite rule
- `docs/specs/2026-05-24-safe-mode-v2-multi-reference-enrolment.md` — per-client embedding slots schema (reused by v2 video as-is)
- `docs/specs/2026-05-25-safe-mode-accept-zero-detection.md` — fail-closed unified rule (carry forward to video)

## Constraints (HARD RULES — read first)

- REPO-RELATIVE paths only in tool calls. Never absolute `/Users/chm/dev/TrainMe/...` paths.
- No emojis anywhere — code, comments, commit messages, PR body, file names.
- Branch: `feat/safe-mode-v2-video` off `staging`.
- PR target: `staging` (NOT `main`). Carl promotes staging to main explicitly.
- After any `.dart` edit, run `dart_analyze` (via the dart MCP) before reporting done.
- NO PHONE INSTALL. PR stays `[QA-blocked]` draft. The `feedback_ask_before_mobile_deployment` memory rule is binding. Carl explicitly asks before any device install.
- The Mac-side Safe Mode Bench Report MUST be regenerated and opened in Carl's browser before requesting any device QA (per `feedback_safe_mode_bench_report`). Bench numbers alone do NOT prove correctness — the visual is what makes the deployment approvable.
- No new Supabase migration needed. Schema is already in place from the v2 photo waves.
- No `CREATE OR REPLACE FUNCTION` on existing RPCs. If you find yourself needing to modify an existing RPC, stop and surface to Carl.
- Preserve Carl's load-bearing colorspace setup (NSNull workingColorSpace, DeviceRGB output) in the v2 video composite — same as v2 photo. Multiple prior regressions on this; do not innovate.

## Architecture decision (pre-locked)

Option C (Hybrid: first-frame identify + Vision tracker + sparse re-confirm) from section 5 of the spec. Do NOT implement Option A or B alone.

State machine: `seeding` → `tracking` → `reConfirming` → `lost` → `noSubject`. Cadences and thresholds in section 8 of the spec; treat the recommended values as starting points, tune post-bench.

## Implementation order

1. Native: factor `pickSubject(faces:slots:threshold:)` out of the v2 photo path into `MobileFaceNetEmbedder.shared` (shared with video).
2. Native: implement `SafeModeV2VideoProcessor` + `applySafeModeV2ToVideo` channel method. Reuse the v2 photo composite helper. Wire progress callback.
3. Native: remove v1 video paths (`SafeModeProcessor`, `applySafeModeToVideo`, `processSafeModeVideo`) in a single cleanup commit.
4. Dart: switch `conversion_service.dart` video-Safe-Mode invocation from v1 to v2. Wire the progress stream.
5. Dart: surface progress on the exercise card as a determinate coral progress bar.
6. Bench: extend the Mac-side bench tool to handle videos. Render the report. Open in Carl's browser.
7. Manual test wave file at `docs/test-scripts/YYYY-MM-DD-safe-mode-v2-video.md`.
8. Test-scripts index entry at top of Active wave.

## Acceptance criteria

Copy from section 7 of the spec.

## Files likely to change

- `app/ios/Runner/VideoConverterChannel.swift`
- `app/lib/services/conversion_service.dart`
- `app/lib/services/safe_mode_service.dart` (verify only — likely no change)
- `app/lib/screens/capture_mode_screen.dart` (verify only — likely no change)
- `app/lib/screens/studio_mode_screen.dart` or the exercise-card widget (progress bar)
- `app/test/services/conversion_service_v2_video_test.dart` (new)
- Mac-side bench tool (path: locate via existing `feedback_safe_mode_bench_report` references)
- `docs/test-scripts/YYYY-MM-DD-safe-mode-v2-video.md` (new)
- `docs/test-scripts/index.md`

## Deliverable

- PR title: `feat(safe-mode-v2): extend face-rec discriminator to videos`
- PR body: What changed, Why, Architecture (call out the hybrid choice), Performance bench numbers from your iPhone, Bench report screenshot/link, How to test, Risk, link to this spec.
- Conventional Commits. No emojis.
- Draft, prefixed `[QA-blocked]`.

## Out of scope

Per section 11 of the spec.
```
