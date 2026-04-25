# Landscape Orientation Support — Analysis & Plan

> Drafted by deep-analysis pass on 2026-04-25. Discussion-ready, not finalised.

## TL;DR

Landscape is already permitted at every OS / framework boundary (Info.plist + `main.dart` allow all four orientations), but **no surface has been reflowed for it**. The "weirdly warps into portrait" symptom on Camera mode is a real bug in `_buildCameraPreview` (`app/lib/screens/capture_mode_screen.dart:870-878`) where preview width/height are deliberately swapped to compensate for portrait sensor rotation — that math goes inside-out the moment the device rotates. The biggest unknown unknown is on the **client surface**: there is currently no way for a client viewing a published plan on `session.homefit.studio` to view a landscape-recorded exercise without 16:9 video being letterboxed inside a 9:16 portrait pill window. Recommended approach: ship in **three phases** — Camera-only landscape (Phase A, low-risk, fixes the stated bug), then `_MediaViewer` reflow (Phase B, contained), then unified player + web client (Phase C, the load-bearing one). Total time estimate ~5-8 working days. Lock the rest of the app (Home, Studio list, ClientSessions, Settings) to portrait — they have no landscape value and reflowing them is wasted work.

## Current state

**Orientation is unlocked everywhere. Nothing reflows.**

