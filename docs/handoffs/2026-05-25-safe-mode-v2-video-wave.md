# Handover — Safe Mode v2 video wave shipped

**Created:** 2026-05-25 by Claude at end of session. Wave landed both PRs on staging in this session; another session will build two adjacent waves on top. This document is **additive** — it captures only what this wave changed plus the seams the next waves should know about. Read the spec (`docs/specs/2026-05-25-safe-mode-v2-video.md`) and the merged PRs for full detail; don't re-derive from this doc.

**Status:** Wave complete on staging. Not on main yet. No phone install performed. Bench report rendered but empty (placeholder, no sample clips dropped in yet).

## Table of contents

- [What landed this wave](#what-landed-this-wave)
- [Staging tip + commit anchors](#staging-tip--commit-anchors)
- [Decisions that bind future work](#decisions-that-bind-future-work)
- [Files this wave changed — adjacent waves should know](#files-this-wave-changed--adjacent-waves-should-know)
- [Subsystem state after the wave](#subsystem-state-after-the-wave)
- [Open follow-ups (NOT done this wave)](#open-follow-ups-not-done-this-wave)
- [Operational lessons learned today](#operational-lessons-learned-today)
- [How to resume / extend](#how-to-resume--extend)

## What landed this wave

Two PRs merged to `staging` in this session, in this order:

| PR | Branch | Merge SHA | Title |
|---|---|---|---|
| #506 | `feat/safe-mode-v2-video-native` | `e6cece1` | `feat(safe-mode-v2): native v2 video pipeline + bench tool extension` |
| #497 | `feat/safe-mode-v2-video-dart` | `e385266` | `feat(safe-mode-v2): Dart wiring + progress UI for v2 video` |

**The wave is the spec at `docs/specs/2026-05-25-safe-mode-v2-video.md` shipped end-to-end.** Hybrid Option C architecture (first-frame identify + Vision tracker + sparse re-confirm + 3-consecutive-miss tolerance). v1 video pipeline removed in the same wave. Mac-side bench tool extended to handle videos.

Authored across SIX sub-agent runs in this session — three died at the ~30-minute Anthropic-instability ceiling, three completed cleanly. WIP-commit-and-respawn pattern got the work across the line; nothing was lost.

## Staging tip + commit anchors

```
e385266  Merge pull request #497 from .../feat/safe-mode-v2-video-dart
e6cece1  Merge pull request #506 from .../feat/safe-mode-v2-video-native
```

`main` is one commit behind this handover doc (this doc lands direct-to-main, no PR).

Branches still on origin (not yet deleted):
- `feat/safe-mode-v2-video-native`
- `feat/safe-mode-v2-video-dart`

## Decisions that bind future work

These are product calls Carl made during the wave. Adjacent waves must honour them.

1. **Hybrid Option C is the architecture.** No re-litigation of Option A (first-frame-identify-only) or Option B (sparse-sampling-only). Spec section 5 carries the analysis.
2. **`safe_mode_algorithm_version = 3`** — v2 video inherits the constant bumped by PR #485 last week. Both photo and video stamp the same value. Re-process affordance keys on `< kSafeModeAlgorithmVersion`. **Don't introduce a media-type-specific constant.**
3. **`threshold` arg on the wire IS the solo-floor (0.10), NOT a cosine threshold.** The 0.55–0.60 cosine values in spec section 5 are aspirational multi-ref tuning targets describing embedding quality, not runtime gates. Spec section 8 has the disambiguation paragraph.
4. **EventChannel name `homefit-safe-mode-v2-video-progress` is locked** in spec section 8. Native registers it; Dart subscribes. Don't rename without coordinating both surfaces.
5. **Miss definition is `face AND segmentation BOTH fail`** (single-signal v1 definition is retired). Backlit captures with segmentation still firing are accepted with safe variant. To exercise the rejection path now, fully obscure the lens (palm over lens, lens cap on). Spec section 6b carries the rewrite. Acceptance criterion #8 + test wave item #8 already updated.
6. **Re-confirm tolerates 3 consecutive misses** before dropping the tracker, provided tracker confidence is still ≥ `trackerConfidenceFloor` (0.5). Spec section 6d carries the rule. Counter is `consecutiveReConfirmMisses` on `SafeModeV2VideoProcessor`.
7. **No phone install initiated by Claude.** `feedback_ask_before_mobile_deployment` is binding. The next session must ask Carl per-session before any `install-device.sh` / `homefit-install-device` / `homefit-ship-to-phone`.
8. **Bench report is the visual-proof gate.** Carl must approve the rendered `~/Desktop/Safe Mode Bench Report.html` before device QA per `feedback_safe_mode_bench_report`. The infrastructure is in place; sample clips are not.

## Files this wave changed — adjacent waves should know

If your wave touches any of these files, expect interaction with this wave's logic:

### Native (Swift)

- `app/ios/Runner/VideoConverterChannel.swift` — major rewrite. New `SafeModeV2VideoProcessor` enum (state machine), `SafeModeV2VideoProgressHandler` (FlutterStreamHandler for the progress EventChannel), `applySafeModeV2ToVideo` channel method, per-frame helpers (`floodFillBinarySafeModeV2`, `paintHeadExpansionSafeModeV2`, `faceContourPolygonPxSafeModeV2`, `pointInPolygonSafeModeV2`). v1 `SafeModeProcessor` class + `applySafeModeToVideo` + `processSafeModeVideo` channel methods deleted. Composite reuses v2 photo's `CIBlendWithMask` + DeviceRGB colorspace setup byte-for-byte. New shared constant `kSafeModeV2BlurRadius1080` + helper `safeModeV2BlurRadius(forMinDim:)` used by photo + video + bench.
- `app/ios/Runner/MobileFaceNetEmbedder.swift` — `pickSubject(faceEmbeddings:slots:soloFloor:)` shared helper extracted with typed `FaceMatch` / `SubjectPick` / `PickBranch` records. Both v2 photo and v2 video paths now delegate to this. `PickBranch` gained a `.noReferences` case to disambiguate from `.noFaces`.

### Dart

- `app/lib/services/conversion_service.dart` — new `_applySafeModeV2ToVideo` method, new `Stream<SafeModeV2VideoProgress>` on `ConversionService.onSafeModeV2VideoProgress`, new `EventChannel('homefit-safe-mode-v2-video-progress')` subscription. v1 `safeOutputPath` flag fully removed from `_convertVideo`. **Critical:** `_convert()`'s video branch now has `on SafeModeRejection { rethrow; }` before the generic catch — this is the C1 privacy-regression fix. Don't move it.
- `app/lib/widgets/capture_thumbnail.dart` — new `_SafeModeV2VideoProgressOverlay` widget. Determinate coral progress bar bound to per-exercise progress stream. Filters by `exerciseId` so concurrent captures don't bleed.
- `app/lib/screens/capture_mode_screen.dart` — lifted the v1 video-suppression block in `_startVideoRecording`. Now defers to the shared `_shouldGateOnSafeModeV2()` + `_resolveSafeModeV2State().isReady` gate (covers both photo and video). The self-trainer sub-gate (PR #8) runs FIRST, then the v2 face-embedding gate. Order is load-bearing.

### Tests + docs

- `app/test/services/conversion_service_v2_video_test.dart` (new) — 10 tests, including a C1 regression catcher using mocked `MethodChannel` that asserts `SafeModeRejection.missingFaceEmbedding` propagates through the queue handler. The agent verified this test by REMOVING the rethrow and watching it fail — load-bearing.
- `docs/test-scripts/2026-05-25-safe-mode-v2-video.md` (new) — 13 numbered manual test items across 5 sections. Item 13 expects `safe_mode_algorithm_version = 3` (not `2`).
- `docs/test-scripts/index.html` — new entry added at the top of "Order · test these now".
- `docs/specs/2026-05-25-safe-mode-v2-video.md` — pre-existing on main. Rewritten in this wave: section 6b miss-rate redefinition, section 6d 3-consecutive-miss tolerance, section 7 acceptance criterion #8 + section 10 test item #8 retired heavy-backlit rejection, section 8 pinned EventChannel name + threshold-arg disambiguation, sections 1 + 7 algo version stamped at 3.

### Mac-side bench tool

- `tools/safe-mode-v2-bench/Sources/SafeModeBench/SafeModeV2VideoPipeline.swift` (new, 873 lines) — macOS mirror of `SafeModeV2VideoProcessor`. Same state machine, same composite, same colorspace. Drift between this and iOS is a real risk; if you change the iOS pipeline, mirror here too.
- `tools/safe-mode-v2-bench/Sources/SafeModeBench/main.swift` — new `--video` mode.
- `tools/safe-mode-v2-bench/generate_video_report.py` (new) — Python generator. Auto-discovers `.mp4`/`.mov` in `samples/`, invokes CLI, renders HTML at `~/Desktop/Safe Mode Bench Report.html`.

## Subsystem state after the wave

- **CLAUDE.md `## Safe Mode` section is STALE.** Still describes the v1 largest-bbox heuristic + `SafeModeProcessor` class that no longer exists. Update needed (docs-direct-to-main) once Carl has device-QA confidence in v2. Until then, the spec at `docs/specs/2026-05-25-safe-mode-v2-video.md` is the source of truth.
- **Bench report**: `~/Desktop/Safe Mode Bench Report.html` exists, placeholder state (no sample clips). Framework works end-to-end. To exercise: drop test clips + reference embedding into `tools/safe-mode-v2-bench/samples/`, then `python3 tools/safe-mode-v2-bench/generate_video_report.py --bench tools/safe-mode-v2-bench --embedding tools/safe-mode-v2-bench/samples/embedding.bin --output "/Users/chm/Desktop/Safe Mode Bench Report.html"`.
- **CI is green on both PRs as merged.** Flutter analyze + flutter test (10/10) + iOS build + web checks + Vercel previews + Supabase Branching `Apply all migrations against Postgres 17` + `Populate vault.secrets on preview branch DB` all pass.
- **No new Supabase migrations in this wave.** The v2 video schema was already in place from the v2 photo waves; nothing in `supabase/migrations/` changed.
- **No web player changes.** Wave is mobile + portal-agnostic.

## Open follow-ups (NOT done this wave)

These were deferred during the wave and Carl owns the call on each. Listed so an adjacent wave knows what's queued.

1. **CLAUDE.md `## Safe Mode` section rewrite.** Describe v2 face-rec discriminator + state machine + miss redefinition. Docs-direct-to-main when done.
2. **Add `safe_mode_v2_video_mask_smoothing` to `docs/BACKLOG.md`** per spec section 6a. Two candidate strategies documented (sliding-window averaging vs motion-compensated keyframe interpolation). Triggers if Carl eyeballs device output and sees per-frame mask-edge jitter.
3. **L2 from code review: defensive byte-count assert.** In `_applySafeModeV2ToVideo`, add `assert(subjectEmbeddingSlots.every((s) => s.length == kFaceEmbeddingBytes), ...)` so corrupt cache state surfaces at the Dart boundary instead of crashing native silently. `kFaceEmbeddingBytes = 2048` per `gotcha_face_embedding_units.md`.
4. **M2 from code review: test-scripts `index.html` → `index.md` migration** per `feedback_test_scripts_as_markdown`. Pre-existing infrastructure issue from before the markdown-checkbox rule. Wider cleanup than this wave's scope.
5. **Pre-existing silent-fallback audit.** Both v2 photo AND v2 video `_applySafeMode*` methods return an empty outcome (no rejection) on `PlatformException`, `TimeoutException`, `MissingPluginException` — which then skips the upload swap and uploads the raw video to cloud raw-archive. This violates `feedback_no_silent_fallbacks`. Carl flagged it as out-of-scope for this wave; deserves its own pass that decides whether these should also throw `SafeModeRejection` with a new reason (`safeModePassFailed`?).
6. **Branch cleanup.** `feat/safe-mode-v2-video-native` + `feat/safe-mode-v2-video-dart` still on origin. Carl can delete when comfortable.

## Operational lessons learned today

Worth capturing for any session that spawns sub-agents in the next ~24 hours while the Anthropic instability may persist:

- **~30-minute runtime ceiling** kept killing sub-agents today. 3 of 6 agents died at the 30–36 min mark with transcripts going silent simultaneously across parallel agents (synchronised death is the platform-side signal).
- **WIP-commit-and-respawn pattern** is the recovery: commit dead agent's uncommitted work to the branch, push, spawn a tighter-scoped finisher agent told to verify + complete + open PR. Worked 3 times today; nothing was lost.
- **Short-scope agents survive better.** Finisher B (Dart) completed in ~17 min. The dying agents were the heavier 30+ min ones.
- **Channel signature is the contract** between native + Dart agents working in parallel. Lock it verbatim in BOTH briefs. The native side registers, the Dart side subscribes — they meet at the channel name + arg shape + return shape.
- **CI `flutter analyze` runs with `-e`** so any warning or info-level issue exits non-zero. Local `dart_analyze` via the MCP can be more permissive. Always verify by checking the actual GitHub Actions check status before declaring "analyze clean".
- **Rebase conflicts were small and resolvable inline** (3 regions across 2 PRs). The `homefit-resolve-test-script-index` skill handled the test-scripts cascade pattern cleanly. The spec file `add/add` was resolved via `git checkout --ours` since HEAD had legitimate post-fixer rewrites.
- **`gh pr merge` returns 0 against already-merged PRs.** Always verify with `gh pr view N --json state,mergeCommit --jq '{state, sha: (.mergeCommit.oid // "NULL")}'` and assert state=MERGED + non-null sha. Per `gotcha_gh_pr_merge_silent_success.md`.

## How to resume / extend

If your wave is unrelated to v2 video, you can ignore most of this doc — just be aware of the file list in the "Files this wave changed" section so you don't unknowingly conflict.

If your wave touches Safe Mode adjacent surfaces (premises, capture-time gating, embedding service, conversion pipeline, upload swap, audit feed):

1. **Read the spec** at `docs/specs/2026-05-25-safe-mode-v2-video.md` first. Don't re-derive from this doc.
2. **Check the PR diffs** at https://github.com/carlheinmostert/TrainMe/pull/506 and https://github.com/carlheinmostert/TrainMe/pull/497 for the actual code shape.
3. **Run the bench tool** if you're tuning thresholds or cadences — `tools/safe-mode-v2-bench/generate_video_report.py` is the loop. Sample clips + reference embedding from Carl's enrolment.
4. **If your wave needs device QA**, ask Carl per-session per `feedback_ask_before_mobile_deployment`. The test script at `docs/test-scripts/2026-05-25-safe-mode-v2-video.md` has 13 items ready for him to walk through.
5. **If your wave changes the native pipeline**, mirror in the Mac-side bench at `tools/safe-mode-v2-bench/Sources/SafeModeBench/SafeModeV2VideoPipeline.swift` to keep the iOS-vs-bench drift at zero.
6. **If your wave needs a new EventChannel or MethodChannel**, follow this wave's pattern: define the channel name as a constant in BOTH sides + pin it in your spec section 8 + reference `gotcha_face_embedding_units.md` for byte-count contracts.

Staging is the source of truth for the v2 video shipped state. The wave has not promoted to `main` yet — Carl owns that decision when he's ready.
