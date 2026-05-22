# 2026-05-22 — Safe Mode redesign wave · build bbce3e8

Test script for the wave that bundles: PR #420 (hysteresis + countdown), #421 (editor privacy + Studio polish), #422 (Clients header redesign + Safe Mode toggle), #423 (face algorithm + Gaussian blur).

Open in CC Desktop preview pane (Cmd+Shift+V). Strike items as they pass (`- [x] ~~text~~`); flip to `- [ ] FAIL — note` for failures.

## Table of Contents

- [Pre-flight](#pre-flight) — items 1-3
- [Clients header redesign + Safe Mode toggle](#clients-header-redesign--safe-mode-toggle) — items 4-9
- [Settings practice picker](#settings-practice-picker) — items 10-11
- [Persistent Safe Mode banner](#persistent-safe-mode-banner) — items 12-15
- [Hysteresis + countdown](#hysteresis--countdown) — items 16-19
- [Banner icon + Studio toggle removal](#banner-icon--studio-toggle-removal) — items 20-21
- [Studio editor privacy fix](#studio-editor-privacy-fix) — items 22-25
- [Face-based subject discriminator](#face-based-subject-discriminator) — items 26-28
- [Gaussian blur treatment](#gaussian-blur-treatment) — items 29-30
- [Studio toolbar padding](#studio-toolbar-padding) — item 31
- [HUD diagnostic](#hud-diagnostic) — item 32

## Pre-flight

- [ ] **1.** Launch app, confirm build SHA on home footer reads `bbce3e8 · staging`.
- [ ] **2.** Sign-in state preserved from previous build (no Sign-In screen).
- [ ] **3.** Staging tint visible on chrome.

## Clients header redesign + Safe Mode toggle

- [ ] **4.** Top-left header has the Safe Mode toggle icon (shield + two figures) next to the `person_add` icon.
- [ ] **5.** The row below the Clients/Classes/Workouts tabs is GONE — practice picker + credits pill removed. Only "Updated just now" sync line remains.
- [ ] **6.** Outside any polygon, tap Safe Mode toggle → state engages manual → persistent coral banner appears at top of screen.
- [ ] **7.** Tap again → toggle off → banner fades out (500ms).
- [ ] **8.** Step inside your home polygon → toggle automatically becomes locked (coral fill + small lock glyph in the corner).
- [ ] **9.** Tap the locked toggle → snackbar appears: "Enforced by your current premises" (or similar). State doesn't change.

## Settings practice picker

- [ ] **10.** Open Settings → practice row now has a chevron indicating it's interactive.
- [ ] **11.** Tap practice row → bottom-sheet picker opens → switch (if 2+ practices) → Settings row updates with new practice name.

## Persistent Safe Mode banner

- [ ] **12.** With Safe Mode active, banner appears at top of EVERY screen (Clients, Studio, Settings, editor sheet).
- [ ] **13.** Banner sub-line reads "Home · bystanders obscured" when auto-active in a polygon, "Manual · bystanders obscured" when manual.
- [ ] **14.** Banner has a subtle breathing pulse animation (~2.5s cycle).
- [ ] **15.** Banner is positioned below the iOS status bar, doesn't overlap the dynamic island or notch.

## Hysteresis + countdown

- [ ] **16.** Active in polygon. Step OUT of polygon → sub-line changes to "Leaving Home · {N}s" with countdown ticking down each second (starts at ~60s).
- [ ] **17.** Walk back IN during the trailing window → sub-line reverts to "Home · bystanders obscured" immediately. No countdown.
- [ ] **18.** Stay outside for the full window (4 misses × ~15s = ~60s) → banner fades out smoothly over 500ms then collapses.
- [ ] **19.** Transient GPS errors (briefly cover the antenna) do NOT increment the deactivation counter — banner stays.

## Banner icon + Studio toggle removal

- [ ] **20.** Banner icon is visibly larger (~36px) with dark shield + coral cutouts — reads clearly against the coral banner background.
- [ ] **21.** Studio settings sheet (gear icon → Now tab) no longer has a Safe Mode toggle row.

## Studio editor privacy fix

- [ ] **22.** Capture a video inside your polygon with a bystander visible. Wait for conversion.
- [ ] **23.** Open the exercise in editor sheet → switch to **B&W** treatment → bystander appears as a BLURRED region (not original un-obscured, not coral silhouette).
- [ ] **24.** Switch to **Colour/Original** treatment → bystander is ALSO blurred (privacy preserved across all treatments).
- [ ] **25.** SafeModeIcon overlay near the treatment selector sits BESIDE the Colour pill, no longer overlapping it.

## Face-based subject discriminator

- [ ] **26.** Take a selfie photo where the bystander is more centered / straight-on than you (similar framing to your earlier test).
- [ ] **27.** Open in editor → confirm YOU are the visible subject and the BYSTANDER is blurred. No more wrong-person bug.
- [ ] **28.** Try with multiple bystanders behind you → all are blurred except you (largest face = subject).

## Gaussian blur treatment

- [ ] **29.** New blur treatment looks like a "sensitive photo" blur — heavy Gaussian softening, no flat coral fill anywhere.
- [ ] **30.** Blur is consistent on both videos and photos. Background (non-person pixels) passes through normally.

## Studio toolbar padding

- [ ] **31.** Open Studio → space above and below the bottom toolbar is symmetric. No wasted gap at the bottom of the screen.

## HUD diagnostic

- [ ] **32.** Top-right of camera viewfinder still shows the diagnostic HUD with status / gate / fix / match / premises lines.