| Surface | Lock state | What happens if rotated today |
|---|---|---|
| iOS Info.plist (`app/ios/Runner/Info.plist:77-89`) | All 3 orientations allowed on iPhone (no UpsideDown), all 4 on iPad | OS lets the rotation event through |
| Flutter `main.dart:32-37` | All 4 `DeviceOrientation` values allowed | Flutter forwards rotation to widget tree |
| Per-screen overrides | **None exist anywhere** | Every screen receives rotation events |
| Camera capture | Not locked | Bug: preview math inverts (see Symptom #1 below) |
| `_MediaViewer` | Not locked | Chrome collides; trim panel becomes a 700-px-wide bar with same handle hit targets |
| Studio mode list | Not locked | Bottom-anchored list works visually but loses one-handed reach affordance |
| Home / ClientSessions | Not locked | Lists reflow OK but FAB and PracticeChip overlap awkwardly with the slimmer nav bar |
| `PlanPreviewScreen` (legacy native preview) | Not locked | Uses `controller.value.aspectRatio` correctly so video frames OK; overlay chrome breaks |
| `UnifiedPreviewScreen` (current default) | Not locked | WebView reflows with the OS, but the `web-player` bundle has no landscape CSS |
| Web player (deployed) | n/a | Same — zero landscape media queries (`web-player/styles.css` only has `max-width: 420/480/640`) |

**Native conversion already respects orientation correctly.** `VideoConverterChannel.swift:411-423` reads the source `videoTrack.preferredTransform`, detects 90/270° rotation, swaps `naturalSize.width/height` accordingly, and re-applies `transform` to all three writers (line/segmented/mask) at lines 457, 502, 553. A landscape-recorded source produces a landscape line-drawing output without needing pipeline changes — the line-drawing aesthetic LOCK at v6 is unaffected.

**The data model has zero orientation hints.** No `aspect_ratio`, `width`, `height`, `orientation`, or `is_landscape` columns exist on `exercises` (Supabase or SQLite). Every consumer derives aspect ratio at playback time from `VideoPlayerController.value.aspectRatio` or the rendered `<video>` element's natural dimensions.

## Decisions to make

These are real product trade-offs Carl needs to decide before Phase B/C:

1. **Mixed-orientation plans on the client player — allowed?**
   - *Recommended default: YES, allow it.* The client web player adapts each pill to its source aspect ratio. Mixing 9:16 squat captures with 16:9 lateral-gait captures is a feature, not a defect, and matches how a practitioner thinks about exercise demonstration. The alternative (force every exercise in a plan to share an orientation) would feel constraining and would punish anyone who landscape-recorded one out of ten exercises.

2. **Should the Studio mode list rotate to landscape?**
   - *Recommended default: NO, lock it portrait.* The bottom-anchored one-handed reach is the load-bearing UX (R-09). A landscape Studio gives you wider but shorter cards — the chip rows wrap badly, the InlineActionTray loses vertical room, the bottom safe area rest bars collapse. Locking it portrait costs nothing because the practitioner has just left a CAMERA-mode rotation; they're already reaching to rotate the phone back. Same applies to Home, ClientSessions, Settings.

3. **What about the practitioner's preview (UnifiedPreview)?**
   - *Recommended default: YES, support landscape.* The practitioner needs to verify what the client will see. If the client sees landscape, the practitioner must too. The client and practitioner now share the same `web-player/` bundle so this is one job, not two.

4. **Lock orientation while a video recording is in flight?**
   - *Recommended default: YES.* Mid-recording rotation produces a video with messy embedded transform metadata + a partial-rotated frame at the rotation moment. Standard pattern. Light implementation lift.

5. **Photo capture: store the EXIF rotation OR bake it into the file?**
   - *Recommended default: bake it.* The line-drawing converter and B&W/Original treatments need to render consistently across mobile, web, and the WhatsApp link preview. EXIF-honouring is uneven (web `<img>` does, AVAssetReader internally does, but the segmented archive may lose it). Bake-on-write is one fewer surface area.

6. **Add `aspect_ratio` to the data model?**
   - *Recommended default: YES, but only as `numeric` (e.g. `1.778` for 16:9, `0.5625` for 9:16).* Lets the web player size pills correctly BEFORE the video metadata loads. Currently the player has to guess (or jump after first paint).

7. **Body focus / Vision segmentation on landscape source?**
   - *Validated: works fine.* Vision person segmentation is orientation-agnostic. The pipeline reads BGRA pixel buffers post-rotation; the body mask is generated on whatever shape the source is. No tuning impact on v6/v7 LOCKED constants.

## Surface-by-surface impact

### Camera capture (`app/lib/screens/capture_mode_screen.dart`)

**Symptom #1 root cause located.** Lines 870-878:

```dart
child: FittedBox(
  fit: BoxFit.contain,
  child: SizedBox(
    width: _cameraController!.value.previewSize?.height ?? 0,  // !!!
    height: _cameraController!.value.previewSize?.width ?? 0,  // !!!
    child: CameraPreview(_cameraController!),
  ),
),
```

The `camera` plugin's `previewSize` always reports the sensor's native dimensions in landscape (e.g. `1920x1080`). The current code hard-swaps width/height to fake portrait orientation. When the device rotates landscape, the swap is now wrong — the preview becomes a landscape video stretched into the swapped portrait box, then `BoxFit.contain` scales it down weirdly. Carl perceives this as "warps into a portrait."

**Fix:** use the `OrientationBuilder` (or `MediaQuery.of(context).orientation`) and only swap when the device is portrait; pass `previewSize.width` / `previewSize.height` straight through in landscape. The `CameraPreview` widget itself handles the rest.

**Other camera concerns:**
- The shutter row uses `Column(mainAxisSize: min)` inside a bottom-anchored SafeArea (line 829-836). In landscape this dumps the shutter, lens row, and "Hold for video" hint at the bottom centre — all of them stay on screen but the hint becomes overly prominent in the wider canvas. Recommend: move the lens row + hint to the side with the shutter in landscape, or accept the layout as-is for v1.
- The peek box at left-edge mid-height (line 805-810) keeps working visually in landscape but is now adjacent to the shutter row's left edge — they don't overlap (shutter is centred) but the gap collapses. Acceptable for v1.
- `_buildTopBar` (line 882) is a `Row` of close button → centred title → flash → flip. Flexes naturally in landscape with extra slack in the centre. No change needed.
- `_buildRecordingOverlay` uses `Padding(top: 44)` to clear the iOS notch. In landscape the notch moves to the side; this offset becomes redundant but harmless.
- **Lock orientation during recording.** Add `SystemChrome.setPreferredOrientations([currentOrientation])` on `_startVideoRecording` and restore on `_stopVideoRecording`. AVFoundation otherwise embeds a transform that reflects the orientation at first frame, not the entire clip — a mid-clip rotation is not a graceful experience.

### `_MediaViewer` (Studio thumbnail viewer — `app/lib/screens/studio_mode_screen.dart:1994-3253`)

The chrome inventory and what each occludes in a landscape canvas:

| Element | Position | Portrait fit | Landscape concern |
|---|---|---|---|
| Treatment segmented control (vertical pill) | `left: 12, top: 0, bottom: 0`, vertically centred (line 2862-2888) | Sits in left rail, doesn't overlap video frame | Same; rotated text reads weird in landscape because spine is now horizontal-ish to the eye |
| Exercise-name pill | `top: padding.top + 12`, centred, max-width `screen - 96` (line 2895-2947) | Top-centred above video | Becomes very wide; might collide with close X (top-right) when title is long |
| Bottom-right play/pause overlay | `right: 20, bottom: padding + 48 + trimLift` (line 2955-2969) | Sits below video bottom | In landscape, "right" + "bottom" puts it in the corner WHERE THE TRIM PANEL EXTENDS TO — collision unless the trim panel is also reflowed |
| Bottom-centre dot indicators | `bottom: padding + 16 + trimLift` (line 2974-2987) | Below video, above mute pill | In landscape, the trim panel is wider, dots compete with trim handles for the same horizontal band |
| Mute pill ("Audio on" / "Muted") | `left: 20, bottom: padding + 12 + trimLift` (line 2995-3009) | Lower-left of video | Same column as trim panel's left handle in landscape — collision |
| Body focus pill | `left: 20, bottom: padding + 12 + 36 + 8 + trimLift` (line 3013-3030) | Stacked above mute | Same column collision concern |
| Trim panel | `left: 12, right: 12, bottom: padding + 8`, height `_TrimPanel.panelHeight = 96` (line 3034-3078, panel constant at line 3541) | Full width below video | In landscape: full ~700 px wide bar with same drag handles → handle hit targets stay 24-ish px wide but the proportional pixels-per-ms grows 2x. Fine usability-wise but visually loose. The panel itself works; the chrome stacking around it does not. |
| Close X | `top: padding.top + 8, right: 8` (line 3079-3094) | Top-right corner | In landscape, close X is now at one of the long edges, adjacent to the exercise-name pill if pill is long |
| Tune gear (crossfade) | `top: padding.top + 8 + 48 + 4, right: 12` (line 3099-3123) | Stacked under close X | Same concern as close X; stays workable |
| Crossfade tuner bottom sheet | Material `showModalBottomSheet`, full-width (line 3237-3252) | Slides up from bottom, ~50% screen height | In landscape this eats most of the available vertical canvas. Sheet presentation needs to switch to a side panel or popover. |
| Prep overlay / video frame | `AspectRatio(aspectRatio: a.value.aspectRatio)` (line 3173-3174) | Lets video pick its ratio | Works correctly for both orientations of source — but the surrounding `Center` may letterbox/pillarbox awkwardly |

**Trim panel in landscape — the load-bearing question:** the existing math at `_TrimPanel._updateHandle` (line 3583-3615) computes `dx / _barWidth * durationMs`. In landscape `_barWidth` doubles, so 1ms of video = 0.5 px. That's actually MORE precise, not less — usability improves. The visual concern is purely the height: a 96-px tall panel pinned to the bottom of a 390-px tall landscape canvas eats 25% of the screen. Recommend: in landscape, drop panelHeight to ~64 (single row of handles + readout, no live-readout line). Acceptable trade.

**Recommended `_MediaViewer` landscape layout (sketch):**

```
   ┌──────────────────────────────────────────────────────┐
   │ [X]  ……exercise name pill……   [tune]                │
   │ [Line] ┌──────────────────────────┐                  │
   │ [B&W]  │                          │  [mute]          │
   │ [Orig] │       VIDEO              │  [body-focus]    │
   │        │       (16:9 here)        │  [▶/⏸]          │
   │        └──────────────────────────┘                  │
   │           ──[trim handles]──                         │
   └──────────────────────────────────────────────────────┘
```

- Treatment control stays on left rail (already vertical-axis there).
- Mute / body focus / play-pause migrate to a vertical right rail (mirrors the wider gap on landscape long edges).
- Trim panel collapses to ~64 px, single-row mode.
- Crossfade tuner becomes a `showDialog` popover anchored to the gear icon, not a bottom sheet.

### Workout preview (`PlanPreviewScreen` + unified `web-player` bundle via `UnifiedPreviewScreen`)

**`UnifiedPreviewScreen`** is currently the default path (Wave 4 Phase 2). It just hosts a `WebView` (`unified_preview_screen.dart:355-373`) — orientation reflow is whatever the bundle does. So this bullet collapses into "the web player needs landscape CSS."

**`PlanPreviewScreen`** is the legacy native preview. Largely retired but still in the tree (`app/lib/screens/plan_preview_screen.dart:1778-1825`). Video uses `controller.value.aspectRatio` which is correct. Mute/play overlays use `Positioned(top: 12, right: 12)` — fine in landscape but tight against the notch on iPhones with the Dynamic Island in landscape orientation. Skip in v1; hide PlanPreviewScreen entirely behind a feature flag if not already retired.

### Web player (`session.homefit.studio` — also runs inside `UnifiedPreviewScreen`)

Zero landscape support today. `web-player/styles.css` has only `max-width: 420 / 480 / 640` breakpoints — no `orientation: landscape` query, no aspect-ratio adaptation. The pill matrix, plan-bar, and active-slide-title are all designed for a portrait phone aspect.

**Critical gotchas the web player will hit:**

1. **Pill matrix.** The horizontal scrolling matrix at the top expects ~390 px of width. On a 700-px landscape phone the pills become wide, the active pill's "fluid-fill timer" stretches, and the auto-centre-the-active-pill scroll math may break. JS in `web-player/app.js` will need a landscape branch.
2. **Card viewport.** The video / card stack expects `90vh` of vertical room. In landscape that's ~390 px; the active card's bottom controls (timer chip, treatment controls, body-focus settings popover) cluster together. Same overlap class as Symptom #2.
3. **Fullscreen.** Already partially landscape-friendly (via `body.is-fullscreen` rules), but `web-player/styles.css:1970-2017` doesn't differentiate fullscreen-portrait from fullscreen-landscape.
4. **Service worker cache name.** Bumping `web-player/sw.js` `homefit-player-v16-three-treatment` to a new name is mandatory whenever the bundle ships landscape — old cached bundles will stay portrait-locked.
5. **WhatsApp link preview (OG middleware).** Unaffected — middleware only serves bot-friendly metadata.

### Studio mode list / Home / ClientSessions / Settings

**Lock these to portrait** with a per-route `setPreferredOrientations`. They have no landscape value:
- Home is a clients list with FAB — no landscape benefit, FAB collides with PracticeChip.
- ClientSessionsScreen is the client's session list with name + consent chip + sessions — same shape as Home.
- Settings is a vertical scroll of cards — landscape just shrinks the cards to the centre 60% of screen.
- Studio list is the editor — bottom-anchored one-handed reach IS the design (R-09).

Lock pattern:

```dart
@override
void initState() {
  super.initState();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
}

@override
void dispose() {
  // Restore the global "anything goes" set so subsequent screens are free.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  super.dispose();
}
```

Risk: dispose runs AFTER the next screen's initState. Two screens calling `setPreferredOrientations` in sequence — the order depends on Flutter's lifecycle. Test carefully on push + pop.

### Photos pipeline

`CameraController.takePicture()` returns a JPEG with iOS embedded EXIF rotation. On the iOS native side (`extractThumbnail` and the line-drawing photo converter) the EXIF orientation IS NOT explicitly read — it implicitly works because UIImage and Vision honour EXIF on load. The line-drawing JPG output for photos is written via `vImage` — verify it carries forward EXIF, OR explicitly bake-the-rotation-into-pixels at conversion time.

Wave 22 stores the raw colour JPG in `raw-archive`. If iOS Safari `<img>` honours EXIF (it does) but the segmented variant from Vision does not preserve EXIF (likely), then on web the original is upright but the colour-segmented variant would be sideways. **Verify on device with a landscape photo capture.**

### Native conversion pipeline

**Already landscape-ready** as noted above. Verifications needed:
- Run the line-drawing converter on a landscape source — confirm output preserves landscape (line 411-423 logic should hold).
- Confirm Vision person segmentation produces a usable mask on landscape input (it should — orientation-agnostic).
- Confirm the segmented and mask sidecar writers also apply `transform` (lines 502, 553 — they do).
- Confirm `extractThumbnail` for thumbnails respects orientation (`autoPick` motion-peak frame extraction).

Risk: low. Pipeline already does this.

### Server-side / data model

- No `aspect_ratio` column today. Adding one requires a Supabase migration + SQLite schema bump. Optional for Phase A/B; required for Phase C if we want the web player to size pills correctly before video load.
- `get_plan_full` doesn't return any orientation hint. Adding one is a one-line RPC change.
- `clients.video_consent` is treatment-level (`line_drawing` / `grayscale` / `original`). No orientation gate needed.

## Unknown unknowns / risks flagged

1. **Mid-recording rotation produces files with broken metadata.** AVFoundation captures `videoOrientation` at recording start. iOS does NOT re-encode on rotation; the embedded transform reflects the device orientation at first frame. If the practitioner rotates during a 30-second video, the resulting clip is half-portrait, half-landscape with one transform. Affects: line-drawing render, web player playback. **Mitigation: lock orientation while recording.**

2. **Two `setPreferredOrientations` calls within the same frame.** Flutter's screen-pop / push ordering can call dispose + initState back-to-back. If Studio's dispose fires after MediaViewer's initState (which forces landscape allowance), Studio's restore-to-portrait wins and forces the viewer into portrait. **Mitigation: use a static "stack" of preferred orientations OR manage at the route observer level.**

3. **WebView orientation handoff.** `UnifiedPreviewScreen` allows the WebView to rotate freely. The Swift `WKURLSchemeHandler` doesn't care about orientation. But the WebView's first paint computes layout — if the user rotates between `initState` and `onPageFinished`, the layout race could leave the bundle thinking it's portrait when it's landscape. **Mitigation: emit a `window.dispatchEvent('resize')` from native on rotation, or rely on the bundle's MutationObserver.**

4. **iPad behaviour.** iPad Info.plist allows all 4 orientations including upside-down. We've never tested or designed for tablet form factors. **Recommend: explicitly drop iPad from MVP via `UISupportedInterfaceOrientations~ipad` matching iPhone, OR accept tablet is broken for now.**

5. **Dual-video crossfade memory pressure on landscape.** `_MediaViewer` runs TWO `VideoPlayerController` instances on the same source (`studio_mode_screen.dart:2356-2360`) for crossfade. On landscape with a 1080p source, that's two simultaneous H.264 decoders on full-frame data. Older devices (pre-A14) may throttle. **Worth profiling.**

6. **Trim handle pixel precision.** The trim handle's drag-to-seek throttle (`_seekThrottleMs = 33`, line 3559) is calibrated against a portrait-width bar. On landscape the bar is 2x wider → twice as many pixel events per ms of video, hitting the seek throttle harder. Acceptable but flag.

7. **Service-worker cache split.** Web player visitors who already cached the v16 bundle will stay portrait-only until cache invalidation. The `homefit-player-v16-three-treatment` cache name MUST be bumped on the landscape deploy.

8. **Mixed orientations in one published plan.** When the client web player has a circuit of [9:16 squat, 16:9 lateral lunge, 9:16 plank], the pill matrix's pill widths assume ~equal duration. Pills are duration-weighted in fullscreen but not orientation-aware; the active card swap between portrait→landscape would jolt. **Decision needed (see Decisions to make #1).**

9. **`_TogglePill` and `TreatmentSegmentedControl` rotated text.** The vertical treatment pill on the left rail uses rotated book-spine text. In landscape, that text would now be the wrong rotation direction relative to the user's eye. Re-evaluate.

10. **Downstream accessibility / VoiceOver.** Landscape changes the focus ring traversal order. Hasn't been validated for VoiceOver yet but should be.

11. **The "Wave 8: landscape capture" comment in `main.dart:27-31` is dated.** It allowed landscape but never finished the work. Either follow through (this brief) OR remove the comment + lock to portrait globally as a one-line change. If Carl decides "portrait everywhere, defer landscape", undoing this is a single PR.

12. **`PlanPreviewScreen` is still in the tree.** If we ship landscape, it's a fourth surface to either retire-or-fix. Recommend retire (it's been superseded by the unified bundle).

