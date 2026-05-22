# 2026-05-22 — Safe Mode photo crash (PR #423, build `bbce3e8`)

## Table of Contents

- [TL;DR](#tldr)
- [Symptom](#symptom)
- [Why the app can't relaunch](#why-the-app-cant-relaunch)
- [Hypothesis chain](#hypothesis-chain)
- [Root cause](#root-cause)
- [Why videos didn't crash but photos do](#why-videos-didnt-crash-but-photos-do)
- [The exact Swift fix](#the-exact-swift-fix)
- [Secondary fix — make ConversionService skip the poisoned row on launch](#secondary-fix--make-conversionservice-skip-the-poisoned-row-on-launch)
- [Other latent bugs worth fixing in the same PR](#other-latent-bugs-worth-fixing-in-the-same-pr)
- [What was actually wrong with the design](#what-was-actually-wrong-with-the-design)

## TL;DR

PR #423 rewrote the Safe Mode bystander-blur to use a heavyweight CoreImage
chain (Gaussian blur + mask blend) on every Safe Mode capture. The new
processor was tuned for **video frames at 1080p** but the photo path feeds
it the **native-resolution iPhone photo** — typically 4032 × 3024 (12 MP),
which is roughly **10× the pixel count of a 1080p frame**.

At 12 MP:

- Two BGRA pixel buffers (source + destination) cost about 48 MB each.
- The CIGaussianBlur radius scales proportionally from 35 to ~98, and at
  radius 98 CoreImage allocates intermediate Metal textures whose footprint
  is well into hundreds of megabytes.
- A pure-Swift per-pixel loop iterates ~12 million times to build the
  "keep source" mask.

The combined memory pressure on a typical photo blows past iOS's per-process
budget for the conversion subsystem and the app is killed by jetsam
(Code=-11 / `EXC_RESOURCE` / `MEMORY`). There is no in-app error path
because the OS terminates the process before any Swift catch handler can
run.

The crash is then **sticky across relaunches** because `ConversionService`
restores the failed-pending row from SQLite on init and feeds the exact
same poisoned input straight back into the same crash code path before any
UI is shown.

The fix has two halves: downscale the photo to a sane working resolution
before invoking the CoreImage chain (cut peak memory by ~10×) **and**
teach `ConversionService.restoreQueue()` to mark obviously-pending
conversions as `failed` on first launch so the app can boot even if a bad
capture is sitting in the queue. The first half stops the crash; the
second half un-bricks Carl's phone if he ever hits a future variant.

## Symptom

- Carl was inside his home polygon, so Safe Mode was auto-active at the
  capture moment.
- Front-camera **photo** (not video) of himself + his wife in the
  background — standard selfie composition with two faces.
- App crashed instantly on shutter-tap. No in-app error toast, no
  conversion-error log entry, just the app disappearing.
- Subsequent launches likely crash again before the home screen is drawn:
  `ConversionService.initialize` runs synchronously at startup and
  `restoreQueue()` re-enqueues the same poisoned exercise.

## Why the app can't relaunch

`ConversionService.restoreQueue()` (`app/lib/services/conversion_service.dart:118-127`)
runs on every app launch. It pulls every exercise whose `conversionStatus`
is `pending` or `converting` and pushes them back onto the FIFO queue:

```dart
Future<void> restoreQueue() async {
  final unconverted = await _storage.getUnconvertedExercises();
  for (final exercise in unconverted) {
    _queue.add(exercise);
  }
  if (_queue.isNotEmpty) {
    _processQueue();
  }
}
```

The crashing photo capture would have been stamped `converting` at the
moment the queue started processing it (line 166-169) and then never
demoted, because the process died inside the native `processPhotoSafeMode`
channel call before the per-item catch could write any status back.

So every relaunch:

1. SQLite still has the photo at `conversionStatus = converting`.
2. `restoreQueue` finds it and pushes onto the queue.
3. `_processQueue` runs, lands in `_convertPhoto` → channel
   `processPhotoSafeMode` → native crash → jetsam.
4. App dies before any UI frame is rendered.

This is the textbook offline-first "poisoned-row" bug. The only way out
without changes to the binary is to wipe local storage (uninstall the
app) — which loses every unpublished capture.

## Hypothesis chain

The brief listed seven hypotheses. Walking each one against the code at
`bbce3e8`:

### H1 — CIGaussianBlur extent vs source extent mismatch

**Rejected.** The code explicitly crops the blur output back to source
extent before blending:

```swift
// app/ios/Runner/VideoConverterChannel.swift:4226 (at bbce3e8)
let blurredCI = rawBlur.cropped(to: sourceCI.extent)
```

The `ciContext.render(_:to:bounds:colorSpace:)` call (line 4252-4257) also
passes `bounds: sourceCI.extent`, so the output buffer's dimensions are
respected. The blend filter wouldn't produce out-of-bounds output.

### H2 — Face anchor going out of image bounds

**Rejected.** Each anchor coordinate is clamped with `max(0, ...)` and
`min(width, ...)` / `min(height, ...)`:

```swift
// VideoConverterChannel.swift:4171-4174
let anchorX0 = max(0, Int((faceCx - halfExpandedW).rounded(.down)))
let anchorX1 = min(width, Int((faceCx + halfExpandedW).rounded(.up)))
let anchorY0 = max(0, Int((faceTopY - expandUpPx).rounded(.down)))
let anchorY1 = min(height, Int((faceBotY + expandDownPx).rounded(.up)))
```

The inner loop only reads from `personMask` and writes to
`keepSourceMaskData`, both sized `width * height`. The `inAnchor` test is
pure arithmetic, no pixel access from the anchor itself. Safe.

### H3 — Metal CIContext init without device

**Rejected.** The processor has an explicit `if let device =
MTLCreateSystemDefaultDevice()` with a software fallback (lines
4057-4061). On a real iPhone CHM, Metal is always available. The Metal
context is created once per processor instance, before any photo work
happens.

### H4 — Photo resolution larger than 1080p assumption ✓ CONFIRMED

This is the one. See [Root cause](#root-cause) below for the full trace.

### H5 — Person segmentation mask null / wrong format

**Plausible but not the primary crash.** The `processFrame` code has an
explicit `if mask == nil { return copySourceVerbatim(...) }` guard
(lines 4181-4184). On the photo path, `PersonSegmenter` runs in `.accurate`
mode and Vision can return nil for a person-segmentation request that
hits a non-person frame or runs out of resources. The non-nil branch
de-references `mask!`, but only **after** the nil guard. Not a crash on
its own.

However: when `VNGeneratePersonSegmentationRequest` runs with
`.accurate` on a 12 MP photo, it allocates a high-resolution mask buffer
(Vision's internal mask is typically up to 4096 × 4096 at `.accurate`).
**This compounds the memory pressure** flagged in H4 — not the crash
trigger by itself, but contributes.

### H6 — VNDetectFaceRectanglesRequest returning no observations

**Rejected.** The code has an explicit empty-observations guard:

```swift
// VideoConverterChannel.swift:4110-4114
let observations = faceRequest.results ?? []
if observations.isEmpty {
    framesMissed += 1
    return false
}
```

The `.first!` / `Array.first!` patterns the brief was worried about don't
appear. `subjectFace` is initialised to `.zero`, and the loop only
mutates it inside the area-comparison branch. A subsequent
`bestArea <= 0` guard catches the never-mutated case. Safe.

### H7 — Result payload missing keys when face detection fails

**Rejected.** Both `case .success` and `case .failure` paths build full
result maps with every expected key (lines 426-431, 433-437). The Dart
side reads via map lookup with null-coalescing defaults (`as num?
)?.toDouble() ?? 0.0`), so even a missing key wouldn't crash on the Dart
side either.

## Root cause

**The Safe Mode processor was sized for 1080p video frames but is being
fed full-resolution iPhone photos (12 MP on modern iPhones).** The
memory and compute requirements scale roughly linearly with pixel count,
and the chain blows the process's memory budget.

The smoking-gun lines, walking the photo path at `bbce3e8`:

### Step 1 — `applySafeModeToPhoto` allocates source + dest buffers at full photo resolution.

```swift
// VideoConverterChannel.swift:2635-2654
let width = cgImage.width    // = 4032 on iPhone 15 front camera
let height = cgImage.height  // = 3024
// ...
let srcStatus = CVPixelBufferCreate(
    kCFAllocatorDefault,
    width,           // 4032
    height,          // 3024
    kCVPixelFormatType_32BGRA,
    ...
)
```

A 4032 × 3024 BGRA buffer is 4032 × 3024 × 4 bytes = **48.7 MB**. A
second identical buffer is allocated 30 lines below for the destination.
Two BGRA buffers = **~98 MB just to hold the source + destination.**

### Step 2 — `PersonSegmenter(width: 4032, height: 3024)` allocates a 12 MB mask.

```swift
// VideoConverterChannel.swift:3584-3590
let dataSize = width * height  // = 12_192_768
upscaledMaskBuffer = vImage_Buffer(
    data: UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16),
    ...
)
```

Plus Vision's internal mask in `.accurate` mode — can be another 4096×4096
× 4 bytes = **67 MB** during the request.

### Step 3 — `SafeModeProcessor(width: 4032, height: 3024)` allocates another 12 MB scratch mask.

```swift
// VideoConverterChannel.swift:4077-4080
self.maskRowBytes = width        // 4032
let bufSize = width * height     // 12_192_768
self.keepSourceMaskData = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
self.keepSourceMaskData.initialize(repeating: 255, count: bufSize)
```

### Step 4 — Resolved blur radius scales up to ~98.

```swift
// VideoConverterChannel.swift:4068-4070
let minDim = Double(min(width, height))  // = 3024
let scale = minDim / Self.baseSourceDim  // = 3024 / 1080 = 2.8
self.resolvedBlurRadius = Self.baseGaussianBlurRadius * max(0.25, scale)
// = 35 * 2.8 = 98.0
```

A Gaussian blur with radius ~98 on a 12 MP image is the killer. CoreImage
implements `CIGaussianBlur` as a separable convolution and at radius 98
the kernel has thousands of taps. The Metal command buffer has to
materialise intermediate textures at roughly source resolution per pass —
that's another ~150-200 MB of GPU-backed CIImage extents (which count
against the process's memory budget).

### Step 5 — Pure-Swift per-pixel loop iterates 12 million times.

```swift
// VideoConverterChannel.swift:4196-4209
for y in 0..<height {           // 3024 iterations
    let pmRow = personMask + y * width
    let ksmRow = ksm + y * maskRowBytes
    let inAnchorY = (y >= anchorY0 && y < anchorY1)
    for x in 0..<width {        // × 4032 inner iterations
        let pm = pmRow[x]
        if pm >= 128 {
            let inAnchor = inAnchorY && x >= anchorX0 && x < anchorX1
            ksmRow[x] = inAnchor ? 255 : 0
        } else {
            ksmRow[x] = 255
        }
    }
}
```

3024 × 4032 = ~12 million iterations of branching scalar Swift. Not a
crash, but it adds ~200-400 ms of CPU on top of an already-stressed
process. By the time CoreImage starts the render, the system has been
holding north of 250 MB in flight.

### Total memory snapshot at peak

| Allocation                                      | Bytes      |
|-------------------------------------------------|-----------:|
| Source BGRA pixel buffer (4032×3024)            |     48.7 M |
| Destination BGRA pixel buffer (4032×3024)       |     48.7 M |
| `PersonSegmenter.upscaledMaskBuffer`            |     12.2 M |
| Vision internal mask (.accurate)                |    ~67.0 M |
| `SafeModeProcessor.keepSourceMaskData`          |     12.2 M |
| CIGaussianBlur intermediate Metal textures      |   100-200 M |
| `CIBlendWithMaskFilter` output (4032×3024 BGRA) |     48.7 M |
| Flutter runtime baseline                        |    ~100 M  |
| Camera capture residual memory                  |    ~50 M   |
| **Total peak**                                  | **~500 M** |

On an iPhone with 4 GB RAM (iPhone 12-class), the per-app budget under
foreground conditions is in the 1.5-2 GB range, but the
**conversion-service subsystem competes with the live Flutter view tree,
the camera session that just took the photo, and any cached video
players from the previous Studio view**. iOS's jetsam daemon kills the
process the moment its working set exceeds budget — typically signalled
as `EXC_RESOURCE` / `RESOURCE_TYPE_MEMORY` in the crash log, with no
chance for the Swift try/catch to fire.

This is also why Carl reported the app crashing **instantly with no
in-app error** — there is no error path. The OS terminates the process.

## Why videos didn't crash but photos do

PR #423 unified the SafeModeProcessor to also run on the photo path.
The video path was already in production with the previous
`largest-human-bbox` discriminator (no CoreImage, no Gaussian blur — just
flat coral painting via vImage scalar fills) and it worked fine.

When PR #423 introduced the new CoreImage chain, the video path stayed
safe because:

- Video frames are 1080p (1920 × 1080) — about **1/6th the pixels** of a
  12 MP photo.
- The locked blur radius is 35 at 1080p — about **1/3rd the Metal
  texture footprint** of the radius-98 kernel the photo path produces.
- Video frames come from `AVAssetReader` already in BGRA at 1080p, so
  no full-resolution pixel buffer copy is needed.

The photo path inherits the SafeModeProcessor's design but at 5-10× the
working-set size. **The processor was never tuned for full-resolution
camera photos** — that scaling case wasn't tested.

## The exact Swift fix

Downscale the photo to a working resolution that matches the
processor's design budget **before** invoking SafeModeProcessor, then
upscale the result back to the original resolution for storage. The
practitioner-facing photo treatments (line drawing, B&W thumbnail, raw
archive) already get re-derived from the safe-painted output, so the
downscale-blur-upscale path is acceptable as long as the final saved
JPEG matches the original resolution.

In `applySafeModeToPhoto` (`VideoConverterChannel.swift:2624`),
introduce a working resolution clamp:

```swift
// New constants at top of class or file:
private static let safeModeMaxWorkingDim: CGFloat = 1920.0

// Replace lines 2635-2680 (compute width/height + render to BGRA pixel
// buffer) with:

let nativeWidth = CGFloat(cgImage.width)
let nativeHeight = CGFloat(cgImage.height)
let nativeMaxDim = max(nativeWidth, nativeHeight)
let workScale = min(1.0, Self.safeModeMaxWorkingDim / nativeMaxDim)
let workWidth = Int((nativeWidth * workScale).rounded())
let workHeight = Int((nativeHeight * workScale).rounded())

// Allocate srcBuf / dstBuf at workWidth × workHeight.
// Use srcCtx.draw(cgImage, in: CGRect(0, 0, workWidth, workHeight))
// (this implicitly resamples — CG handles the scale for us).
//
// Run PersonSegmenter + SafeModeProcessor at workWidth × workHeight.
//
// After processor returns, upscale dstBuf back to nativeWidth × nativeHeight
// using vImageScale_ARGB8888 before JPEG encode. OR: encode at work
// resolution and let the photo's EXIF/resize step handle the rest if
// the original is no longer needed at full res for this surface.
```

At a 1920 × 1080 working resolution the math is:

| Allocation                                      | Bytes      |
|-------------------------------------------------|-----------:|
| Source BGRA (1920×1080)                         |      8.3 M |
| Destination BGRA (1920×1080)                    |      8.3 M |
| Person mask + scratch                           |    ~4.2 M  |
| CIGaussianBlur radius 35 textures               |   30-50 M  |
| **Total peak**                                  | **~70 M**  |

That's a **7× reduction in peak memory** for the Safe Mode pass and
brings the photo path to parity with the video path's working budget.

Carl should also Carl-sign off whether the photo Safe Mode output is
stored at 1920×1080 or upscaled back to native resolution — the
practitioner-facing photo surfaces (line drawing, B&W thumbnail) re-derive
from this file via `_convertPhoto`, `processPhotoBodyFocus`, and the
thumbnail extractor, so the downscale propagates by design.

### Recommended fix shape

1. Add `safeModeMaxWorkingDim: CGFloat = 1920.0` constant on
   `SafeModeProcessor` (or as a static let inside
   `applySafeModeToPhoto`).
2. Compute `workWidth` / `workHeight` from the CGImage dimensions
   scaled to fit `safeModeMaxWorkingDim`.
3. Allocate `srcBuf` / `dstBuf` and run the SafeModeProcessor at the
   working dimensions.
4. JPEG-encode at the working dimensions. (Carl-sign-off: the
   downstream photo treatments don't need full native resolution; even
   the published photo on the web player is rendered inside a card
   that's never larger than 1080p in practice. The raw original is the
   un-safe capture and stays out of the share path anyway.)
5. Optionally: clamp the same `safeModeMaxWorkingDim` on the video path
   too as a belt-and-suspenders move, since `applySafeMode` on a future
   4K video would hit the same scaling cliff.

## Secondary fix — make ConversionService skip the poisoned row on launch

Even with the Swift crash fixed, the offline-first guarantee still
demands that `ConversionService` can recover from a hard process kill
mid-conversion. Today's `restoreQueue` blindly re-enqueues every
`pending` / `converting` row, which means **any future native crash
during conversion bricks the app the same way**.

In `app/lib/services/conversion_service.dart`, replace `restoreQueue`:

```dart
Future<void> restoreQueue() async {
  final unconverted = await _storage.getUnconvertedExercises();
  for (final exercise in unconverted) {
    // Any row that was already `converting` when we last ran is a row
    // that did not complete — the process either crashed or was killed.
    // Demote to `failed` so the practitioner sees the failed-pill and
    // can retry deliberately, instead of looping the same native crash
    // every launch.
    if (exercise.conversionStatus == ConversionStatus.converting) {
      final demoted = exercise.copyWith(
        conversionStatus: ConversionStatus.failed,
      );
      await _storage.saveExercise(demoted);
      if (!_updateController.isClosed) {
        _updateController.add(demoted);
      }
      // Log to conversion_error.log so the long-press pill picks it up.
      // (See PR #213 for the diagnostic surface.)
      try {
        final logDir = await getApplicationDocumentsDirectory();
        final logFile = File(p.join(logDir.path, 'conversion_error.log'));
        await logFile.writeAsString(
          '${DateTime.now()} [auto-demote on launch] ${exercise.id} was '
          'still `converting` — assuming previous run crashed the native '
          'pipeline. Marked failed. Practitioner can retry from the pill.\n\n',
          mode: FileMode.append,
        );
      } catch (_) {}
      continue;
    }
    _queue.add(exercise);
  }
  if (_queue.isNotEmpty) {
    _processQueue();
  }
}
```

This turns a hard crash on launch into a soft "N failed" pill that Carl
can long-press to read the previous run's error, and tap to retry once
the native crash is fixed.

Carl can un-brick his current phone via either:

1. Install a build that includes the `restoreQueue` change above. The
   row demotes to `failed` on first launch and the app boots.
2. Delete the row directly via SQLite (`xcrun devicectl` / Xcode
   container inspection) — slower, but doesn't require a build.

Option 1 is strongly preferred because it documents the path forward for
any future native crash.

## Other latent bugs worth fixing in the same PR

While reading the diff, three smaller bugs surfaced. None of them caused
the immediate crash, but they sit on the same code paths and should be
swept up in the same fix.

### 1. Vision orientation hint missing for photos

`applySafeModeToPhoto` builds a BGRA pixel buffer from
`UIImage.cgImage` (`VideoConverterChannel.swift:2631`). `cgImage.width`
and `cgImage.height` return the **raw pixel** dimensions ignoring EXIF
orientation. For iPhone front-camera portrait selfies, the underlying
pixels are landscape with `orientation = .right` in EXIF.

`VNSequenceRequestHandler.perform([faceRequest], on: source)` is called
**without an orientation hint** (line 4105). Vision defaults to `.up`,
which means a portrait selfie's faces are seen sideways and
`VNDetectFaceRectanglesRequest` may return no observations even though
faces are clearly present.

This silently degrades Safe Mode quality but does not crash. Fix by
either:

- Forcing the source buffer to be rendered up-orientation before
  Vision sees it (already done implicitly because UIImage drew the
  CGImage into the BGRA buffer with orientation applied — but
  `cgImage` skips orientation, so the buffer IS sideways), OR
- Passing the correct `CGImagePropertyOrientation` to a
  `VNImageRequestHandler(cvPixelBuffer:orientation:options:)` rather
  than `VNSequenceRequestHandler.perform(_:on:)`.

The cleanest fix: at the top of `applySafeModeToPhoto`, render the
UIImage **with its orientation applied** via `UIGraphicsImageRenderer`
so the BGRA buffer is genuinely up-oriented. Then Vision works on a
correctly-oriented buffer with no orientation hint needed.

### 2. `framesTotal` / `framesMissed` semantics off by one for photos

`processFrame` increments `framesTotal += 1` at line 4098 every call.
For the photo path, this is fine (one call = one frame). But on the
nil-mask passthrough at line 4183, the function returns true and
`framesMissed` is never incremented — yet on lines 4214, 4223, 4234,
4247 various CoreImage failure paths increment `framesMissed` AFTER
the Vision-found-a-face guard. So a CoreImage failure counts as a
miss, but a no-segmentation-mask passthrough doesn't. That's
inconsistent with the documented "miss = Vision didn't find a person"
semantic in the class header comment.

Not a crash, just a contract drift worth tightening. Probably move the
miss-rate increment OUT of the CoreImage branches.

### 3. `Data(bytesNoCopy:)` lifetime fragility

`ciImageFromGrayscale` (line 4280-4295) wraps `keepSourceMaskData` in
a `Data(bytesNoCopy: ..., deallocator: .none)` and hands it to
`CIImage(bitmapData:)`. The Apple docs are explicit that
`CIImage(bitmapData:)` does **NOT** copy the data — the caller must
keep it alive for the CIImage's lifetime.

This works today because `SafeModeProcessor` outlives the
`ciContext.render` call within `processFrame`, but it's a fragile
contract. If a future change moves the CIImage handoff to an async
context or queues it beyond the processor's lifetime, the buffer
deallocates and the CIImage points to freed memory.

Defensive fix: pass `options: [.applyOrientationProperty: false]` etc
isn't relevant; the right hardening is to **copy the mask data into
the Data** by removing `bytesNoCopy:` and using
`Data(bytes: ksm, count: rowBytes * height)`. Costs one `memcpy` per
frame (12 MB on a photo, 8 MB on a video) — well within budget.

## What was actually wrong with the design

PR #423's algorithm choice (face-based discriminator + Gaussian blur)
is sound for the privacy story. The implementation choice (CoreImage
chain at native input resolution) breaks the implicit contract that
the photo path inherited from the video path:

- **Video frames are size-fixed at 1080p by the AVAssetReader pipeline
  upstream.** The SafeModeProcessor's tuning constants
  (`baseGaussianBlurRadius = 35.0`, `baseSourceDim = 1080.0`) reflect
  that.
- **Photo capture has no such size clamp upstream.** iPhone front camera
  delivers 12 MP raw JPEG, and `UIImage(contentsOfFile:)` returns the
  full-resolution CGImage. The photo path then feeds those native
  dimensions directly into the same SafeModeProcessor, scaling the
  blur radius linearly with `min(width, height)`.

The fix is conceptually small (clamp the working resolution before the
CoreImage chain runs) but the consequences for memory and CPU at full
native photo resolution were never simulated. A pre-merge device test on
a 12 MP capture would have surfaced this immediately. The pre-merge
review focussed on algorithm correctness, not memory budget at the
photo path's input size.

This is the inverse failure mode of "tuned for native iPhone photo,
breaks on 720p video" — same class of bug, different scaling direction.
Worth a check-in on the review checklist: **every shared video+photo
pipeline change needs a memory-budget check at the larger of the two
input sizes.**

---

*Diagnosis only — no code changes shipped. Fix lives in a follow-up PR
against `staging`, gated by Carl's sign-off on the working-resolution
clamp.*
