# Handover — Safe Mode photo-capture crash fix

**Created:** 2026-05-22 by Claude (current session) for execution in a fresh session.
**Status:** ready to dispatch. Carl approved the fix scope. App on iPhone CHM is currently bricked by this bug.
**Target branch:** `staging` (NOT main).
**Suggested branch name:** `fix/safe-mode-processor-crash-and-hardening`.

## Table of Contents

- [Current state of the world](#current-state-of-the-world)
- [The bug](#the-bug)
- [Why the app cannot relaunch](#why-the-app-cannot-relaunch)
- [The fix — seven items in one PR](#the-fix--seven-items-in-one-pr)
- [Out of scope](#out-of-scope)
- [Verification](#verification)
- [Conventions](#conventions)
- [References](#references)

## Current state of the world

- **Staging tip:** `594c46a` — this is PR #423's REVERT (`Revert "feat(safe-mode): face-based subject + Gaussian blur treatment"`). The face-based discriminator + Gaussian blur work is currently NOT on staging.
- **Broken code that needs fixing:** the original PR #423 commit is `bbce3e8`. It's in git history but not on staging. The new fix PR should re-apply the desired functionality + harden the issues below in a single new branch off staging tip.
- **iPhone state:** Carl's iPhone CHM still has build `bbce3e8` installed and **the app cannot launch** (boot-loops on `ConversionService.restoreQueue()` re-running a poisoned `converting` row from the failed selfie capture). Until the new fix lands + installs, the app is bricked. Carl is fine with this — he's not currently using the app for client work and prioritises a proper fix.
- **Crash logs available:**
  - `/Users/chm/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/0340CE37-3BA8-459E-A1A6-062B785E11A7/Runner-2026-05-22-160118.ips` — first crash (selfie capture).
  - `/Users/chm/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/760EAA44-F227-4D80-8E47-58CAF6F52D4D/Runner-2026-05-22-160124.ips` — relaunch crash (same trap, 6s later).
  - Both confirm `EXC_BREAKPOINT/SIGTRAP` in `SafeModeProcessor.init(width:height:)`.

## The bug

**Primary root cause (confirmed via crash log):** a 6-character typo in the Core Image filter name on commit `bbce3e8`, file `app/ios/Runner/VideoConverterChannel.swift`, lines 4076-4077:

```swift
self.blurFilter = CIFilter(name: "CIGaussianBlur")!         // ✓ correct
self.blendFilter = CIFilter(name: "CIBlendWithMaskFilter")! // ✗ WRONG
```

The Core Image **filter registration name** is `"CIBlendWithMask"` (no "Filter" suffix). The Swift CLASS that wraps the filter is `CIBlendWithMaskFilter` — the agent that wrote PR #423 confused the class identifier with the string-name passed to `CIFilter(name:)`.

`CIFilter(name: "CIBlendWithMaskFilter")` returns `nil` → force-unwrap (`!`) traps the Swift runtime → `EXC_BREAKPOINT/SIGTRAP` → process dies.

**Crash location confirmed:** faulting thread queue `com.raidme.video_converter.processing`, stack:

```
SafeModeProcessor.init(width:height:)              ← TRAP HERE (offset 944)
specialized VideoConverterChannel.applySafeModeToPhoto(srcPath:destPath:)
closure #5 in VideoConverterChannel.handle(_:result:)
```

The constructor crashes BEFORE any frame is processed.

**Impact on both pipelines:** photo and video both call the same `SafeModeProcessor(width:height:)` constructor (lines 1132 for video, 2705 for photo). Both crash identically. Carl only tested photo first, so the video crash is latent but real.

## Why the app cannot relaunch

`ConversionService.restoreQueue()` at `app/lib/services/conversion_service.dart:118-127` pulls every `pending` / `converting` SQLite row on init and re-enqueues for processing. The poisoned photo row was stamped `converting` when the native crash hit. Each app launch:

1. SQLite still has the `converting` row.
2. `restoreQueue` re-enqueues it.
3. Native `processPhotoSafeMode` channel is called.
4. SafeModeProcessor.init runs.
5. Same force-unwrap traps.
6. App dies before any UI frame.

Boot-loop. This is a separate bug from the filter-name typo and must also be fixed.

## The fix — seven items in one PR

All seven changes belong in a single PR. Branch off the current staging tip (`594c46a`); base contains the revert of #423, so you start from a working baseline.

### 1. Fix the Core Image filter name + harden force-unwraps

**File:** `app/ios/Runner/VideoConverterChannel.swift` (the file you'll re-apply from `bbce3e8` and fix).

Re-apply PR #423's `SafeModeProcessor` rewrite from `git show bbce3e8 -- app/ios/Runner/VideoConverterChannel.swift`. Then:

```swift
// BEFORE (BROKEN — PR #423 lines 4076-4077):
self.blurFilter = CIFilter(name: "CIGaussianBlur")!
self.blendFilter = CIFilter(name: "CIBlendWithMaskFilter")!

// AFTER:
guard let blurFilter = CIFilter(name: "CIGaussianBlur"),
      let blendFilter = CIFilter(name: "CIBlendWithMask") else {
    fatalError("Core Image filters CIGaussianBlur/CIBlendWithMask not available — iOS version mismatch?")
}
self.blurFilter = blurFilter
self.blendFilter = blendFilter
```

`fatalError` here is acceptable because if these built-in CoreImage filters are missing, the OS itself is broken — not something we can recover from. The change converts an opaque SIGTRAP into a labelled crash message in the log.

### 2. Clamp photo working resolution to 1920px max-dim

**File:** `app/ios/Runner/VideoConverterChannel.swift`, in `applySafeModeToPhoto(srcPath:destPath:)` around line 2624.

iPhone front camera photos are typically 4032×3024 (12MP). Feeding that directly into `SafeModeProcessor` + Vision + CoreImage at full resolution allocates ~500MB peak working set — iOS jetsam will kill the process. Clamp to 1920px max-dim before allocating pixel buffers.

```swift
// Compute work resolution. Scale down to fit within 1920px max-dim.
let nativeWidth = uiImage.cgImage?.width ?? 0
let nativeHeight = uiImage.cgImage?.height ?? 0
let workScale = min(1.0, 1920.0 / Double(max(nativeWidth, nativeHeight)))
let workWidth = Int(Double(nativeWidth) * workScale)
let workHeight = Int(Double(nativeHeight) * workScale)
// Then allocate srcBuf/dstBuf at (workWidth × workHeight), draw the CGImage
// scaled into the source buffer, run SafeModeProcessor on those work dimensions.
// Up-scale the resulting mask back to native resolution and apply to the
// original-resolution photo for the final output — OR keep the output at work
// resolution if the editor display path doesn't need native res.
```

### 3. Clamp video working resolution to 1080p max-dim

**File:** `app/ios/Runner/VideoConverterChannel.swift`, in the video `convertVideo` flow around the SafeModeProcessor init (line 1132 ish).

Same concern as photo: if a practitioner shoots 4K video (3840×2160), per-frame buffer memory + Vision mask + CoreImage intermediates exceed the safe budget. Clamp to 1080p (1920×1080) max-dim for the work pipeline. Output can up-rez back if needed, but in practice 1080p is what we want for the safe variant.

### 4. Demote `converting` SQLite rows to `failed` on `restoreQueue()` init

**File:** `app/lib/services/conversion_service.dart`, in `restoreQueue()` around line 118-127.

Currently `restoreQueue` re-enqueues every `pending` and `converting` row. A row in `converting` state at app launch means the previous process died mid-conversion — re-running it on the same code path will most likely crash again. Demote it to `failed` so the user sees the "N failed" pill and can manually retry.

```dart
// In restoreQueue, BEFORE re-enqueuing:
final stuck = await db.query('exercises',
    where: 'conversion_status = ?',
    whereArgs: ['converting']);
for (final row in stuck) {
  await db.update('exercises',
      {'conversion_status': 'failed', 'last_conversion_error': 'Aborted by prior crash on init'},
      where: 'id = ?',
      whereArgs: [row['id']]);
}
// Then proceed with re-enqueuing 'pending' rows only.
```

This means a single bad native crash CAN'T brick the app on relaunch. Failed rows surface through the existing "N failed" long-press log reader.

### 5. Add orientation hint to `VNDetectFaceRectanglesRequest`

**File:** `app/ios/Runner/VideoConverterChannel.swift`, `SafeModeProcessor.processFrame` and `applySafeModeToPhoto`.

Front-camera photos and videos have an EXIF orientation of `.right` (portrait) or `.left` depending on device orientation. When the buffer is rendered from `cgImage`, EXIF orientation is dropped — but Vision still expects you to pass `orientation:` to its request handler. Without the hint, Vision sees faces sideways and either returns no observations OR returns ones that don't match what the human eye sees.

Pass the orientation explicitly:

```swift
let orientation: CGImagePropertyOrientation = .up  // OR derive from EXIF / device orientation
let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
try handler.perform([faceRequest])
```

For PHOTOS taken from the front camera in portrait mode, the source orientation is typically `.right`. For VIDEOS, derive from the AVAssetTrack's preferred transform. The diagnostic doc has more detail.

### 6. Replace fragile `Data(bytesNoCopy:, deallocator: .none)` with `Data(bytes:count:)` copy

**File:** `app/ios/Runner/VideoConverterChannel.swift`, somewhere in the new CoreImage glue (search for `Data(bytesNoCopy`).

The `.none` deallocator means the Data wrapper doesn't own the underlying memory. If the source pointer is freed before all Data references are released, you get a use-after-free. Copy instead for safety:

```swift
// BEFORE (fragile):
let data = Data(bytesNoCopy: ptr, count: size, deallocator: .none)

// AFTER (safe):
let data = Data(bytes: ptr, count: size)
```

One-line copy. Performance overhead is negligible (single memcpy per frame).

### 7. Update the diagnosis doc on main with the corrected primary root cause

**File:** `docs/diagnoses/2026-05-22-safe-mode-photo-crash.md` (already on main, committed in `f1e3cfb`).

The diagnostic agent that wrote the original doc ran in parallel with the crash log surfacing and didn't have access to it. The doc's PRIMARY hypothesis (H4 — memory exhaustion / jetsam) is incorrect. The actual primary root cause is the filter-name typo. Add a "**Correction 2026-05-22**" section at the top of the doc:

```markdown
## Correction — 2026-05-22 (post crash-log review)

The primary root cause is NOT memory exhaustion / jetsam (hypothesis H4 below).
Crash logs (Runner-2026-05-22-160118.ips, Runner-2026-05-22-160124.ips)
confirm an EXC_BREAKPOINT/SIGTRAP in SafeModeProcessor.init at offset 944.
This is a force-unwrap of CIFilter(name: "CIBlendWithMaskFilter") which
returns nil — the correct Core Image filter name is "CIBlendWithMask" (no
"Filter" suffix). The class name is CIBlendWithMaskFilter; the string-name
passed to CIFilter(name:) is "CIBlendWithMask".

H4's memory-cliff concern is still valid as a latent issue for 12MP photo
input + 4K video input — that's why fixes #2 and #3 in the handover are
included alongside the primary filter-name fix.

The other secondary findings (boot-loop via restoreQueue, Vision orientation
hint, Data(bytesNoCopy:) fragility) remain valid and are also in scope.
```

This update goes direct-to-main per `feedback_specs_direct_to_main` since it's a doc.

## Out of scope

- Per-practitioner deep-linking on the practice profile (V2).
- New `safe.mp4` / `safe.jpg` cloud-side changes — the pipeline that uploads the safe variant is unchanged.
- Tap-to-confirm UI for ambiguous subject selection (separate Flutter PR later — but the `lowConfidence` flag in the result payload from PR #423 should still be returned so the Flutter UI can wire to it eventually).
- Floor plans / live transparency page implementation (separate spec at `docs/specs/2026-05-22-safe-mode-transparency.md`).
- The Settings practice-row chevron gating bug (stacked as S-19, separate fix).
- The other items still in the stack file (S-11 already fixed in #421 which is on staging, S-13/S-16/S-17/S-18 still pending).

## Verification

After the fix lands + installs to iPhone CHM:

1. **App launches** — the boot-loop is broken. The poisoned `converting` row from the prior crash is now stamped `failed`. App opens to Clients screen normally.
2. **Photo capture works** — take a selfie with bystander in frame. No crash. App stays alive. Conversion completes. Bystander appears as a Gaussian blur (not a coral silhouette) in the resulting safe.jpg.
3. **Video capture works** — record a 5s video with bystander in frame. No crash. Conversion completes. Bystander appears as Gaussian blur in safe.mp4.
4. **Wrong-person bug fixed** — bystander straight-on / centered, subject (you) at an angle holding the phone — the BYSTANDER is blurred (not you). Confirms orientation hint + face-based discriminator work together.
5. **Failed pill works** — long-press the "N failed" pill on the Studio card (PR #213 territory). The recovered-from-crash row appears in the failed list with the message "Aborted by prior crash on init".
6. **No memory spikes** — capture a video at full resolution, monitor Xcode memory gauge if connected. Peak should stay under ~250MB.
7. **`dart analyze` clean** across all `app/lib/` edits.
8. **`flutter build ios --debug --simulator` compiles cleanly.**

## Conventions

- No emojis in commits, code, or PR descriptions.
- Branch: `fix/safe-mode-processor-crash-and-hardening`.
- Target: `staging` (NOT main).
- Commit message: `fix(safe-mode): processor init crash + memory clamp + boot-loop recovery + orientation`.
- PR title: `fix(safe-mode): un-crash the processor + harden against memory cliff and boot-loop`.
- PR body must include:
  - Reference to the crash log (Runner-2026-05-22-160118.ips).
  - Diagnosis chain (filter-name typo → SIGTRAP → boot-loop via restoreQueue).
  - List of all 7 changes mapped to files + line ranges.
  - Verification steps Carl will run on device.
  - A note that `docs/diagnoses/2026-05-22-safe-mode-photo-crash.md` has been corrected on main with the primary root cause.
- Use `mcp__dart__analyze_files` after Dart edits.
- Use `xcodebuild` MCP to compile-test the iOS target before opening the PR.
- After PR is opened, wait for CI green, merge with `gh pr merge --squash --delete-branch`, then build + install via `./install-device.sh staging` on iPhone CHM.

## References

- **Diagnosis doc (needs correction):** [docs/diagnoses/2026-05-22-safe-mode-photo-crash.md](../diagnoses/2026-05-22-safe-mode-photo-crash.md) — committed in `f1e3cfb`. Primary hypothesis H4 (memory exhaustion) is incorrect; corrected version of root cause is the filter-name typo.
- **Crash logs (local to Carl's Mac):**
  - `/Users/chm/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/0340CE37-3BA8-459E-A1A6-062B785E11A7/Runner-2026-05-22-160118.ips`
  - `/Users/chm/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/760EAA44-F227-4D80-8E47-58CAF6F52D4D/Runner-2026-05-22-160124.ips`
- **PR #423 (reverted via #426):** [github.com/carlheinmostert/TrainMe/pull/423](https://github.com/carlheinmostert/TrainMe/pull/423) — original face-based + Gaussian blur PR that introduced the typo. The fix re-applies its functionality with the typo corrected.
- **Revert PR #426:** [github.com/carlheinmostert/TrainMe/pull/426](https://github.com/carlheinmostert/TrainMe/pull/426) — current staging baseline.
- **Stack file:** [docs/test-scripts/2026-05-22-stack.md](../test-scripts/2026-05-22-stack.md) — for context on what other items are in flight; S-11/12/14/15/17 already landed in earlier PRs.
- **Test script for the broader wave:** [docs/test-scripts/2026-05-22-safe-mode-redesign-wave.md](../test-scripts/2026-05-22-safe-mode-redesign-wave.md) — Carl's test items 26-28 (face discriminator) and 29-30 (Gaussian blur) will be re-verified by this fix.
- **Safe Mode transparency spec (out of scope for this fix):** [docs/specs/2026-05-22-safe-mode-transparency.md](../specs/2026-05-22-safe-mode-transparency.md).
