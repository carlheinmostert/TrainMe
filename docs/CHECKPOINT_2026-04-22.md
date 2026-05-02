# CHECKPOINT 2026-04-22 — Studio visual hygiene marathon + web player wireframe workshop

**Read this first on fresh session.** Supersedes `CHECKPOINT_2026-04-21.md` for all work after that date.

---

## What shipped today

### Wave 18 chain — Studio UI polish, iterative

A single ~12-hour marathon of Studio-UI refinement driven by device QA on every wave. 11 shipped wave commits + 2 SQL migrations + 1 web-player wireframe.

**Arc (oldest → newest, all on `main`):**

| Wave | Commit | Summary |
|---|---|---|
| 18 prep | `b8fc9cd` | Home-screen Settings top-right, Diagnostics queue-dump button, SRF hotfix SQL |
| 18 | `ab219b6` | Studio visual hygiene — 10 items: new StudioToolbar (Import/Preview/Publish/Share with coral triangles), exercise card groups PLAYBACK/PLAN/PACING/NOTES, preset chip rows (Reps/Sets/Hold), Rest bar chip row, SessionCard cleanup, Media Viewer coral mute pill, `saveExercise` dirty-stamp fix |
| 18.1 | `4ef9dfc` | Accordion (PLAN/PACING/NOTES single-open), unified mutable chip lists (cap 8 MRU), toolbar 52→40pt, rest-row Dismissible restored, **atomic `replace_plan_exercises` RPC** (closes 23505 regression on publish-reorder) |
| 18.2 | `e44c616` | Toolbar gap tighter, mixed-case header summary, PLAYBACK joined accordion, coral dot LEFT of chevron, summary wrap (3 lines), chip text vertically centred, rest chips wrap to multi-row |
| 18.3 | `d9d3b43` + `305d3d2` + `0a269c6` | Rest chip layout cascade fix (wrap + IntrinsicWidth on chips + minHeight on container), coral dot moved RIGHT, expanded header preserves label+summary |
| 18.4 | `4fa6dd4` | `[Custom]` → `[+]` icon, chip spacing 6→4pt, section header 11→13pt |
| 18.5 | `2ec3a36` | Chip spacing 4→2pt, chip padding 12→10pt, `[+]` reshape, summary font 11→13pt, **"Duration per rep" two-mode redesign** (segmented control replaces old Custom/toggle) |
| 18.6 | `d94b5cd` | `[+]` padding 12pt, rest-row background fix (surfaceBase instead of surfaceRaised), collapsed group spacing tightened, Duration-per-rep label stacks above control, font rebalance (all tiers to 13pt) |
| 18.7 | `1a97d15` | `[+]` structural nesting fix (CustomPaint wraps Container), PREP "· default" suffix removed, **Duration-per-rep PREP-style redesign** (value with dashed underline + source toggle below), inline editor Done/Cancel buttons, section header 13→14pt |
| 18.8 | `e6c6086` | `[+]` padding 12→10pt, inline editor respects card width, section header 14→16pt (label AND summary, same size), expand gap 8→2pt, NOTES summary single-line with whitespace-collapse |

**Main is at `be04500`** (Wave 18.8 merged).

### Supabase migrations applied (idempotent, live)

- `supabase/schema_fix_milestone_r_srf.sql` — fixes `= ANY (SRF)` in `set_client_exercise_default` + `get_client_by_id`. Unblocks Wave 8 sticky defaults for Carl's stuck queue of 9 ops.
- `supabase/schema_fix_publish_replace_exercises.sql` — new atomic `replace_plan_exercises(p_plan_id, p_rows jsonb)` SECURITY DEFINER RPC. Closes 23505 regression on reorder-then-publish.

### Web Player wireframe workshop (paused)

Interactive draggable wireframe at `docs/design/mockups/web-player-wireframe.html`. Two phone mocks side-by-side (Page layout + Exercise card anatomy), ~20 named regions total, drag-reorder via Sortable.js, state persists in localStorage. Every region has a stable name (`plan-bar`, `card-viewport`, `peek-panel`, `media`, `decoded-grammar`, `timer-chip`, etc.) for referencing in conversation. **Carl was going to use this for a web-player layout design session — paused when the Studio polish chain took over.**

### Infrastructure + docs

- Consolidated Wave 18.1 canonical test script (36 items) — supersedes Wave 18.
- Device QA test scripts for every wave (18 / 18.1 / 18.2 / 18.3 / 18.4 / 18.5 / 18.6 / 18.7 / 18.8) in `docs/test-scripts/`.
- New memory rule: [feedback_always_test_script.md](../../.claude/projects/-Users-chm-dev-TrainMe/memory/feedback_always_test_script.md) — every wave/patch that installs to the phone MUST ship with a test script + index.html entry.

---

## Where we are right now (freeze state for handoff)

### On Carl's iPhone

- **Wave 18.8 installed** (44.8MB Runner.app, built from `be04500`).
- QA on 18.8 pending.

### Docs server

Running on port 3457, serving from `/Users/chm/dev/TrainMe/docs`. Active test script link: http://127.0.0.1:3457/test-scripts/2026-04-22-wave18.8-device-qa.html

### Open loops

