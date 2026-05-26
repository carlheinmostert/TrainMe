# Checkpoint — 2026-05-26 (face enrolment ARKit pivot)

## Table of Contents

- [TL;DR](#tldr)
- [What landed (in order)](#what-landed-in-order)
- [Architecture as of this checkpoint](#architecture-as-of-this-checkpoint)
- [Verified on Carl's iPhone](#verified-on-carls-iphone)
- [Pending verification](#pending-verification)
- [Known follow-ups](#known-follow-ups)
- [Disk space + housekeeping](#disk-space--housekeeping)
- [Memory entries to add](#memory-entries-to-add)
- [Fresh-session quickstart](#fresh-session-quickstart)

## TL;DR

After a multi-hour debugging session, face enrolment now works end-to-end on
TrueDepth devices (iPhone X+). The path is:

```
ARFaceTrackingConfiguration.isSupported
   ├─ true  → FaceEnrolmentARKitChannel (continuous 6-DoF pose)
   └─ false → FaceEnrolmentCameraChannel (Vision/AVCaptureSession fallback)
                                          ← STILL HAS THE AVMETADATA CROP BUG
                                          ← non-TrueDepth users get garbage embeddings
```

Six PRs merged to `staging` between `b543130` and `c347041`. Carl ran the full
6-prompt sweep end-to-end on iPhone 17 Pro and confirmed it works.

Staging tip: **`c347041`** (fix(face-enrolment): flip ARKit yaw sign).
iPhone CHM is on this build.

## What landed (in order)

| PR | SHA | Title | What it did |
|---|---|---|---|
| [#534](https://github.com/carlheinmostert/TrainMe/pull/534) | `f69a6c3` | Vision streamed-yaw rebuild (Phase 2) | Phase 2 of the Vision-on-CMSampleBuffer attempt. Restored 6-prompt sequence with pitch. Later proved wrong path (Vision quantizes yaw to 45° on iOS 18+ and returns nil pitch). |
| [#538](https://github.com/carlheinmostert/TrainMe/pull/538) | `9815b70` | Safe Mode self-recognition diagnostic (Wave M41) | Added Diagnostics → "Test self-recognition" action + "Log Safe Mode match details" toggle. Diagnosed the AVMetadata-bounds crop bug as root cause of the cosSim ≈ 0.09 mismatch. |
| [#537](https://github.com/carlheinmostert/TrainMe/pull/537) | `8a4c735` | M40 ARKit primary with Vision fallback | New `FaceEnrolmentARKitChannel.swift` using ARFaceAnchor.transform. Routes via `ARFaceTrackingConfiguration.isSupported` at launch. |
| [#540](https://github.com/carlheinmostert/TrainMe/pull/540) | `888db7d` | Home screen cosmetic polish | My Workouts pill internal padding + top-bar action buttons vertically centered on the logo. |
| [#542](https://github.com/carlheinmostert/TrainMe/pull/542) | `db71270` | Restore pose debug HUD | Undid the ARKit agent's over-deletion. `_DebugPoseHud` widget + `FaceEnrolmentDebugHudPreference` toggle in Diagnostics, gated default-off. |
| [#543](https://github.com/carlheinmostert/TrainMe/pull/543) | `05bd52e` | Decouple yaw/pitch tolerance (M42) | Per-axis tolerance budgets instead of Manhattan sum. yaw=20°, pitch=30°. Fixes the "natural phone-holding posture eats the budget" issue. |
| [#545](https://github.com/carlheinmostert/TrainMe/pull/545) | `c347041` | Flip ARKit yaw sign (M42b) | Removed the double-negation on yaw. Empirically verified: left turn now produces negative yaw, right turn positive — matches kPromptSequence targets. |

## Architecture as of this checkpoint

### Face enrolment pose source — capability-gated split

`AppDelegate.swift` decides at launch which channel registers. Both expose the
identical Flutter surface:

- MethodChannel `homefit/face-enrolment-camera`
- EventChannel `homefit/face-enrolment-pose-stream`
- PlatformView view-type `homefit/face_enrolment_camera_preview`

**TrueDepth (iPhone X+):** `FaceEnrolmentARKitChannel.swift`. Uses
`ARFaceTrackingConfiguration` + `ARSessionDelegate`. Pose comes from
`ARFaceAnchor.transform` decomposed into YXZ Euler angles. **Yaw is NOT
negated** (the agent's original code over-negated; verified empirically on
Carl's iPhone 17 Pro). Pitch + roll keep their negation per the
user-perspective sign convention.

Face crops for embedding capture come from `VNDetectFaceRectanglesRequest`
(correct Y-flip) — this side-stepped the AVMetadata crop bug that the
fallback channel still has.

**Non-TrueDepth (iPhone SE family):** `FaceEnrolmentCameraChannel.swift`.
Vision-on-CMSampleBuffer pose source. **Still has the AVMetadata-bounds
crop bug** in `captureFrameAndEmbed` — non-TrueDepth users will get
the same cosSim ≈ 0.09 mismatch we hit before fixing for the ARKit path.
See [Known follow-ups](#known-follow-ups).

### Prompt walker accept gate

Per-axis tolerance budgets, NOT Manhattan sum:

```dart
const double yawTolerance = 20.0;    // primary discriminator, tight
const double pitchTolerance = 30.0;  // ergonomic baseline drift, loose
if (dYaw > yawTolerance || dPitch > pitchTolerance) return; // reject
```

The natural phone-holding pitch is ~-12°, so a tight pitch tolerance
combined with Manhattan sum was eating the budget. Per-axis lets us be
strict on the prompt's primary axis (yaw) and forgiving on the secondary
(pitch).

### Debug surfaces

All under Settings → 7-tap logo → Diagnostics:

1. **"Show face-enrolment pose HUD"** toggle — coral-bordered pill on the
   enrolment screen showing events count, nil-axis count, live yaw/pitch,
   target, and Manhattan delta. Default off.
2. **"Log Safe Mode match details"** toggle — appends per-face cosSim
   scores to `conversion_error.log` after every Safe Mode photo capture.
   Readable via long-press on the Studio "N failed" pill.
3. **"Test self-recognition"** action — opens the system camera, takes a
   selfie, runs the same Safe Mode v2 matcher pipeline as the production
   path, surfaces verdict + bestSim + branch + per-face cosSims in a
   bottom sheet with plain-English interpretation.

## Verified on Carl's iPhone

- Full 6-prompt enrolment sweep completes
- HUD shows continuous yaw (sub-degree precision, not Vision's quantized 45°)
- Yaw sign matches expectation: right turn → positive, left turn → negative
- Pitch reads ~-12° at natural phone-holding posture (correct sign)
- Cosmetic polish (PR #540): My Workouts pill padding balanced, top-bar
  icons aligned to logo centerline

## Pending verification

Carl was running these as the session wrapped:

1. **Diagnostics → Test self-recognition** → expected: Verdict: Recognised,
   bestSim ≥ 0.45. (The diagnostic surface from PR #538 uses the same
   matcher as production, so this confirms enrolment-time embeddings
   match capture-time embeddings.)
2. **Real Safe Mode self-photo** into the Self-client session → face should
   stay sharp (not blurred)
3. **Negative case** — Safe Mode photo with an unenrolled face in frame →
   that face should still get blurred

## Known follow-ups

### Critical — non-TrueDepth face crop bug

`FaceEnrolmentCameraChannel.captureFrameAndEmbed` (the Vision fallback for
iPhone SE family) still uses `AVMetadataFaceObject.bounds` for the crop
without Y-flip / orientation reconciliation. Same root cause that the M40
ARKit channel side-stepped by using `VNDetectFaceRectanglesRequest`.

Per the PR #538 author's note, the fix is to lift the ~20-line
`VNDetectFaceRectanglesRequest` block from `FaceEnrolmentARKitChannel.swift`
(lines 463-507 area) into `FaceEnrolmentCameraChannel.captureFrameAndEmbed`
just before the existing `imageW`/`imageH` declarations. Replace
`faceBoundsNormalized` reads with the top-left-origin Y-flipped rect from
Vision.

Until this lands, iPhone SE users will hit the same cosSim ≈ 0.09 verdict
we just spent hours diagnosing. They can enrol but recognition will fail.

### Cosmetic — ARKit roll sign

We dropped the yaw negation in PR #545 because we empirically saw the YXZ
extraction was already producing user-perspective yaw. Pitch reads correctly
with its current negation (Carl's natural -12° = chin tucked down, which
matches user-perspective convention). Roll is also currently negated by
parity with pitch — likely wrong by the same logic that yaw was wrong, but
the prompt walker doesn't gate on roll so it's cosmetic. Verify on a future
enrolment that asks the user to tilt their head sideways (no current prompt
does).

### Backlog continues to stand

Nothing in the broader backlog moved this session. Hostinger redirects,
PayFast prod, ZA lawyer red-pen, `support@homefit.studio` mailbox — all
still pending Carl.

## Disk space + housekeeping

**State at session end:**
- 14 GB freed by nuking `~/Library/Developer/Xcode/DerivedData` (during the
  install retry — disk was at 100% / 117 MB free)
- Currently ~14 GB available on the 460 GB volume
- **~30 GB still recoverable** from agent worktree `app/build` directories

**~50 stale agent worktrees** live under `/Users/chm/dev/TrainMe/.claude/worktrees/agent-*`
— each has an `app/build` directory of ~700 MB from when that agent built once
for analysis. The agents are long-done; the build artifacts are pure waste.

Pruning strategy in priority order:

1. `git worktree list` to enumerate
2. For each `agent-*` worktree where the underlying branch has been merged
   to staging or main: `git worktree remove --force <path>`
3. For dangling directories with no git registration:
   `rm -rf <path>/app/build` (safer than removing the whole worktree —
   leaves the git references intact in case something is mid-flight)
4. After major pruning: `git worktree prune` to clean stale refs

A cleanup pass at the start of the next session would be appropriate —
ideally before any new builds run.

## Memory entries to add

Add to `~/.claude/projects/-Users-chm-dev-TrainMe/memory/`:

### `gotcha_arkit_yaw_no_negation.md`

> ARKit `ARFaceAnchor.transform` decomposed into YXZ Euler angles produces
> user-perspective yaw DIRECTLY — do not negate. The original M40 agent
> applied the AVCaptureSession-pattern negation by reflex; empirical
> verification on iPhone 17 Pro showed this flipped left/right. Pitch
> + roll DO need negation per the user-perspective convention. See
> `FaceEnrolmentARKitChannel.swift` `userPoseDegrees` and PR #545.

### `feedback_decoupled_pose_tolerance.md`

> Per-axis tolerance for the face-enrolment prompt walker:
>   - yaw 20° (tight — yaw is the primary discriminator across buckets)
>   - pitch 30° (loose — natural phone-holding posture is pitch ~-12°)
>
> Do NOT use Manhattan-sum. The natural posture eats the budget for any
> prompt that's NOT pitch=0 / yaw≠0. Per-axis matches the ergonomic
> reality: yaw is what the prompt is actually testing, pitch is baseline
> drift we tolerate.

### `feedback_face_enrolment_debug_hud_lives_in_diagnostics.md`

> Three permanent diagnostic surfaces under Settings → 7-tap logo → Diagnostics
> for face enrolment + Safe Mode recognition:
>   - "Show face-enrolment pose HUD" toggle (events count + live yaw/pitch
>     + target + delta on the enrolment screen)
>   - "Log Safe Mode match details" toggle (cosSim values appended to
>     conversion_error.log per Safe Mode photo)
>   - "Test self-recognition" action (run Safe Mode v2 matcher pipeline
>     against a fresh selfie, show verdict + bestSim in bottom sheet)
>
> Don't delete these as cleanup — they're load-bearing for any future
> regression triage. The M40 ARKit agent over-deleted them once already
> (recovered via PR #542).

## Fresh-session quickstart

For a new context window to pick up the project state:

1. **Read this checkpoint first.** It's the most recent.
2. Then `CLAUDE.md` for the broader project context. Note the Safe Mode
   section has been updated with the M40 capability-gated split.
3. Branch state: staging tip is `c347041`. Carl's iPhone CHM is on this
   build (verified via the SHA in Settings).
4. Active worktrees that should be cleaned up early:
   - `face-debug-hud`, `decouple-pose-tol`, `arkit-yaw-flip`,
     `restore-pose-hud` — all merged, safe to remove
   - `agent-*` directories — most are stale; verify branch state before
     removing
5. The non-TrueDepth fallback bug is the next-most-actionable Safe Mode
   work. Spec it carefully — the ARKit agent's PR #538 body has the exact
   fix pattern in the "Suggested follow-up wire" paragraph.

---

Session timestamp: 2026-05-26 22:50 SAST. Author: Claude (via Carl's
iPhone QA driving the diagnostic loop).
