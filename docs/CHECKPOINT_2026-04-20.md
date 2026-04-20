# Session Checkpoint — 2026-04-20 (end of day)

> **Hi future Claude.** Carl will greet you with "Where were we?" in a fresh session.
> Read this doc + `CLAUDE.md` + the active wave test plan first.

## One-sentence status

**Full-day merge cascade: audio mux truly fixed (via concurrent drain), per-exercise treatment preference + vertical pill text rotation, portal practice rename + inline popover switcher, delete-client RPC bug fix, credit model overhaul to 3/8-free-credits with 5% lifetime + goodwill floor, B&W thumbnails, logo v2 locked, test-script infrastructure with pass/fail + notes + live server sink, Wave 2 passed 40/40 with 1 fail + 3 pass-notes, Wave 3 created awaiting implementation.**

## The arc of today

Morning started on checkpoint handoff from the prior session. Then a long cascade:

1. **Three-treatment UX** — mobile preview + MediaViewer converged on the segmented-control + consent switch pattern. Vertical pill orientation to match vertical swipe. PR #23 / #24 / #30.
2. **Line-drawing thumbnails** — tried motion-peak + person-crop (PR #22), still unreadable; switched practitioner-facing surfaces to B&W (PR #33). Line drawing preserved on client surfaces (web player).
3. **Brand logo v2** — retired the heartbeat/roof Pulse Mark; new matrix-in-coral-band with 3 progressively-shrinking grey ghost pills each side, 2×2 circuit (2 exercises × 2 cycles). Lockup variant stacks wordmark above matrix with ascender-safe viewBox `0 -2 48 16`. PR #34.
4. **Credit model overhaul (Milestone M)** — +3 credits organic signup, +8 credits referred signup, referrer gets 5% lifetime rebate with goodwill floor of 1 credit on first rebate payout. One-time +10 bonuses removed. PR #32.
5. **Delete client** — cascade soft-delete with undo (Milestone L). First version shipped with a PL/pgSQL ambiguous-column bug (`42702` — SETOF return-column `id` shadowed `clients.id` in UPDATE). Fixed live + PR #37 audit trail.
6. **Portal rename + switcher (Milestone N)** — killed the 1990s practice-picker dropdown. New pattern: `In practice: {EditableName}  ⇄ Switch` with inline edit on tap + custom popover (not a native select) on the switch link. PR #36.
7. **Audio bug saga** — PR #29 added `sourceFormatHint` for audio writer input; didn't actually work because `includeAudio` defaulted to `false` in the Dart model. PR #39 unconditionally passed `true`. That exposed a deeper bug — attached audio track but drained it serially AFTER the video loop, tripping AVAssetWriter's interleave backpressure and hanging the video pump indefinitely. PR #40 added kill-switch + diagnostics. PR #41 (final) refactored to **concurrent drain** via `requestMediaDataWhenReady` on separate dispatch queues per input, DispatchGroup waiting on both `markAsFinished` before `finishWriting`. Audio now plays on Line treatment.
8. **Per-exercise treatment preference (Milestone O)** — swipe-to-set persists per exercise via new `preferred_treatment` column (SQLite v17 + Supabase). Plus vertical pill text rotation (90° book-spine style). PR #38.
9. **Disk cleanup** — went from 2.3 GiB free → 45 GiB free across multiple passes. 44 worktrees → 9. Stale agent worktrees, DerivedData, Homebrew + npm + pip + Playwright + Claude caches, old DMGs, VSCode VSIX cache, iOS 26.4.1 simulator runtime (re-downloaded the device SDK after accidentally deleting it).
10. **Test-script infrastructure** — evolved through several iterations:
    - Phase 1: markdown → didn't render in preview panel.
    - Phase 2: HTML with checkboxes.
    - Phase 3: Added localStorage persistence.
    - Phase 4: Added sequential numbering (1..N flat) so Carl can reference by number.
    - Phase 5 (current): Pass/fail buttons + note field on BOTH pass and fail. Live POST to local Python server at `docs/test-scripts/_server.py` writing `{slug}.results.json`. Port 3457.
    - Wave discipline: new requirements queue into NEXT wave, current wave stays stable for testing.
11. **Business case xlsx + exec summary** — 5-year model with 9 sheets, 54 named ranges, 1480 formulas. CHOOSE-based scenario toggle at `Assumptions!C6`. Refactored (PR #35) — fixed circular ref in Growth!B11, rewrote formulas to named refs, added 5 Excel Tables. Exec summary HTML at `docs/business-case/executive-summary.html` — Chart.js + sliders, tweaking assumptions recomputes live.
12. **Wave 2 QA** — 40/40 items tested. 36 silent passes, 3 pass-with-note, 1 fail. Wave 3 backlog created with 4 items.

## PRs merged today (in order)

Wave 1 pile (morning): #22, #23, #24 → then later #26, #28, #29, #30, #31, #32, #33, #34.
Wave 2 pile (afternoon): #36, #37, #38, #39 → audio bug cascade → #40 kill-switch → #41 true fix (concurrent drain).
Business case: #35 **still open** — has xlsx refactor + exec summary. Decide on merge before closing this session.

## What's on device right now

- **iPhone CHM**, UDID `00008150-001A31D40E88401C` (iPhone 17 Pro, slot `iPhone18,1`).
- **SHA**: post-`0a3816c` (PR #41 concurrent drain merge).
- Audio works on Line treatment. Conversion completes in seconds for short clips.

## Wave 2 results (processed)

- **1 fail:** #7 — long-press iOS context menu collides with the bottom-anchored Studio card layout.
- **3 pass-with-notes:**
  - #3 — mute button also pauses the video; needs decoupling.
  - #5 — default prep countdown 15s too long; reduce to 5s + add per-exercise override.
  - #22 — "N pending" chip doesn't appear while offline; should show always.
- **36 silent passes.**
- Results file: `docs/test-scripts/2026-04-20-wave2-device-qa.results.json`.

## Wave 3 test plan (created, AWAITING IMPLEMENTATION)

`docs/test-scripts/2026-04-20-wave3-device-qa.html`. 13 items across 4 feature areas:

1. **Long-press + bottom-anchor collision fix** (items 1-2) — Wave 2 #7 fail.
2. **Decouple mute from play/pause** (items 3-5) — Wave 2 #3 pass-note.
3. **Prep countdown 5s default + per-exercise override** (items 6-10) — Wave 2 #5 pass-note. Requires a new `prep_seconds` column on Supabase `exercises` + SQLite mirror, Studio card edit UI, web-player respect, constant change in `plan_preview_screen.dart`.
4. **Pending chip visible offline** (items 11-13) — Wave 2 #22 pass-note.

**Next session's first job:** spawn implementation agents for each area, land the PRs, install to device, Carl works Wave 3.

## Still pending (not in Wave 3 — deferred work)

- **Share-kit `/network` page implementation** — two agent attempts ran out of context mid-flight. Mockup at `docs/design/mockups/network-share-kit.html` is the spec.
- **Mobile R-11 twin** for portal rename/switcher — the portal (PR #36) has the new pattern but the mobile practice-chip sheet still shows the old UX.
- **Test plan Phase 1** — no tests exist for business-logic RPCs yet.
- **Dead-code sweep** — PR #10 flagged items.
- **PayFast production cutover** — blocked on Carl's merchant account.

## Blocked on Carl

- PayFast production merchant account.
- Apple Developer Program activation.
- Legal review of privacy + TOS copy.
- Decision on whether to merge PR #35 (business case + exec summary).

## Infrastructure state

- **Docs server** — `python3 /Users/chm/dev/TrainMe/docs/test-scripts/_server.py /Users/chm/dev/TrainMe/docs 3457` running in background. Serves static docs + accepts POST to `/api/test-results/{slug}.json`. **If not running, start it before opening any test script.** Check with `lsof -ti:3457`.
- **iOS syslog stream** — `/tmp/ios-syslog.log` may still be live from `idevicesyslog -u 00008150-001A31D40E88401C`. Restart if debugging iOS again.
- **LibreOffice 26.2.2** now installed at `/Applications/LibreOffice.app` (needed for xlsx recalc skill). `soffice` symlinked at `/opt/homebrew/bin/`.
- **libimobiledevice** installed (for `idevicesyslog`).
- **Disk** — 45 GiB free.

## Account / practice setup for testing

Unchanged from previous checkpoint. Same users, practices, membership table. See prior sections below.

## Design rules in force

Unchanged: R-01 (undo-not-confirm), R-02 (header purity), R-06 (practitioner vocab), R-09 (defaults obvious), R-10 (player parity mobile↔web), R-11 (portal↔mobile twins), R-12 (dashboard hygiene). Line-drawing v6 LOCKED.

**Added today:**
- **Logo v2 geometry LOCKED** — matrix `viewBox="0 0 48 9.5"`, lockup `viewBox="0 -2 48 16"`. 3 ghost pills per side (progressively sized + lightened greys `#4B5563` / `#6B7280` / `#9CA3AF`), 2×2 circuit grid in coral tint band, single sage rest pill. Don't re-derive — paths in `web-portal/src/components/HomefitLogo.tsx`, `app/lib/widgets/homefit_logo.dart`, `web-player/app.js buildHomefitLogoSvg()`.
- **Credit model LOCKED** — 3 / 8 / 5%-lifetime / goodwill-floor-of-1. Never "+10" anywhere. Migration `schema_milestone_m_credit_model.sql` applied live.
- **Test scripts** — HTML under `docs/test-scripts/` with pass/fail+notes + server sink. See `feedback_test_scripts_as_markdown.md` + `feedback_test_wave_discipline.md` in memory.

## How to resume

1. Read `CLAUDE.md`.
2. Read this doc.
3. Read memory files — `feedback_test_wave_discipline.md` + `feedback_test_scripts_as_markdown.md` are load-bearing for the test flow.
4. Read Wave 3 backlog at `docs/test-scripts/2026-04-20-wave3-device-qa.html`.
5. Ask Carl what he wants to pick up. Default priority: implement Wave 3 items 1-4, then re-install + QA.

**Carl's preferred working style** — unchanged from prior checkpoint. Delegate multi-file coding to sub-agents (worktree isolation), push to branches + PR, don't push directly to main, always re-run `install-device.sh` after mobile PRs land. Test scripts pinned in preview panel at http://localhost:3457/test-scripts/…, state auto-persisted.

**One thing Carl almost always asks next:** "where were we?" → this doc. Or "let's test Wave 3" → spawn the implementation agents, land the PRs, install, he works the checklist.
