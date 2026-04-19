# Mobile Code Review — 2026-04-19

Scope: `app/` only. Branch: `chore/mobile-simplify` off `bisect/studio-circuit-header`.
After eight large PRs landed on the base branch, this pass applies safe
simplifications and flags the rest for human judgment.

## Headline numbers

| Metric | Baseline | After | Delta |
| --- | ---: | ---: | ---: |
| `flutter analyze --no-pub` issues | 25 | **0** | −25 |
| `app/lib/` lines changed | — | +27 / −490 | **net −463** |
| Files touched | — | 6 | — |

`flutter build ios --debug --simulator --no-codesign` failed in this
sandbox with `iOS 26.4 is not installed. Please download and install
the platform from Xcode > Settings > Components` — an environment
issue, not caused by the edits. `flutter analyze` passes clean.

## Findings table

| File | Finding | Severity | Status |
| --- | --- | --- | --- |
| `lib/widgets/powered_by_footer.dart` | `_PulseMarkPainter` class unreferenced (replaced by `HomefitLogo`) | low | applied — deleted |
| `lib/screens/sign_in_screen.dart` | Second `_PulseMarkPainter` — literal duplicate of the footer's, also replaced by `HomefitLogo` | low | applied — deleted |
| `lib/widgets/progress_pill_matrix.dart` | `_kEtaSlotWidth` / `_kEtaSlotGap` consts unreferenced (ETA widget moved out of the track) | low | applied — deleted |
| `lib/widgets/progress_pill_matrix.dart` | `_iconColor` / `_labelFor` static helpers unreferenced (pill text is computed inline now) | low | applied — deleted |
| `lib/widgets/progress_pill_matrix.dart` | `_PillIconPainter` unreferenced (pills are text-only now) | low | applied — deleted |
| `lib/widgets/progress_pill_matrix.dart` | Two `// ignore: unused_local_variable` sinks holding refs to unused parameters "for API symmetry" | low | applied — both sinks removed |
| `lib/screens/plan_preview_screen.dart` | `_buildInlineTimerRing` + `_TimerRingPainter` unreferenced (three-mode tap-to-pause now lives in the pill matrix + card body) | low | applied — deleted; drops `dart:math` import |
| `lib/screens/plan_preview_screen.dart` | `_buildCircuitBar` + `_circuitDot` unreferenced (progress-pill matrix owns circuit signalling) | low | applied — deleted + stale `// removed` comment also gone |
| `lib/screens/plan_preview_screen.dart` | `_buildBadges` + `_badge` unreferenced (pipe-shorthand on pills replaced the reps/sets/hold badges) | low | applied — deleted |
| `lib/screens/plan_preview_screen.dart` | `_ExercisePage.timerChip` field + constructor param never supplied; the two null-check branches in `_buildMetadataOverlay` were dead | low | applied — field + param removed, branches collapsed |
| `lib/screens/plan_preview_screen.dart` | `_formatTimer` orphaned once `_buildInlineTimerRing` went | low | applied — deleted |
| `lib/widgets/capture_thumbnail.dart` (x2) · `lib/screens/session_capture_screen.dart` (x3) | Closure params use the legacy `(_, __, ___)` shape; Dart 3 analyzer flags `unnecessary_underscores` | low | applied — switched to `(_, _, _)` |
| `lib/screens/session_capture_screen.dart` (2546 lines) · `lib/screens/studio_mode_screen.dart` (1823 lines) | Oversized screens. Giant `build()` trees with deep indentation. | med | flagged — see below |
| `lib/screens/plan_preview_screen.dart` (1262 after edits, was 1589) | Still large but improved. Has an awkward `if (!isRest && ... mediaType == video ...)` in `_buildMedia()` that should be extracted to a small `_needsBodyTapWrapper` helper | low | flagged — low-risk rename, but out of scope for this PR |
| `lib/widgets/progress_pill_matrix.dart` (1473 after edits, was 1583) | Genuinely complex — grid layout + peek overlay + scrub chevron + teaching peek + animation. 1400+ lines in one file. Could split `_PeekOverlay` + `_ScrubChevron` into `progress_pill_matrix/` subdirectory | med | flagged |
| `lib/services/` — singleton vs DI inconsistency | `AuthService.instance` (singleton) vs `LocalStorageService` / `ConversionService` (constructor-DI threaded via main.dart). Pragmatic split (auth = global state, storage = lifecycle-aware) but worth documenting. | low | flagged |
| No `ApiClient` abstraction yet | `Supabase.instance.client` is still accessed directly from `auth_service.dart:57` and `upload_service.dart:138`. Task description referenced an `ApiClient.instance` that doesn't exist on this branch — the data-access-layer PR hasn't been merged yet. | n/a | informational only |
| `test/widget_test.dart` | Placeholder test (`expect(1 + 1, 2)`) | low | left alone per scope |

