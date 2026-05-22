# 2026-05-22 — Safe Mode pipeline not blurring bystanders (diagnosis)

## Table of Contents

- [TL;DR](#tldr)
- [Symptom](#symptom)
- [Hypothesis chain](#hypothesis-chain)
- [Evidence](#evidence)
- [Root cause](#root-cause)
- [The four un-safe files](#the-four-un-safe-files)
- [Why PR #402 looked right but shipped broken](#why-pr-402-looked-right-but-shipped-broken)
- [Fix sketch](#fix-sketch)
- [Why this is not a one-line fix](#why-this-is-not-a-one-line-fix)
- [Cross-cutting impact: videos too](#cross-cutting-impact-videos-too)
- [Recommended next step](#recommended-next-step)
- [Pointers for the parallel agent](#pointers-for-the-parallel-agent)

## TL;DR

PR #402's Safe Mode upload swap covers exactly ONE of the four files the web
player uses to render a photo's B&W / Original treatments. The other three
(`*.segmented.jpg`, `_thumb_bw.jpg`, `_thumb_color.jpg`) are still derived
from the raw un-safe capture and overwrite the Safe variant's privacy
guarantee at the consumer end. The Hero / lobby / active-slide selector in
`web-player/exercise_hero.js` prefers two of those un-safe files OVER the
swapped one, which is why Carl saw both people fully visible on the web
player despite the banner having fired at capture time.

## Symptom

iPhone staging build `1c2fd06`. Carl captured a photo of himself + bystander
inside his enforcing premises polygon, saw the Safe Mode banner on the
viewfinder, published, opened the URL on the web player, and observed:

- Bystander fully visible in B&W treatment. No coral silhouette anywhere.
- Carl himself also fully visible (expected — he is the largest person).
- Items 50-54 + 88 of the 2026-05-21 test list all fail.

## Hypothesis chain

The brief listed six hypotheses. Working through them:

1. **Photo Safe Mode native pass never ran.** REJECTED.
   `processPhotoSafeMode` is defined in `app/ios/Runner/VideoConverterChannel.swift`
   at line 393 (channel routing) + line 2563 (`applySafeModeToPhoto`).
   `app/lib/services/conversion_service.dart:1032-1036` invokes it via
   `_videoChannel.invokeMethod('processPhotoSafeMode', ...)` from inside the
   photo branch of `_convert()`. Both sides of the channel exist and the
   call site is wired.

2. **Pass ran, segmentation found no bystander.** REJECTED on the symptom.
   If Vision had returned zero observations the `framesMissed/framesTotal`
   ratio would be 1.0, which exceeds `kSafeModeMaxMissRate=0.05`. The Dart
   `_processQueue` at line 237-243 then throws `SafeModeRejection` and
   deletes the exercise. Carl's photo published successfully, so Vision
   DID find at least one human (himself), miss-rate was below 5%, and
   `safeRawFilePath` got stamped on the row.

3. **`safe_raw_file_path` not populated in SQLite.** REJECTED.
   `conversion_service.dart:267-269` writes the path via `copyWith` and
   `_storage.saveExercise(done)` at line 557 persists it. SQLite v44
   carries the column (`local_storage_service.dart:1280`).

4. **Upload service doesn't pick `safe_raw_file_path` for photos.** REJECTED.
   `upload_service.dart:2431-2433` checks `useSafeVariant`; line 2435-2436
   selects `safeRawFilePath` over `rawFilePath`; the upload at line
   2500-2504 writes to the same key (`{practice}/{plan}/{exercise}.jpg`)
   with `upsert: true`. The swap works.

5. **Upload uses wrong key.** REJECTED. Storage path is unchanged
   (`{practice}/{plan}/{exercise}.jpg` for photos, `.mp4` for videos).

6. **Stale `get_plan_full` URL.** REJECTED. `get_plan_full` synthesises
   signed URLs at call time from the storage key. Whatever bytes are at
   that key get served. No URL caching.

The smoking gun is none of those six. It's a SEVENTH hypothesis the brief
didn't enumerate.

## Evidence

`web-player/exercise_hero.js:225-264` — `pickPrimarySrc(exercise, treatment, bodyFocus)`
is the single source of truth for what URL the web player renders as the
photo's active media (slide + lobby Hero):

```js
function pickPrimarySrc(exercise, treatment, bodyFocus) {
  if (!exercise) return null;
  if (treatment === 'bw') {
    var isPhoto = exercise.media_type === 'photo' || exercise.media_type === 'image';
    if (isPhoto && exercise.thumbnail_url_bw) return exercise.thumbnail_url_bw;  // <-- (A)
    if (bodyFocus) {
      return exercise.grayscale_segmented_url || exercise.grayscale_url || null; // <-- (B)
    }
    return exercise.grayscale_url || exercise.grayscale_segmented_url || null;   // <-- (C)
  }
  if (treatment === 'original') {
    if (bodyFocus) {
      return exercise.original_segmented_url || exercise.original_url || null;   // <-- (D)
    }
    return exercise.original_url || exercise.original_segmented_url || null;
  }
  return exercise.line_drawing_url || exercise.media_url || null;
}
```

`bodyFocus = exercise.body_focus !== false` at line 402. `false === false`
yields true, so `bodyFocus = false` (matches the mobile default). Photo B&W
therefore falls to arm **(A)** first, then **(C)**.

The four cloud files involved:

| Field | Storage key | Bucket | Safe-aware in PR #402? |
|---|---|---|---|
| `thumbnail_url_bw` | `{plan}/{exercise}_thumb_bw.jpg` | media (public) | **NO** |
| `grayscale_url` | `{practice}/{plan}/{exercise}.jpg` | raw-archive | **YES** — swap works |
| `grayscale_segmented_url` | `{practice}/{plan}/{exercise}.segmented.jpg` | raw-archive | **NO** |
| `thumbnail_url_color` | `{practice}/{plan}/{exercise}_thumb_color.jpg` | raw-archive | **NO** |

Arm **(A)** fires whenever `_thumb_bw.jpg` exists. That file is produced by
`_extractPhotoThumbnailVariants` in
`app/lib/services/conversion_service.dart:525-532`, which is fed
`rawPath: rawAbs` (line 526) — the un-safe raw capture. Same for
`_thumb_color.jpg`. The `.segmented.jpg` is produced by
`processPhotoBodyFocus` (`conversion_service.dart:1085-1105`), which calls
`ClientAvatarProcessor` — that applies a body-focus blur (foreground
person stays crisp, background dims) and treats ALL detected humans as
foreground. It does not blur or paint bystanders.

So the active slide in B&W gets the public, raw-derived `_thumb_bw.jpg`,
and Carl sees both people in full clarity.

## Root cause

PR #402 (Safe Mode completion) treated the upload swap as a per-key
operation on the canonical raw file (`.jpg` for photos, `.mp4` for videos)
and forgot that the web player reads from FOUR keys per treatment, three of
which are derived files baked from the raw capture by independent passes in
the conversion service. The safe variant overwrites the canonical raw at
cloud key `.jpg`, but the player prefers `_thumb_bw.jpg` over
`grayscale_url` AND uses `_thumb_color.jpg` for the Original lobby Hero AND
serves the segmented body-focus JPG over the raw JPG when body_focus is on.
None of those three derived files are produced from safe bytes.

Concretely:

1. `_extractPhotoThumbnailVariants` reads `rawPath: exercise.absoluteRawFilePath`
   (conversion_service.dart:526). It needs to read the safe variant when
   `safeRawFilePath != null && safeModeActive == true`.
2. `_convertPhotoBodyFocus` reads `inputPath: exercise.absoluteRawFilePath`
   (conversion_service.dart:1092). Same issue. The body-focus pass itself
   is also fundamentally not bystander-aware — it preserves all detected
   humans, which is the wrong semantic for Safe Mode.
3. The upload loop at `upload_service.dart:2289-2369` uploads
   `.segmented.jpg` from the unmodified segmented file. Even if its source
   were the safe variant, the body-focus pass over the safe variant would
   restore the safe-painted bystander pixels because the segmented pass
   per-pixel composites RGB from the source (the safe pixel) but body-pop
   blur sources its background-dimmed pixels from the same source. So the
   coral region would persist, but it would also pull the upstream
   composite logic order. Worth testing rather than assuming.

## The four un-safe files

For an audit + fix planning surface — exact line refs.

**`_thumb_bw.jpg`** (lobby Hero + active slide primary for photo B&W)
- Generation: `conversion_service.dart:525-532` (`_extractPhotoThumbnailVariants` call site) feeds raw.
- Native isolate: `conversion_service.dart:2412-2500` ish — re-decodes raw, applies CSS-grayscale equivalent + contrast 1.05 in code.
- Upload: `upload_service.dart` near line 1991+ (`uploadMedia` to media bucket).
- URL emission: `supabase/migrations/20260516144710_photo_thumb_bw.sql:263-278`.

**`_thumb_color.jpg`** (lobby Hero for Original; B&W when `_thumb_bw.jpg` missing)
- Generation: same call as above. `colorOutPath: colorPath` at line 529.
- Upload: `upload_service.dart:2614` (raw-archive bucket).
- URL emission: `supabase/migrations/20260516144710_photo_thumb_bw.sql:228-252`.

**`.segmented.jpg`** (active slide for photo B&W when body_focus ON)
- Generation: `conversion_service.dart:1085-1105` (`_convertPhotoBodyFocus`).
- Native: `processPhotoBodyFocus` channel method — body-pop blur, no bystander logic.
- Upload: `upload_service.dart:2311-2369`.
- URL emission: `supabase/migrations/20260513161415_photo_thumb_variants.sql:123-138`.

**`.jpg` (safe-swap winner)** (active slide for photo B&W when body_focus OFF + no `_thumb_bw.jpg`)
- This is the only one PR #402 covers.
- Upload: `upload_service.dart:2425-2519` (the photo branch).
- URL emission: `supabase/migrations/20260513161415_photo_thumb_variants.sql:96-102`.

## Why PR #402 looked right but shipped broken

The PR description focuses on "upload swap" for the raw archive bucket
photo + video keys, and the code review focused on the swap logic +
`useSafeVariant` plumbing. None of the reviewers traced what the web
player actually reads when rendering a photo in B&W — that path goes
through `pickPrimarySrc` → `thumbnail_url_bw` FIRST. The mismatch between
"upload swap covers the raw archive .jpg" and "web player reads four
different bucket entries" is the kind of cross-surface gap that's invisible
from any single file diff.

Two surfaces were updated in the same PR (mobile + DB), but the third
surface (the consumer — `web-player/exercise_hero.js` + `app.js`) was
treated as already correct because its URLs hadn't moved. They hadn't
moved, but their UPSTREAM files were never re-derived from safe bytes.

## Fix sketch

Two plausible shapes:

### Shape A — feed safe bytes into every downstream pass

`conversion_service.dart` runs the safe pass FIRST, then feeds
`safePhotoPath` (when present) into every variant generator instead of
`rawAbs`. Concretely:

1. Run `processPhotoSafeMode` before the body-focus + thumbnail-variant
   passes (currently it runs LAST in the photo branch).
2. If `safePhotoPath != null` AND `safePhotoActive`:
   - Use `safePhotoPath` as the source for `_extractPhotoThumbnailVariants`
     (line 526's `rawPath:` argument).
   - Use `safePhotoPath` as the source for `_convertPhotoBodyFocus`
     (line 1092's `inputPath` argument).
   - Use `safePhotoPath` as the source for the line-drawing conversion at
     `_convertPhoto` (line 968). Otherwise the line drawing itself betrays
     bystander identity through silhouette.
3. Same logic for the video pipeline — when the safe writer fired and
   produced `_safe.mp4`, all downstream extractions (thumbnails,
   segmented, mask) need to read from `_safe.mp4`. Today they all read
   from the raw archive.

Pros: localizes the change to the conversion service. Upload service +
DB unchanged. Native pipeline unchanged.

Cons: re-orders the conversion pipeline. The line-drawing tuning is
LOCKED at v6 per `CLAUDE.md` — feeding safe pixels (with coral patches)
into the line-drawing edge detector will change line output for any
plan with bystanders. Probably acceptable (de-identification was already
the design intent of line drawing) but needs sign-off.

### Shape B — apply safe paint to every downstream variant separately

Each downstream pass calls its own coral-paint step after generating its
output:

1. `_extractPhotoThumbnailVariants` runs SafeModeProcessor over its outputs.
2. `processPhotoBodyFocus` does the same.
3. The video-side passes (segmented, mask, thumb_color) do the same.

Pros: each variant keeps its current creative semantic; we just bolt on
bystander coral at the end.

Cons: 4x the Vision calls per capture (each pass independently runs
person rect + person segmentation). Photos are one-shot so fine; videos
are 30fps and re-running per frame is non-trivial. Also requires
threading the Vision results from the safe pass into the other passes
to amortise the cost, which is most of the work of Shape A anyway.

Recommendation: **Shape A**, with explicit Carl signoff on whether the
line drawing should be fed safe pixels too (probably yes — bystander
silhouette is identity). Specifically:

```dart
// conversion_service.dart — photo branch, around line 967
//
// New order: safe pass FIRST. Returns either the safe-painted JPG path
// or null. All subsequent passes accept either the raw or the safe
// path as their canonical source.
String? safePhotoPath;
double safePhotoMissRate = 0.0;
final safePhotoActive = _isSafeModeActive();
if (safePhotoActive) {
  // ... existing processPhotoSafeMode call, but here ...
}
final canonicalSource = safePhotoPath ?? exercise.absoluteRawFilePath;

// Now run line-drawing conversion from canonicalSource:
await _convertPhoto(canonicalSource, convertedPath);

// And the body-focus pass:
await _convertPhotoBodyFocus(canonicalSource, segmentedCandidate);

// And the thumbnail variants:
await compute(_extractPhotoThumbnailVariants, _PhotoThumbArgs(
  rawPath: canonicalSource,
  // ... rest unchanged
));
```

Same shape for the video branch — pass `safeOutputPath` as the canonical
source to the thumbnail extraction loops in `_processQueue` (lines
299-440 ish, the video-thumbnail block).

Three more things to land alongside:

1. **Capture-time stamp wins over runtime check.** The photo Safe Mode
   pass currently re-reads `SafeModeService.instance.isActive` at
   conversion time (`conversion_service.dart:1024`). Conversion happens
   asynchronously after capture; if Carl walks out of the polygon
   between shutter and conversion, the safe pass is skipped even though
   `exercise.safeModeActive == true` at capture time. The capture-time
   stamp on the exercise model is the source of truth. Replace the
   runtime check with `exercise.safeModeActive`.

2. **Body-focus segmented variant deserves a Safe Mode review.** Even
   when fed safe pixels, the body-focus pass's "preserve all detected
   humans" semantic clashes with Safe Mode. The bystander, having been
   painted coral by the safe pass, is no longer a human in the pixels —
   Vision's person segmentation in body-focus probably won't detect them,
   so body-focus dim should affect everything except Carl. Verify on a
   real capture before shipping.

3. **`_thumb_bw.jpg` (and `_thumb_color.jpg`) need re-upload triggering
   when their source bytes changed.** The existing skip-if-exists logic
   in the upload loops will leave the un-safe thumbnails in cloud unless
   forced. Either bump a SQLite flag (`safeVariantApplied`) and force
   re-upload when that's set, or unconditionally `upsert: true` the
   thumbnail variants on every Safe Mode publish.

## Why this is not a one-line fix

- The conversion order has to change (safe pass moves from LAST to FIRST
  in the photo branch).
- Multiple call sites feed `rawAbs` to native; each needs the conditional
  swap.
- The video pipeline has the same structural issue and the safe writer
  there runs concurrently with the other writers, not sequentially —
  re-ordering to "safe first, then others read safe" requires a different
  shape on iOS (currently all four writers drain in parallel from the
  same source frame in `convertVideo`).
- The upload loops for `.segmented.*`, `_thumb_bw.jpg`, `_thumb_color.jpg`
  need to force re-upload (override exists-skip) when the safe variant
  applies, mirroring the S-C2 fix that PR #403 added for the main `.jpg`
  branch.
- The line-drawing tuning is LOCKED at v6 — feeding safe pixels into the
  line-drawing edge detector is a v6 violation that needs explicit Carl
  signoff regardless of how obvious it sounds.

A minimum-viable hotfix could land just the photo branch first
(re-order safe pass to first, feed safe path to downstream passes, force
re-upload of derived variants), and queue the video branch + line-drawing
question for a follow-up. Even the photo-only patch is 4-6 file edits
across conversion_service.dart + upload_service.dart + at least one new
SQLite flag + the native side's photo helper (if line drawing now reads
from `_safe.jpg`).

## Cross-cutting impact: videos too

Same structural issue applies to videos. `get_plan_full` for a video B&W:

1. `grayscale_url` → `.mp4` in raw-archive (safe-swap covers this).
2. `grayscale_segmented_url` → `.segmented.mp4` in raw-archive (NOT safe).
3. `thumbnail_url_color` → `_thumb_color.jpg` in raw-archive (NOT safe).
4. `thumbnail_url_line` → `_thumb_line.jpg` in media bucket (line drawing
   derived from raw frames — not safe).

Active slide rendering picks segmented when body_focus is on. Lobby Hero
picks thumb_color. Without fixing the video pipeline, the same bystander
leak ships on videos.

The video pipeline's safe writer (`safeOutputPath` in `convertVideo`) is
documented at `VideoConverterChannel.swift:281-298` and writes a real
`.mp4`. The segmented + mask + thumb_color extraction sites need to swap
to it analogous to the photo fix.

## Recommended next step

Spawn a focused sub-agent on a single branch
`fix/safe-mode-downstream-variants` targeting `staging`. Scope:

1. Photo branch first (faster iteration, no AVAssetWriter to wrestle).
   Re-order `_convert` photo branch: safe pass → line + body-focus +
   thumbnails all sourced from safe.
2. Force re-upload of `.segmented.jpg`, `_thumb_bw.jpg`, `_thumb_color.jpg`
   when `exercise.safeModeActive == true`. Mirror the S-C2 fix shape
   from PR #403.
3. Video branch second. Either feed `_safe.mp4` into the segmented + mask
   + thumb extractors, or accept that video Safe Mode is a follow-up
   wave (photos alone unblock items 50-54).
4. Switch the conversion-time gate from `SafeModeService.instance.isActive`
   to `exercise.safeModeActive` so an exercise captured under Safe Mode
   keeps its safe pipeline even if the practitioner leaves the polygon.

Test on device: capture a photo with Carl + bystander inside the polygon,
publish, open web player, verify the bystander shows coral in B&W AND
in Original AND in the lobby Hero. Then test the same for video.

Do NOT mark items 50-54 + 88 of the 2026-05-21 test list as
re-verifiable until all three downstream files honour the safe variant.

## Pointers for the parallel agent

The parallel sub-agent on `feat/safe-mode-camera-and-studio-redesign`
should NOT touch:

- `app/lib/services/conversion_service.dart` — the fix re-orders the
  photo + video conversion branches.
- `app/lib/services/upload_service.dart` — the fix extends the
  Safe Mode swap logic into the `.segmented.*` and thumbnail upload
  loops.
- `app/ios/Runner/VideoConverterChannel.swift` — the fix may need to
  add a Swift-side helper that feeds `processPhotoSafeMode`'s output
  into `_convertPhoto` / `processPhotoBodyFocus` without a Dart-side
  round trip.

Files the parallel agent is presumably safe to modify (camera UI +
Studio toggle + editor default): `app/lib/screens/capture_mode_screen.dart`
(banner/icon area only — leave the `safeModeActive` stamp at line 1118-
1127 alone), the various Studio screen files, and any new safe-mode
related widget files. If they need to touch `capture_mode_screen.dart`'s
persist path, coordinate to merge order.