## Proposed phased plan

### Phase A — Camera capture + orientation lock infrastructure (1-2 days, low risk)

**Goal:** fix Carl's stated symptom #1 (camera "warps to portrait"), introduce the per-screen orientation lock pattern, lock all surfaces EXCEPT camera + viewer to portrait.

**Files touched:**
- `app/lib/screens/capture_mode_screen.dart` — fix `_buildCameraPreview` width/height swap (use `OrientationBuilder`); lock orientation while recording is in flight.
- `app/lib/screens/home_screen.dart` — push portrait lock in initState.
- `app/lib/screens/client_sessions_screen.dart` — same.
- `app/lib/screens/studio_mode_screen.dart` — push portrait lock at the StudioMode level (NOT at SessionShell — that breaks the swipe between Studio and Camera).
- `app/lib/screens/settings_screen.dart` — same.
- `app/lib/screens/sign_in_screen.dart` — same (sign-in stays portrait).
- `app/lib/screens/auth_gate.dart` — bootstrap-error banner stays portrait.

**Risk:** medium-low. Per-screen orientation locks have well-known lifecycle gotchas (decision #2 risk above). Mitigate with a small `OrientationLockGuard` widget that pushes on initState + restores on dispose, with an explicit "global default" tracked via a top-level `ValueNotifier`.

**Test script bullets:**
- Sign-in screen: rotate, must stay portrait. PASS.
- Home: rotate, must stay portrait. PASS.
- Tap a client → ClientSessionsScreen: rotate, must stay portrait. PASS.
- Tap a session → SessionShell starts in Studio: rotate, Studio stays portrait. PASS.
- Swipe right to Camera: rotate to landscape, camera preview reflows correctly (no warp), shutter row stays bottom. PASS.
- In Camera landscape, long-press shutter to record video: rotation locks at landscape; OS rotation doesn't change orientation mid-record. Release: video file plays back as landscape on the studio card thumbnail.
- Swipe back to Studio mid-landscape: Studio forces portrait. PASS.
- Open `_MediaViewer` from Studio: viewer allows landscape. (Phase A does NOT yet reflow viewer chrome — chrome may overlap; that's Phase B.)

### Phase B — `_MediaViewer` landscape reflow (2-3 days, medium risk)

**Goal:** fix Carl's stated symptom #2. Make the `_MediaViewer` chrome reflow gracefully when the device rotates while open.

**Files touched:**
- `app/lib/screens/studio_mode_screen.dart` — `_MediaViewer` build method (line ~2799) wrapped in `OrientationBuilder`; chrome positioning conditioned on orientation.
- `app/lib/widgets/treatment_segmented_control.dart` — verify vertical-axis layout still works in landscape; possibly switch to horizontal-axis when landscape.
- `_TrimPanel` — accept an optional `compact: bool` mode that drops the live-readout line; landscape callers pass `compact: true` and shrink panelHeight to ~64.
- `_CrossfadeTunerSheet` — when called in landscape, present as a `showDialog` popover anchored to the gear, not a `showModalBottomSheet`.

**Risk:** medium. Chrome-cluster collisions are a layout-test heavy area. Lots of `Positioned` with hard-coded numerics that need orientation branches. The existing `_bottomChromeTrimLift` math becomes less load-bearing in landscape but more complex (need horizontal-rail-lift too).

**Test script bullets:**
- Open `_MediaViewer` on a portrait video → rotate to landscape → all chrome elements visible, no overlap. PASS.
- Drag trim handle in landscape: scrub follows, video pauses on drag, resumes on release. PASS.
- Treatment segmented control responds to taps in landscape. PASS.
- Body focus toggle responds in landscape. PASS.
- Tune gear → opens a popover (NOT bottom sheet) in landscape, slider drag updates crossfade. PASS.
- Open `_MediaViewer` on a landscape source video, in portrait device orientation → video letterboxes correctly inside portrait. PASS.
- Open same on landscape device orientation → video fills correctly. PASS.
- Page-swipe left/right in landscape — works. PASS.
- Vertical-swipe to cycle treatment in landscape — works (gesture lives on the page). PASS.
- Close X in landscape — accessible. PASS.

### Phase C — Web player + unified preview landscape support (2-3 days, higher risk; touches both surfaces simultaneously per R-10)

**Goal:** the unified `web-player/` bundle responds correctly to landscape on both the practitioner's `UnifiedPreviewScreen` and the deployed `session.homefit.studio` for clients.

**Files touched:**
- `web-player/styles.css` — add `@media (orientation: landscape)` rules for `.plan-bar`, `.workout-timeline-bar`, `.matrix-col`, `.card-viewport`, `.active-slide-header`, `.settings-popover`, `.fullscreen-toggle`, `.playpause-toggle`, `.body-focus-pill`, etc.
- `web-player/app.js` — verify the auto-scroll-to-active-pill math works in landscape (it computes pill offsets from `getBoundingClientRect`; should hold). Add a `resize` listener that recomputes the `--row-template-fs` for the matrix on rotation.
- `web-player/sw.js` — bump `CACHE_NAME` to `homefit-player-v17-landscape` (or whatever).
- `app/lib/screens/unified_preview_screen.dart` — verify the WebView allows orientation changes (it does by default); optionally inject a `window.dispatchEvent('resize')` JS message after rotation.
- Optional schema migration: add `exercises.aspect_ratio numeric NULL` so the bundle can size pills before video loads.

**Risk:** medium-high. Two surfaces to test simultaneously. The web player has 2104 lines of CSS without a single orientation media query — there are unknown landscape collisions hiding. Vercel preview deploy + fresh cache invalidation is the test loop.

**Test script bullets:**
- Practitioner UnifiedPreview in portrait — exists baseline, no regression.
- Practitioner UnifiedPreview rotated to landscape — pill matrix reflows, active card occupies most of the canvas, prep overlay stays centred, settings popover doesn't extend off-screen.
- Mid-workout rotation: timer + active pill highlight stays in sync. PASS.
- Client web (Safari iOS) in portrait — baseline, no regression.
- Client web rotated to landscape — same as practitioner.
- Mixed-orientation plan: 9:16 + 16:9 exercises in one circuit, viewed on landscape phone — both render correctly.
- Service-worker bumped — old clients get the new bundle on next visit.
- WhatsApp link preview unaffected.
- Fullscreen + landscape: works (chrome dim rules at line 2008-2048 still sensible).

## Out of scope (defer)

- **Android.** Not built yet; Phase A-C are iOS-only.
- **iPad.** Tablet form factor never validated. Lock to iPhone-only orientations via `UISupportedInterfaceOrientations~ipad` if confidence is needed.
- **Practitioner Studio mode in landscape.** Bottom-anchored UX is load-bearing; stays portrait.
- **Home / ClientSessions / Settings landscape.** Same — no value, locked portrait.
- **Sign-in / Auth gate landscape.** No reason.
- **PlanPreviewScreen (legacy native preview).** Recommend retire entirely instead of supporting landscape there.
- **Mid-clip transform editing.** If a user accidentally rotated during a recording (shouldn't, given Phase A's lock), Phase A delivers the lock; we do NOT build a post-hoc rotation editor.
- **Aspect-ratio storage as required column.** Phase C optional only.
- **Body focus tuning for landscape.** v6 LOCKED constants are aesthetic — orientation doesn't affect them.
- **Web portal landscape.** `manage.homefit.studio` is desktop-first; unaffected.

## Open questions for Carl

1. **Single-tier or multi-tier rollout?** Phase A alone fixes the camera bug — could ship that and leave Phases B/C for next wave. OR ship A+B together, then C as its own wave. Recommendation: ship A alone first, then a combined B+C as a "landscape player" wave once A has baked on device for ~3 days.

2. **Mixed-orientation plans on the published web — accept now, or constrain to single-orientation per plan as v1?** (Decision #1 above.)

3. **Add `exercises.aspect_ratio` schema column now** (Phase C opt-in), or defer until first user feedback that the pre-load pill sizing matters?

4. **Lock iPad to iPhone-only orientations**, or punt iPad entirely (no install support) for MVP?

5. **PlanPreviewScreen** — retire as part of this work (recommend), or leave the dead code path for future?

6. **Body focus / Vision segmentation memory cost on landscape 1080p with dual-video crossfade** — worth a proactive profile, or wait for QA to flag a stutter on older devices?

7. **Should landscape capture come with a "tap to rotate the OUTPUT 90°" affordance**, in case the practitioner accidentally landscape-recorded a portrait demo? (Likely future polish; not Phase A.)
