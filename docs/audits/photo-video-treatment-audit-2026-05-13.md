# Photo vs Video Treatment Audit — 2026-05-13

## Table of Contents

- [Executive summary](#executive-summary)
- [Current state per surface](#current-state-per-surface)
  - [1. Web player — lobby hero strip](#1-web-player--lobby-hero-strip)
  - [2. Web player — active slide playback](#2-web-player--active-slide-playback)
  - [3. Web player — prep-phase countdown hero](#3-web-player--prep-phase-countdown-hero)
  - [4. Web player — share-as-PNG snapshot](#4-web-player--share-as-png-snapshot)
  - [5. Embedded workflow Preview (iOS WKWebView)](#5-embedded-workflow-preview-ios-wkwebview)
  - [6. Mobile filmstrip on ClientSessionsScreen](#6-mobile-filmstrip-on-clientsessionsscreen)
  - [7. Mobile MediaViewerBody (editor sheet Preview tab)](#7-mobile-mediaviewerbody-editor-sheet-preview-tab)
  - [8. Studio cards](#8-studio-cards)
- [Photo vs video divergence map](#photo-vs-video-divergence-map)
- [Gap analysis — current QA failures](#gap-analysis--current-qa-failures)
- [Proposed abstraction](#proposed-abstraction)
- [Edge cases](#edge-cases)
- [What's NOT in scope](#whats-not-in-scope)

## Executive summary

The four QA failures (B6, D13, F17, F21) all root to **three separate decisions about heroes/posters that are spelled out in eight places without sharing any contract**. Photos and videos diverge along five axes: source-file column (`rawFilePath` vs `archiveFilePath`), thumbnail pipeline (single raw JPG vs three native-extracted variants `_thumb.jpg` / `_thumb_color.jpg` / `_thumb_line.jpg`), poster URL shape on the wire (`thumbnail_url` only vs `thumbnail_url` + `thumbnail_url_line` + `thumbnail_url_color`), grayscale realisation (CSS filter vs ColorFilter.matrix), and body-focus availability (N/A vs per-exercise).

The most consequential divergence is in the web player lobby: a single `activeTreatment` variable drives every hero in the row strip (B6 — global leak), `pickTreatmentPoster` reads three URL fields that don't exist on the public cloud-fetched surface (D13 — snapshot ignores active treatment), `_pickFilmstripHeroes` clamps photos to a single cell by design (F17 — three photos → one cell), and the photo conversion path stamps `thumbnailPath = rawFilePath` directly without producing line/color variants (F21 — preview can't choose a treatment for photos the same way it does for videos).

Recommended fix: a single `resolveExerciseHero(exercise, treatment, bodyFocus, surface)` resolver per surface (web JS + Flutter Dart) returning `{ url, posterUrl, dom: { class, filter }, caps: { bodyFocusAvailable, treatments: [...] } }`. Adopting it would trivially fix B6 (resolver is per-exercise) and D13 (poster URL is treatment-correct). F17 needs a discrete rule change in `_pickFilmstripHeroes`. F21 needs the photo conversion path to produce variant files, which is a separate ticket but unblocks adoption symmetry. ETA hand-wave: 1 PR for the resolver + B6/D13 callsites; 1 small PR for F17 rule; 1 medium PR for F21's photo variant pipeline.

## Current state per surface

For every surface below: source-of-truth function, treatment + body-focus resolution, photo vs video branching, state scope.

### 1. Web player — lobby hero strip

**Source-of-truth function:** `renderHeroHTML(slide, objPos)` at `web-player/lobby.js:1106`, called from `exerciseRowHTML` at `web-player/lobby.js:662`. Posters are picked via `pickTreatmentPoster(slide, treatment)` at `web-player/lobby.js:1095`.

**Treatment resolution:** Reads the **module-level** `activeTreatment` (initialised at `lobby.js:62` from `api.getDefaultTreatment()`, which lives at `web-player/app.js:5514`). `getDefaultTreatment` picks the **first non-rest exercise's** `getEffective(s, 'treatment')` and applies it to the entire lobby:

```js
// web-player/app.js:5514
getDefaultTreatment: function () {
  for (let i = 0; i < slides.length; i++) {
    const s = slides[i];
    if (s && s.media_type !== 'rest') {
      const t = getEffective(s, 'treatment');
      if (t === 'bw' && !planHasGrayscaleConsent) return 'line';
      if (t === 'original' && !planHasOriginalConsent) return 'line';
      return t || 'line';
    }
  }
  return 'line';
},
```

`renderHeroHTML` then renders every row using that single `activeTreatment` — not `getEffective(slide, 'treatment')` per row:

```js
// web-player/lobby.js:1109
const url = api.resolveTreatmentUrl
  ? api.resolveTreatmentUrl(slide, activeTreatment)
  : (slide.line_drawing_url || slide.thumbnail_url || null);
// ...
const posterSrc = pickTreatmentPoster(slide, activeTreatment);
```

**Body focus resolution:** Indirectly via `resolveTreatmentUrl(slide, activeTreatment)` at `web-player/app.js:1581`, which reads `getEffective(exercise, 'bodyFocus')` per-exercise. So body-focus IS per-exercise even when treatment is plan-global — an asymmetric state-scope choice.

**Photo vs video branching:** Inside `renderHeroHTML`:
- Photo (`isPhoto = slide.media_type === 'photo' || 'image'`) → always renders `<img>`, applies `is-grayscale` CSS class when `activeTreatment === 'bw'`. Uses `url` (treatment URL) or `posterSrc` (treatment poster); both point at the same JPG for photos.
- Video → renders `<img>` (NOT `<video>`) as a static poster, with `data-video-src` carrying the actual video URL. `swapToVideoOnActiveRow` at `web-player/lobby.js:1713` replaces the `<img>` with a `<video>` on the active row only (single-active-decoder rule from PR #255).

**Treatment poster URL shape divergence:** `pickTreatmentPoster` reads three fields that only exist on the **embedded** surface (mobile WKWebView):

```js
// web-player/lobby.js:1095
function pickTreatmentPoster(slide, treatment) {
  if (!slide) return '';
  const legacy = slide.thumbnail_url || '';
  if (treatment === 'line') {
    return slide.thumbnail_url_line || legacy;
  }
  return slide.thumbnail_url_color || legacy;
}
```

The public web player's `api.js` `_normaliseExercise` at `web-player/api.js:244` **does not normalise `thumbnail_url_line` / `thumbnail_url_color`** — the cloud RPC `get_plan_full` and `upload_service.dart:1094` only write the single `thumbnail_url` column. The embedded preview's `unified_preview_scheme_bridge.dart:326-333` *does* emit all three:

```dart
// app/lib/services/unified_preview_scheme_bridge.dart:326
'thumbnail_url_line': (e.thumbnailPath != null && e.thumbnailPath!.isNotEmpty)
    ? '/local/${e.id}/hero_line'
    : null,
'thumbnail_url_color': (e.thumbnailPath != null && e.thumbnailPath!.isNotEmpty)
    ? '/local/${e.id}/hero_color'
    : null,
```

So on the public surface, every row's `posterSrc` falls back to the legacy `thumbnail_url` regardless of treatment — and the legacy thumbnail is the **B&W variant** for videos (extracted with `grayscale: true` at `conversion_service.dart:240`), and the **raw color JPG** for photos (`conversion_service.dart:343-345`).

**State scope:** treatment = plan-global (single `activeTreatment` for the lobby); body-focus = per-exercise via `getEffective`.

### 2. Web player — active slide playback

**Source-of-truth function:** `buildMedia(exercise, index)` at `web-player/app.js:1424`, called per slide inside `buildCard`. Treatment resolves via `slideTreatment(exercise)` at `web-player/app.js:385`; URL via `resolveTreatmentUrl(exercise, treatment)` at `web-player/app.js:1581`.

**Treatment resolution:** Strictly per-exercise:

```js
// web-player/app.js:385
function slideTreatment(exercise) {
  const hasGray = !!(exercise && (exercise.grayscale_segmented_url || exercise.grayscale_url));
  const hasOrig = !!(exercise && (exercise.original_segmented_url || exercise.original_url));
  const candidate = getEffective(exercise, 'treatment');
  if (candidate === 'bw' && !hasGray) return 'line';
  if (candidate === 'original' && !hasOrig) return 'line';
  return candidate || 'line';
}
```

`getEffective` layers client overrides (the gear popover, mid-workout) over practitioner defaults from `preferred_treatment`.

**Body focus resolution:** Per-exercise via `getEffective(exercise, 'bodyFocus')`. `resolveTreatmentUrl` consumes it:

```js
// web-player/app.js:1586
if (treatment === 'bw') {
  if (bodyFocusOn) {
    return exercise.grayscale_segmented_url || exercise.grayscale_url || null;
  }
  return exercise.grayscale_url || exercise.grayscale_segmented_url || null;
}
```

**Photo vs video branching:** `buildMedia` at `web-player/app.js:1452`:
- Video → emits a `.video-loop-pair` with two stacked `<video>` slots (Wave 19.7 dual-video crossfade). Poster set via `posterAttr = exercise.thumbnail_url ? "poster=..." : ''` — **uses the legacy single `thumbnail_url` (B&W variant), regardless of active treatment.**
- Photo → emits `<img src="${resolvedUrl}" class="${grayscaleClass}">`. The src IS treatment-correct (line drawing JPG vs raw colour JPG), and `is-grayscale` CSS class flips on for B&W.

**State scope:** treatment + body-focus both per-exercise — but the `<video>` poster attribute uses `thumbnail_url` (always B&W for videos) so the freeze-frame between unloads doesn't match the active treatment.

### 3. Web player — prep-phase countdown hero

**Source-of-truth function:** `buildPrepOverlay(slide)` at `web-player/app.js:1178` (in the worktree's branch) / staging-head fix from PR #316 lands at the same line on `76af230`.

**Worktree state (older — pre-PR #316):**

```js
// web-player/app.js:1178 (worktree)
function buildPrepOverlay(slide) {
  const heroSrc = slide && slide.thumbnail_url
    ? `<img class="hero-poster" src="${escapeHTML(slide.thumbnail_url)}" alt="" aria-hidden="true">`
    : '';
  return `
    <div class="prep-overlay" hidden>
      ${heroSrc}
      <div class="prep-overlay-number">15</div>
    </div>
  `;
}
```

**Staging-head state (post-PR #316, commit `5e5b474`):**

```js
function buildPrepOverlay(slide) {
  if (!slide || !slide.thumbnail_url) { /* digit only */ }
  const slideT = slideTreatment(slide);
  const grayscaleClass = slideT === 'bw' ? ' is-grayscale' : '';
  return `
    <div class="prep-overlay" hidden>
      <img class="hero-poster${grayscaleClass}" data-treatment="${slideT}" src="${escapeHTML(slide.thumbnail_url)}" alt="" aria-hidden="true">
      ...
```

Even after the staging fix, `buildPrepOverlay` still uses `slide.thumbnail_url` (the single legacy field). It applies `is-grayscale` CSS class for `bw`, and **no class for `line` or `original`**. Since `thumbnail_url` for VIDEOS is the B&W-from-raw variant (`_thumb.jpg`, extracted with `grayscale: true`), the `line` and `original` prep posters both render **B&W**.

**Photo vs video branching:** None — `buildPrepOverlay` does not branch on `media_type`. Photos and videos both feed `slide.thumbnail_url` straight to `<img src>`. For photos, `thumbnail_url` IS the raw color JPG (stamped from `rawFilePath` at `conversion_service.dart:343`), so a photo's prep hero IS treatment-correct for `original`, accidentally-grayscale for `bw` via the CSS filter, and **wrong (color when line should be line)** for `line`.

**State scope:** per-slide (function takes one slide).

### 4. Web player — share-as-PNG snapshot

**Source-of-truth function:** `triggerLobbyShare()` at `web-player/lobby.js:2260` + `preloadAsDataUrls(rootEl)` at `web-player/lobby.js:2197`.

**Treatment resolution:** Inherits whatever the live DOM currently shows. The snapshot path swaps `img.src` → data URL (lines 2299-2309) and `v.poster` → data URL (lines 2310-2316) for html2canvas to rasterise. The poster URL is whatever the row was rendered with (per §1 above — `pickTreatmentPoster(slide, activeTreatment)`).

**Photo vs video branching:** All inactive rows are `<img>` (treatment-aware src per §1). The single active row is a `<video>` (after `swapToVideoOnActiveRow`). The snapshot relies on the video's `poster` attribute:

```js
// web-player/lobby.js:1746
if (v.dataset.posterSrc) v.setAttribute('poster', v.dataset.posterSrc);
```

`data-poster-src` carries `pickTreatmentPoster(slide, activeTreatment)` from line 1186 — on the public surface that's the legacy `thumbnail_url` (B&W for videos) regardless of active treatment.

**Critical gap:** The video's `poster` attribute is a plain URL — html2canvas reads it as an image **without** the `is-grayscale` CSS class that was applied to `<img>` siblings. So even in `bw` mode where the rest of the lobby's CSS filter renders correctly, the active video row's poster in the PNG is whatever's at the URL (which IS already B&W for videos → accidentally correct for `bw`, wrong for `original` if there were ever a color-variant).

**State scope:** snapshot inherits DOM at moment of trigger — per-row state from §1.

### 5. Embedded workflow Preview (iOS WKWebView)

**Source-of-truth functions:** Same JavaScript as §1-§4 (the WebView loads the mirrored `app/assets/web-player/` bundle). Differences come from the **iOS scheme handler bridging Dart**:

- `UnifiedPlayerSchemeHandler.swift` resolves `homefit-local://plan/...` URLs (`app/ios/Runner/UnifiedPlayerSchemeHandler.swift:86`).
- `UnifiedPreviewSchemeBridge` provides plan JSON + media file paths over a MethodChannel (`app/lib/services/unified_preview_scheme_bridge.dart`).

**Treatment resolution:** Same per-exercise model as the public web player. The bridge's `_exerciseToPayload` at `app/lib/services/unified_preview_scheme_bridge.dart:268` emits:

```dart
'preferred_treatment': e.preferredTreatment?.wireValue,
'line_drawing_url': lineUrl,
'grayscale_url': (consent.grayscale && archiveUrl != null) ? archiveUrl : null,
'original_url': (consent.original && archiveUrl != null) ? archiveUrl : null,
'grayscale_segmented_url': segmentedUrl,
'original_segmented_url': segmentedUrl,
```

**Body focus resolution:** `body_focus` field IS emitted (per `c4bf6ce` / `b8faaad` history — "fix(embedded-preview): forward body_focus from bridge so heroes don't pull segmented variant").

**Photo vs video branching:** Resolved in `_resolveMediaPath` at `app/lib/services/unified_preview_scheme_bridge.dart:168`:

```dart
case 'archive':
  if (exercise.mediaType == MediaType.photo) {
    relative = exercise.rawFilePath;     // photo → raw color JPG
  } else {
    relative = exercise.archiveFilePath;  // video → 720p H.264 mp4
  }
  break;
```

And in `_exerciseToPayload` at `:279`:

```dart
final archiveUrl = e.mediaType == MediaType.video && e.archiveFilePath != null
    ? '/local/${e.id}/archive'
    : (e.mediaType == MediaType.photo && e.rawFilePath.isNotEmpty
        ? '/local/${e.id}/archive'
        : null);
```

**Critically the embedded surface DOES emit `thumbnail_url_line` + `thumbnail_url_color`** (`:326-333`), but for photos the bridge's switch on `case 'hero_line'` / `case 'hero_color'` at `:214-221` reads `exercise.thumbnailPath` and applies `replaceFirst('_thumb.jpg', '_thumb_line.jpg')` — but for photos `thumbnailPath == rawFilePath` (per `conversion_service.dart:344`), so the replaceFirst is a no-op (the filename doesn't end in `_thumb.jpg`) and the resolved path is the raw color JPG **for all three** "treatments" of a photo.

**State scope:** treatment per-exercise + body-focus per-exercise (bridged from local SQLite); lobby treatment leak from §1 applies here too.

### 6. Mobile filmstrip on ClientSessionsScreen

**Source-of-truth function:** `_pickFilmstripHeroes(session)` at `app/lib/widgets/session_card.dart:38`. Per-cell rendering at `_FilmstripCell.build` at `:931` + `_FilmstripCell._resolveFile(ex)` at `:980` (or the staging-head version with `cacheWidth` param at the same line numbers in `c3078a4`).

**Treatment resolution:** Hardcoded — there is **no treatment selection** on the filmstrip. The cell builder always applies a B&W matrix filter for videos and renders photos as-is (line drawing JPG):

```dart
// app/lib/widgets/session_card.dart:957
if (exercise.mediaType == MediaType.video) {
  image = ColorFiltered(
    colorFilter: _kFilmstripGrayscale,
    child: image,
  );
}
return SizedBox.expand(child: image);
```

**Body focus resolution:** Not relevant — static thumbnail.

**Photo vs video branching:** The killer for F17:

```dart
// app/lib/widgets/session_card.dart:38
List<ExerciseCapture> _pickFilmstripHeroes(Session session) {
  final videos = <ExerciseCapture>[];
  for (final ex in session.exercises) {
    if (ex.isRest) continue;
    if (ex.mediaType == MediaType.video) {
      videos.add(ex);
      if (videos.length >= _kFilmstripMaxCells) break;
    }
  }
  if (videos.isNotEmpty) return videos;
  // No videos — fall back to the first photo (single cell).
  for (final ex in session.exercises) {
    if (ex.isRest) continue;
    if (ex.mediaType == MediaType.photo) return [ex];   // ← returns 1 photo
  }
  return const [];
}
```

The rule is "videos first, up to 4; if zero videos, **first photo only** (single cell)". Three photos render as a single-cell filmstrip showing only the first photo. That's F17 by design — not a bug in the rendering pipeline but in the picker rule.

And `_resolveFile` per-cell for photos at `:990`:

```dart
final f = File(ex.displayFilePath);  // line-drawing converted JPG
if (!f.existsSync()) return null;
return f;
```

Photos always render the line drawing. Combined with the videos-only B&W ColorFilter, the filmstrip ends up mixing-treatment (B&W videos + line-drawing photos) which is the documented intent in the docstring at `:920-923`.

**State scope:** plan-global (the picker selects from `session.exercises`).

### 7. Mobile MediaViewerBody (editor sheet Preview tab)

**Source-of-truth functions:**
- `_MediaViewerBodyState._effectiveTreatmentFor(ExerciseCapture e)` at `app/lib/screens/studio_mode_screen.dart:3992`.
- `_sourcePathForTreatment(ExerciseCapture e, Treatment t)` at `:4017`.
- `_hasArchive(e)` at `:3870` (branches `MediaType.video` → archive file; `MediaType.photo` → raw file).

**Treatment resolution:** Per-exercise via `exercise.preferredTreatment` with a fall-back when archive is missing:

```dart
// studio_mode_screen.dart:3992
Treatment _effectiveTreatmentFor(ExerciseCapture e) {
  final pref = e.preferredTreatment;
  if (pref == null) return Treatment.line;
  if (pref == Treatment.line) return Treatment.line;
  return _hasArchive(e) ? pref : Treatment.line;
}
```

**Body focus resolution:** Per-exercise via `e.bodyFocus`:

```dart
// studio_mode_screen.dart:3938
bool get _enhancedBackground => _current.bodyFocus ?? true;
bool get _enhancedBackgroundEnabled => _treatment != Treatment.line;
```

**Photo vs video branching:** `_sourcePathForTreatment` at `:4017`:

```dart
switch (t) {
  case Treatment.line:
    return e.displayFilePath;
  case Treatment.grayscale:
  case Treatment.original:
    if (_enhancedBackground) {
      final seg = e.absoluteSegmentedRawFilePath;
      if (seg != null && File(seg).existsSync()) return seg;
    }
    return e.absoluteArchiveFilePath;   // ← video-only path; photos have NO archive
}
```

**Gotcha:** `e.absoluteArchiveFilePath` is the 720p H.264 mp4 — never set for photos (per `gotcha_photo_video_local_path_asymmetry.md`). So for photos, the grayscale/original branch returns null and downstream playback shows the dark fallback. The MediaViewer correctly bails earlier via `_isVideo(_current)` check at `:4055` before `VideoPlayerController.file(File(path))`, so for photos it never reaches the broken path — but the body-focus pill still renders **for photos**:

```dart
// studio_mode_screen.dart:5148
if (!isVideo) {
  // Photo path — body focus only.
  return bodyFocus;
}
```

That's the "photo + body-focus toggle currently no-op" the brief calls out — the pill is rendered but `_onEnhancedBackgroundToggle` rebinds video which is a no-op for photos.

**State scope:** treatment + body-focus per-exercise (rebound on PageView swipe via `_initVideoForCurrent`).

### 8. Studio cards

**Source-of-truth function:** `StudioExerciseCard.build` at `app/lib/widgets/studio_exercise_card.dart:166` delegates to `MiniPreview(staticHero: true)` at `:211`.

**Treatment resolution:** `MiniPreview._treatmentFor(ex)` at `app/lib/widgets/mini_preview.dart:203`:

```dart
Treatment _treatmentFor(ExerciseCapture ex) =>
    ex.preferredTreatment ?? Treatment.line;
```

Per-exercise from the model field; no client overrides on this surface (practitioner only).

**Body focus resolution:** Implicit via `_videoPathFor` at `:218` — selects segmented variant when `bodyFocus ?? true`. Body-focus is not toggleable from Studio cards.

**Photo vs video branching:** `MiniPreview._buildMedia` at `:385`:

```dart
if (ex.mediaType == MediaType.photo) {
  return _PhotoFrame(exercise: ex, treatment: treatment);
}
if (widget.staticHero) {
  return _HeroFrameImage(
    exercise: ex,
    treatment: treatment,
    ...
  );
}
return _VideoFrame(...);
```

- `_PhotoFrame.build` at `:448` picks file by treatment: line → `absoluteConvertedFilePath`, grayscale/original → `absoluteRawFilePath`. Applies grayscale `ColorFilter.matrix` for grayscale. Has a fallback chain (treatment file → thumbnail → raw → converted → fallback widget).
- `_HeroFrameImage.build` at `:597` (video staticHero) reads `exercise.absoluteThumbnailPath` and does `replaceFirst('_thumb.jpg', '_thumb_line.jpg')` for Line, `replaceFirst('_thumb.jpg', '_thumb_color.jpg')` for Original, untouched for B&W (the default thumbnail is B&W from raw).

**State scope:** per-exercise via the model field. No global state.

## Photo vs video divergence map

| Decision point | Photo | Video | File / line |
|---|---|---|---|
| Local raw column | `exercise.rawFilePath` (color JPG, .heic accepted) | `exercise.archiveFilePath` (720p H.264 mp4) | `gotcha_photo_video_local_path_asymmetry.md`; `ExerciseCapture.absoluteRawFilePath` / `absoluteArchiveFilePath` |
| Line file column | `exercise.convertedFilePath` (line-drawing JPG) | `exercise.convertedFilePath` (line-drawing mp4) | both via `displayFilePath` getter |
| Segmented body-focus variant | None (no segmented JPG pipeline on this branch) | `exercise.segmentedRawFilePath` (body-pop mp4) | `app/lib/screens/studio_mode_screen.dart:4023` |
| Thumbnail pipeline | `thumbnailPath = rawFilePath` (single color JPG, treated as the thumbnail) | Native `extractFrame` produces `_thumb.jpg` (B&W from raw), `_thumb_color.jpg` (color from raw), `_thumb_line.jpg` (line from converted) | `app/lib/services/conversion_service.dart:343-345` (photo); `:217-279` (video) |
| Wire `thumbnail_url` shape | One field (the raw color JPG) | One field (`_thumb.jpg` = B&W) on public; three fields on embedded preview | `web-player/api.js:244-282` (no `_line`/`_color` keys); `app/lib/services/unified_preview_scheme_bridge.dart:326-333` |
| Cloud raw upload | JPG to `raw-archive` at publish (`upload_service.dart:1628`) | mp4 to `raw-archive` at publish (`upload_service.dart` raw-archive video path) | |
| Three-treatment URLs returned by `get_plan_full` | `line_drawing_url` = line JPG; `grayscale_url` / `original_url` = SAME raw color JPG (CSS filter does B&W) | `line_drawing_url` = line mp4; `grayscale_url` / `original_url` = raw mp4 (different file from line) | `_normaliseExercise` in `web-player/api.js:244` |
| B&W realisation | CSS `filter: grayscale(1)` on `<img>` via `.is-grayscale` (web); `_kGrayscaleFilter` / `_kFilmstripGrayscale` matrix in Flutter | Same CSS filter on `<video>`; same Flutter matrix; OR a separately encoded B&W variant for videos via `_thumb.jpg` | `web-player/styles.css` (`.is-grayscale`); `app/lib/widgets/capture_thumbnail.dart:12`; `app/lib/widgets/session_card.dart:22` |
| Body focus availability | N/A (no segmented JPG; toggle is no-op) | Per-exercise; segmented variant available for grayscale + original | `studio_mode_screen.dart:5148` (photo shows pill); `:3938` getter |
| Lobby hero element | `<img>` always | `<img>` as poster + `<video>` swap on active row | `web-player/lobby.js:1131` (photo); `:1148-1188` (video) |
| Active slide hero element | `<img>` with grayscale class | `.video-loop-pair` with two `<video>` slots | `web-player/app.js:1452` (video); `:1545` (photo) |
| Studio card hero | `_PhotoFrame` widget — treatment-aware file picker with fallback chain | `_HeroFrameImage` widget — treatment-aware `_thumb_*.jpg` picker | `app/lib/widgets/mini_preview.dart:442` / `:580` |
| Filmstrip hero | `displayFilePath` (line drawing JPG); no grayscale filter applied | `absoluteThumbnailPath` (B&W from raw); grayscale ColorFilter applied for parity | `app/lib/widgets/session_card.dart:980` |
| Filmstrip picker behavior | Single photo cell (drops all other photos) | Up to 4 video cells | `app/lib/widgets/session_card.dart:38-54` |
| Body-focus pill rendering | Renders the pill but toggle does nothing (no-op rebind) | Renders the pill, toggle rebinds the video to segmented or untouched | `studio_mode_screen.dart:5148`, `:3954` |
| Web player gear popover body-focus state | Toggle disabled per PR #316 staging fix (was: enabled, no-op) | Enabled when treatment ≠ line | `web-player/app.js:~4140` (staging) |
| Treatment fallback when grayscale URL missing | Falls back to line (silently) | Falls back to line (silently) | `web-player/app.js:394` |

## Gap analysis — current QA failures

### B6 — Setting first video to Line causes all heroes to render in Line in the lobby; prep hero for first slide misses Line

**Root cause (Part 1, the leak):** `web-player/app.js:5514` `getDefaultTreatment` picks the **first non-rest exercise's** effective treatment and returns it as the lobby's plan-global `activeTreatment`. `lobby.js:62` stores this single variable; `renderHeroHTML` at `lobby.js:1109` consumes it for **every** row — `api.resolveTreatmentUrl(slide, activeTreatment)`, not `getEffective(slide, 'treatment')`. The treatment is treated as plan-global in the lobby, even though `preferred_treatment` is per-exercise everywhere else.

**Root cause (Part 2, prep hero):** `buildPrepOverlay(slide)` at `web-player/app.js:1178` reads `slide.thumbnail_url` — the legacy single field. For videos that's the `_thumb.jpg` B&W variant. Even the staging-head fix (PR #316, `5e5b474`) only adds an `is-grayscale` CSS class for `bw` — Line treatment receives **no CSS class** and the underlying URL is still the B&W thumbnail. So the prep hero shows B&W; the actual `<video>` that takes over after prep plays the correct Line URL because `buildMedia` uses `resolveTreatmentUrl(exercise, slideT)` (which returns `line_drawing_url`).

The bigger fix needed for Part 2: `buildPrepOverlay` must pick `thumbnail_url_line` (or `thumbnail_url_color` for `original`) when on the embedded surface, and on the public surface a) the upload pipeline needs to write line + color thumbnails too, or b) the prep overlay falls back to applying CSS filters per treatment.

### D13 — Snapshot PNG shows color hero where actual video plays Line

**Root cause:** The snapshot path swaps `<img src>` and `<video poster>` to data URLs (`web-player/lobby.js:2299-2316`), and html2canvas renders the active `<video>` as its `poster` attribute. The poster came from `pickTreatmentPoster(slide, activeTreatment)` (`lobby.js:1186`) and on the public web player falls back to `slide.thumbnail_url` (the legacy B&W or, for photos, the raw color JPG) because `thumbnail_url_line` / `thumbnail_url_color` are not present on the cloud-fetched payload (`web-player/api.js:244-282` does not normalize them).

Variant scenario reported: "first video color while played Line." If the first exercise is a video and `activeTreatment = 'line'` (per §1 leak above), the lobby renders the row's `<img>` with `posterSrc = thumbnail_url_line || thumbnail_url`. On the public surface `thumbnail_url_line` is undefined → `posterSrc = thumbnail_url` (which IS B&W). So the snapshot would expect B&W, not color. But on the **embedded** surface the bridge emits `thumbnail_url_line = /local/{id}/hero_line` → swap path then attempts to fetch this for data-URL preload at `lobby.js:2197-2233`. `fetch(homefit-local://...)` might or might not succeed depending on the scheme handler's `preloadAsDataUrls` behavior; if it fails, the data URL map misses that src and the live img keeps its original URL. **Open question I'd validate on device:** whether `preloadAsDataUrls` succeeds for `homefit-local://` URLs.

The simpler D13 mechanism: the active video's `<video poster>` does NOT inherit the `.is-grayscale` CSS filter applied to its `<img>` sibling. So even when `activeTreatment === 'bw'` and the html2canvas snapshot of `<img>` siblings correctly renders B&W (via onclone CSS), the `<video>`'s poster URL is rasterised as-is. If the poster came from a color-variant URL (some race where `posterSrc = thumbnail_url_color`), the snapshot shows color.

### F17 — 3 photos render as 1 cell in Line treatment

**Root cause:** `_pickFilmstripHeroes` at `app/lib/widgets/session_card.dart:38-54` is **by design** "videos first, up to 4; zero videos → first photo only":

```dart
if (videos.isNotEmpty) return videos;
for (final ex in session.exercises) {
  if (ex.isRest) continue;
  if (ex.mediaType == MediaType.photo) return [ex];   // returns AFTER first photo
}
```

The "in Line treatment" angle: photos in the filmstrip render via `_FilmstripCell._resolveFile` at `:980` which returns `File(ex.displayFilePath)` — i.e., the converted line-drawing JPG. So the single photo cell renders the line drawing (correct per the docstring at `:920-923`). The bug isn't *the line treatment* — that's intentional — the bug is *only one cell*. The docstring explicitly says "static heroes for up to N=4 cells, video heroes preferred; rest-only / photo-only sessions get a single fallback cell." If Carl wants three photos to all show, the rule needs to change to "videos first up to N; if no videos, photos up to N."

### F21 — Capture → convert → preview → publish breaks for photos

**Root cause (most likely):** Asymmetric thumbnail pipeline. `conversion_service.dart:325-346` for photos stamps `thumbnailPath = exercise.rawFilePath` directly — there is no `_thumb.jpg` extraction, no `_thumb_color.jpg`, no `_thumb_line.jpg`. So:
- The lobby's `pickTreatmentPoster(slide, treatment)` does `slide.thumbnail_url_line.replaceFirst('_thumb.jpg', '_thumb_line.jpg')` on the embedded surface for photos — this is a no-op (the photo's `thumbnailPath` is the raw filename, which doesn't end in `_thumb.jpg`). The bridge returns the raw color JPG for all "hero" kinds. Net: photos render correctly as raw on the embedded surface.
- On the public surface, `thumbnail_url` is the cloud-uploaded line-drawing JPG path (via `upload_service.dart:1094` and the line-drawing photo-treatment flow), NOT the raw. So a photo's `thumbnail_url` IS the line variant for photos and B&W for videos — **opposite semantics**. Photo prep overlays show line, video prep overlays show B&W. This is the documented Wave 22 photo-three-treatment parity behavior, but the divergence between the two surfaces is itself confusing.

What Carl described — "breaks somewhere for photos" — could be the publish writing the wrong thumbnail URL for photos (the line variant ends up where the lobby expects the color), or the line JPG missing on publish, or the conversion service stamping the wrong column. Without his exact failure trace I'll flag this as **the divergence cluster around photo's missing thumbnail variant pipeline** — the abstraction will surface the asymmetry and force a decision.

## Proposed abstraction

**Name:** `resolveExerciseHero` (web JS) / `ExerciseHeroResolver` (Flutter Dart).

**Shape:** One synchronous function per surface that takes the exercise + active state and returns a record describing how to render that exercise's hero/poster on that surface.

### Web JS contract

```js
// web-player/exercise_hero.js (new file, shared by app.js + lobby.js)
/**
 * Resolve the hero/poster shape for a single exercise.
 *
 * @param {object} exercise — slide row from get_plan_full / bridge.
 * @param {object} opts
 * @param {'line'|'bw'|'original'} opts.treatment — effective treatment for THIS exercise.
 * @param {boolean} opts.bodyFocus — effective body-focus for THIS exercise.
 * @param {'lobby'|'deck'|'prep'|'snapshot'} opts.surface — which web surface is asking.
 * @returns {ExerciseHero}
 *
 * ExerciseHero shape:
 *   {
 *     mediaTag: 'img' | 'video' | 'skeleton',
 *     src: string | null,              // primary URL (active treatment)
 *     posterSrc: string | null,        // <img> src OR <video poster> URL, treatment-correct
 *     domClass: string,                // 'is-grayscale' applied when appropriate
 *     filterCss: string | null,        // explicit filter (for CSS filter-only treatment)
 *     caps: {
 *       hasBodyFocus: boolean,         // body-focus toggle is meaningful here
 *       availableTreatments: Array<'line'|'bw'|'original'>,
 *       treatmentLockedTo: 'line'|null // when consent forces line
 *     }
 *   }
 */
```

### Flutter Dart contract

```dart
// app/lib/services/exercise_hero_resolver.dart (new file)
class ExerciseHero {
  final File? videoFile;        // for surfaces that play video (MediaViewer)
  final File? posterFile;       // for surfaces that show a still (Studio card, filmstrip)
  final ColorFilter? filter;    // null when no filter needed
  final ExerciseHeroCaps caps;
}

class ExerciseHeroCaps {
  final bool hasBodyFocus;
  final List<Treatment> availableTreatments;
  final Treatment? treatmentLockedTo;
}

enum HeroSurface { studioCard, filmstrip, mediaViewer, peek }

ExerciseHero resolveExerciseHero({
  required ExerciseCapture exercise,
  required Treatment treatment,
  required bool bodyFocus,
  required HeroSurface surface,
});
```

### Files

- **New:** `web-player/exercise_hero.js` — pure function module, no DOM ops; exported as `window.HomefitHero.resolve(...)`. Loaded via `<script src="exercise_hero.js">` before `app.js` and `lobby.js`.
- **New:** `app/lib/services/exercise_hero_resolver.dart` — top-level function. No state, no IO except `File.existsSync()` for fallback chains.

### What it replaces (call sites to change)

**Web JS:**
- `web-player/lobby.js:1095` `pickTreatmentPoster` → resolver.posterSrc
- `web-player/lobby.js:1106` `renderHeroHTML` → switch to `resolveExerciseHero(slide, { treatment: getEffective(slide, 'treatment'), bodyFocus: ..., surface: 'lobby' })` PER ROW (fixes B6 leak)
- `web-player/lobby.js:1186` data attribute carriage → resolver.posterSrc
- `web-player/app.js:1178` `buildPrepOverlay` → resolver with surface='prep' (fixes prep-hero treatment)
- `web-player/app.js:1452-1552` `buildMedia` → resolver + write `posterAttr` from resolver.posterSrc
- `web-player/app.js:1581` `resolveTreatmentUrl` → call resolver internally; keep the public function name for backwards-compat shim
- `web-player/app.js:5514` `getDefaultTreatment` → delete (the lobby renders each row with its own per-exercise treatment now; the lobby's treatment-pill picker becomes the global override only, applied via `applyTreatmentOverrideToAllExercises`)

**Flutter Dart:**
- `app/lib/widgets/mini_preview.dart:203` `_treatmentFor` → resolver
- `app/lib/widgets/mini_preview.dart:442` `_PhotoFrame.build` → resolver.posterFile + resolver.filter
- `app/lib/widgets/mini_preview.dart:580` `_HeroFrameImage.build` → resolver
- `app/lib/widgets/capture_thumbnail.dart:98` `_resolveSource` → resolver
- `app/lib/widgets/session_card.dart:980` `_FilmstripCell._resolveFile` → resolver
- `app/lib/screens/studio_mode_screen.dart:4017` `_sourcePathForTreatment` → resolver (replace return-value with `ExerciseHero.videoFile?.path`)
- `app/lib/screens/studio_mode_screen.dart:3992` `_effectiveTreatmentFor` → resolver.caps.treatmentLockedTo
- `app/lib/screens/studio_mode_screen.dart:3870` `_hasArchive` → resolver.caps.availableTreatments.contains(...)

### Migration plan (R-10 parity preserved through migration)

1. **PR 1 — Resolver + B6 fix (small, lobby only).** Ship `exercise_hero.js`. Migrate `web-player/lobby.js` `renderHeroHTML` to call the resolver per row instead of using plan-global `activeTreatment`. Delete `getDefaultTreatment`. Treatment-pill picker still applies a plan-global override via `applyTreatmentOverrideToAllExercises` (unchanged). Embedded preview gets the fix for free since it shares the bundle.

2. **PR 2 — Prep hero treatment + active-slide poster (web only).** Migrate `buildPrepOverlay` and `buildMedia.posterAttr` to call the resolver. Fixes B6 part 2.

3. **PR 3 — Snapshot poster fix (web only).** Audit `triggerLobbyShare` to ensure the active video's poster is the resolver-correct URL (and optionally apply CSS filter to the poster via a per-treatment data URL re-encode, which is the only way to bake B&W into the rasterised PNG since `<video poster>` doesn't inherit CSS filters from siblings). Fixes D13.

4. **PR 4 — Flutter resolver + Studio/filmstrip/MediaViewer adoption.** Ship `exercise_hero_resolver.dart`. Migrate `MiniPreview`, `CaptureThumbnail`, `_FilmstripCell`, and `MediaViewerBody`. Delete duplicate `_kGrayscaleFilter` and `_kFilmstripGrayscale` constants in favor of one shared `ExerciseHero.filter`.

5. **PR 5 — F17 rule change.** Change `_pickFilmstripHeroes` from "first photo only" to "videos up to N, else photos up to N." Independent of the resolver migration — could ship before or after.

6. **PR 6 — F21 photo thumbnail variant pipeline.** Extend `conversion_service.dart` photo branch to extract `_thumb.jpg` (B&W via ColorFilter on raw), `_thumb_color.jpg` (= raw), `_thumb_line.jpg` (= converted) — symmetric to the video branch. Extend `upload_service.dart` to upload `_thumb_color.jpg` for photos too. Extend the bridge's `hero_line` / `hero_color` resolver to handle photo paths correctly. Then `pickTreatmentPoster` works identically across both media types, and the public web player gets three-treatment posters for photos.

### Which failures are "trivially fixed by adopting the abstraction"?

- **B6 part 1 (lobby leak):** Yes — the resolver is per-exercise; the global `activeTreatment` is no longer the treatment input.
- **B6 part 2 (prep hero):** Mostly — once `buildPrepOverlay` calls the resolver. **Caveat:** the resolver still needs treatment-correct posterUrl, which requires F21 to ship for the public surface (so `thumbnail_url_line` exists on cloud-fetched plans).
- **D13:** Partial. The resolver picks the right poster URL but `<video poster>` doesn't inherit CSS filters during html2canvas rasterisation — needs an explicit per-treatment poster URL (which F21's color thumbnail pipeline provides), OR a re-encode step in the snapshot path.
- **F17:** No — discrete rule change in `_pickFilmstripHeroes`.
- **F21:** No — needs the photo conversion variant pipeline.

## Edge cases

The abstraction must handle:

- **Rest periods.** `exercise.isRest` (Flutter) / `media_type === 'rest'` (web). Resolver returns `mediaTag: 'skeleton'` (web) / `posterFile: null, videoFile: null` (Flutter). Callers branch on `mediaTag === 'skeleton'` to render the rest UI without trying to play anything.
- **Mid-playback treatment switching.** The web player gear popover (`web-player/app.js:~4080`) writes per-exercise overrides via `setOverride(exId, 'treatment', value, defaultValue)`. Calling code reaches into `getEffective(exercise, 'treatment')` on the next render. The resolver takes treatment as input — it's the caller's job to invoke it on the right tick. The resolver itself is stateless; it doesn't watch a stream.
- **Missing variants.** Resolver returns a fallback chain spelled out explicitly:
  - Line: line file → fail. (Line is always present once conversion is done; no fallback needed.)
  - B&W: segmented variant if bodyFocus → archive (raw) → line (with `is-grayscale`/`ColorFilter.matrix` applied).
  - Original: archive (raw) → line (and `caps.treatmentLockedTo = 'line'` so the gear popover can disable the segment).
  - For posters: line → `thumbnail_url_line` → `thumbnail_url` (B&W) → skeleton. Color: `thumbnail_url_color` → `thumbnail_url` → skeleton. B&W: `thumbnail_url` → `thumbnail_url_color` (with filter) → skeleton.
- **Signed URL 403 expiry.** Out of scope for the resolver. The web player's existing error handlers (`web-player/app.js:418` for the deck, `web-player/lobby.js:1204` for the lobby) refetch the plan and re-call the resolver via the same code path. The resolver is idempotent on the new input.
- **Consent withheld.** Resolver inspects `exercise.grayscale_url` / `exercise.original_url` (NULL = consent absent). When the requested treatment has a NULL URL, resolver returns `caps.treatmentLockedTo = 'line'` and renders with `treatment: 'line'` regardless of input. The web player's UI separately disables the locked treatment in the gear popover.
- **Photo + body-focus toggle.** `caps.hasBodyFocus = mediaType === 'video'`. Photo callers render the body-focus pill as `enabled: false` with the existing tooltip ("Body focus applies to colour playback only."). The web player's gear popover row at `paintGearPanel` already does this per the PR #316 staging-head fix; the resolver formalises it as a capability flag so all surfaces converge on the same behavior.

## What's NOT in scope

- **Lobby live-DOM data-URL swap + html2canvas tainted-canvas trap.** That's an html2canvas/CORS plumbing issue (already covered by PR #270-#275 history). The PNG-treatment bug (D13) sits on top, but the snapshot infrastructure itself is treatment-orthogonal.
- **The deck's dual-video crossfade.** Mentioned in §2 only because it's the active-slide rendering shape. Resolver returns one URL; the dual-video pair management stays.
- **Studio settings sheet "Now / Defaults / Plan" tabs.** Out of scope — they configure values but don't render heroes.
- **Hero-frame picker (offset slider, `regenerateHeroThumbnails`).** Picker writes `focus_frame_offset_ms` and re-extracts thumbnails for videos. Photos don't have a Hero offset because their raw IS the Hero (per `mini_preview.dart:351-353`). The resolver consumes whatever thumbnails are on disk — it doesn't generate them.
- **Photo +/- body-focus state diff during PageView swipe in MediaViewer.** The body-focus pill rendering for photos is a UX bug; the resolver makes it expressible (`caps.hasBodyFocus`), but the existing fix (`c8e26cd fix(mobile-viewer): disable body-focus pill on photos`) is the correct local fix. Resolver adoption just makes it formally consistent.
- **E14 circuit animation, D10 modal-in-PNG.** Mentioned in the brief as treatment-unrelated; not investigated.
- **Service worker cache name bump** — orthogonal to the abstraction (would need bumping on any web change anyway).
- **Conversion-service photo variant pipeline implementation details** — F21 PR 6 above outlines the work; the audit doesn't prescribe the native vs Dart implementation choice.
