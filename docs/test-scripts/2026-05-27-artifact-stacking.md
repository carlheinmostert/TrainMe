# 2026-05-27 — Artifact stacking UI (Studio + My Workouts)

PR #548 (`dc518d3`). Brings the artifact-stacking UI from the mockup to both surfaces: Studio gets a fanned deck above the exercise list showing the session's published artifacts; the consumer `/me` page groups artifacts into bundles per source session, removes all Share buttons, and adds a "Use as template for a client" CTA on owner-viewed bundles.

Open the mockup side-by-side while testing: `docs/design/mockups/2026-05-27-artifact-stacking.html`.

## Pre-flight

- [ ] 1. Install ran cleanly: app launches without a white-screen crash.
- [ ] 2. Sign in (or persistent session resumed) and land on the Clients screen.
- [ ] 3. Practice chip top-right shows your current practice — single-tap should not lose state.

## Studio — session-anchored deck

Open an existing published session (one that already has a `plan_url` published — ideally one with both `plan_url` + `handout`).

- [ ] 4. Above the exercise list, a fanned deck is visible. Front card sits flat (centred), back cards fan out to the upper-right with progressive rotation + scale ramp-down.
- [ ] 5. Front card has a coral accent (border + kind-pill). Back cards have neutral chrome.
- [ ] 6. Front card breathes — subtle scale pulse (~1.2%) over a ~3.6s loop. Should feel gentle, not twitchy.
- [ ] 7. Tap a back card → it rotates to the front of the stack with a snappy spring landing (~720ms, slight overshoot). Other cards reflow to new positions.
- [ ] 8. Cards display kind-specific thumbnails: workout plan = filmstrip-style strip of exercise hero frames; handout = document-style lines with a coral title bar.
- [ ] 9. Open a session that you haven't published yet (or one with no artifact rows) — the deck zone collapses cleanly (no orphaned empty container).
- [ ] 10. Publish a session, return to Studio — the new artifact card appears in the deck without needing to leave the screen + re-enter. If a re-render is needed, that's a paper cut to flag.

## Studio — tap-to-play per kind

- [ ] 11. Tap the front workout-plan card → play-burst beat fires (coral halo expands outward, card grows briefly), then the existing in-app preview deck opens. Back-navigating returns to Studio with the deck intact.
- [ ] 12. Tap the front handout card → play-burst beat fires, then a full-screen WebView opens loading `https://session.homefit.studio/h/{planId}` (or the staging twin). Handout renders. Close button returns to Studio.
- [ ] 13. Tap a placeholder/future-kind card (if any are present in your test data) → friendly "Coming soon" SnackBar fires; does NOT error or crash.

## Studio — brand-skin awareness

Requires the practice to have an active brand-skin subscription (Wave 4). Skip if not subscribed.

- [ ] 14. Front card's coral accent is replaced with the practice's brand color. Back cards stay neutral.
- [ ] 15. Lapse-state (grace window) — if the practice is in grace, the front card chrome shifts to a dimmed brand color (visual signal that something has changed). Skip if practice is fully active.

## My Workouts (`/me`) — bundle stacks

Open `https://staging.session.homefit.studio/me` in Safari. Sign in with the magic-link flow if needed (Wave 2 — should land cleanly on `/me`).

- [ ] 16. Page loads without errors. Console clean.
- [ ] 17. Artifacts the test account has claimed are grouped into bundles, one bundle per source session. Bundles list vertically.
- [ ] 18. Each bundle renders as a horizontal fanned deck (max 3 visible cards). Front card has coral accent.
- [ ] 19. Tap a back card in a bundle → it rotates to the front with the same spring curve as mobile. Other cards reflow.
- [ ] 20. **There is NO Share button anywhere on `/me`.** Not in headers, not on individual cards, not in any menu. Confirm explicitly — this is load-bearing for monetization.
- [ ] 21. For bundles where you (the signed-in user) are the practitioner who owns the artifact, a "Use as template for a client" CTA appears below the bundle. For bundles received from another practitioner, the CTA does NOT appear.
- [ ] 22. Tap the "Use as template for a client" CTA → Safari attempts to open `studio.homefit.app://template?session_id=X`. iOS shows the standard "Open in homefit?" prompt. Tap "Open" — the app launches (deep-link handler is NOT wired yet, so the app just opens to its last screen; this is expected for now).

## My Workouts — accessibility + edge cases

- [ ] 23. The deck animation respects `prefers-reduced-motion` — if Settings → Accessibility → Motion → Reduce Motion is ON, the breathing pulse + rotation animations are suppressed or significantly reduced. Verify by toggling Reduce Motion mid-session.
- [ ] 24. Tap an empty area around a bundle (between cards, in the padding) — no accidental rotation fires; only direct card taps register.
- [ ] 25. Pull-to-refresh on `/me` works without breaking the deck layout.

## Regression smoke

- [ ] 26. Capture screen still works: short-press = photo, long-press = video, slide-up-to-lock recording, lens pills, peek box.
- [ ] 27. Publish flow still works end-to-end (no regression on the credit gate or the multi-kind picker from Wave 3).
- [ ] 28. The "Email this plan" managed-share path (Wave 5) still works — Resend delivery to a real address.
- [ ] 29. Brand-skin lapse banner (Wave 4) still mounts on authenticated portal pages when the practice is in grace.

## Notes

- Stack item 1 (remove "1cr" subtitle under Publish) — NOT in this PR. Look for the subtitle to confirm it's still there; will be removed in the next stack execution.
- Stack item 2 (Preview + Share artifact-kind picker) — NOT in this PR. Preview/Share still skip the picker.
- Self-trainer auto-publish-no-share-sheet — NOT in this PR.
- The "Use as template" deep-link handler in the mobile app — NOT wired. The CTA fires the URL but the app doesn't intercept it yet.
