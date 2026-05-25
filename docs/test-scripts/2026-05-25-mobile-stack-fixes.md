# 2026-05-25 mobile stack fixes (PR `fix/mobile-stack-2026-05-25`)

Eight items from `docs/test-scripts/2026-05-25-stack.md` (mobile half):
M1, M2, M3, M4, M8, M9, M10, M11. Walk on iPhone CHM after install.

Item numbers below are **independent of the stack file's M-prefix** — strike
the number when the listed verification path passes.

## M8 — Exercise Clipboard (sev1)

- [ ] **1.** Open any session in Studio with at least 3 captured exercises.
  Right-swipe slowly on the topmost exercise card so only the `[Copy]
  [Duplicate]` action pane is revealed (partial swipe). Tap `Copy`. The
  source card MUST stay visible in the list — only the AppBar chip should
  pop in showing `1`. Confirm the gutter-rail bullet is still attached to
  the exercise card body (no ghosting).

- [ ] **2.** Right-swipe the same card aggressively past the ~70 % threshold
  (long swipe). The row should snap back into place after the swipe; a
  `2` appears on the chip (the long-swipe auto-commits Copy). The source
  card must NOT disappear from the list. Repeat on exercises 3, 4, 5 to
  confirm the bug doesn't regress on multi-copies.

- [ ] **3.** Pop back to Clients (Home) — chip is gone from this screen
  (expected — Home isn't a Studio AppBar). Open a DIFFERENT session in
  Studio. The chip must be present in that session's AppBar showing the
  carried-over count (e.g. `5`). Tap the chip body — the paste sheet
  surfaces with the 5 items.

- [ ] **4.** From the paste sheet, paste 2 items into the new session.
  Confirm the chip count drops to 3 (paste auto-removes the pasted
  items from the clipboard per spec D6). Tap the chip's `×` — chip
  disappears, count drops to 0.

- [ ] **5.** Left-swipe Delete on any source card — the card removes
  with the existing undo SnackBar. Confirm the clipboard chip
  count drops if the deleted exercise was previously copied (reactive
  pruning).

## M1 — Home AppBar

- [ ] **6.** On Home → My Workouts tab, confirm BOTH icon clusters are
  visible: left (`+` / shield) AND right (`?` / gear). Previously the
  left pair hid on My Workouts.

- [ ] **7.** Switch to Clients tab → same four icons stay visible.
  Switch to Classes → same four icons. None of the icons should hide
  on any tab.

- [ ] **8.** Eyeball: the four icons should vertically center on the
  matrix glyph + wordmark axis of the brand lockup. Previously they
  sat above the centerline.

- [ ] **9.** Eyeball: the black space above and below the lockup feels
  tighter than the previous build. The lockup no longer dominates the
  top of the screen.

## M2 — My Workouts empty-state copy

- [ ] **10.** Sign in to a fresh test account (or delete the Self-
  client's sessions) so My Workouts is empty. The body copy reads:
  `Tap New Session to record a workout. Use it as your own follow-
  along, or share it with the people you train.` (NOT the old
  "every clip becomes a line drawing" wording.)

- [ ] **11.** Confirm the headline `Record your first workout` and the
  muted line `Got a link from your practitioner? Tap to claim it.`
  are still present below the new body.

## M3 — Safe Mode hint overlay debug toggle

- [ ] **12.** Open Camera mode. The top-right corner must NOT show the
  black HUD chip (GPS lat/lng + premises match block). This was the
  always-on debug overlay; default is now OFF.

- [ ] **13.** Pop back to Settings → scroll to the About section → tap
  the version row `7 times` quickly to surface the Debug panel. A
  new row appears: `Show Safe Mode hint overlay` with an adaptive
  switch (default OFF).

- [ ] **14.** Flip the switch ON. Pop back into a session → Camera
  mode. The HUD chip is now visible top-right. Flip the switch OFF
  again in Settings → re-open Camera → HUD is gone.

## M4 — Camera 0.5x lens

- [ ] **15.** On a triple-camera iPhone (16e qualifies), open Camera
  mode pointing at a wide scene (whole room visible). Tap the `0.5×`
  pill on the right edge — the viewfinder MUST show MORE of the scene
  (wider FOV). Previously it zoomed IN (narrower FOV).

- [ ] **16.** Tap the `1×` pill — viewfinder returns to the wide camera
  default framing.

- [ ] **17.** If telephoto is available, tap `2×` or `3×` — those zoom IN
  as expected. (Sanity check that the M4 fix didn't break the existing
  zoom-in lenses.)

## M9 — Client-detail consent pill

- [ ] **18.** Open any client's detail screen. The consent chip in the
  header now reads `N/6 granted` (was `N/5`). Tap the chip → consent
  sheet opens. Toggle the `Safe Mode face recognition` switch ON →
  count increments. Toggle OFF → count decrements.

- [ ] **19.** R-10 parity: open `staging.manage.homefit.studio/clients/{id}`
  for the same client. The portal chip also reads `N/6 granted`.

## M10 — Safe Mode subscribe chip

- [ ] **20.** Inside an enforcing Safe Mode premises, WITHOUT an
  active subscription: the prior full-width orange banner is GONE.
  Instead, a small coral chip aligned RIGHT under the AppBar reads
  `[shield] Subscribe to capture here →`. ~24 px tall (was ~95 px).

- [ ] **21.** Tap the chip — external Safari opens the portal
  `/safe-mode/subscribe` page. Reader-App compliant (no in-app
  purchase button on the chip).

- [ ] **22.** Walk OUT of the premises geofence — chip disappears.
  Walk back IN — chip returns.

- [ ] **23.** If you have an active sub: in-zone shows the existing
  `SAFE MODE ACTIVE` orange banner (not the new chip). Out of zone
  shows nothing. Manual-mode override still shows the full banner
  (the chip is auto-mode only).

## M11 — Studio CAPS toolbar vertical balance

- [ ] **24.** Open Studio in any session. Eyeball the bottom workflow
  pill (`CAPTURE · ADJUST · PREVIEW · PUBLISH · SHARE`) — the gap
  above and below the pill should read roughly symmetrical (~6-8 pt
  each side). The previous build had ~34 pt of black space below
  the pill (the iPhone 16e home-indicator safe-area inset).

- [ ] **25.** Confirm the pill still clears the home indicator strip
  (not visually overlapping). A small clearance gap is intentional.
