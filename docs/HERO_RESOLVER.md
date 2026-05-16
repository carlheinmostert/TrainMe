# Hero Resolver — Single Source of Truth for Hero-Image Rendering

**Status:** adopted 2026-05-16. Binding on web today (PR #364, commit
`0035831` on `staging`). Flutter consumer migration tracked in
[`docs/BACKLOG.md`](BACKLOG.md) — when it lands, the same rule applies
to the four mobile surfaces.

**Supersedes:** ad-hoc inline crop math across `lobby.js`, Studio /
filmstrip / camera-peek widgets, and the PDF export path.

## Table of Contents

- [The Rule](#the-rule)
- [Why this exists](#why-this-exists)
- [Resolver API (web)](#resolver-api-web)
- [Resolver API (Flutter, today + future)](#resolver-api-flutter-today--future)
- [Forbidden patterns + correct alternative](#forbidden-patterns--correct-alternative)
- [What is allowed](#what-is-allowed)
- [Enforcement](#enforcement)

## The Rule

All hero-image rendering on every surface — Studio card, filmstrip,
camera peek, web-player lobby, web-player PDF export — goes through
the hero resolver. No inline crop math lives anywhere else. The
resolver owns the "given a portrait/landscape source JPG + a stored
offset, produce the 1:1 view" transformation; consumers receive a
square poster (web: data URL whose intrinsic dimensions are 1:1;
Flutter, post-migration: an `ExerciseHero` struct carrying both the
source file and the crop semantics) and render it without further
geometry.

No `object-fit: cover` + `object-position` on `.lobby-hero-media`. No
inline `heroCropOffset` arithmetic in consumers. No new `<img
src="..._thumb*.jpg">` tags in lobby code or PDF code that route
around the resolver. Reads of `heroCropOffset` happen only inside the
resolver module(s) and the editor that authors the value.

## Why this exists

The crop is shared logic that used to be duplicated across every
consuming surface:

- Flutter Studio exercise card (mobile)
- Flutter ClientSessions filmstrip background tiles (mobile)
- Flutter camera-peek bottom-left thumb (mobile)
- Web-player live lobby `<img>` (web)
- Web-player PDF export via html2canvas (web)

Five copies of the same math — "given a portrait/landscape JPG + a
stored offset, produce the 1:1 view" — each surface had to know the
geometry. The duplication is a structural debt by itself, but it
silently mutated into a real bug on the PDF surface: html2canvas
ignores CSS `object-fit` and `object-position`. The live lobby
relied on those two properties to do the crop at render time, so
when the rasteriser ran, portrait posters came out squashed into 1:1
squares without honouring the practitioner's chosen offset. Live
lobby looked right; PDF looked wrong; the asymmetry was invisible
until someone exported.

PR #364 ([`web-player/hero_resolver.js`](../web-player/hero_resolver.js))
landed the web fix: bake the crop into the bitmap before any
consumer sees it. The `<img>` no longer needs `object-fit`; the PDF
inherits the fix for free because html2canvas just rasterises the
already-square data URL. The source JPG on disk stays
portrait/landscape — the crop happens at consumption time, per
surface, against the in-memory exercise row (which carries
`aspect_ratio` + `hero_crop_offset`).

The mobile half of this argument is filed in [`docs/BACKLOG.md`](BACKLOG.md)
under "Flutter hero-crop resolver — migrate the five mobile
consumers". The web fix shipped on its own because it carried a real
bug; the Flutter consumers are stable today (duplication, not bug)
and refactoring them is queued separately.

## Resolver API (web)

Module: [`web-player/hero_resolver.js`](../web-player/hero_resolver.js).

Loaded via `<script src="hero_resolver.js">` BEFORE `lobby.js` so
`window.HomefitHeroResolver` is available when the lobby renders. No
external dependencies; no inline scripts (CSP `script-src 'self'`).

```js
const dataUrl = await window.HomefitHeroResolver.getHeroSquareImage({
  exerciseId,       // wire `exercise.id` — cache key component
  treatment,        // 'line' | 'bw' | 'original' — cache key component
  sourceUrl,        // per-treatment thumbnail JPG URL (signed Supabase URL or data: URL)
  heroCropOffset,   // 0.0..1.0; default 0.5. Vertical centre for portrait sources; ignored for landscape.
  targetSize,       // edge length in CSS pixels; canvas honours devicePixelRatio internally
});
// dataUrl is a square JPEG that <img src> and html2canvas both render
// identically. No CSS object-fit / object-position downstream.
```

Returns: `Promise<string>` — a JPEG data URL of the square crop.

Cache: in-module `Map<cacheKey, Promise<string>>`. Keyed on
`(exerciseId | treatment | heroCropOffset | targetSize)`. Soft cap
200 entries, batch-evict the oldest 25 on overflow. Treatment switch,
page navigation, and scroll-driven re-render all hit cache.

Diagnostics: `window.HomefitHeroResolver.inspect()` returns
`{ size, cap }` for QA scripts. `clearCache()` resets the map.
`_computeCropRect()` is exported for unit-test-style probes.

## Resolver API (Flutter, today + future)

Today: [`app/lib/services/exercise_hero_resolver.dart`](../app/lib/services/exercise_hero_resolver.dart)
already exists as a partial implementation of this pattern. It
returns an `ExerciseHero` struct carrying `posterFile` / `filter` /
`treatment` / `caps`. The crop offset is **not part of the contract
yet** — consumers currently derive `Alignment` from
`Exercise.heroCropOffset` via the helper at
[`app/lib/utils/hero_crop_alignment.dart`](../app/lib/utils/hero_crop_alignment.dart),
which is itself a centralised location but still leaves the
`heroCropOffset` field read by five widgets and the helper itself
runs alongside `Image.file(..., fit: BoxFit.cover, alignment:
heroCropAlignment(exercise))`.

Future (BACKLOG): extend `ExerciseHero` to carry
`double heroCropOffset` and introduce a `CroppedHero(widget)`
builder that mirrors the web resolver's `computeCropRect`. Migrate
the five consumers (Studio card, filmstrip, peek, ClientSessions
hero, editor sheet preview) so widgets never compute `Alignment`
from raw offset. Add a drift-guard unit test that asserts the Dart
`CroppedHero` and the JS `HomefitHeroResolver._computeCropRect`
produce the same `(sx, sy, sw, sh)` for a representative set of
(aspect ratio, offset) tuples. Scope, rationale, and effort
estimate live in [`docs/BACKLOG.md`](BACKLOG.md).

Until the migration lands, the centralised helper at
`app/lib/utils/hero_crop_alignment.dart` is the single Flutter
location where `Alignment` is derived from `heroCropOffset`. New
Flutter widgets that need a hero crop **must** call
`heroCropAlignment(exercise)` rather than rebuilding the math
inline.

## Forbidden patterns + correct alternative

| Forbidden | Why it breaks the rule | Correct alternative |
|-----------|-----------------------|---------------------|
| `object-fit: cover` on `.lobby-hero-media` (the `<img>` selector, not the `video.lobby-hero-media` selector) | Reintroduces the workaround the resolver replaced; the data URL is already 1:1 so `object-fit` is dead weight. html2canvas would ignore it anyway, silently regressing PDF export. | Call `HomefitHeroResolver.getHeroSquareImage(...)` from `hydrateHeroCrops` in `lobby.js`. The resolver delivers pre-cropped images. The `video.lobby-hero-media` exception stays — video frames stream natively at source aspect ratio and need `object-fit: cover` to crop to the 1:1 slot. |
| Inline `heroCropOffset` / `hero_crop_offset` arithmetic in any consumer (`* (h - w)`, `* 2 - 1`, `(w - h) / 2`, etc.) | Each copy is one more place to bug-fix when the math changes. The PDF squash bug was exactly this — five copies, four right, one wrong, no easy way to find the divergence. | Web: call `HomefitHeroResolver.getHeroSquareImage(...)`. Flutter (today): call `heroCropAlignment(exercise)` from `app/lib/utils/hero_crop_alignment.dart`. Flutter (post-migration): consume `ExerciseHero` with crop semantics via `CroppedHero`. |
| New `<img class="lobby-hero-media" src="..._thumb*.jpg">` tags in lobby code or PDF code | A direct thumbnail-URL `<img>` bypasses `hydrateHeroCrops` and silently rolls back to "uncropped image cropped by CSS" — the exact pre-PR-#364 state. | Render the same `<img>` shape via `renderHeroMedia` in `lobby.js` so `hydrateHeroCrops` swaps the src to a data URL. For PDF export specifically, the live `<img src>` is already the data URL by the time the cloneNode runs — no separate path needed. |
| Flutter widgets reading `exercise.heroCropOffset` directly | Each new reader is one more migration target when the Flutter side moves to a resolver-shaped contract. Even today, every reader has to redo the clamp + axis-pick logic. | Today: call `heroCropAlignment(exercise)` from `app/lib/utils/hero_crop_alignment.dart`. Post-migration: read it off the `ExerciseHero` the resolver hands back. |

## What is allowed

- Writes to `heroCropOffset` from
  [`app/lib/widgets/hero_crop_viewport.dart`](../app/lib/widgets/hero_crop_viewport.dart)
  — the editor's crop authoring widget. This is the **only writer**
  of the field. It persists via `_persistHeroCrop` in
  [`app/lib/screens/studio_mode_screen.dart`](../app/lib/screens/studio_mode_screen.dart).
- Reads inside the resolver modules themselves:
  - `web-player/hero_resolver.js`
  - `app/lib/services/exercise_hero_resolver.dart`
  - `app/lib/utils/hero_crop_alignment.dart` (centralised
    `Alignment` derivation until the BACKLOG migration lands)
- Reads inside the model declaration:
  - `app/lib/models/exercise_capture.dart` (field declaration,
    `fromMap`, `toMap`, `copyWith`)
- Wire-layer reads in the data-access layer for persistence:
  - `app/lib/services/upload_service.dart` (writes the field to
    Supabase via the access layer)
  - `app/lib/services/sync_service.dart` (reads the field from
    Supabase via the access layer)
  - `app/lib/services/unified_preview_scheme_bridge.dart` (round-
    trips the field through the unified-preview wire format)
- The editor sheet's `Preview` tab read at
  `app/lib/widgets/exercise_editor_sheet.dart` — this is the editor
  surfacing the offset to the viewport widget, not a renderer
  computing crop math.
- Test files and mocks.

If a new file needs to read `heroCropOffset` for rendering, that
file belongs on the allow-list — and that probably means the
resolver should be extended to cover the use case instead.

## Enforcement

Three layers:

1. **This document** — the rule, the forbidden patterns, the
   alternatives.
2. **Memory** — `feedback_hero_resolver_single_source.md` in
   Carl's auto-memory tells future sessions to redirect plans that
   add crop logic outside the resolver. Referenced at planning
   time, not at code-review time.
3. **CI** — [`scripts/ci/check-hero-resolver.sh`](../scripts/ci/check-hero-resolver.sh),
   wired into the `Custom rules (bash)` job in
   [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). Scans
   `web-player/` and `app/assets/web-player/` (R-10 mirror) for the
   forbidden CSS pattern, scans `web-player/lobby.js` (and its
   mirror) for the forbidden static `_thumb` `<img>` pattern, and
   scans `app/lib/` for `heroCropOffset` reads outside the allow-
   list. Failure prints the file, the line, and the resolver
   alternative.