## Top 5 things to fix that are NOT in this PR

1. **`session_capture_screen.dart` is 2546 lines.** The file mixes
   camera controller lifecycle, shutter gesture recognition, pinch-to-zoom
   pills, haptic ticks, recording overlay, per-second tick timer, peek
   thumbnail, and the viewer/editor modals. It badly needs splitting —
   at minimum extract the editor/viewer modal tree into a sibling
   widget, and the camera-controls overlay into its own file. Needs a
   careful pass on a real device because recording state is state-heavy.
2. **`studio_mode_screen.dart` layout bug is still sensitive.** The
   file carries long inline comments explaining "we tried X, reverted
   to Y" across three failed attempts. Once `BACKLOG_STUDIO_LAYOUT.md`
   is retired and the current plain `ReorderableListView.builder` is
   confirmed stable, the defensive Stack-based rail explanation in
   `_buildRowWithContext()` can shrink — but only after device
   verification.
3. **`conversion_service.dart` (928 lines) has platform-channel logic
   and queue management interleaved.** The FIFO queue + progress
   stream + single-pass retry + native bridge would read cleanly as
   two files (`conversion_queue.dart` + `conversion_channel.dart`).
   Risk: this is the hot path for the line-drawing pipeline; any
   refactor must have a device smoke test before landing.
4. **No `ApiClient` surface yet.** `upload_service.dart` and
   `auth_service.dart` both reach directly into
   `Supabase.instance.client`. When the data-access-layer PR lands,
   migrate both to `ApiClient.instance` in a single follow-up so all
   RPC/storage/auth calls funnel through one typed seam.
5. **No real widget tests.** `test/widget_test.dart` is a placeholder.
   At minimum `progress_pill_matrix.dart` (pure rendering given inputs)
   and the `duration_format.dart` helpers deserve golden/unit tests
   before the next big screen refactor.

## Patterns Carl should be aware of going forward

- **Dead-API-symmetry antipattern.** Three of the removed declarations
  had docstrings saying *"kept on the widget's API to avoid churn"* or
  *"kept for API symmetry"*, plus `// ignore: unused_local_variable`
  sinks in `_hitTest`. If an analyzer warning has to be silenced or a
  param held as a reference-only to stop lints firing, that's a signal
  the abstraction is drifting. Prefer deleting; add it back when the
  caller materialises.
- **Long-lived "DEPRECATED" comments.** The `timerChip` field carried
  `DEPRECATED — superseded by tap-to-pause ...` and was dead on
  arrival. If a field is deprecated and has no callers, drop it the
  same PR that removes the last caller. Deprecation comments in
  private `_widget` APIs have no downstream consumers to warn.
- **Widget-local `CustomPainter` duplication.** Both `sign_in_screen`
  and `powered_by_footer` had byte-identical `_PulseMarkPainter`
  implementations — the comment in the sign-in screen literally said
  *"duplicated because the other file's painter is private"*. Now
  that `HomefitLogo` owns both, this lesson is baked in: if two files
  need the same painter, make the painter public (or wrap it in a
  public widget) rather than copy-pasting.
- **Singleton vs DI split in `services/`.** `AuthService.instance`
  (global session state, one user-scope at a time) is the right
  call; `LocalStorageService` passed through constructors (per-session
  SQLite handle) is also right. Future services should match:
  *cross-cutting global state → singleton; per-flow state → DI*.
- **File-size early-warning threshold.** Three files are now over 1800
  lines (`session_capture_screen`, `studio_mode_screen`,
  `plan_preview_screen`). Consider a convention: whenever a
  screen's `build()` exceeds roughly 400 lines, extract one level of
  `_XxxSection` widgets into a sibling file. Done preemptively this
  avoids the "can't safely refactor, too much risk" state the capture
  screen is now in.

## Build + analyze evidence

- Analyzer: `flutter analyze --no-pub` — **0 issues** (down from 25).
- Build: not verified in sandbox (`iOS 26.4` SDK not installed).
  Recommend running `./install-sim.sh` on Carl's machine before
  merging.
