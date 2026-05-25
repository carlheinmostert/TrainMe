# Exercise Clipboard — handover

## Table of Contents

- [Status](#status)
- [What was built](#what-was-built)
- [PR #505 commit stack](#pr-505-commit-stack)
- [Code review findings — all addressed](#code-review-findings--all-addressed)
- [Files touched](#files-touched)
- [Tests](#tests)
- [Documents created on main](#documents-created-on-main)
- [How to continue](#how-to-continue)
- [Open items](#open-items)
- [References](#references)

## Status

**Ship-ready, awaiting practitioner review + device QA.** PR #505 (`feat/exercise-clipboard` → `staging`) is in draft, rebased onto current staging tip, with all known code-review issues resolved including the B-1 cross-rebase carry-through. Carl triggers merge to staging when satisfied; no other PR sits between the feature and staging at this point.

## What was built

A transient, in-memory clipboard inside Studio mode that lets a practitioner copy exercises from any session they're editing and batch-paste them into the session they're currently in. The headline use case is assembling a custom client plan by pulling exercises from My Workouts (the user's own self-captures) plus prior client sessions, without re-capturing what's already on disk.

Five surfaces touched:

- **Studio card swipe** — partial right-swipe reveals two coral buttons `[Copy]` `[Duplicate]`; long right-swipe auto-commits Copy (the dominant action). Left-swipe = Delete (unchanged). Rest periods omit the Copy button. Built on `flutter_slidable` (new dep, 1 line in pubspec).
- **Editor sheet Copy button** — a clipboard-icon pill in the reachability-inverted bottom AppBar, between the exercise name and the next-arrow chevron.
- **Top-right clipboard chip** — coral capsule `[icon N ×]` in the Studio AppBar, visible only when count ≥ 1. Tap opens the paste sheet; `×` clears all.
- **Paste bottom sheet** — list of clipboard items, all selected by default, with thumbnail + name + source-session label. Tap any row to toggle. Primary CTA `Paste N items` commits the batch at end-of-session in FIFO order. Locked targets (past the 14-day grace) get a `Unlock to paste · 1 credit` variant CTA that integrates the existing unlock flow.
- **Copy animation** — coral particle flies in a diagonal arc from the card or editor-sheet button to the chip; chip pulses + count badge increments on landing. Same animation from both source surfaces.

Eleven locked decisions guide the implementation; full spec at `docs/specs/2026-05-25-exercise-clipboard.md`.

## PR #505 commit stack

Rebased onto staging tip `e385266`. Four commits, linear history:

| SHA | Subject |
|---|---|
| `fc2dce6` | fix(clipboard): B-1 — carry selfVerified through cloneExerciseInto |
| `7e567ed` | test(clipboard): unit tests for ClipboardService + cloneExerciseInto |
| `5426226` | fix(clipboard): six code-review findings on PR #505 |
| `7e47b6c` | feat(studio): exercise clipboard — copy across sessions, batch paste |

Total vs staging: 13 files, +3108 / -182.

## Code review findings — all addressed

Code review caught one blocking issue, six should-fix items, and several nits. Status of each:

| Finding | Description | Status |
|---|---|---|
| B-1 | `cloneExerciseInto` missing `selfVerified` carry — would mis-classify pasted Self-client rows for publish free-path after rebase | Fixed in `fc2dce6` |
| S-1 | D1 single-practice scope had no actual enforcement; multi-practice users could silently mix exercises across boundaries | Fixed in `5426226` — `practiceId` on `ClipboardItem`, scope-filtered visible items, scope-aware `clearAll()` |
| S-2 | Reactive pruning only fired when Studio was mounted; Safe Mode rejections elsewhere left orphan pointers | Fixed in `5426226` — `ClipboardService.bindToConversionService(...)` wired at app startup |
| S-3 | CONTEXT.md "Clipboard" term missing | Already on main (commit `4bc7347`) per the specs-direct-to-main rule |
| S-4 | Unlock-then-paste race; silent bail with no user-facing message | Fixed in `5426226` — `_openUnlockSheet` returns `Future<bool>`, caller shows SnackBar on failure |
| S-5 | Chip placement before settings button instead of trailing | Fixed in `5426226` — `actions:` reordered |
| S-6 | Dashed border on locked CTA fell back to solid | Fixed in `5426226` — hand-rolled `CustomPaint` + `_DashedBorderPainter`, no new dep |
| S-7 | No unit tests for `ClipboardService` or `cloneExerciseInto` | Added in `7e567ed` (15 + 16 tests = 31 total) + 1 selfVerified assertion in `fc2dce6` |
| N-7 | Doc comment on `archivedAt` / `rawArchiveUploadedAt` asymmetry | Fixed in `5426226` |

Other nits (N-1 through N-6) were explicit "leave as-is" verdicts from the reviewer — no action.

## Files touched

Implementation:
- `app/lib/main.dart` (1 line — singleton wiring)
- `app/lib/services/clipboard_service.dart` (new)
- `app/lib/services/exercise_clone.dart` (new — shared deep-copy helper)
- `app/lib/screens/studio_mode_screen.dart` (Slidable swap, chip mount, paste flow, unlock-then-paste)
- `app/lib/widgets/clipboard_chip.dart` (new)
- `app/lib/widgets/paste_bottom_sheet.dart` (new)
- `app/lib/widgets/clipboard_flight_animation.dart` (new)
- `app/lib/widgets/exercise_editor_sheet.dart` (Copy button in bottom rail)
- `app/pubspec.yaml` (added `flutter_slidable: ^3.1.2`)

Tests:
- `app/test/services/clipboard_service_test.dart` (new — 15 tests)
- `app/test/services/exercise_clone_test.dart` (new — 16 tests)

Docs (in PR):
- `docs/test-scripts/2026-05-25-exercise-clipboard.md` (new — device QA script)
- `docs/test-scripts/index.html` (link entry at top of "Test these now")

## Tests

**Unit tests** in PR — 31 tests total, all passing:

- `clipboard_service_test.dart` (15) — empty init, addItem populate + dedupe, rest-period defensive rejection, FIFO order, clearAll, notifySourceDeleted (hit + miss), ChangeNotifier semantics, itemById, unmodifiable view.
- `exercise_clone_test.dart` (16) — full D8 Carry / Reset / Strip matrix, including the `selfVerified` carry assertion added by `fc2dce6`. Uses real temp dirs + mocked `path_provider`.

**Device QA** — script at `docs/test-scripts/2026-05-25-exercise-clipboard.md`. Walks: Studio swipe behaviour, editor-sheet Copy, chip + paste sheet, reactive pruning on source delete, locked-target unlock-then-paste flow, rest-period exclusion. Standard Markdown checkboxes; tick as you go.

## Documents created on main

These all live on main (not on the PR branch — per the specs-direct-to-main rule):

- `docs/specs/2026-05-25-exercise-clipboard.md` — the locked spec with 11 decisions (commit `53da333`)
- `docs/design/mockups/2026-05-25-exercise-clipboard.html` — visual mockup of every key state (commit `53da333`)
- `docs/adr/0023-exercise-clipboard-is-transient.md` — captures the transient-by-design decision (commit `117e9fc`)
- `CONTEXT.md` — Clipboard term entry added in the "Capture & playback" section (commit `4bc7347`)
- `docs/handoffs/2026-05-25-exercise-clipboard.md` — this document

## How to continue

When ready to ship:

1. **Review PR #505** in GitHub. The branch is rebased onto staging tip; diff is final.
2. **Install on device.** When you want this on your iPhone, say "install clipboard to phone" or run the standard install script. Build mode profile, no debugger attached.
3. **Walk the device QA script** at `docs/test-scripts/2026-05-25-exercise-clipboard.md`. Tick items as you go.
4. **Promote to staging.** When QA passes, mark PR #505 ready-for-review and merge to `staging`. Standard squash or merge-commit per your preference — staging history isn't sacred.
5. **Promote staging to main.** Follow the existing release-train pattern (`v2026-05-25.N` tag, release-notes auto-generated from PR titles). The `homefit-promote-staging-to-main` skill handles this.

There is no follow-up wave needed. The clipboard's v1 scope (single-practice, in-memory, no per-item curation, no cross-practice paste) is intentional per spec + ADR; future expansions (cross-practice, persistence, copy-circuit) are documented as out-of-scope in the spec and require a separate brainstorm.

## Open items

**None on the implementation side.** Everything the code review surfaced is addressed and verified.

**On the device side** — until you install + walk the QA script, treat this as "ship-ready pending QA". The implementation is high-confidence (unit tests cover the load-bearing contracts; impl agents reported `flutter analyze` clean; the code-reviewer agent gave a ship-with-fixes verdict and all fixes landed) but no surface this complex ships without device validation.

## References

- **Spec** — `docs/specs/2026-05-25-exercise-clipboard.md`
- **Mockup** — `docs/design/mockups/2026-05-25-exercise-clipboard.html`
- **ADR-0023** — `docs/adr/0023-exercise-clipboard-is-transient.md`
- **PR** — https://github.com/carlheinmostert/TrainMe/pull/505
- **Test script** — `docs/test-scripts/2026-05-25-exercise-clipboard.md`
- **Related ADRs** — 0016 (14-day structural-edit grace, drives locked-target paste flow), 0019 (editor sheet reachability inversion, drives Copy button placement), 0020 (Self-trainer as practitioner with self as client, drives the My Workouts source surface)
