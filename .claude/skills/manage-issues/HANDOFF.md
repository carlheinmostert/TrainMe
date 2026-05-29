# Handoff — managed-issues system build

For a fresh session resuming after Carl's break. The **whole system is built and on `main`**; only **operationalising** it remains. This doc is the "where we are + what's next" pointer — the durable design lives in committed docs (referenced below), so don't re-derive it.

## What this is

We evolved Carl's personal `manage-issues` skill into a full **issue-management discipline system** for `carlheinmostert/TrainMe`: capture tangents → triage on a GitHub Projects board (his phone inbox) → approve → build → his merge → his validation → done. Designed in a grill session, built in 4 staged commits.

## Read these first (canonical — do NOT duplicate)

All under `/Users/chm/dev/TrainMe/.claude/skills/` (committed to `main`, symlinked into `~/.claude/skills/` for laptop use — repo is the single source of truth):

- **`manage-issues/DESIGN.md`** — the spec. The whole system in one doc (architecture, state machine + mermaid, board/inbox, validation + phone cursor, merge mode, init, build plan, deferred items). **Read this first.**
- `manage-issues/SKILL.md` — the sweep (the running state machine). Modes: default sweep · `dry-run` · `merge` · `init`.
- `manage-issues/init.md` — the `init` reconciler runbook (labels, board, CLAUDE.md rule, config).
- `manage-issues/STATE_MACHINE.md` — the diagram (note: slightly behind DESIGN.md on AWAITING_VALIDATION; DESIGN.md is authoritative).
- `manage-issues-intake/SKILL.md` — the capture half ("park/log/capture/stack it" → files a bare-TRIAGE issue via a background sub-agent).
- `.github/managed-issues.json` — the per-repo wiring (project IDs, Stage option IDs, queue ceiling). Read by the sweep.

**Commit trail on `main`** (oldest→newest): `b030aae` skills-into-repo · `36edf4f` state-machine reshape · `4462c06` DESIGN.md · `344b4ab`+`8c98a67` stage 1 (init+board) · `b2494c9` manual-board-view doc · `ef3bccb` Go column · `da1ad85` stage 2 (board-driven sweep) · `73954b0` dry-run mode · `a108c9c` stage 3 (intake + CLAUDE.md rule) · `dd59fe6` stage 4 (validation wiring). Main tip = `dd59fe6`.

## Live state

- **Board: "Managed Issues — TrainMe", project #2** → https://github.com/users/carlheinmostert/projects/2 . Columns (Stage field): Triage · Needs you · Go · Building · Hold · Done. **View 1 is set to Board layout grouped by Stage** (done manually — see below).
- **14 open issues adopted**: 9 in "Needs you", 5 in "Triage". A **dry-run proposal comment** sits on all 14 (marker `<!-- managed-issue-bot:dry-run -->`) — comment-only, nothing was acted on.
- 5 issues sit at the merge gate with open PRs (#570/#572/#576/#578/#579 → PRs #580–#584); #571/#574/#575/#577 deferred for dependency ordering; #585/#568/#567 await Carl's `/go`.

## What remains — operationalising (the actual next work)

**Do in this order to de-risk:**

1. **Live build test (one issue).** The build path has only been *previewed* (dry-run), never fired. Carl picks one issue to approve — **#567** (design-approval) or **#585** (fix-approval) — then run the build path on **just that one**: branch from `staging` → code → push → open PR (`Refs #N`, not `Fixes`) → it lands in `awaiting-merge`. Confirms build → PR → validation on real code before any automation.
2. **Schedule the hourly Routine, dry by default.** Use the `schedule` skill to run `/manage-issues dry-run carlheinmostert/TrainMe` hourly. It clones `main` (has everything). **Setup dependency:** the cloud Routine needs a GitHub token in its env (`GH_TOKEN`) to read/write issues — wire that when setting up. Watch a few cycles, then flip to live; add a separate `merge`-mode run later.

## Gotchas / decisions the next session MUST know

- **GitHub Projects *views* are UI-only** — there is NO GraphQL mutation to create/configure a board view (confirmed against the live schema). Board layout + "group by Stage" is a **one-time manual step per repo** (documented in `init.md` step 2c). Everything else (project, fields, options, items, status) is API-automatable.
- **CLAUDE.md divergence:** the `<!-- managed-issues:intake -->` rule is on `main` AND in Carl's working-tree CLAUDE.md (his working copy is divergent + has WIP). When he reconciles, the same marked block is in both — expect a clean merge, but if it conflicts, keep one copy of the block.
- **"stack" now = capture** → routes to `manage-issues-intake`, retiring the old local stack-file. The `feedback_stack_means_queue` memory + its MEMORY.md index line were updated this session.
- **The always-on intake rule is now live** (CLAUDE.md): proactively park scope-expanding tangents to GitHub via the intake sub-agent + a one-line notice; "stack/park/log it" on demand; one issue per item, "stack these as one" to bundle.
- **Direct-to-main for skills/docs/config** via ephemeral worktree (per `feedback_specs_direct_to_main`); confirm pushes with Carl; never commit his CLAUDE.md WIP (edit main's copy in the worktree, his working copy separately).
- **Dry-run mechanism:** delete the prior dry-run comment → re-read thread → repost fresh proposal at the bottom (always last = proof it saw everything). Reply-detection ignores dry-run comments.

## Suggested skills for the next session

- `manage-issues` (and `dry-run`/`merge`/`init` modes) — the system itself.
- `schedule` — to set up the hourly Routine.
- `homefit-write-checkpoint` — if Carl wants this folded into a dated project checkpoint.

## Deliberately deferred (not bugs — see DESIGN.md "Deliberately deferred")

Stale-issue timeout; priority/severity fast-lane; bot-side fix verification beyond tests + the optional sim smoke-check.
