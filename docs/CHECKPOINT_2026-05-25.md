# Checkpoint — 2026-05-25 — Safe Mode v2 polish day (six PRs + enrolment polish wave)

**One-day wave of six PRs on staging that turned Safe Mode v2 from "shipped but bruised" into "shipped and polished".** Three bug-fix PRs in the morning closed the v2-on-photos sev1 chain (colorspace darkness, algo-version bump to re-surface the reprocess row, embedding-decoder units bug that silently dropped every embedding through sync). Three feature PRs in the afternoon hardened the surrounding UX (accept zero-detection captures with telemetry + orphan-row fix; enrolment polish phase 1 with camera toggle + consent sheet restructure; enrolment polish phase 2 with pose gating + quality scoring + manual avatar selection). The session also surfaced a dead-agent salvage event (PR #496 — Phase 2 implementation agent died silently with 3,700 lines of clean uncommitted work), a pgvector CI hiccup blocking #491 and #496, and a parked v2-on-video spec at `docs/specs/2026-05-25-safe-mode-v2-video.md` queued for a fresh session.

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The day's six PRs in narrative](#the-days-six-prs-in-narrative)
- [The dead-agent salvage event](#the-dead-agent-salvage-event)
- [The pgvector CI hiccup](#the-pgvector-ci-hiccup)
- [Other parallel-session PRs that landed on staging today](#other-parallel-session-prs-that-landed-on-staging-today)
- [Memory entries added this session](#memory-entries-added-this-session)
- [Known follow-ups](#known-follow-ups)
- [v2-on-video spec parked](#v2-on-video-spec-parked)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end

- **Staging tip:** `d452f3e` — PR #496 (Safe Mode v2 enrolment polish phase 2). Live on `staging.session.homefit.studio` + `staging.manage.homefit.studio`.
- **Main tip:** `97e2078` — docs-only ahead of staging (`docs(checkpoint): wave-2 PRs spawned — #492 #493 #494`). The six PRs in this checkpoint are staging-only pending the next promotion window.
- **Carl's iPhone CHM:** still on build `277e839` (pre-today's wave). **No device install happened today.** Carl told the parallel session (building atop staging for QA) to produce the next iPhone build — so the next install will pick up the full Safe Mode v2 polish day plus the parallel-session items below.
- **Active stack file:** `docs/test-scripts/2026-05-25-stack.md` — created during the wave. Carry-forward state TBD by Carl.
- **Vercel deploys today:** ~6 portal + ~3 player across the bug-fix and enrolment-polish PRs. No spend spike observed.
- **Wedged infra:** Supabase Branching `MIGRATIONS_FAILED` on staging — STILL wedged from 2026-05-11; pgvector CI fix (#498) addressed migration-check CI but not Branching reconciliation. Handoff still at `docs/handoffs/2026-05-23-safe-mode-embedding-and-branching-reconciliation.md`.
- **Blocked on Carl (unchanged from 2026-05-17-pm):** Hostinger 301 redirects (`homefit.studio/privacy|terms` → `manage.homefit.studio/...`); `support@homefit.studio` mailbox; ZA lawyer red-pen of privacy/terms scaffold; PayFast production merchant account.

## The day's six PRs in narrative

In merge order. All six landed on staging; all six are staging-only pending the next staging → main promotion.

### PR #482 — photo render uses DeviceRGB colorspace

`fix(safe-mode-v2): photo render uses DeviceRGB colorspace — kills dark + whole-frame-blur`. The Safe Mode photo render call was passing `colorSpace: nil` against a default CIContext, causing CoreImage to emit linear-light bytes that the JPG encoder mis-interpreted as gamma-encoded sRGB. The visible symptom was photos rendering ~30% too dark with the whole frame appearing to be lightly blurred. Fix: pass `CGColorSpaceCreateDeviceRGB()` explicitly on the render. Bench evidence (brightness within 0.4% of source, sharpness ratio 1.02) at `/tmp/safe-mode-bench-iter-1.html`. Carl device-verified the fix on his iPhone. Why it mattered: this was the sev1 that blocked the V2 photo path from being trustable as the canonical pipeline.

### PR #485 — bump algo version to 3 to re-surface re-process row

`fix(safe-mode-v2): bump algo version to 3 — surfaces re-process row for existing v2 captures`. Single-line bump. The editor sheet only renders the "Re-process Safe Mode" row when the captured-algo-version is older than the current algo-version constant. Without the bump from 2 → 3, every existing v2-captured-but-dark photo had no UI affordance to regenerate through the corrected (#482) pipeline. The Dart-side reprocess wiring was already correctly multi-ref from Wave-E — only the version constant was missing. Why it mattered: closed the loop on #482 by giving Carl a one-tap path to regenerate his stock of dark v2 captures.

### PR #489 — CachedClient embedding decoder expects 2048 bytes not 512

`fix(safe-mode-v2): CachedClient embedding decoder expects 2048 bytes not 512`. Units bug: both Dart decoders in `CachedClient` (cloud-JSON path + SQLite-row path) checked `bytes.length != 512` but MobileFaceNet outputs 512 floats × 4 bytes = 2048 bytes. Every sync silently dropped the embedding → cold-start hydration never primed → the capture screen showed "Prepare a face fingerprint" CTA for clients who were already enrolled. Fix: introduced `kFaceEmbeddingBytes = 2048` constant in `safe_mode.dart` + fixed both decoders to reference the constant + corrected 3 drifted doc comments that said "128-D" / "128 FP32 LE" / "512-byte" + added 12 regression tests. One test explicitly asserts the broken 512-byte shape is now REJECTED — locks in that the previous bug shape can't silently come back. Why it mattered: without this, the multi-ref enrolment work from Wave-E couldn't actually cold-start a real-world client.

### PR #490 — accept zero-detection captures + telemetry + orphan-row fix

`fix(safe-mode): accept zero-detection captures + telemetry + orphan-row fix`. Three changes bundled per Carl's "all in one PR" ask:

1. **Accept zero-detection captures.** Captures where Vision detected zero humans (landscape shots, equipment close-ups, empty room) were being rejected by Safe Mode under the previous fail-closed rule. Real-world: a practitioner records equipment-only B-roll inside a premises and the capture refuses. Single unified rule across photos + videos: zero detections = accept, since there are no bystanders to protect against.
2. **Telemetry.** Every accepted-empty event writes a `safe_mode.accepted_empty` row to `capture_audit_events` with a scene fingerprint (mean RGB, entropy, complexity score — no image bytes). Required relaxing a CHECK constraint on the `kind` column to admit the new value. The agent flagged this as a spec-vs-dispatch tension and took the minimal-change path.
3. **Orphan-exercise-after-rejection bug.** Hypothesis 2 of the parallel investigation turned out correct: Studio + ClientSessions had no removal stream to subscribe to. When a Safe Mode rejection deleted an exercise row, the screens kept rendering the stale row until the user navigated away. Fix is structural — new `onExerciseRemoved` stream fires alongside the rejection delete; both UI screens subscribe. Regression test went red → green.

Why it mattered: closed three small-but-annoying paper cuts in one PR, kept the telemetry pipeline honest for the live-page roster, and surfaced the orphan-row bug that had been confusing Carl during prior QA sessions.

### PR #491 — enrolment polish phase 1

`feat(safe-mode-v2): enrolment polish phase 1 — camera toggle + consent sheet + consent-aware mode scaffolding`. Six concerns:

1. **Camera flip toggle on enrolment screen.** Sticky per-device; default rear for client enrolment and selfie for self-enrolment.
2. **`FaceEnrolmentMode` enum.** Encodes the four-cell consent matrix (face-rec on/off × avatar consent on/off). Avatar-only, embedding-only, both, neither.
3. **Avatar-tap intercept + capture-banner "Set face" CTA.** Both consent-aware: open the editor in the correct mode OR show a SnackBar directing the practitioner to the consent sheet if the relevant toggle is off.
4. **avatarOnly simple-mode capture.** Single-shot shutter, no sweep, no embedding generation. Replaces the legacy avatar-only path retired during Wave-E.
5. **Consent sheet restructure.** Dropped the "Safe Mode" section header; moved the face-rec toggle into the "Profile" group below the avatar toggle. R-10 parity — added the face-rec toggle on the web portal too (it had never been wired through there). **Surprise during implementation:** the consent sheet had FOUR sections (Video / Profile / Analytics / Safe Mode) not three — the spec missed the Analytics section that landed in Wave 17. The agent handled correctly (dropped only the Safe Mode header, kept Analytics intact). Worth flagging in the spec drift section below.
6. **Test scaffolding.** Mode-resolution unit tests for all 4 matrix cells.

Why it mattered: turned the awkward "consent first then come back to enrol" flow into a coherent matrix the UI honours everywhere.

### PR #496 — enrolment polish phase 2

`feat(safe-mode-v2): enrolment polish phase 2 — pose gating + quality scoring + manual avatar`. Three concerns:

1. **Real-time pose-gated capture.** Vision pose stream feeds the sweep; the sweep accepts a frame only if pose differs by ≥25 degrees Manhattan distance from every existing slot AND quality score ≥60. Guidance ring with 6 segments lights up as buckets fill. Auto-begins on face detection (no "Start" button per Carl's mockup signoff).
2. **Per-embedding quality scoring.** Composite 0..100: 30% face confidence + 25% sharpness + 20% lighting + 15% pose uniqueness + 10% embedding L2 norm. Rejected slots flash a rose-tinted toast showing the raw score (per Carl's mockup signoff — show the number, don't sugar-coat).
3. **Manual avatar selection grid.** Post-sweep, a 3×2 grid of face crops with a quality histogram. Frontal-pick is highlighted by default; practitioner can tap to override. Skipped entirely in `embeddingOnly` mode.

Five mockup design decisions were honored per Carl's signoff: 6 pose buckets (not 8), reject toast shows raw score, pose labels in word-form, dashed face guide, no Start button.

Why it mattered: turned the multi-ref enrolment into a structured, observable, quality-aware capture loop instead of the implicit "trust the random sweep frames" Wave-E baseline.

## The dead-agent salvage event

Mid-session, the Phase 2 implementation agent worked for approximately 30 minutes, wrote ~3,700 lines of well-formed Phase 2 code across 3 Dart files + 1 mockup carry-forward + 45 unit tests (analyzer clean, all tests passing). Then its transcript file stopped being written to. The harness never sent a completion notification because the agent died silently. Carl noticed before I did and asked "we may have dead agents."

Diagnostic signal: the agent's jsonl `mtime` was 30 min stale; the agent worktree had uncommitted changes; no PR opened.

Salvage path (no work lost):

1. Verified the dead agent's uncommitted diff by running `flutter analyze` (clean) and `flutter test` (45/45 pass) inside the agent's worktree.
2. Authored the missing test wave script (`docs/test-scripts/2026-05-25-safe-mode-v2-enrolment-polish-phase2.md`) plus the index entry — the agent had skipped both before dying.
3. Committed all the agent's work verbatim, pushed to the planned branch, opened PR #496 as draft stacked on Phase 1.
4. Zero code modifications to the agent's actual implementation work — just packaging.

This event motivated a new memory entry: [`feedback_dead_agent_salvage.md`](../.claude/projects/-Users-chm-dev-TrainMe/memory/feedback_dead_agent_salvage.md). The general lesson: when a sub-agent goes silent past its expected duration, check the transcript jsonl's mtime first. If the agent wrote substantial content before dying, the worktree preserves the work — salvage by completing any missing deliverables (test scripts, index entries) then committing manually.

## The pgvector CI hiccup

While PR #491 was waiting on CI, a parallel-session PR (#486 self-trainer wave schema) landed on staging with a migration that required the Postgres `vector` extension. The CI image didn't have pgvector installed. Every downstream PR's "Apply all migrations against Postgres 17" check failed by inheriting the broken migration.

Carl resolved this in the other session — PR #498 (`fix(ci): install pgvector in migration-check service container`) landed on staging at `5a3b59b`. PR #491 then needed a refresh push to pick up the new workflow (GitHub Actions runs workflows from the PR HEAD, not the base). Same dance for PR #496 after Phase 1 merged. Both went green and merged after that.

The lesson is structural: any PR that lands a new Postgres extension requirement should be paired with the matching CI service-container update in the same wave, not relied on as a separate follow-up. The asymmetry between "new extension lands" and "CI catches up" is asymptotic — the first downstream PR after the schema bump is the one that gets bitten.

## Other parallel-session PRs that landed on staging today

Multiple PRs merged in parallel that this session didn't author but had to merge through. Listing them here to give the next session context on the full staging delta beyond today's six:

- **#486** — `feat(schema): self-trainer wave additive migrations`. Self-trainer foundation schema (additive only — no breaking changes to existing tables). Required pgvector, which surfaced the CI hiccup.
- **#487** — `feat(home): rename Workouts → My Workouts`. IA rename ahead of the self-trainer wave.
- **#488** — `fix(web-player): make SW invisible — network-first HTML + live-page bypass + auto-claim + auto-reload`. Service-worker reliability pass. Closes a long-running "stale player after deploy" complaint.
- **#483, #484** — portal back-arrow + live-popover polish.
- **#495** — `fix(portal): iPhone portrait rendering — page width + header safe-area + build chip`.
- **#498** — `fix(ci): install pgvector in migration-check service container`. Unblocked #491 and #496.
- **#499** — `fix(portal): iPhone portrait overflow — fully contain cards, fix Earn CTA + build chip`. Follow-up to #495.

## Memory entries added this session

Two new entries:

- [`feedback_dead_agent_salvage.md`](../.claude/projects/-Users-chm-dev-TrainMe/memory/feedback_dead_agent_salvage.md) — Symptom + detection + salvage path for sub-agents that die without notifying the harness. Anchored on the PR #496 real example. Includes the "when to salvage vs dispatch fresh" decision rule.
- [`gotcha_face_embedding_units.md`](../.claude/projects/-Users-chm-dev-TrainMe/memory/gotcha_face_embedding_units.md) — MobileFaceNet embeddings are 512 floats × 4 bytes = 2048 bytes. The canonical constant is `kFaceEmbeddingBytes = 2048`. Lists the 5 sites that had drifted before PR #489 fixed them. Symptom of the bug + tests-as-regression-guard pattern documented.

Both entries got one-liner pointers prepended to `MEMORY.md`.

## Known follow-ups

NOT in any of today's PRs — flagged for the next session.

1. **Multi-ref cold-start hydration gap.** `SyncService._pullClients` + `CaptureModeScreen._refreshCachedClient` only read from the legacy `cached_clients.face_embedding` column. They don't fall back to the new `cached_client_face_embeddings` table. Today's test client has BOTH (legacy + multi-ref) so the byte-length fix in PR #489 unblocked it. But a pure-multi-ref-only client (no legacy backfill) would still hit "Prepare a face fingerprint" CTA after app restart. Documented in PR #489's body under Follow-up.
2. **Phase 2 telemetry data structure.** The `capture_audit_events.kind` CHECK constraint was relaxed in PR #490 to accept `safe_mode.accepted_empty`. Worth a quick spec audit to make sure the kind enum is centralized somewhere agents can consult before adding more values — otherwise the constraint will keep growing one-relaxation-per-PR.
3. **Spec drift on consent sheet structure.** The enrolment polish phase 1 spec missed that Wave 17 added an Analytics section to the consent sheet. The agent handled it correctly inline, but the spec itself (`docs/specs/2026-05-25-safe-mode-v2-enrolment-polish.md`) should be amended with an "Update history" pass capturing the four-section reality.
4. **Device install.** iPhone CHM is on build `277e839` (pre-today's wave). The parallel session will produce the next iPhone build atop staging. The polish phase 2 features (pose gating, quality scoring, manual avatar grid) can only be properly QA'd on device.
5. **Supabase Branching reconciliation.** Still wedged in `MIGRATIONS_FAILED` from 2026-05-11. The pgvector CI fix addressed migration-check CI but not Branching. Handoff still at `docs/handoffs/2026-05-23-safe-mode-embedding-and-branching-reconciliation.md`.
6. **Carry forward from 2026-05-17-pm:** Hostinger 301 redirects, `support@homefit.studio` mailbox, ZA lawyer red-pen, PayFast prod merchant account — all still blocked on Carl.

## v2-on-video spec parked

Spec at `docs/specs/2026-05-25-safe-mode-v2-video.md` on main (commit `3890f72`), signed off. Architecture: Option C (Hybrid — first-frame face-rec + Vision tracker + sparse re-confirm every 2s). v1-fallback question signed off as Option 1 (conservative no-subject mode when subject can't be identified). Implementation parked for a fresh session per Carl's request — the photo polish day was already big enough.

## Fresh-session handoff

If a fresh session opens here: read this checkpoint top-to-bottom for the wave context, then `git log origin/staging --oneline --since=2026-05-25 | head -15` for the per-PR detail. The two memory entries added today are short and worth a one-read pass. Staging tip is `d452f3e`; main is docs-only ahead at `97e2078`. The next session's work is whatever the parallel-session iPhone build surfaces in QA — Carl's plan is to install on iPhone CHM with the consolidated staging build before the next staging → main promotion window.

The v2-on-video spec at `docs/specs/2026-05-25-safe-mode-v2-video.md` is the next planned feature wave; pick it up when Carl signals readiness.
