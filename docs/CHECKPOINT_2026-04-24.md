# Checkpoint — 2026-04-24 (Player UX overhaul + Photos parity + Video reps model)

**Read this first on fresh session.** Supersedes `CHECKPOINT_2026-04-23.md` for current state. Earlier checkpoints remain authoritative for their era.

## TL;DR

Heaviest UX iteration day on the player to date. **18 commits on `main`**, **15 web-player cache versions** (`v40 → v57`), **4 install-device builds**. Three big features (photos three-treatment / video reps per loop / mobile EB toggle) shipped via four parallel agents, plus a long chain of inline rep-stack polish driven by Carl's live device QA.

**Single canonical run:** `docs/test-scripts/2026-04-24-wave26-end-of-day-canonical.html` — 16 items across 7 sections covering everything live as of today's close. Supersedes Waves 22, 23, 24, 25 (all moved to Past).

## What landed today (chronological)

### Morning (v40 → v45)
- `1280c75` — Wave 19.5 toggle rebind + segmented bar visibility
- `4640e6f` — Wave 19.5 long-press peek chrome strobe fix
- `8007750` — segment tints (later replaced by full vertical stack)
- `23d7b29` — "Show me" client treatment override (4-position segmented in gear popover, per-plan localStorage)
- `5e94ec6` — vertical chrome stack on right edge, no ambient dim, footer build marker
- `90ea4a7` — capture defaults reach cloud (`conversion_service._processQueue` re-reads SQLite to avoid clobbering by stale in-memory ExerciseCapture)
- `6f2ad18` — dual-video crossfade + rep tick on loop seam
- `3f6ef4f` — rep tick label degrades on legacy data

### Afternoon — Wave 20 (soft trim) + Wave 21 (vertical rep stack)
- Wave 20 (cherry-picked into a chain ending `8a61eab`): schema + `_MediaViewer` trim editor + mobile playback + web playback + Wave 20 test script. Bonus catch: `replace_plan_exercises` RPC was silently dropping `inter_set_rest_seconds` since Milestone Q — patched in passing.
- Wave 21 (`6d335c0` + `a915fdc`): vertical rep-block stack replaces horizontal segmented bar. Bottom-up "stacking your reps" metaphor.

### Iteration on the rep stack (v46 → v50)
- `8d07de4` — circuit slides honoured (1 set per slide regardless of `slide.sets`); photos no longer auto-hidden; sets=1+reps=1 hide rule
- `5554fd9` — rep-hold guard (later reverted)
- `cedfe07` — duration is the source of truth (REVERT v47, unify rep stack + timer; rep counter derives from elapsed time, not loop count)
- `6ffc7af` — paint handoffs at slide change + final-rep landing
- `5e1b3bc` — uniform rest block size, active fill as progress bar, drain animation

### Wave 22 (photos three-treatment) — `7e190f2 → 7f87697`
Photos now match videos: line_drawing_url + grayscale_url + original_url all populated. Mobile uploads raw color photo to raw-archive bucket. Web player applies CSS grayscale filter on `<img>` for B&W (single source). 4 commits.

### Wave 23 (consolidated polish for 19.5/20/21) — `a396c50`
20-item canonical test script bundling the morning's iteration. Later superseded by Wave 26.

