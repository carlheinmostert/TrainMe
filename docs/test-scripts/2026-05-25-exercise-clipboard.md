# Exercise Clipboard — device QA

PR `feat/exercise-clipboard` (Wave: Exercise Clipboard, 2026-05-25). Spec at `docs/specs/2026-05-25-exercise-clipboard.md`. Mockup at `docs/design/mockups/2026-05-25-exercise-clipboard.html`.

In-memory clipboard for cross-session exercise paste. Lives only in Studio. Clears on app cold-start. Single-practice scope at v1.

## How to run this script

- Install the build per the wave brief.
- Open at least TWO real-client sessions in the same practice (or your Self / Me session plus one real-client session). Pre-populate both with at least 2-3 exercises each so the copy + paste flow has real material to land on.
- Walk top to bottom. Strike a line through each passing item; reply with the numbers of any failures.

## Studio swipe — `[Copy] [Duplicate]` reveal (D4)

- [ ] 1. Open a session with 3+ exercises. Right-swipe a non-rest card partway (about a third of the way across). Two coral buttons reveal: `Copy` on the left, `Duplicate` to its right. Both labels readable; icons crisp.
- [ ] 2. Tap `Duplicate` from the partial-swipe reveal. Card collapses; a clone of the exercise appears immediately BELOW the original with the same media, sets, name. Undo snackbar appears at the bottom. (Verifies the `cloneExerciseInto` refactor preserved the existing duplicate path.)
- [ ] 3. Right-swipe another card partway. Tap OUTSIDE the card (anywhere else in the list). The reveal collapses back to neutral without copying or duplicating.
- [ ] 4. Right-swipe the same card partway. Tap `Copy`. Card snaps back into place. A coral chip appears in the top-right of the AppBar showing `📋 1 ×`.
- [ ] 5. Right-swipe a SECOND non-rest card all the way across (long swipe). Card snaps back; chip count increments to `2`. (Long-swipe auto-commits Copy per D4.)
- [ ] 6. Right-swipe the SAME card you copied in step 4 again. Tap `Copy`. Chip stays at `2` (no duplicate add) — but the chip pulses to acknowledge the gesture. (De-dupe by `sourceExerciseId`.)
- [ ] 7. Left-swipe a card all the way. Card animates out; deletion undo snackbar appears. Chip count unaffected.

## Rest periods are not copyable

- [ ] 8. If your session has a rest period, right-swipe it. Either NO `[Copy]` button is offered (the start-action pane is suppressed), or the swipe just behaves like the legacy delete-only Dismissible. There is no path to add a rest period to the clipboard.

## Editor sheet Copy button (D6)

- [ ] 9. Tap an exercise card to open the editor sheet. In the bottom rail (reachability-inverted bottom AppBar), between the exercise name + meta and the right chevron, you see a small coral pill `[📋 Copy]`.
- [ ] 10. Tap `[📋 Copy]`. The button pulses briefly. The chip up at the top-right of Studio (visible above the 88% sheet) bumps its count by 1 (or fades in if it was empty).
- [ ] 11. Tap `[📋 Copy]` again on the same exercise. Button pulses, but the chip count does NOT increment (de-dupe).
- [ ] 12. Use the chevrons to navigate to another exercise in the same sheet. Tap `[📋 Copy]`. Chip count bumps by 1.
- [ ] 13. Open the editor sheet on a REST period card. The `[📋 Copy]` button is NOT rendered between the exercise name and the next chevron. (Rest is non-copyable per D8.)

## Chip behaviour (D5)

- [ ] 14. Clear all items: tap the `×` on the chip's right edge. Chip fades out + collapses; AppBar settles to its empty-clipboard layout (just the settings cog at the far right).
- [ ] 15. Re-copy one item via swipe. Chip fades in with `📋 1 ×`. Layout: clipboard icon, count, thin divider, `×`. Coral capsule with a soft drop shadow.

## Paste sheet basics (D7)

- [ ] 16. With 3 items in the clipboard, tap the chip body (NOT the `×`). A bottom sheet titled `Paste from clipboard` slides up over the Studio list. All 3 rows present, each with a checkmark filled coral on the left, a small thumbnail, the exercise name, and a `VIDEO · just now` / `PHOTO · just now` metadata line.
- [ ] 17. The CTA at the bottom reads `Paste 3 items` (or matching count). Backdrop behind the sheet is dimmed.
- [ ] 18. Tap one row to deselect — its checkmark goes hollow + the row dims to ~45% opacity. CTA updates to `Paste 2 items`.
- [ ] 19. Tap the row again to re-select. Row brightens; CTA returns to `Paste 3 items`.
- [ ] 20. Tap `Paste 3 items`. Sheet auto-dismisses. Three new cards appear at the END of the current session, in the same order they were copied (FIFO oldest-first). Each is a deep copy: new id, new media files on disk, but identical look and behaviour to the source.
- [ ] 21. After paste, tap the chip again. Sheet re-opens with the SAME items still present (re-paste-into-another-session is the headline value). All three checkmarks default to selected (D7 — default-all-selected).

## Cross-session paste (D2, single-practice — D1)

- [ ] 22. From Session A, copy 2 exercises. Navigate back to the clients list, open Session B (different real client, SAME practice). Confirm the chip is visible in B's Studio AppBar with the items still loaded.
- [ ] 23. Tap the chip; `Paste from clipboard` sheet opens. Tap `Paste 2 items`. Two new cards land at the end of Session B. Each one's media plays correctly (line drawing + colour + B&W treatments).
- [ ] 24. Go back to Session A. The original exercises you copied are still there, unchanged.

## Reactive pruning (E1)

- [ ] 25. Copy 2 exercises into the clipboard from Session A. Without leaving Studio, swipe-LEFT to DELETE one of the source exercises you just copied.
- [ ] 26. Chip count drops from 2 to 1 immediately (in the same paint as the source's deletion). No need to tap anything else.
- [ ] 27. If you have the paste sheet open when the deletion fires, the dead row animates out of the sheet. If pruning empties the clipboard entirely, the sheet auto-dismisses.

## Locked-target paste (E2)

- [ ] 28. Find or set up a session that's PAST the 14-day structural-edit grace (a published plan whose `first_opened_at` is more than 14 days ago and that hasn't been unlocked). The AppBar shows the lock indicator.
- [ ] 29. Copy 1-2 exercises into the clipboard. Tap the chip. The paste sheet opens, but the CTA reads `🔒 Unlock to paste · 1 credit` (or `Unlock to paste 2 items · 1 credit`).
- [ ] 30. Tap that locked CTA. The familiar 1-credit unlock sheet rises (the same one the padlock chip would surface). Tap `Unlock`. On success: unlock sheet dismisses, the paste runs automatically, and the new card(s) land at the end of the now-unlocked session.
- [ ] 31. Cancel the unlock instead. Paste does NOT run. Clipboard items remain.

## Persistence rule (D3)

- [ ] 32. With 2-3 items in the clipboard, fully background the app (swipe up). Re-open. Chip count is still there.
- [ ] 33. With 2-3 items in the clipboard, fully KILL the app from the iOS app-switcher (swipe up on the card). Re-open. Chip is gone — the clipboard cleared on cold-start (D3 — in-memory only).

## Studio drag-to-reorder still works (regression check)

- [ ] 34. Long-press and drag a card vertically. The card lifts and you can drop it in a different position. Reorder still functions exactly as before the swap from Dismissible to Slidable.
