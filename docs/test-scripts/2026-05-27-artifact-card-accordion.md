# Artifact-card accordion — device QA (2026-05-27)

Replaces the PR #548 fanned-deck UI with a per-session vertical
accordion-expand on three surfaces (R-10 parity):

- **Mobile** — ClientSessionsScreen (Clients tab -> client) AND
  My Workouts (Home tab -> My Workouts)
- **Web** — `/me` on `session.homefit.studio` (sign in via magic link)

Spec: `docs/specs/2026-05-27-artifact-card-expansion.md`
Mockup: `docs/design/mockups/2026-05-27-artifact-card-expansion.html`

## Pre-flight

- [ ] Build is the staging tip (`feat/artifact-card-accordion` branch
      merged into staging). Confirm via the build chip — short SHA on
      the Home `HomefitLogo` (mobile) or footer (web).
- [ ] At least one client exists with one published plan that has BOTH
      a workout plan AND a handout artifact. (PR #548 publish flow
      writes both kinds by default.) If not, mint one: Clients -> open
      a client -> New Session -> add 1-2 exercises -> Publish -> select
      both Workout plan + Handout in the gate.

## ClientSessionsScreen (mobile)

- [ ] 1. Open the Clients tab and tap into a client that has at least
      one published session. The published session card paints a faint
      peek edge offset down + right behind the card. The chevron at
      the right side of the card is coral.
- [ ] 2. A session in the same list that has NO published artifacts
      paints exactly as before — no peek edge behind, no coral
      chevron, only the static grey chevron-right glyph.
- [ ] 3. Tap the coral chevron on the published session. The peek
      lifts upward and fades. The card stays in place. Artifact cards
      stagger into view below the session card. A 3px coral hairline
      rail draws downward along the left edge of the artifact stack.
- [ ] 4. Tap the body of the SAME session card (not the chevron) —
      the existing behaviour holds: Studio mode opens for that
      session. Back-arrow returns to the list.
- [ ] 5. Tap the chevron on a SECOND published session while the
      first one is expanded. The first session collapses (rail fades,
      artifact cards stagger out, peek slides back in, chevron rotates
      back). The second session expands.
- [ ] 6. Tap the chevron on the currently-expanded session. It
      collapses cleanly back to rest state.
- [ ] 7. Expand a session, then tap the front artifact card
      (Workout plan). The in-app preview deck opens. Back-arrow returns
      to the client list with the accordion still expanded.
- [ ] 8. Expand a session, then tap the handout artifact card. A
      full-screen WebView loads at `session.homefit.studio/h/{planId}`.
      Back-arrow returns.
- [ ] 9. Swipe the published session card left. Soft-delete fires
      immediately with the Undo SnackBar. (Verifies the Dismissible
      affordance survived the accordion wrap.)

## My Workouts (mobile)

- [ ] 10. Tap the Home tab -> My Workouts.
- [ ] 11. Published self-workout cards show the same peek + coral
      chevron treatment as ClientSessionsScreen. Unpublished cards
      paint clean (no peek, no chevron).
- [ ] 12. Expand one — the accordion behaves identically: rail draws,
      artifacts stagger in. Tap the front artifact card to open the
      preview deck; back-arrow returns.

## Studio (mobile) — regression

- [ ] 13. Open any session in Studio (capture or edit). NO fanned
      deck appears above the exercise list. The exercise list sits
      flush below the AppBar.
- [ ] 14. Publish a fresh artifact from Studio (Publish toolbar cell
      -> select kinds -> commit). The publish completes, the lock
      pill polish + status post-publish snapshot still updates, but
      no deck mounts.

## Web `/me`

Surface URL (staging): `https://staging.session.homefit.studio/me`.
Sign in via magic link if not already.

- [ ] 15. The signed-in list paints session-card rows, one per
      published plan. Each row with artifacts shows the peek behind
      + coral chevron at the right end of the card.
- [ ] 16. Tap the chevron — peek lifts + fades, accordion expands
      with rail + staggered artifact cards.
- [ ] 17. Tap the front artifact card (Workout plan). Browser
      navigates to `/p/{planId}` (the workout-player surface). Press
      back; accordion still expanded.
- [ ] 18. Tap the handout artifact card. Browser navigates to
      `/h/{planId}`. Press back; accordion still expanded.
- [ ] 19. Tap a second session's chevron — first collapses, second
      expands (single-open).
- [ ] 20. For an owner bundle (you are the practitioner who minted
      the plan), the "Use as template for a client" coral CTA renders
      INSIDE the expanded artifact area (NOT on the collapsed session
      card). Tapping it fires the
      `studio.homefit.app://template?session_id=X` deep-link (iOS will
      prompt to open in homefit.studio if installed).
