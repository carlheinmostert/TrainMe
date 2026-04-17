# Pending Device Tests

Work that has landed on `main` but hasn't been visually verified on Carl's iPhone yet. Batched so Carl installs once and tests many.

Reference items by commit hash + feature name when reporting feedback.

---

## Pending — install and verify

### Commit `7fc84e6` — Studio card + Home UI refinements
- Slider labels shrunk (likely to be replaced by the next item — see below)
- Preview sub-section removed from expanded cards
- Chevron + drag handle sit flush as a pair
- Thumbnail tap opened `PlanPreviewScreen` at the exercise's slide index — **superseded** by the next item

### Commit `2de937e` — Slider vertical layout + thumbnail media viewer
- Slider rows now render as `Column`: `[label on left, value on right]` row above, slider full-width below. Full card width. No truncation, no "R..." artefacts.
- Thumbnail tap opens a full-screen `_MediaViewer`: auto-plays video (tap to pause/resume), or shows photo, with close button top-right. Rest exercises are non-tappable (no media).
- Replaces the behaviour from `7fc84e6` which incorrectly opened the workout-mode `PlanPreviewScreen`.

### Commit `7fc84e6` — Home screen inversion
- Sessions list bottom-anchored (`reverse: true` pattern from Studio).
- New Session button moved to just above the footer.
- Powered-by-homefit.studio footer pinned at the very bottom.

### Commit `fc30f69` — Rest page timer consolidation (Flutter preview)
- Deleted the fullscreen centered rest overlay.
- Timer chip now shows on rest slides (running/paused modes).
- Rest card simplified: icon + "Rest" label + "Next up: X" subtitle, no duplicate countdown number.
- Web player version of this already validated — test the Flutter preview.

### Earlier commits `6b8847a` / `dc992db` (validated briefly, worth re-verifying post-merge)
- Per-second `mediumImpact` haptic tick during video recording.
- Pulsing red dot as visual backup during recording.
- Peek box with no spinner.
- Pinch-to-zoom + 0.5x/1x/2x/3x lens row on camera.
- Long-press release reliably stops recording.

---

## When ready to test

```bash
cd /Users/chm/dev/TrainMe/.claude/worktrees/zen-euler-36b643/app && flutter build ios --release
```

VPN off →

```bash
xcrun devicectl device install app --device 00008150-001A31D40E88401C /Users/chm/dev/TrainMe/.claude/worktrees/zen-euler-36b643/app/build/ios/iphoneos/Runner.app
```

VPN on. Walk through each section and feed back by commit hash.
