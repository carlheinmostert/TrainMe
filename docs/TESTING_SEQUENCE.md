# Testing Sequence — 2026-04-17

Round of hands-on testing for everything landed since the last verified install. Items are sequentially numbered — say "item 17 broken" and Claude knows exactly what you mean.

Two tracks you can run in either order:

- **Track A — Main branch** (current `main`, commit `c5b8bdd` or later). Validates quality + workout-mode UX wins on the existing single-screen app.
- **Track B — Session Shell branch** (`claude/session-shell-refactor`). The A/B candidate for the Capture/Studio split.

Run Track A fully first so you see the "new production baseline." Then switch to Track B to compare the UX structural change against it.

---

## Setup

1. **Build + install main branch for device**
   ```bash
   git checkout main && git pull
   cd app && flutter build ios --release
   ```
   Then VPN off → install via:
   ```bash
   xcrun devicectl device install app \
     --device 00008150-001A31D40E88401C \
     /Users/chm/dev/TrainMe/.claude/worktrees/zen-euler-36b643/app/build/ios/iphoneos/Runner.app
   ```
   → VPN back on.

2. **App launches cleanly, home screen shows sessions.**

---

## Track A — Main branch on device

### Capture + line-drawing quality

3. **Record a short video (3-5s) of a person in front of gym equipment.** Release finger to stop.

4. **Wait for conversion to finish** (count increments in the in-studio card, `conversion_status` goes to `done`).

5. **Thumbnail in the session list shows two-zone rendering:** body crisp, equipment visibly dimmer. Not a hard-cutout background.

6. **Preview the video inside the app.** Body lines noticeably darker/crisper than background throughout; equipment shows as a ghost not erased.

7. **No hard silhouette seam where body meets the machine** (edge softening working).

8. **Record a frame-only shot — no person visible.** Full-dim rendering (everything faint). Acceptable; tells you what a person-less capture looks like.

9. **Record with default iPhone camera settings** (which is HDR/Dolby Vision on iPhone 15 Pro+). Thumbnail generates successfully — no blank or broken preview.

10. **Record a photo (tap, not long press).** Converts on the main isolate without UI freeze. Two-zone rendering applied here too.

### Duration estimate (video-as-one-rep)

11. **Record a ~5-second video exercise, set reps = 10, sets = 3.** The duration estimate updates to reflect ~5s/rep (not the old 3s default). Total ~2:30 → ~5:00 range.

12. **Set custom duration override on same exercise.** Override wins over the video-derived calc.

### Workout mode (Flutter preview on device)

13. **Open an existing plan with at least 3 exercises + 1 rest.** Tap "Start Workout".

14. **First exercise: 15-second prep countdown appears in bottom-right chip** (not a fullscreen gate). Shows seconds counting down.

15. **Video on the current card auto-plays (muted, looped).** No play-button overlay visible over the video while it plays.

16. **Tap chip during prep → skips prep, exercise timer starts immediately.** Chip switches to M:SS + tiny pause icon.

17. **Tap chip during running exercise → timer pauses, video pauses, chip shows play icon.**

18. **Tap chip again → both resume.**

19. **Swipe left on an exercise mid-timer → advances to next slide, cancels current timer, new slide's prep starts.**

20. **Swipe left on a rest slide → advances past the rest to the next exercise.** NOT stuck on the rest.

21. **Nav chevrons (if shown) work on every slide type**, including rest.

22. **On a rest slide, tap the big countdown number → pauses, number dims to ~50% opacity, play icon appears over it.** Tap again → resumes.

23. **Let the last exercise run to completion** → "Workout Complete" screen appears.

### Share flow

24. **Tap Share on a session card.** iOS share sheet contains ONLY the plan URL. No multi-line preamble. Paste into WhatsApp → unfurls as a link preview.

### Web player (pushed live, test on mobile Safari independently)

25. **Open a published plan URL on mobile Safari.** Plan loads, videos auto-play muted + looped.

26. **Tap Start Workout → 15s prep chip appears bottom-right of card.** Not a fullscreen overlay.

27. **Same three-mode tap behaviour on the web chip** (skip prep / pause / resume).

28. **Swipe and chevron navigation work on any slide, including rest.**

29. **Rest paused state shows dim number + play icon** on the web player.

30. **Video auto-plays + loops** on the web player throughout workout mode.

### Capture sub-screen behaviour (main branch still uses the old single-screen flow)

31. **Tap "New Session" → goes to the existing combined capture + edit screen** (not a mode split yet — that's Track B).

---

## Track B — Session Shell branch (A/B candidate)

32. **Switch branch + rebuild**
    ```bash
    git checkout claude/session-shell-refactor && git pull
    cd app && flutter build ios --release
    ```
    Install via the same `devicectl` command. VPN dance as usual.

33. **Tap "New Session" → opens Camera mode directly** (not Studio). Full-screen camera preview, shutter at bottom.

34. **Top bar shows the session name** (small, unobtrusive, non-tappable).

35. **Top corners: flip camera, flash, exit.** All three work.

36. **Short-press shutter → photo captured.** Peek box (left edge, mid-height) shows thumbnail + count = 1.

37. **Long-press shutter → recording starts.** Pulsing red dot top-left, 30-second countdown top-centre in big bold tabular-nums.

38. **Feel the per-second haptic tick while recording** (real device only, not sim). Barely perceptible, rhythmic.

39. **Release finger → recording stops.** Thumbnail animates into the peek box, count increments. Haptic on stop.

40. **Long-press shutter, hold for 30s → auto-stop with double-tick haptic.** Big countdown hits 0:00 and stops on its own.

41. **Swipe right (or tap the left-edge coral pull-tab) → transitions to Studio mode.**

42. **Studio mode has all edit features:** sliders, reorder, circuits, notes, inline name edit. Behaves identically to main-branch Studio.

43. **Studio mode: swipe left (or tap the right-edge coral pull-tab) → back to Camera mode.**

44. **No retake option anywhere in Camera mode.** (Tough love: bad take? do it again, clean up in Studio later.)

45. **A/B verdict:** Does Track B feel meaningfully better than Track A during a simulated capture session? Key moments to notice:
    - Less temptation to fiddle with sliders mid-capture
    - Shutter-tap-to-shutter-tap speed
    - Attention on the "client" (or whatever you're recording) vs attention on phone

---

## Decision

46. **Session Shell verdict:** merge to main, discard, or keep as feature-flag fallback.

47. **Quality verdict on two-zone segmentation:** ship as-is, tune the 35% background strength, or revise the approach.

48. **Any regression from the workout-mode UX overhaul** vs what you had in the last build.

---

## How to give feedback

Reference items by number. Any of:

- "Item 16 feels wrong — the chip should show X"
- "Item 22 broken — nothing happens when I tap"
- "Items 6 and 7 are great, 5 needs tuning"

Claude can dive straight into the right code with that.