### Late afternoon stack-nav + chevron polish (v51 → v55)
- `ccc8b07` — breather overlay clears at slide change (no two timers); navigable rep stack (tap any block to jump)
- `8bb541f` — pointer-events fix so rep stack actually receives taps (was passing through to video pause/play)
- v55 chevron-shift attempt with `:has()` (didn't work in practice — Carl reported chevron still overlapping)

### Wave 24 (video reps per loop) — `4ac428f → 97a2cd7`
Practitioner records videos with N reps (default 3, was implicitly 1). Retired DURATION PER REP / "From video / Manual" toggle from UI. Per-rep time always derives from `video_duration ÷ video_reps_per_loop`. New PACING field "REPS IN VIDEO". 5 commits. SQLite v25 → v26.

### Wave 25 (mobile Enhanced Background toggle) — `cd0c749 → abfb974`
`_MediaViewer` finally plays the segmented body-pop variant for B&W + Original. New toggle pill — initially placed as vertical book-spine in the left-edge column, repositioned later to horizontal at bottom-left above the mute pill.

### EOD polish (v56 → v57)
- `7d6d5dd` — chevron class toggle (replaced `:has()` with JS-applied `has-rep-stack` class) + top-down wave drain animation (~600ms staggered transition delays)
- `01abdf5` — EB pill horizontal repositioning + trim handles pause video on drag-down + resume on release
- `fc101ae` — Web "Enhanced background" → "Body focus" parity rename + trim handles seek video to dragged frame in real time

## Live state (EOD 2026-04-24)

- Web player cache: **`homefit-player-v57-body-focus-label`**
- Latest install-device commit: **`fc101ae`**
- Active branch: `claude/wonderful-burnell-933210` (synced with main)
- Mobile SQLite schema: **v26**
- Supabase migrations applied today: `schema_milestone_x_soft_trim.sql` (Wave 20), `schema_wave22_photos_three_treatment.sql`, `schema_wave24_video_reps_per_loop.sql`

## All commits today
```
fc101ae fix: web "Body focus" label parity + trim handles seek video to drag position
01abdf5 fix(mobile): EB pill horizontal above mute + trim handles pause/resume video
7d6d5dd fix(web-player): chevron class toggle + top-down wave drain animation
3cccc1d docs(test-scripts): Wave 25 mobile-eb-toggle verification
... (Wave 25 chain) ...
d94140d docs(test-scripts): Wave 24 video-reps verification
... (Wave 24 chain) ...
8bb541f fix(web-player): rep stack blocks receive taps (was passing through to video)
ccc8b07 fix(web-player): clear breather overlay at slide change + navigable rep stack
... (Waves 22/23 chain) ...
6ffc7af fix(web-player): rep stack handoffs at slide change + final-rep landing
cedfe07 fix(web-player): unify rep stack + timer — duration is the source of truth
... etc
```
Run `git log --oneline 9548bad..HEAD` for the full list.

## Active wave queue (test-scripts/index.html)

1. **Wave 26 — End-of-day canonical** (slot 1, NEW) — single 16-item run for all of today's work
2. Wave 19 — Web-player polish round 2
3. Wave 18.11 — polish round 8
4. Wave 18.1 — canonical baseline
5. Wave 15 — Offline-sync robustness
6-13. Older waves carrying over from earlier weeks

Past waves (with results loaders): Wave 25 (superseded by 26), Wave 24 (sup. 26), Wave 23 (sup. 26 — was already a consolidation of 19.5/20/21), Wave 22 (sup. 26), older.

## Pending / known-issue carry-over

- **Wave 26 not yet tested** — Carl approved all changes inline during iteration but hasn't formally walked the consolidated script.
- **Legacy plan `8f64489f-f712-4c1c-87b3-f958819cd2ae`** (Lauren) — has the photo-three-treatment data only for NEW captures; the existing position-3 photo is stuck with single-source baked-in line-drawing data.
- **`stickyCustomDurationPerRep` plumbing in `studio_mode_screen.dart`** is dead code post-Wave-24 (`customDurationSeconds` writes retired). Worth a follow-up dead-code sweep.
- **Long-press 4× zoom on trim handles** (Wave 20 punt) — drag affordance alone in v1.
- **`existsSync()` on UI thread** in `_sourcePathForTreatment` (Wave 25) — perf is fine for short captures but worth eyeballing on 16-exercise plans during rapid swipe.
- **Mobile parity for the "Show me" segmented control** — the unified WebView plan-preview already gets it via R-10. The Flutter native `_MediaViewer` has the vertical treatment pill; consistency between the two preview surfaces was deliberate (different UX targets).

## Known load-bearing context that isn't obvious from the code

- **Duration is the source of truth.** The rep stack derives `repsInSet` from elapsed proportion of `setPhaseRemaining`, NOT from video loop count. The video crossfades at its natural rate underneath; the loop seam handler does NOT touch the rep counter. This is the architecture Carl insisted on (commit `cedfe07`) after we discovered the two-clocks problem mid-afternoon. Any future change that re-introduces "advance set on rep N" via the loop seam will reintroduce the drift bug.
- **Circuit slides are ALWAYS 1 set per slide.** Helper `effectiveSetsForSlide(slide)` returns 1 when `slide.circuitRound` is truthy. Used in `calculatePerSetSeconds`, `calculateDuration`, `beginSetMachineForCurrent`, and `updateRepStack`. A 3-round circuit unrolls into 3 separate slides, NOT one slide with 3 sets.
- **Photo treatments use a single source URL with CSS filter for B&W.** The mobile pipeline uploads raw color JPG to `raw-archive` (consent-gated) AND the line-drawing converted JPG to `media`. RPC returns both as separate URLs. Web player B&W on photos is `<img class="is-grayscale">` with `filter: grayscale(1) contrast(1.05)` — same source as Colour, no second file.
- **Video reps per loop is per-EXERCISE, not per-client.** Default 3 on fresh captures via `withPersistenceDefaults`. NULL on legacy rows means "1 rep per loop" (preserves pre-feature behaviour). UI: PACING accordion's TOP row.
- **`replace_plan_exercises` RPC has been quietly dropping fields** between Milestone Q and Wave 20. Each new column on `exercises` needs explicit add to that RPC's INSERT column list. Wave 20 patched `inter_set_rest_seconds`; Wave 24 patched `video_reps_per_loop`. Worth a future audit RPC + integration test.
- **iOS Safari `:has()` works in 15.4+ but isn't always reliable** for our `.card-viewport:has(.rep-stack:not([hidden]))` use. v55 attempt failed silently. v56 switched to JS-toggled class — more reliable across versions.

## How to resume

1. Read this checkpoint, then `CLAUDE.md`'s "Current Phase" section.
2. Carl's Wave 26 consolidated script is at `docs/test-scripts/2026-04-24-wave26-end-of-day-canonical.html` — 16 items, runs ~30-40 minutes on device. Open via `http://localhost:3457/test-scripts/2026-04-24-wave26-end-of-day-canonical.html` if `_server.py` is running.
3. If Carl reports issues from Wave 26 QA, the per-feature scripts (Waves 22/24/25 in Past) have more granular item breakdowns for debugging.
4. R-10 invariant: any `web-player/*` edit auto-applies to the Flutter plan-preview WebView; the per-exercise `_MediaViewer` is Flutter-native and needs separate work.
5. SW cache name + `PLAYER_VERSION` const must rev together (comment in both files documents this).

## Out-of-scope but on the radar

- Practitioner-side analytics on "% of clients overriding their preferred_treatment via Show me" — backlog item from earlier today.
- Mobile preview vs WebView preview consolidation — historical divergence; might be worth unifying in a future wave.
