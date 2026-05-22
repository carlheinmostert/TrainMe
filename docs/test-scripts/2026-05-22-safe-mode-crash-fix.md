# 2026-05-22 — Safe Mode crash fix · build 75afb33 (PR #427)

Test script for [PR #427 — `fix(safe-mode): un-crash the processor + harden against memory cliff and boot-loop`](https://github.com/carlheinmostert/TrainMe/pull/427). Installed on iPhone CHM from staging tip `75afb33` (which contains the squash-merge commit `4c0be37`).

The PR landed seven changes:

1. Core Image filter name fix (`CIBlendWithMaskFilter` → `CIBlendWithMask`) + force-unwrap hardened to `guard let / fatalError`.
2. Photo working-resolution clamp to 1920px max-dim before SafeModeProcessor allocates buffers.
3. Video frame-budget documentation + extension point (latent — pipeline currently encodes ≤1080p; no active scaling).
4. `restoreQueue()` demotes any `converting` SQLite rows to `failed` on app launch so a native crash can't brick relaunch. Recovery line appended to `{Documents}/conversion_error.log`.
5. Orientation hint added to `VNDetectFaceRectanglesRequest` for both photo (`UIImage.imageOrientation`) and video (`AVAssetTrack.preferredTransform`) paths.
6. `Data(bytesNoCopy:, deallocator: .none)` replaced with `Data(bytes:count:)` copy throughout the CoreImage glue.
7. Diagnosis doc on main (`docs/diagnoses/2026-05-22-safe-mode-photo-crash.md`) corrected with the real root cause (was H4 / memory exhaustion — actually was the filter-name typo).

Open in CC Desktop preview pane (Cmd+Shift+V). Strike items as they pass (`- [x] ~~text~~`); flip to `- [ ] FAIL — note` for failures.

## Table of Contents

- [Pre-flight](#pre-flight) — items 1-2
- [Boot-loop recovery](#boot-loop-recovery) — items 3-4
- [Photo Safe Mode capture](#photo-safe-mode-capture) — items 5-7
- [Video Safe Mode capture](#video-safe-mode-capture) — items 8-9
- [Subject vs bystander discriminator](#subject-vs-bystander-discriminator) — item 10
- [Memory headroom](#memory-headroom) — item 11

## Pre-flight

- [ ] **1.** Launch the app. Confirm the home-footer build SHA reads `75afb33 · staging` (or whatever short SHA `git rev-parse --short HEAD` returns for the staging tip you installed).
- [ ] **2.** Sign-in state preserved from the previous build (no Sign-In screen). The keep-auth install path is in effect.

## Boot-loop recovery

The point of item #4 is that the prior poisoned `converting` row from yesterday's `bbce3e8` crash should now be demoted on launch and the app must NOT die before showing UI.

- [ ] **3.** App opens to the Clients screen normally (no crash, no boot-loop). This is the single most important item in this wave — without this one passing, nothing else matters.
- [ ] **4.** Open the session that had the failed Safe Mode photo capture from yesterday. Long-press the "N failed" pill on its card. The bottom sheet shows a `Aborted by prior crash on init` line for the previously-poisoned row. Confirms the recovery path wrote to `conversion_error.log` per PR #213's reader.

## Photo Safe Mode capture

Items 5-7 verify that the ORIGINAL crash is gone AND that the Gaussian-blur treatment from the reverted PR #423 now actually works.

- [ ] **5.** Inside your home polygon (Safe Mode auto-engaged, or manually toggled on). Open Camera mode and take a selfie with a bystander in the frame. No crash. Capture completes. Conversion runs and finishes (the spinner clears, the card moves out of converting state).
- [ ] **6.** The resulting safe variant for that photo shows the BYSTANDER as a Gaussian blur (soft-edged, not pixelated, not a coral silhouette). You — the subject — render normally.
- [ ] **7.** Open the photo in the editor sheet. Tap through preview. The displayed image is the safe variant (per yesterday's `feedback_no_original_display_safe_mode`); no "view original" affordance exists.

## Video Safe Mode capture

- [ ] **8.** Same polygon, Safe Mode on, record a 5-second video with a bystander in frame (you do an exercise; bystander walks past or stands in the background). No crash. Conversion completes.
- [ ] **9.** The resulting safe.mp4 shows the bystander Gaussian-blurred frame-by-frame. Tracking is reasonable (the blur follows the bystander as they move; you stay sharp).

## Subject vs bystander discriminator

Item #10 is the wrong-person bug from S-13 — bystander straight-on and centered, you off-axis holding the phone — face discriminator should still pick the right person.

- [ ] **10.** Position a bystander centered and head-on to the camera, then hold the phone yourself at an angle (off-centre, partial face). Capture a photo. The BYSTANDER is blurred (not you). This combines the face-based discriminator (re-applied from #423) with the orientation hint (item 5 in the PR) — without the orientation fix, Vision sometimes reported no faces and the algorithm would mis-pick.

## Memory headroom

- [ ] **11.** Optional / nice-to-have: with Xcode attached and the memory gauge visible, capture a full-resolution photo and a 30-second video. Peak working set should stay well under 250MB. (If you don't have time to plug into Xcode, skip — the synthetic crash from yesterday is the real signal.)
