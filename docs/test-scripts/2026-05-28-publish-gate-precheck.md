# Publish gate — pre-check workout player so edits re-publish (free) — device QA (2026-05-28)

One Studio publish-gate change (mobile-only — Studio config, not client
consumption, so no R-10 web parity):

- **Workout player pre-checked on gate open.** Whenever the publish gate
  opens, the core "Workout player" (`plan_url`) row is already ticked and
  the confirm button is enabled. PR #557's no-op guard means the gate is
  never reachable when the plan is fully up to date, so there is always
  publishable work in the player row by the time the gate opens.
- **Edits to an already-published plan can be re-published.** Before this
  fix, editing a published workout and tapping Publish opened a gate where
  the player row was locked as "Live" and nothing was checkable — the
  confirm button stayed permanently disabled and the practitioner could
  NOT ship their edits. Now the player row re-opens as a checkable +
  pre-checked re-publish row.
- **Re-publishing is FREE.** An already-published (already-paid) plan
  never re-charges on re-publish. The gate's running total shows "Free"
  / 0 credits, the player row's price column shows "Free", and the CTA
  reads "Publish 1 artifact · free".
- **First publish charging unchanged.** A never-published plan still
  shows the workout-player tier price (1 or 2 credits) on first publish.
- **Handout / future kinds stay opt-in.** Only the player is pre-checked;
  the handout and any future kinds remain unchecked by default.

Branch: `fix/publish-gate-precheck-edits`
Files: `app/lib/widgets/publish_gate_sheet.dart`,
`app/lib/screens/studio_mode_screen.dart`

## Pre-flight

- [ ] Build is the staging tip (this branch merged into staging).
      Confirm via the build chip — short SHA on the Home `HomefitLogo`.
- [ ] Have a client with at least one PUBLISHED session whose workout
      player is already live (publish a session, ticking the player on
      the gate, if you don't have one).

## Pre-check on gate open

- [ ] 1. Open a brand-new DRAFT session (never published) with at least
      one exercise. Tap PUBLISH. The gate opens with the "Workout player"
      row ALREADY TICKED (coral check) and the confirm button ENABLED.
- [ ] 2. In the same first-publish gate, the "Workout handout" row is
      UNTICKED (opt-in). Only the player is pre-checked.

## Edit re-publish (the bug this fixes)

- [ ] 3. Open the already-PUBLISHED session from pre-flight. Make a
      content edit (change a rep count, rename or add an exercise). Tap
      PUBLISH. The gate opens with the "Workout player" row TICKED and the
      confirm button ENABLED (it is NOT locked as a greyed "Live" row).
- [ ] 4. Tap the confirm button. The publish runs and your edits ship —
      the plan version bumps and the live player reflects the edit.

## Credit correctness (re-publish is free)

- [ ] 5. In the edit-republish gate from step 3, the big "Total now"
      number reads "Free" (sage), NOT "1" / "2". The "Workout player"
      row's right-hand price column also reads "Free / 0 cr".
- [ ] 6. The confirm button label reads "Publish 1 artifact · free"
      (NOT "· 1 credit").
- [ ] 7. Check the credit balance (Home chip / portal) before and after
      completing the re-publish in step 4 — it is UNCHANGED. Re-publishing
      an already-paid plan charges nothing.

## First publish still charges (regression)

- [ ] 8. In the first-publish gate from step 1 (never-published plan),
      the "Workout player" row's price column shows its tier price ("1"
      / "credit", or "2" for a > 75 min plan) — NOT "Free". The big
      "Total now" shows that credit cost.
- [ ] 9. Complete that first publish. The credit balance DROPS by the
      tier price (1 or 2). First-publish charging is unaffected by this
      fix.

## Live row stays locked when truly up to date

- [ ] 10. On a published session with a handout ALSO already live and NO
      content edits: the no-op toast fires before the gate opens (per the
      2026-05-27 publish-button wave) — so you won't see the gate. This is
      expected; the pre-check only matters once the gate is reachable.
- [ ] 11. If you publish ONLY the player (not the handout) and then,
      with NO edits, tap PUBLISH again: the gate opens (handout still
      pending). The "Workout player" row shows as locked "Live" (no
      pending edits → not re-checkable) while the "Workout handout" row
      is checkable. Confirm enables once the handout is ticked. The total
      shows the handout's cost (Free) — the live player adds nothing.