- [ ] 21. Tap the chevron on a row that has no artifacts (rare on
      `/me` since the RPC only returns plans with artifacts — flag
      "no chevron rendered" if it's there at all).

## R-10 parity check

- [ ] 22. Compare mobile and web side-by-side on the same plan. Peek
      offset, chevron color, expanded accordion timing, rail color,
      artifact-card pill copy ("PUBLISHED" / "LIVE") all match.

## Accessibility

- [ ] 23. On web — enable macOS reduce-motion (System Settings ->
      Accessibility -> Display -> Reduce motion). Reload `/me`,
      expand a row. Peek-lift, rail-draw, and stagger are instant;
      chevron rotation still animates (it's a directional cue).
- [ ] 24. Tab to the chevron with the keyboard on web; press Enter.
      It toggles the accordion. The chevron has a visible focus ring.

## Edge cases

- [ ] 25. Brand-skin-subscribed practice (Carl-sentinel + active
      brand subscription) — the FRONT artifact card uses the brand
      color for its accent border. The rail stays coral regardless.
- [ ] 26. Single-artifact bundle (only Workout plan, no handout
      published yet) — expand still works; just one artifact card
      animates in.
- [ ] 27. Many-artifact bundle (rare today — only the workout-plan +
      handout kinds ship, so max 2). If a future kind lands, stagger
      continues at 50ms + 60ms per card.

## Wave 2 — iteration (2026-05-27 afternoon)

After Wave 1 device-QA, four refinements landed in `feat/artifact-card-iteration`:
rail gutter, two stacked action buttons, slowed deal-of-cards animation,
and button-order locked (Studio on top, Artifacts on bottom). Re-run the
following on mobile + web after the wave merges to staging.

### Rail visibility in the gutter

- [ ] 28. Expand a published session on ClientSessionsScreen. The
      artifact cards are inset roughly 10dp from the session card's
      left edge; the coral 3dp rail sits fully visible in the gap
      between the session card's left edge and the artifact card's
      left edge. No part of the rail is obscured by card chrome.
- [ ] 29. Same check on My Workouts. Same check on /me. All three
      surfaces show the rail in the gutter, not behind the cards.

### Two stacked action buttons

- [ ] 30. Every session card (published AND unpublished) on
      ClientSessionsScreen + My Workouts shows the Studio action
      button (pencil + chevron-right `›`) at the right end of the
      card-body row. Tap the Studio button: Studio mode opens for
      that session.
- [ ] 31. Sessions WITH artifacts also show the Artifacts action
      button (stacked-cards + chevron-down `▾`) stacked BELOW the
      Studio button. Sessions WITHOUT artifacts hide the Artifacts
      button entirely — only the Studio button renders.
- [ ] 32. Tap the Artifacts button on a published session. The
      accordion expands as before. The chevron-down arrow on the
      Artifacts button rotates 180° to point up. Tap again: collapses,
      arrow rotates back.
- [ ] 33. Tap the body of the session card (not either button). Studio
      mode opens (existing behaviour preserved — the Studio button is
      an additional explicit affordance, not a replacement).
- [ ] 34. Tap-target check: each button visibly measures ~36pt, but
      the combined vertical hit area covers the card-body padding so
      each individual button still hits Apple HIG's 44pt minimum.
      Verify by tapping just above/below each visible button — the
      button still fires.
- [ ] 35. Press states: tap and hold each button. The button scales
      down briefly (active state). Both buttons brighten on hover/press.

### Slowed deal-of-cards animation

- [ ] 36. Expand a session with at least 3 artifacts. The cards visibly
      SLIDE DOWN from behind the session card (not fade in place).
      Deeper cards travel farther than the front card. Total time
      from tap to last card landing is roughly 1.5 seconds.
- [ ] 37. The coral rail draws from top to bottom AFTER the siblings
      below push down — there's a perceptible head-start delay before
      the rail begins drawing.
- [ ] 38. Reduce-motion check: enable iOS Settings → Accessibility →
      Motion → Reduce Motion. Expand a session. The cards land
      instantly with no slide animation. The Artifacts button arrow
      still rotates (it's a directional cue, not decoration).

### Web `/me` parity

- [ ] 39. On /me as an OWNER (signed in as the practitioner who minted
      the plan): the Studio button appears on the session row. Tap it
      — the deep-link to `studio.homefit.app://template?session_id=X`
      fires. iOS prompts to open homefit.studio if installed.
- [ ] 40. On /me as a NON-OWNER (signed in as a consumer who claimed
      a plan from a different practitioner): the Studio button is
      HIDDEN. Only the Artifacts button renders. The "Use as template"
      CTA inside the expanded area is also hidden for non-owners
      (preserved from Wave 1).
- [ ] 41. Side-by-side comparison: mobile ClientSessionsScreen vs web
      /me for the same plan. Both surfaces show the same gutter
      inset, same button stack, same slowed animation timing. Cards
      land in the same order with similar perceived rhythm.

### Regression — preserved behaviours from PR #549

- [ ] 42. Studio is still clean (no fanned deck above the exercise
      list). Publishing still works.
- [ ] 43. /me has no Share button anywhere (load-bearing for
      monetization, preserved from PR #549).
- [ ] 44. Brand-skin-subscribed practice: the front artifact card
      still uses the brand color for its accent border. The rail
      stays coral regardless. (Same check as item 25.)
- [ ] 45. Soft-delete swipe still fires on the session card with
      the new action stack mounted in the trailing slot (regression
      check for item 9).
