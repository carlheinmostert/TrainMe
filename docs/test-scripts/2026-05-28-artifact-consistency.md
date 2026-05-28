# Artefact consistency — Interactive vs Printable Workout Guide — device QA (2026-05-28)

Renames the two artefacts, aligns the Printable Workout Guide to the
Interactive lobby's design, adds a standard footer + real referral QR,
removes the printable's client treatment toggle, and wires the dead Print
button to the native iOS print sheet.

PRs: [#562 web+DB](https://github.com/carlheinmostert/TrainMe/pull/562),
[#563 mobile](https://github.com/carlheinmostert/TrainMe/pull/563). Staging
tip `8af4457`. Stack of origin items: `docs/test-scripts/2026-05-28-stack.md`.

- **Mobile** — the staging build on iPhone CHM.
- **Web (staging)** — `https://staging.session.homefit.studio/p/{planId}`
  (Interactive lobby), `/h/{planId}` (Printable Guide), `/me` (your list).

## A. Naming (both surfaces)

- [ ] 1. Mobile Studio: open the Publish gate and the Preview artefact
      picker — the two kinds read "Interactive Workout Guide" and
      "Printable Workout Guide" (never "Workout player" / "Workout handout"
      / "Take-home handout").
- [ ] 2. Mobile artefact cards (Clients -> a client, and My Workouts) show
      the same two names.
- [ ] 3. Web `/me` + the handout page use the same two names; grep your eye
      for any leftover "Workout plan" / "handout".

## B. Status pill + version (both)

- [ ] 4. Mobile artefact cards: the status pill reads "Published" (the old
      "Live" variant is gone) and shows `Published · v{N}` with the right
      version number.
- [ ] 5. Web `/me` artefact cards show the same `Published · v{N}`.

## C. Printable Workout Guide screen — mobile in-app

- [ ] 6. Open the Printable Workout Guide from a session. There is NO top
      AppBar — it's full-bleed with a floating dismiss/close chip. Tapping
      the chip returns you.
- [ ] 7. Tap the in-page Print button. The native iOS print sheet appears
      (AirPrint printer selection AND Save-as-PDF via the share icon) —
      it is no longer a dead no-op.

## D. Printable Workout Guide — content (web staging `/h/`)

- [ ] 8. There is NO Line / B&W / Original toggle on the page. Each
      exercise renders in the treatment the PRACTITIONER selected for it.
- [ ] 9. Open the same plan's lobby (`/p/`) and the printable (`/h/`) side
      by side: exercise cards share the same design — same hero crop, same
      circuit grouping (with circuit names), same dose/stats wording and
      the SAME rep numbers.
- [ ] 10. The practitioner's name shows on the printable (byline) — it was
      blank before.

## E. Standard footer + real QR (both surfaces)

- [ ] 11. The "Powered by homefit.studio" footer block appears on BOTH the
      lobby (`/p/`) and the printable (`/h/`), and looks identical.
- [ ] 12. Scan the footer QR with your phone camera — it opens
      `manage.homefit.studio/r/{your referral code}`. (If your practice has
      no referral code yet, the QR is cleanly hidden — not a broken
      checker-pattern placeholder.)
- [ ] 13. The "get the app / save this plan to your phone" block looks the
      same on the lobby and the printable (same homefit logo glyph + copy).

## F. Brand-skin (web staging — only if your practice has an active brand skin)

- [ ] 14. On the handout, the brandable chrome (header lockup, save-to-phone
      chip, circuit labels, accents) picks up your brand colour; the
      "powered by homefit.studio" seal stays coral; the exercise cards stay
      neutral dark.

## G. Regression

- [ ] 15. The Interactive Workout Guide (`/p/` player) still runs end to end
      — Start Workout, pill matrix, treatment switching — i.e. adding the
      shared footer didn't break the working player.
- [ ] 16. The change-spine from the prior wave still works: edit an exercise
      on a published session -> coral spine on that card + the session card.
