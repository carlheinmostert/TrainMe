# Checkpoint — 2026-05-04

**Big polish + diagnostics day — 27 PRs landed, 2 Supabase migrations applied.**

Started the day at `c18cfe7` (chore(flutter): treatment short label Original → Colour, #199 — last of the prior session). Ended at `8be3b30` (#223 white text on session card). Two milestones along the way: the cloud-Claude PR triage (#196/#197/#198), then the agent-driven polish wave + hold-position model + filmstrip cards.

## Current state on Carl's iPhone

- **Bundle**: `studio.homefit.app`
- **Build**: includes everything through PR #223 (latest install ran 2026-05-04 morning SAST)
- **Includes**: see "What's live" below

## Where main is

- HEAD: `8be3b30 fix(client-list): white text on session card (drop the muted-grey) (#223)`
- 0 open PRs, 0 in-flight agents at session close

## Supabase migrations applied (live)

Both ran via `supabase db query --linked --file ...` after the SQL was reviewed:

- **`schema_wave43_hold_position.sql`** — adds `hold_position TEXT NOT NULL DEFAULT 'end_of_set'` to `exercise_sets`. Migration backfills rows with `hold_seconds > 0` to `'per_rep'` so already-shipped plans keep their displayed durations. Adds CHECK constraint `('per_rep', 'end_of_set', 'end_of_exercise')`. `replace_plan_exercises` + `get_plan_full` re-created with the new column threaded through; every prior column carried forward per the schema-migration discipline rule.
- **`schema_wave_circuit_names.sql`** — adds `circuit_names jsonb NOT NULL DEFAULT '{}'::jsonb` to `plans`. `list_practice_plans` re-created with `circuit_names` threaded into the per-plan payload. `get_plan_full` needs no edit (emits `to_jsonb(plan_row)` automatically).

## SQLite schema bumps

- v33 → v34 (Wave 43 hold_position) — same migration as Supabase, applied locally
- v34 → v35 (skipped — was an internal numbering placeholder during stacked rebases)
- v35 → v36 — wave hold_position landed at v36 in main
- v36 → v37 (Wave Circuit-Names) — `sessions.circuit_names TEXT` JSON-encoded `{circuitId: name}` map

## What's live

### New features
- **#216 Hold position 3-mode picker** — `Per rep` / `End of set` / `End` segmented control under the Hold stepper in the Plan tab. Default for new sets is `End of set`. Math branches per mode in BOTH surfaces (web player + Flutter). Existing-row backfill preserves displayed durations.
- **#205 Inline-editable circuit names** — practitioner can rename "Circuit A" to anything; persists per-session, JSON-encoded jsonb on plans. Web player reads via `plan.circuit_names[circuit_id]`.
- **#217 Studio settings sheet → tabs (Now / Defaults / Plan)** — tabbed layout to stop the sheet being scrolly. Detent stays 85%, always lands on Now. Phase B placeholder treatment from #211 preserved per-tab.
- **#218 Hero-frame static thumbnails everywhere** — Studio card thumbnails + editor sheet header thumbnail are now the static Hero frame, not a playing video loop. New `staticHero: true` mode on `mini_preview.dart`. The Preview tab inside the editor still uses `MediaViewerBody` — motion stays where motion belongs.
- **#220 Filmstrip hero background on session cards** — up to 4 video heroes tiled horizontally as the card background. B&W via `ColorFilter.matrix`. 1px black hairlines between cells. R-10 not relevant (mobile only). Card height bumped +30% (~80px → 104px).
- **Card iteration sweep (#221 + #222 + #223)** — drop the leading icon block, replace with a floating count glyph (`_LeadingCountGlyph` — coral 42pt single-digit / 34pt multi-digit Inter with tabular figures + drop shadow); uniform 30% dark veil over the filmstrip (was L-to-R 0.92→0.55→0.30 gradient); body text swap `textSecondaryOnDark` → `textOnDark` so the muted grey reads white against the lighter veil.

### Bug fixes that surfaced from real device usage
- **#206 Soft-delete SnackBar root-messenger** — `Studio → settings sheet → Delete plan` now actually surfaces the undo SnackBar (was silently failing because the captured `ScaffoldMessenger.of(context)` belonged to Studio's local Scaffold which got disposed on `Navigator.pop`). Installed a `rootScaffoldMessengerKey` on `MaterialApp` for the post-pop case. Same fix flips selection-leak on cross-exercise nav (`_selectedTrimHandle` reset in `_onPageChanged`).
- **#208 Conflict-marker leak cleanup** — earlier #202 rebase left literal `<<<<<<< HEAD` text in `docs/test-scripts/index.html` on main. Resolver only handled one of the conflict regions in the cascade. Cleaned + saved `gotcha_test_scripts_index_cascade.md`.
- **#212 + #213 Stuck-conversion debugging** — diagnosed Carl's "stuck converting" report. Found two issues: (a) UI double-count — `Session.pendingConversions` counted `failed` rows so a single failure rendered both "1 converting…" + "1 failed" pills; (b) damaged mp4 file with no AVFoundation recovery (Code=-11829). Fixes: tighten the count math; add long-press on the "N failed" pill to read `{Documents}/conversion_error.log` from the device with copy-all + delete-log buttons. Saved `gotcha_corrupted_raw_video.md`. v8 hand-pose disabled defensively then re-enabled in #219 once cleared.
- **#214 → #215 Rep-stack collapse rescue v1 + v2** — bug-D's `weight-chip min-width: 68px` from #200 collided with bug-C's `.rep-stack { width: 34px }`. The aside (`flex: 0 0 auto`) claimed 68px in a 34px parent and squashed the rep blocks to 0. v1 dropped the chip min-width (still bad — chip's natural width still overflowed); v2 absolutely-positioned the aside outside the column entirely, freeing the blocks column to use full width and restoring chip uniformity.
- **#219 Segmentation head-clip + v8 re-enable** — auto-picked Hero thumbnails were chopping off heads because Vision's mask gives faces/hair lower confidence than the torso, so the bbox stops at the neck. Asymmetric crop pad: 25% top, 10% other sides. v8 hand-pose re-enabled (RCA cleared the dilator's name).

### Diagnostic + dev tooling
- **#201 Orphan-agent detection hooks** — `PostToolUse` hook records every isolated-worktree Agent dispatch into `.claude/state/agent-registry.jsonl` + brief sidecar; `SessionStart` hook scans for orphans (different session_id, dirty worktree, no merged PR) and emits a `<orphan-agents-detected>` system reminder. Means future fresh sessions auto-detect dead-parent worktrees. 33-assertion stdlib test suite at `.claude/hooks/test_check_orphan_agents.py`.
- **#213 Conversion-error log reader** — long-press the "N failed" pill on a session card to open a bottom sheet with the last 5 entries from `{Documents}/conversion_error.log`. Copy-all + Delete-log buttons. Diagnostic surface — `UIFileSharingEnabled` intentionally NOT set, so this is the only way to read the log on a release build without rebuilding.

### Other shipped
- Wave 17 plan analytics (12 event emitters + completion CTA) was actually shipped previously; not in today.
- #196 / #197 / #198 are cloud-Claude PRs from earlier in the day — landed in the morning before the polish wave.

## Memory entries added today

- **`gotcha_test_scripts_index_cascade.md`** — multi-region cascade conflicts on `docs/test-scripts/index.html` slip past single-block regex resolvers. Always `grep -c "<<<<<<<"` before push.
- **`gotcha_corrupted_raw_video.md`** — diagnostic path for "stuck conversion" reports. Check UI double-count first; if real, long-press the failed pill to read `conversion_error.log`. AVFoundation Code=-11829 = unrecoverable damaged file.

## Pending verification on device

Carl manually device-tested most of today's batch as it landed. Latest install (#223) was confirmed visually for the white-text + uniform-veil polish. Test scripts on disk:
- `docs/test-scripts/2026-05-03-camera-capture-trio.html` (#196 + #197 + #198)
- `docs/test-scripts/2026-05-03-hero-handle-trim-panel.html` (#202)
- `docs/test-scripts/2026-05-03-studio-settings-card-ui.html` (#203 + #211 + #217 — updated for tabs)
- `docs/test-scripts/2026-05-03-hero-star-badge.html` (#204)
- `docs/test-scripts/2026-05-03-orphan-agent-hook.html` (#201)
- `docs/test-scripts/2026-05-03-web-player-rep-stack-fixes.html` (#200)
- `docs/test-scripts/2026-05-03-hero-thumbnail-everywhere.html` (#218)
- `docs/test-scripts/2026-05-03-hold-position.html` (#216)
- `docs/test-scripts/2026-05-04-session-card-filmstrip.html` (#220)

Numbering on the index page has drifted from the cascade rebases — could be re-sorted in a separate sweep.

## Open backlog (deferred)

Low priority, none blocking:
- `plan_settings_sheet.dart` refactor (1220 lines / 11 nested private widgets — Phase B concern)
- `_persistHero` / `_persistTrim` shared debounce helper
- `_rawIsLocal` / `_hasArchive` memoisation (sync I/O on UI thread)
- Comment hygiene cleanup (regretted-deletion `// Note:` lines, date-stamped doc comments, `Bug fix A/B/C/D:` task-pointer prefixes)
- Test-script index numbering re-sort

## Carl-side TODOs (unchanged from earlier sessions)

- Apple Developer Program activation (Individual enrollment per 2026-04-28; flip `_appleEnabled = true` + restore Apple button when ready)
- Hostinger 301 redirects: `homefit.studio/privacy|terms` → `manage.homefit.studio/...`
- `support@homefit.studio` mailbox setup
- ZA lawyer red-pen of privacy/terms scaffolds
- PayFast production merchant account signup

## Fresh-session handoff

Read first: this file + `MEMORY.md`. The two new gotcha memories above cover the most likely traps to re-hit. The orphan-agent hooks (#201) mean fresh sessions auto-detect dead-parent worktrees if any are left over.

The `homefit.studio` brand, Reader-App compliance, and the v6 line-drawing tuning lock are all unchanged. v8 hand-pose dilation is back on as of #219; if it ever needs disabling defensively again, flip `handDilationEnabled` at `app/ios/Runner/VideoConverterChannel.swift:180`.