1. **Wave 18.8 QA** — Carl hasn't returned feedback on the 12-item script yet. When he does, triage as usual.
2. **Web player wireframe workshop** — started early in the session, abandoned when Studio polish took over. Carl will want to pick this up. The wireframe is at `docs/design/mockups/web-player-wireframe.html` and should auto-open in the browser when touched.
3. **Photo auto-seed side-effect** — every new photo exercise auto-writes `customDurationSeconds = 5 × reps` on first render, which means PACING shows a coral non-default dot on first view even without practitioner interaction. Carl flagged this as potentially noisy. Hasn't decided if it warrants a "seed on first edit instead of first render" change.
4. **`useVideoLengthAsOneRep` field doesn't exist** — Wave 18.5 agent used `customDurationSeconds == null ↔ From video` as the implicit mode signal. Works but is subtle. If we ever expose mode explicitly it'll need a real field.
5. **Carl's Wave 18.7 feedback** — all incorporated into Wave 18.8. The 18.8 installation on device is the validation.

### Known gotchas carried into next session

- **Build times:** profile build from a fresh worktree is 5-8 minutes cold, <30s warm.
- **iPhone connection:** `install-device.sh` fails with "No provider was found" / "CoreDeviceService was unable to locate a device" when iPhone isn't connected. Plug + unlock, retry.
- **Docs server root:** must be launched as `python3 docs/test-scripts/_server.py docs 3457` from repo root (the `docs` positional arg matters — otherwise `/test-scripts/*` paths 404).
- **Worktree isolation:** agent worktrees fork from `origin/main`, not from parent worktree HEAD. If there's uncommitted work locally, push to origin before dispatching an agent.
- **`install-device.sh` pulls main** — Wave 18 chain merges must be pushed before installing.
- **Merge conflicts on `docs/test-scripts/index.html`** are common because both agents + human edits touch it. Resolve by taking `--ours` then manually adding the agent's new wave entry at position 1.

---

## How to resume

1. **Read this file.**
2. **Read `CLAUDE.md`** if you haven't this session (has the whole project shape).
3. **Check `main`'s latest commit** — `git -C /Users/chm/dev/TrainMe log -1 --oneline` — should be `be04500` (Wave 18.8) or later.
4. **Check for Wave 18.8 feedback** — `cat /Users/chm/dev/TrainMe/docs/test-scripts/2026-04-22-wave18.8-device-qa.results.json`. If it exists, triage the failures.
5. **Check the docs server** — `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3457/test-scripts/index.html`. If not 200, restart: `cd /Users/chm/dev/TrainMe && python3 docs/test-scripts/_server.py docs 3457 &`.
6. **Ask Carl where he wants to go.** Likely options:
   - Triage Wave 18.8 feedback → Wave 18.9.
   - Resume web-player wireframe workshop.
   - Start a new feature branch.

### If Carl asks "where were we?"

Studio polish chain ran through Wave 18.8; 18.8 is on his phone pending QA. Web-player wireframe workshop is paused — `docs/design/mockups/web-player-wireframe.html` has the draggable regions ready.

### Default next step if Carl gives no direction

Ask whether he wants to walk the Wave 18.8 test script (12 items at http://127.0.0.1:3457/test-scripts/2026-04-22-wave18.8-device-qa.html) before deciding.

---

## Quick commands

```bash
# Install latest main to iPhone (builds first if needed)
cd /Users/chm/dev/TrainMe && ./install-device.sh

# Restart the docs server
cd /Users/chm/dev/TrainMe && python3 docs/test-scripts/_server.py docs 3457 &

# See active test scripts in browser
open "http://127.0.0.1:3457/test-scripts/index.html"

# Open the web player wireframe workshop
open /Users/chm/dev/TrainMe/docs/design/mockups/web-player-wireframe.html

# Check Wave 18.8 QA results (if Carl has clicked through)
cat /Users/chm/dev/TrainMe/docs/test-scripts/2026-04-22-wave18.8-device-qa.results.json

# Apply a Supabase migration (linked CLI)
supabase db query --linked --file supabase/<file>.sql
```

---

## Ledger of non-obvious decisions from this session

- **Wave 18 and Wave 18.1 are both in Past waves** (superseded by later rounds). Wave 18.1 stayed at position 2 earlier as "canonical baseline"; after Wave 18.8 both are archived.
- **Preset chip storage** migrated from dual-array (canonical + custom) to single unified mutable list per control. Cap 8, MRU eviction. SharedPreferences key unchanged (`homefit.practitioner.custom_presets`); shape preserved for migration. Seeds written to storage on first read.
- **`replace_plan_exercises`** uses an explicit column list in `jsonb_populate_recordset` — adding new `exercises` columns in future requires updating the RPC's column list (flagged in the RPC's comment).
- **`customDurationSeconds` still stores total** (per-rep × reps) — the UI divides by reps for display. Not changed across the whole Wave 18 chain despite discussion about flipping to per-rep storage. A flip would need a data migration; deferred.
- **Coral on dark has a real perceptual contrast penalty.** Multiple font-size iterations confirmed it. Final Wave 18.8 solution: section header at 16pt vs 13pt inner content (3pt absolute gap).
- **NOTES summary single-line, PACING summary multi-line.** Different constraints. `_GroupHeader.singleLineSummary` bool parameter drives the distinction.
