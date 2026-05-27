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
