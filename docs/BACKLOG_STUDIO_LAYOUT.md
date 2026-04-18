# Studio layout blow-out — 3 failed attempts, pick up here

**Status:** Open. Critical MVP blocker.
**Last update:** 2026-04-18 end-of-session.
**Target file:** `app/lib/screens/studio_mode_screen.dart` + `app/lib/widgets/studio_exercise_card.dart` + `app/lib/widgets/gutter_rail.dart`.

## Symptom

Studio list blows vertically when a plan contains a circuit. With N exercises where at least the first is in a circuit, items 1 through N-2 render off-screen above the viewport, items N-1 and N sit at the bottom, and a huge empty black band fills the middle. Total content claims ~N viewports of height instead of ~N×80px.

Reproduces consistently on Carl's iPhone 17 Pro (iOS 26.4.1) with any session that has ≥1 circuit member. Sessions with zero circuits have not been verified as clean — worth testing first in the next session.

## Three attempts that did NOT fix it

| # | Commit | Hypothesis | Result |
|---|--------|-----------|--------|
| 1 | `9bfc0f8` | `Column.MainAxisSize.max` inside `SliverReorderableList.itemBuilder` was latching to viewport extent. Set `mainAxisSize.min` on the outer Columns in `_buildRowWithContext` + `StudioExerciseCard`. | Same bug on device. |
| 2 | `326c6b8` | `Row(stretch) + IntrinsicHeight + Expanded(card)` was failing intrinsic resolution because of `AnimatedContainer` / `AnimatedSize` in the card tree. Rewrote per-row as a Stack with `Positioned.fill` rail + card as the height-driving child. | Same bug on device. |
| 3 | `424bc49` | `CustomScrollView(reverse: true) > SliverReorderableList` was forwarding unbounded vertical constraints. Replaced with plain `ReorderableListView.builder(reverse: true)`. | Same bug on device. |

All three builds analyzed clean + built clean on macOS. None were verified visually on device before merge — the pattern here is clear in retrospect: **next attempt must be verified visually before landing, not analyzer-clean-and-pray**.

## Where to look next

The bug is NOT in the scroll architecture (ruled out by #3) and NOT in the row-wrapper layout (ruled out by #2). That leaves:

- **The content of a row itself** — most likely `StudioExerciseCard`'s internal tree (`Material > InkWell > AnimatedContainer > Stack > Padding > Column`), which was barely touched by attempts #1-3.
- **The `Positioned(top: 0, bottom: 0)` rail** inside `_buildRowWithContext`'s Stack. `Positioned.fill` inside a Stack with no explicit sizing can cascade unbounded constraints back to the non-positioned child.
- **`GutterSpacerCell(height: 32, railThrough: true)`** inside `_buildCircuitHeaderRow` — this one hasn't been inspected in any attempt.
- **Circuit header row sitting ABOVE the card** in `_buildRowWithContext`. If the header is separately unbounded, its height might be what's blowing up (not the card body).

## Recommended first experiments for next session

In order, each cheap:

1. **Create a test plan with zero circuits.** If 5 standalone exercises render cleanly → circuit-specific bug → focus on `_buildCircuitHeaderRow` + `GutterSpacerCell`. If still broken → the circuit hypothesis was wrong and the bug is universal.
2. **Replace `StudioExerciseCard` with `Container(height: 80, color: Colors.red)` temporarily.** Rebuild. If the list stacks cleanly → bug is in the card tree. If still broken → bug is in the row wrapper or slivers.
3. **Drop the circuit header row entirely** from `_buildRowWithContext` (comment out the `if (isFirstInCircuit) _buildCircuitHeaderRow(...)` line). If this fixes it → circuit header is the blow-out source.
4. **Simplify the per-row Stack to a plain Row** — `Row(gutter + card)` with fixed widths. If that fixes it → the Stack+Positioned.fill rail is leaking unbounded constraints.

## Branch notes

All three failed attempts are merged into main. Do not revert them — the Stack approach and ReorderableListView are likely still correct directions; the bug just lives somewhere else. The next attempt should build on the existing main (post-merge `d61aa62`) rather than start over.

## Reference

- Design spec: `docs/design/project/components.md` — Exercise Card, Gutter Rail, Studio Screen sections.
- Earlier post-mortem pattern for Google Sign-In: `docs/BACKLOG_GOOGLE_SIGNIN.md` (same style of "what failed and why" to read if you're picking up cold).
