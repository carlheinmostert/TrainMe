# Publish always-enabled + "Nothing to publish" toast — device QA (2026-05-27)

One Studio bottom-toolbar change (mobile-only — Studio config, not
client consumption, so no R-10 web parity):

- **Publish is never disabled.** The PUBLISH cell in the Studio workflow
  pill is always tappable. It used to read as a greyed / inert button in
  some states, which looked broken with no explanation (Carl's call).
- **No-op toast when up to date.** Tapping Publish when there is
  genuinely nothing to publish — the plan is already published, no
  content edits are pending, AND every shippable artifact kind (today
  `handout` + `plan_url`) has already been minted — short-circuits BEFORE
  the publish gate opens: no gate sheet, no progress sheet, no credit, no
  network. A dismissible toast reads "Nothing to publish — already up to
  date."
- **Real publish path unchanged.** Any pending change — a new/edited
  exercise, or a shippable artifact kind that has NOT been minted yet —
  routes to the normal publish gate as before.

Branch: `fix/publish-always-enabled`
Files: `app/lib/screens/studio_mode_screen.dart`,
`app/lib/widgets/studio_bottom_bar.dart`

## Pre-flight

- [ ] Build is the staging tip (this branch merged into staging).
      Confirm via the build chip — short SHA on the Home `HomefitLogo`.
- [ ] Have a client with at least one PUBLISHED session that has both a
      handout and a workout-player artifact already live (publish a
      session with both kinds ticked on the gate, if you don't have one).

## Always-enabled cell

- [ ] 1. Open a brand-new DRAFT session (never published) in Studio.
      The PUBLISH cell renders at full opacity (white glyph + label) —
      not greyed. Tapping it opens the publish gate as normal.
- [ ] 2. Open an already-PUBLISHED session with no pending edits. The
      PUBLISH cell still renders at full opacity (not greyed / not
      reading as broken).

## No-op toast (nothing to publish)

- [ ] 3. On the published session from step 2 (all artifact kinds
      already live, no edits since last publish), tap PUBLISH. A toast
      slides up: "Nothing to publish — already up to date." The publish
      GATE SHEET does NOT open. No progress sheet, no spinner.
- [ ] 4. Check the credit balance (Home chip / portal) before and after
      step 3 — it is UNCHANGED. The no-op path charges nothing.
- [ ] 5. The toast auto-dismisses after a few seconds (or swipe it away).
      It is a toast, not a modal — no "OK" / "Cancel" buttons, nothing
      to confirm.

## Real publish still works (pending changes)

- [ ] 6. On the same published session, make a content edit (change a
      rep count, add/rename an exercise). Tap PUBLISH. This time the
      publish GATE SHEET opens normally (NOT the no-op toast) because
      there is a pending content change.
- [ ] 7. Back out of the gate (don't publish), then add a brand-new
      exercise (capture or duplicate). Tap PUBLISH — the gate opens again
      (pending new content). Complete the publish; it succeeds as before.

## Artifact-aware angle (un-minted kind counts as pending)

- [ ] 8. Take a published session that has the workout PLAYER live but
      NOT the handout (publish with only the player ticked, if you can
      reproduce this). With NO content edits, tap PUBLISH. The gate opens
      (NOT the no-op toast) because the handout kind has not been minted
      yet — there is still something to publish. Tick the handout and
      complete the publish.
- [ ] 9. After step 8, with both kinds now live and no edits, tap PUBLISH
      again. NOW the no-op toast fires ("Nothing to publish — already up
      to date") because every shippable kind is minted and content is
      clean.

## Regression — locked / error states unaffected

- [ ] 10. For a plan past its 14-day grace (locked), the PUBLISH slot is
      still the coral UNLOCK cell and tapping it opens the unlock sheet
      (unchanged).
- [ ] 11. If a publish fails (e.g. airplane mode mid-publish), the cell
      shows the coral error glyph and tapping it still opens the error
      details (unchanged — the no-op toast does NOT swallow the error
      tap).
