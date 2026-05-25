# 2026-05-25 — Live-page practitioner-popover polish

**Branch:** `fix/live-popover-report-polish`
**Surfaces:** web player only — `staging.session.homefit.studio/v/homefit/home-2/now`
**Scope:** practitioner-avatar popover button order + Report modal z-index above the Leaflet map.

## Table of Contents

- [Preflight](#preflight)
- [Tests](#tests)
- [Notes](#notes)

## Preflight

- Open the live transparency page for a premises that currently has at least one practitioner pin on the map. Default: `https://staging.session.homefit.studio/v/homefit/home-2/now`.
- If no practitioner is currently active inside that premises, use any other premises with a visible avatar on the map. The popover only renders when there is a tappable practitioner pin.
- Hard-refresh (Cmd+Shift+R on desktop, or pull-to-refresh in mobile Safari) so the new bundle loads. Confirm the build chip in the page footer shows the new commit SHA.

## Tests

- [ ] **1. Popover opens with Report on the LEFT, "View practice profile →" on the RIGHT.** Tap a practitioner avatar on the map. The popover appears anchored to the avatar with the practitioner's name and zone metadata up top, and a single action row below containing — in this order, left-to-right — a `Report` button (transparent background, bordered) and a `View practice profile →` text link (lighter, with the right-pointing arrow glyph). The two actions are baseline-aligned with a small gap between them, not stacked vertically.

- [ ] **2. "View practice profile →" only renders for publicly listed practices.** Open the popover on a premises whose parent practice does NOT have a public profile listing. The Report button still appears (now the only action in the row). No layout gap, no broken arrow.

- [ ] **3. Tapping Report opens the modal FULLY ON TOP of the map.** Tap the Report button. The modal lands above everything: the dim backdrop covers the entire viewport (including the map tiles, the polygon overlay, and the avatar pins); the white-on-dark report card is centered on top; the Cancel and Send report buttons are fully visible and clickable. No part of the modal is occluded by Leaflet panes, controls (zoom buttons, attribution), or the map polygon.

- [ ] **4. Modal works end-to-end.** With the modal open: type a short reason ("test report from QA"), tap Send report. A success toast appears ("Report sent..."). The modal closes cleanly and the map is fully visible again. Tapping the Cancel button on a separate report attempt also closes the modal without sending.

- [ ] **5. Tapping outside still dismisses the popover.** Open the popover. Tap on an empty area of the map (NOT on another avatar). The popover dismisses. Open it again, press Escape — it dismisses. Open it, tap another practitioner's avatar — the previous popover dismisses and the new one appears anchored to the new avatar.

- [ ] **6. "View practice profile →" link still navigates correctly.** With a publicly listed practice's popover open, tap the profile link. Browser navigates to `/v/{practice-slug}` (the public practice profile page). Middle-click (or long-press on mobile → "Open in new tab") opens that URL in a new tab without dismissing the original page's state.

## Notes

- Z-index choice: `.live-report-backdrop` was bumped from `z-index: 100` to `z-index: 9999`. The host element `#live-report-modal` already lives at the document body level (sibling of `<main>`, NOT inside `.leaflet-container`), so it is not trapped in the map's stacking context — z-index here is compared against the whole page. 9999 outranks Leaflet's popup pane (700), tooltip pane (650), and control pane (1000) with room to spare for any future map UI.

- Button order rationale: Report is the more important affordance on a transparency page (the page exists so bystanders can flag misuse), so it leads in the reading order. The profile link is secondary context discovery.

- No SW changes in this PR. The parallel `fix/sw-network-first-and-live-bypass` PR is shipping the SW refactor separately; this branch leaves `sw.js`, `app.js`, `lobby.js`, and the SW-related plumbing in `live.js` untouched to avoid merge conflicts.
