# Exercise Clipboard — handover

## Table of Contents

- [TL;DR for a fresh session](#tldr-for-a-fresh-session)
- [Status](#status)
- [Build session runbook](#build-session-runbook)
- [What was built](#what-was-built)
- [Commit stack on staging](#commit-stack-on-staging)
- [Code review findings — all addressed](#code-review-findings--all-addressed)
- [Files touched](#files-touched)
- [Tests](#tests)
- [Documents on main](#documents-on-main)
- [Promotion path](#promotion-path)
- [Rollback path](#rollback-path)
- [References](#references)

## TL;DR for a fresh session

PR #505 (Exercise Clipboard) is **merged to staging at commit `674e2ef`** with all CI checks green. The next step is building the staging tip onto Carl's iPhone CHM and walking the device QA script. After QA passes, promote staging → main via the release-train pattern.

Two-command quick start:
```bash
# from repo root
./install-device.sh staging        # build + install staging tip on iPhone CHM
open docs/test-scripts/2026-05-25-exercise-clipboard.md   # the QA checklist
```

Carl must explicitly authorize the device install in-session (per `feedback_ask_before_mobile_deployment` memory). Don't auto-run the install command.

## Status

**MERGED to staging on 2026-05-25.** Merge commit `674e2ef`. All 23 CI checks passed including `Custom rules (bash)` (hero-resolver allowlist updated for the two passthrough readers), `Flutter app (analyze + test)` (31 unit tests pass), and `Flutter build iOS (debug, no codesign)`.

Next: device QA on Carl's iPhone CHM, then promote staging → main.

## Build session runbook

**Step 1 — Confirm staging is at the merged tip.**

```bash
cd /Users/chm/dev/TrainMe
git fetch origin staging
git log origin/staging -1 --oneline
# Expect: 674e2ef Merge pull request #505 from carlheinmostert/feat/exercise-clipboard
```

**Step 2 — Ask Carl for explicit go-ahead before installing.**

The `feedback_ask_before_mobile_deployment` memory is a hard rule: never auto-initiate a build that produces an installable artifact. Wait for Carl to say "install" / "deploy to phone" / "ship to iPhone".

**Step 3 — Build + install.**

Default path is the `homefit-install-device` skill (sticky persistent worktree at `.claude/worktrees/iphone-install`, default mode profile, skips `flutter clean` unless dependencies actually changed). Invoke it with environment `staging`.

Fallback path is the shell script: `./install-device.sh staging` (pulls staging, release-builds, installs to iPhone CHM via `xcrun devicectl`).

Either way: profile build mode is the right default. `--debug` builds need a debugger attached and will white-screen-crash on launch standalone (per `gotcha_ios_debug_needs_debugger`).

**Step 4 — Walk the QA script.**

```bash
open docs/test-scripts/2026-05-25-exercise-clipboard.md
```

It's Markdown checkboxes (per `feedback_test_scripts_as_markdown`). Walk every item; tick as you go. The script covers:

1. Studio card — partial right-swipe reveals `[Copy] [Duplicate]` buttons
2. Studio card — long right-swipe auto-commits Copy
3. Studio card — left-swipe still deletes (unchanged from pre-PR)
4. Editor sheet — Copy button in the bottom rail adds to clipboard
5. Chip — appears top-right of AppBar when count ≥ 1
6. Chip — count badge reflects the current practice's items only (D1 enforcement)
7. Chip — tap opens paste sheet with all items selected by default
8. Paste sheet — tap a row toggles selection, CTA count updates live
9. Paste sheet — `Paste N items` commits at end of session in FIFO order
10. Paste sheet — items stay in clipboard after paste (re-paste into another session works)
11. Paste sheet — `× Clear all` empties the clipboard
12. Reactive pruning — deleting a source exercise removes its clipboard pointer immediately
13. Reactive pruning — Safe Mode rejection of a source exercise removes the pointer even when Studio isn't mounted
14. Locked target — past 14-day grace, CTA reads `🔒 Unlock to paste · 1 credit`; tap → unlock sheet → confirm → unlock + paste in one flow
15. Locked target — if unlock fails, SnackBar surfaces the failure; clipboard items retained for retry
16. Rest periods — swipe reveal omits `[Copy]`; editor sheet hides the Copy button
17. Practice switching — clipboard items belonging to inactive practices are hidden (D1)
18. Dashed border — locked-target CTA shows a dashed coral border (mockup-faithful via CustomPaint)
19. Cross-session paste — exercises copied from Client A's session paste cleanly into Client B's session
20. Cross-session paste — pasted row is fully independent (edit hero/treatment/sets without affecting source)

**Step 5 — Report results.**

If everything passes: confirm with Carl that QA is clean. He decides when to promote to main.

If something fails: capture the failing item number + symptom, file an issue or spawn a fix-up agent against staging (per `feedback_delegate_coding`).

## What was built

A transient, in-memory clipboard inside Studio mode that lets a practitioner copy exercises from any session they're editing and batch-paste them into the session they're currently in. The headline use case is assembling a custom client plan by pulling exercises from My Workouts (the user's own self-captures) plus prior client sessions, without re-capturing what's already on disk.

Five surfaces touched:

- **Studio card swipe** — partial right-swipe reveals `[Copy]` `[Duplicate]`; long right-swipe auto-commits Copy. Left-swipe = Delete. Rest rows omit Copy. Built on `flutter_slidable: ^3.1.2` (new dep).
- **Editor sheet Copy button** — clipboard-icon pill in the reachability-inverted bottom AppBar, between exercise name and next-arrow.
- **Top-right clipboard chip** — coral capsule `[icon N ×]` in Studio AppBar, visible only when count ≥ 1.
- **Paste bottom sheet** — list of items, all selected by default; CTA `Paste N items` batch-pastes at end of session in FIFO order. Locked targets get `Unlock to paste · 1 credit` variant.
- **Copy animation** — coral particle flies diagonally from source to chip; chip pulses + count badge increments + light haptic on landing.

Eleven locked decisions in the spec. See `docs/specs/2026-05-25-exercise-clipboard.md` for the full design.

## Commit stack on staging

Merged via `--merge` (preserves history, matches the project's recent merge convention). Five commits on the feature branch + merge commit:

| SHA | Subject |
|---|---|
| `674e2ef` | Merge pull request #505 from carlheinmostert/feat/exercise-clipboard |
| `6865635` | ci(hero-resolver): allowlist clipboard passthrough readers |
| `fc2dce6` | fix(clipboard): B-1 — carry selfVerified through cloneExerciseInto |
| `7e567ed` | test(clipboard): unit tests for ClipboardService + cloneExerciseInto |
| `5426226` | fix(clipboard): six code-review findings on PR #505 |
| `7e47b6c` | feat(studio): exercise clipboard — copy across sessions, batch paste |

Total vs prior staging tip: 14 files, +3115 / -182.

## Code review findings — all addressed

A code-reviewer agent ran against PR #505 against the spec and project conventions. One blocking issue, six should-fix, addressed as follows:

| Finding | Description | Status |
|---|---|---|
| B-1 | `cloneExerciseInto` missing `selfVerified` carry — would mis-classify pasted Self-client rows for publish free-path after rebase | Fixed in `fc2dce6` |
| S-1 | D1 single-practice scope had no actual enforcement; multi-practice users could silently mix exercises across boundaries | Fixed in `5426226` — `practiceId` on `ClipboardItem`, scope-filtered visible items, scope-aware `clearAll()` |
| S-2 | Reactive pruning only fired when Studio was mounted; Safe Mode rejections elsewhere left orphan pointers | Fixed in `5426226` — `ClipboardService.bindToConversionService(...)` wired at app startup |
| S-3 | CONTEXT.md "Clipboard" term missing from PR | Already landed on main (commit `4bc7347`) per the specs-direct-to-main rule |
| S-4 | Unlock-then-paste race; silent bail with no user-facing message | Fixed in `5426226` — `_openUnlockSheet` returns `Future<bool>`, caller shows SnackBar on failure |
| S-5 | Chip placement before settings button instead of trailing | Fixed in `5426226` — `actions:` reordered |
| S-6 | Dashed border on locked CTA fell back to solid | Fixed in `5426226` — hand-rolled `CustomPaint` + `_DashedBorderPainter`, no new dep |
| S-7 | No unit tests for `ClipboardService` or `cloneExerciseInto` | Added in `7e567ed` (15 + 16 tests) + 1 `selfVerified` assertion in `fc2dce6` |
| N-7 | Doc comment on `archivedAt` / `rawArchiveUploadedAt` asymmetry | Fixed in `5426226` |
| CI | Hero-resolver allowlist for clipboard passthrough readers | Added in `6865635` |

Nits N-1 through N-6 had explicit "leave as-is" verdicts — no action.

## Files touched

Implementation:
- `app/lib/main.dart` (singleton wiring)
- `app/lib/services/clipboard_service.dart` (new)
- `app/lib/services/exercise_clone.dart` (new — shared deep-copy helper)
- `app/lib/screens/studio_mode_screen.dart` (Slidable swap, chip mount, paste flow, unlock-then-paste)
- `app/lib/widgets/clipboard_chip.dart` (new)
- `app/lib/widgets/paste_bottom_sheet.dart` (new)
- `app/lib/widgets/clipboard_flight_animation.dart` (new)
- `app/lib/widgets/exercise_editor_sheet.dart` (Copy button in bottom rail)
- `app/pubspec.yaml` (`flutter_slidable: ^3.1.2`)

Tests:
- `app/test/services/clipboard_service_test.dart` (new — 15 tests)
- `app/test/services/exercise_clone_test.dart` (new — 16 tests)

Infrastructure:
- `scripts/ci/check-hero-resolver.sh` (allowlist update for passthrough readers)

Docs (in PR):
- `docs/test-scripts/2026-05-25-exercise-clipboard.md` (device QA script)
- `docs/test-scripts/index.html` (link entry at top of "Test these now")

## Tests

**Unit tests** in PR — 31 tests, all passing in CI:

- `clipboard_service_test.dart` (15) — empty init, addItem populate + dedupe, rest-period defensive rejection, FIFO order, clearAll, notifySourceDeleted (hit + miss), ChangeNotifier semantics, itemById, unmodifiable view.
- `exercise_clone_test.dart` (16) — full D8 Carry / Reset / Strip matrix including `selfVerified`. Uses real temp dirs + mocked `path_provider`.

**Device QA** — script at `docs/test-scripts/2026-05-25-exercise-clipboard.md`. 20-item Markdown checkbox list scoped to what this PR changed.

## Documents on main

These all live on main, separate from the PR (per `feedback_specs_direct_to_main`):

- `docs/specs/2026-05-25-exercise-clipboard.md` — locked spec with 11 decisions (commit `53da333`)
- `docs/design/mockups/2026-05-25-exercise-clipboard.html` — visual mockup (commit `53da333`)
- `docs/adr/0023-exercise-clipboard-is-transient.md` — captures the transient-by-design decision (commit `117e9fc`)
- `CONTEXT.md` — Clipboard term entry in "Capture & playback" section (commit `4bc7347`)
- `docs/handoffs/2026-05-25-exercise-clipboard.md` — this document

## Promotion path

When device QA passes, promote staging → main via the standard release-train pattern. The `homefit-promote-staging-to-main` skill handles this — invoke it with no args; it will:

1. Diff staging vs main
2. Generate release notes from PR titles since the last `v2026-MM-DD.N` tag
3. Open a promotion PR
4. Stop before merge (Carl explicitly promotes)

After Carl merges the promotion PR, `release-tag.yml` auto-tags main as `v2026-05-25.N` (N is the nth release on this UTC day).

## Rollback path

If a sev1 surfaces during device QA, the rollback options are:

1. **Hotfix on staging.** Branch `fix/clipboard-<thing>` off staging, address, merge back. Keep clipboard shipped; fix forward.
2. **Revert on staging.** `git revert -m 1 674e2ef` then push. Clipboard reverts; staging is clean for other work. Re-do the PR when ready.
3. **Block promotion.** Don't run `homefit-promote-staging-to-main` until issues resolve. Staging carries the bug; main stays clean.

Pick whichever matches severity. For an issue affecting only the clipboard surface (most likely case), option 1 is cleanest — the existing infrastructure still works for the rest of the app.

## References

- **Spec** — `docs/specs/2026-05-25-exercise-clipboard.md`
- **Mockup** — `docs/design/mockups/2026-05-25-exercise-clipboard.html`
- **ADR-0023** — `docs/adr/0023-exercise-clipboard-is-transient.md`
- **PR** — https://github.com/carlheinmostert/TrainMe/pull/505 (merged)
- **Merge commit** — `674e2ef`
- **Test script** — `docs/test-scripts/2026-05-25-exercise-clipboard.md`
- **Related ADRs** — 0016 (14-day structural-edit grace, drives locked-target paste flow), 0019 (editor sheet reachability inversion, drives Copy button placement), 0020 (Self-trainer as practitioner with self as client, drives the My Workouts source surface)
- **Related memory** — `feedback_ask_before_mobile_deployment` (build authorization), `feedback_test_scripts_as_markdown` (QA script format), `feedback_specs_direct_to_main` (docs on main, not PR), `gotcha_ios_debug_needs_debugger` (profile build mode default)
