# Unpublished-changes coral spine — device QA (2026-05-28)

Surfaces a coral 4px left-edge "spine" on (a) each Studio exercise card
whose own content changed since the last publish, and (b) each
session-list card when ANY of its exercises is dirty. Mobile-only
practitioner authoring aid — the spine must NEVER appear on the client
web player.

Spec: `docs/specs/2026-05-28-exercise-change-marker.md`
Mockup: `docs/design/mockups/2026-05-28-exercise-change-marker.html`
Branch: `feat/exercise-change-marker` (merged into staging)

Key decision (Carl, 2026-05-28): reorder DOES light the spine — on a
drag-reorder the WHOLE list goes "out of position" so every exercise
card lights up. This reverses the spec draft; items 9-10 below verify it.

## Pre-flight

- [ ] Build is the staging tip with `feat/exercise-change-marker`
      merged. Confirm via the build chip — short SHA on the Home
      `HomefitLogo`.
- [ ] SQLite migrated 49 -> 50 cleanly (the app launched without a
      crash / data-loss after the upgrade install). Existing sessions
      and exercises still load.
- [ ] You have an already-PUBLISHED session with at least 3 exercises.
      If not, mint one: Clients -> open a client -> New Session -> add
      3+ exercises -> Publish.
- [ ] You also have at least one NEVER-published session (draft) with a
      couple of exercises, for the negative test.

## Migration / first-launch sanity

- [ ] 1. Immediately after the upgrade install (before making any
      edit), open the already-published session in Studio. NO exercise
      card shows a spine — pre-migration rows backfilled `NULL`, so
      there is no edit history yet. (Correct: treated as clean since
      last publish.)
- [ ] 2. In the session list (My Workouts / client detail), the same
      published session also shows NO spine yet (nothing edited since
      publish).

## Exercise-card spine — single edit

- [ ] 3. Open the published session in Studio. Change ONE exercise's
      reps (e.g. open the editor sheet, bump reps, close). That ONE
      exercise card now shows a coral 4px spine down its left edge.
- [ ] 4. The OTHER exercise cards in the same session show NO spine.
      Only the one you edited is marked.
- [ ] 5. Go back to the session list. The session card now shows the
      same coral spine on its left edge (because one of its exercises
      is dirty).

## Edit-site coverage (each should light the edited card)

- [ ] 6. In the published session, edit each of these on DIFFERENT
      exercises and confirm the edited card lights its spine each time:
      notes; sets; hold seconds / hold position; video reps-per-loop;
      inter-set rest; soft-trim handles (drag in/out); preferred
      treatment (Line/B&W/Original swipe); body-focus toggle;
      include-audio / mute toggle; circuit assignment. Each edited card
      should gain a spine; untouched cards stay clean.
- [ ] 7. Thumbnail regeneration / re-convert churn does NOT light a
      spine on its own (only genuine content edits do). If a card's
      Hero re-renders without you editing content, it must stay clean.

## Add a new exercise

- [ ] 8. On the published session, swipe-to-duplicate an exercise. The
      NEW duplicated card shows a spine immediately (it was created
      after the last publish). The session card shows a spine too.

## Reorder lights EVERYTHING (Carl's reversal)

- [ ] 9. On the published session (with no prior edits since publish —
      republish first if needed to clear spines), drag-reorder the
      exercises (move one card to a new position). EVERY exercise card
      in the session now shows a spine — not just the moved one.
- [ ] 10. The session card also shows a spine after the reorder.
      (Order is a published-visible property; the whole plan is now
      out of position and needs a republish.)

## Clear-on-publish

- [ ] 11. With several spines showing (from edits + reorder), Publish
      the session. After publish completes, ALL exercise-card spines
      clear.
- [ ] 12. The session card spine also clears after publish (at both
      My Workouts and client-detail list views).

## Never-published session

- [ ] 13. Open the DRAFT (never-published) session in Studio. Edit an
      exercise, reorder, duplicate — NO spine appears on any exercise
      card regardless of what you change. (A never-published plan is
      entirely "new"; the Publish CTA communicates that, not per-card
      noise.)
- [ ] 14. The draft session card in the list also shows NO spine.

## Offline correctness

- [ ] 15. Put the device in airplane mode. Edit an exercise on the
      published session. The edited card lights its spine and the
      session card lights — immediately, offline (the column is
      local-only; no network needed).

## Visual consistency

- [ ] 16. Side-by-side, the exercise-card spine and the session-card
      spine look identical: 4px wide, coral `#FF6B35`, full card
      height, only the right corners rounded (~2px). They must read as
      the same treatment at a glance.
- [ ] 17. On the session card (which has a filmstrip background + dark
      veil), the spine renders coral-crisp ON TOP of the veil — not
      muddied or hidden behind it.

## Client web player — must stay clean (regression)

- [ ] 18. Open the published plan's client URL (`session.homefit.studio/p/{id}`)
      in a browser. NO coral spine appears anywhere — the marker is
      practitioner-only and must never leak to the client surface.

## Regression — editing/persistence still works

- [ ] 19. After all the edits above, force-quit and relaunch the app.
      Reopen the edited session: the spines you set (on still-dirty
      sessions) persist across relaunch, and the actual edits (reps,
      notes, etc.) are still saved correctly.
- [ ] 20. Reorder still actually reorders (the position change sticks),
      and publishing the reordered plan ships the new order.
