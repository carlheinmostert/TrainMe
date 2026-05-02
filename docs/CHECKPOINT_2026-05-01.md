# Checkpoint — 2026-05-01

**Per-set PLAN wave — post-merge QA stack (Rounds 1–8)**

This document is the fresh-session handoff for the post-merge QA work that landed
on top of the per-set PLAN wave (PR #148, merged earlier this day on commit
`c6f5e6e`). Eight rounds of fixes were spawned via background agents over the
course of the session, none of them merged yet.

## Current state on Carl's iPhone

- **Bundle**: `studio.homefit.app`
- **Build SHA**: `7768837` (PR #156 tip — Round 8)
- **Includes**: Rounds 1 through 8 stacked. Carl is testing UNMERGED code.

## Where main is

- HEAD: `c6f5e6e feat(dose): per-set PLAN table + tabbed bottom-sheet editor`
  (this was PR #148, the wave's original landing)
- Nothing since `c6f5e6e` has merged. The 8 round PRs are open and waiting.

## The 8-round stack

Rounds 1 + 2 fixed the original device QA fails (`docs/test-scripts/2026-04-30-wave-per-set-dose.html`).
Rounds 3 onwards iterated on the device-test feedback Carl gave through the
session — each one landed a small, focused fix. No round was merged into main
because Studio is a "review before merge" path (see memory).

| PR | Round | Base | What | Status |
|----|-------|------|------|--------|
| #149 | 1 | main | seeding + pill regression + gesture conflicts + card chrome | OPEN |
| #150 | 2 | main | trigger row Expanded + seeding holes + chip z-order + gesture isolation | OPEN |
| #151 | 3 | main | runtime summary bug + tab-aware detents + chrome polish + scope flip | OPEN |
| #152 | 4 | main | vertical-stack card with icons + photo thumbnail backfill | OPEN |
| #153 | 5 | main | sheet jumpTo + coral notes + photo converted-fallback | OPEN |
| #154 | 6 | round-5 | notes summary uses full text + Hold column flex bumped to 3 | OPEN |
| #155 | 7 | round-6 | defer detent snap one frame on swipe (incomplete fix) | OPEN |
| #156 | 8 | round-7 | wait for `_pageController.position.isScrollingNotifier` to settle before snap | OPEN |

Rounds 1–5 each branched off `main` on GitHub (the agents branched off the
prior agent's local worktree branch but those weren't pushed at the time).
Rounds 6, 7, 8 properly stack. **Merging in order or rebasing is required** —
see "Merge strategy" below.

## What's now live in the build (round-by-round, latest behaviour)

### Studio exercise card
- **Vertical 3-row layout** (Round 4): thumbnail left; right column = title row,
  Plan row, Notes row. Each row is full-width.
- **Icon-only labels** (Round 4): `Icons.fitness_center` (coral) for Plan,
  `Icons.note_alt_outlined` for Notes. **Notes icon is also coral** (Round 5)
  for visual parity.
- **Tightened margins** (Round 4): card outer 14→10pt; button padding 12×8 → 10×6pt.
- **Each button supports 2 lines** of summary with `TextOverflow.ellipsis`.
- **Inline-edit removed from card** (Round 3 scope flip). Cards are read-only
  display surfaces.
- **Photo thumbnail backfill** (Round 4 + 5): photos render their actual
  picture. Fallback chain is `thumbnailPath → rawFilePath → convertedFilePath
  → Icons.photo_outlined`.
- **Plan grammar** mirrors web-player canonical: `3 sets · 10 reps · @ 15 kg ·
  5s hold` (Round 3, full words not `3 × 10`).
- **Notes summary uses FULL text** (Round 6) — flattens whitespace incl.
  newlines into single spaces; no more "first paragraph only" truncation.

### Editor sheet (popup card)
- **Inline-edit title moved to sheet header** (Round 3 scope flip). Dashed-
  underline pattern, tap to edit, returns commit.
- **44×44 thumbnail in sheet header** (Round 3, top-left).
- **Detent system** (Rounds 3 → 5 → 7 → 8):
  - `snapSizes: [0.55, 0.95]`, `minChildSize: 0.55` (hard floor — drag-down
    below 0.55 stays at 0.55, doesn't dismiss).
  - **Tab-aware default**: Preview tab → 0.95 on activation; all other tabs → 0.55.
  - **Snap timing**: tab-strip taps snap immediately (`_switchTab`); swipe-
    induced tab changes wait for `_pageController.position.isScrollingNotifier`
    to settle before snapping (Round 8 — Round 7's `addPostFrameCallback` was
    insufficient because the user's finger was still on the touchscreen).
- **Slider chrome stripped** (Round 3): no chrome lines, leftmost tick = N/A
  (bodyweight).
- **X close button removed** (Round 3): sheet dismisses via drag-down past
  threshold or tap-outside. Treatment pill anchored top-left, no longer
  overlapping Body Focus / Rotate buttons.

### Plan table (inside Plan tab)
- **Reps cell uses canonical `PresetChipRow`** (Round 1 → 2): small horizontal
  pills, inline `[+]` numeric input (no popup), long-press to delete with Undo.
- **Weight slider** isolated from sheet's gesture (Round 5 GestureDetector
  wrapping with no-op horizontal handlers); inline N/A.
- **Hold column equal width** (Round 6): `flex: 2 → 3` on header + data row.
  Hold/Weight/Breather now equal-width; Reps stays narrower at flex:2.

## What's pending / known issues

- **Test script is outdated**: `docs/test-scripts/2026-04-30-wave-per-set-dose-retest.html`
  was authored for round 2 results and the layout/icon changes have superseded
  several items. Carl said "ignoring for now"; rewrite once the stack lands.
- **Notes textarea bug** — Carl reported one observation (line 1 + one word +
  no ellipsis) that was diagnosed as Round 4's `_notesSummary` taking only
  first paragraph; Round 6 fixed it. Verify on next retest.
- **Detent fix verification** — Rounds 7 + 8 deal with the same gesture race
  in different ways. Round 8's `isScrollingNotifier` listener is the most
  robust attempt; needs device verification on Carl's iPhone (which has
  Round 8 installed at SHA `7768837`).
- **Test result audit trail**: `2026-04-30-wave-per-set-dose-retest.round1.results.json`
  + `.round2.results.json` are snapshots saved alongside the live results.
  None committed yet (`.results.json` is gitignored — needs `git add -f` when
  the wave closes).

## Merge strategy decision pending

Carl asked about the stack state. Two clean paths:

1. **Squash merge** — collapse rounds 1–8 into one commit on main with a
   "post-merge QA roll-up" message. Cleanest history; loses per-round
   attribution.
2. **Rebase + merge in order** — rebase each PR onto its predecessor, merge
   sequentially. Preserves round granularity at the cost of 8 merge commits.

Recommended: option (1) once Carl is done with iteration, treating the whole
wave's QA as a single follow-up unit.

## Useful runtime gotchas surfaced this session

(Worth memory entries; not yet written.)

1. **`DraggableScrollableSheet` + `PageView` swipe gesture race**. `jumpTo`
   from inside `onPageChanged` while the user's finger is still on the
   touchscreen interprets the residual vertical motion of the swipe as a
   drag-past-floor and dismisses the sheet. The fix is to defer the snap
   until `_pageController.position.isScrollingNotifier.value == false` —
   `addPostFrameCallback` (one frame, ~16 ms) isn't long enough; the gesture
   spans multiple frames. See `app/lib/widgets/exercise_editor_sheet.dart`
   `_onPageChanged` post-Round 8.

2. **Layout-driven Text rendering with too-narrow `Expanded`**. Round 2's
   inline `[Label · summary]` row inside a half-width `_TriggerButton` left
   the summary `Expanded` with ~31pt of bounded width on iPhone 14 base —
   below Flutter's threshold for rendering an ellipsis glyph. Symptom: blank
   summary on the card with no overflow indicator. Fix: stack label above
   summary, OR widen the parent so the Text has enough room. Round 4's full-
   width buttons sidestep this entirely.

3. **Conversion service photo thumbnail gap**. `_processQueue`'s photo branch
   only probed aspect ratio, never wrote `thumbnailPath`. So every photo
   exercise rendered the placeholder camera icon forever. Round 4 forward-
   fixes by setting `thumbnailPath = rawFilePath` after photo conversion;
   Round 4 + 5 widget-level fallback handles legacy rows with stale or
   missing raw files.

4. **Stacked PRs branched off local-only worktree branches show base=main on
   GitHub**. When agents work in isolated worktrees and push their branches,
   GitHub doesn't see the stacking unless the parent PRs are pushed first.
   Either push parent → child in order, or accept that the stack is logical
   only and reconcile on merge.

## How to resume

1. Read this checkpoint.
2. `gh pr list --state open --search "dose"` to see the 8 PRs.
3. Carl's iPhone has SHA `7768837`. The Settings footer confirms it.
4. The latest open question: detent verification on Round 8 — does swipe
   Preview → Settings still collapse, or did `isScrollingNotifier` fix it?
5. Once Carl has signed off on the stack, propose the merge strategy and
   execute. Then rewrite `2026-04-30-wave-per-set-dose-retest.html` from
   scratch against the final UI state.
