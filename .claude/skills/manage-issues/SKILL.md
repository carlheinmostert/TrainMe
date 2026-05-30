---
name: manage-issues
description: Use when asked to triage, drive, or work through GitHub issues on a repository toward resolution, sweep an issue backlog, or run an unattended issue-management routine over a repo's open issues. Triggers include "/manage-issues", "manage the issue queue", "sweep the issues", "work the backlog".
---

# manage-issues

Autonomously drive every open issue in a GitHub repo one step closer to resolution, then stop. Designed to run **unattended** (e.g. a scheduled hourly Routine), so it never asks interactive questions mid-run — the issue thread + the board are the only conversation.

This skill is a **state machine** whose inbox/control surface is a **GitHub Projects board**. The issue's label *is* its state; the board's **Stage** column mirrors that state and is also where Carl issues commands (by moving a card); the sweep is the clock. Full design: [`DESIGN.md`](DESIGN.md); diagram: [`STATE_MACHINE.md`](STATE_MACHINE.md). Setup/reconcile a repo with [`init.md`](init.md).

**Core principle:** the issue's labels + comment thread + board position are the entire memory. Each run re-reads where every issue is and takes the single next sensible step. Built code ends at `status:awaiting-merge`; a merge moves it to `status:awaiting-validation` (Carl tests) — **only Carl's validation closes an issue.** Carl's approval gates (`awaiting-design-approval`, `awaiting-fix-approval`) and merge gate are his; `needs-info` parks the ball with the logger.

## Inputs

- `$REPO` — `owner/repo`. Defaults to the current repo (`gh repo view --json nameWithOwner -q .nameWithOwner`).
- `$OWNER` — the human whose commands the bot obeys and who holds the developer gates. Read from `.github/managed-issues.json`; defaults to `carlheinmostert`.
- **`.github/managed-issues.json`** — the per-repo config written by `init` (project IDs, Stage option IDs, integration branch, queue ceiling, phone-cursor path, notify email). The sweep reads this first.
- Everything else is read live from the issues + board.

## Modes

The first argument selects the mode (default is the sweep):

- **sweep** (default) — `/manage-issues [owner/repo]` runs the unattended state machine. **Never merges.**
- **dry-run** — `/manage-issues dry-run [owner/repo]` runs the full read + decide pass but makes **no state changes**: instead of acting, it posts/refreshes a "what I'd do" proposal comment on each issue (see [Dry run](#dry-run)). Safe to run as often as you like.
- **merge** — `/manage-issues merge [owner/repo]` runs the sweep *with merge authorised* (key 2 of the two-key merge model — see [Merge mode](#merge-mode)). Merges only PRs Carl has already approved. Add **`cascade`** (`/manage-issues merge cascade [repo]`) to run a **merge train** — keep merging the ready set, re-evaluating after each round, until the queue drains or only Carl-blocked PRs remain.
- **init** — `/manage-issues init [owner/repo]` reconciles a repo to the desired state. Runbook: [`init.md`](init.md). Run once per repo before sweeping.

## Non-negotiable safety rules

These hold on every repo, every run. Violating the letter is violating the spirit.

- **Never merge in the default sweep.** Merging happens *only* in **merge mode**, and even then only PRs that are Carl-approved + CI-green + cleanly mergeable + targeting the integration branch. **Never `main`, never force-merge, never force-push.** Never delete branches. Prod promotion is out of scope (separate gated flow).
- **Never deploy or install to a device** (`feedback_ask_before_mobile_deployment`). Opening a PR is the ceiling; the sweep never builds to the phone.
- **Never touch** CI/CD configs, workflows, secrets, or `.env` files.
- **Code path only on understood repos** — otherwise triage, grill, spec, hand to Carl.
- **The parent never mutates directly** (`feedback_delegate_coding`). The orchestrator decides; a sub-agent executes every GitHub mutation — comments, labels, assignment, branches, PRs, closes, **board moves**. The parent's own `gh`/`git` calls stay read-only.
- **Auto-build is gated by risk** — a bug only auto-builds if it clears the [auto-build checklist](#auto-build-checklist). Everything else goes to a human approval gate.
- **Fail loud, never silently degrade** (`feedback_no_silent_fallbacks`). If the repo isn't init'd, or a step can't be done, say so and stop — don't fake success. Don't dress a guess up as a confidence number.
- **No interactive prompts** (`AskUserQuestion`). Escalate via a comment / `help wanted` + assignment and move on.
- **One consolidated comment per issue per sweep.**
- **Skip parked issues:** `wontfix` / `duplicate` / `invalid` / `status:hold`. Skip PRs.

## Reading config (and the init dependency)

Before anything, the parent reads `.github/managed-issues.json`:

```bash
CFG=$(gh api repos/$REPO/contents/.github/managed-issues.json --jq '.content' 2>/dev/null | base64 -d) || true
```

If it's missing or unparseable, the repo **isn't initialised** → **fail loud**: report "run `/manage-issues init $REPO` first" and stop. Do **not** self-bootstrap labels or guess a board. From a valid config, load: `project.id`, `project.stageFieldId`, `project.options{}`, `owner`, `integrationBranch`, `queueCeiling`, `maxNewPrsPerSweep`, `phoneCursorPath`, `notifyEmail`.

## State model (labels) + board mapping

`init` owns the label *definitions*. The sweep moves issues between states by adding/removing labels, and mirrors each state to the board's **Stage** column.

| State | Label | Ball | Stage column |
|---|---|---|---|
| **TRIAGE** | *none* | bot | Triage |
| **CLASSIFIED** | `bug`/`enhancement`, no `status:` | bot | Triage |
| **NEEDS_INFO** | `status:needs-info` | issue author | Needs you |
| **AWAITING_DESIGN_APPROVAL** | `status:awaiting-design-approval` | Carl | Needs you |
| **AWAITING_FIX_APPROVAL** | `status:awaiting-fix-approval` | Carl | Needs you |
| **BUILDING** | `status:building` | bot | Building |
| **AWAITING_PR** | `status:awaiting-pr` | bot | Building |
| **AWAITING_MERGE** | `status:awaiting-merge` | Carl | Needs you |
| **AWAITING_VALIDATION** | `status:awaiting-validation` | Carl | Needs you |
| **HELP_WANTED** | `help wanted` | Carl | Needs you |
| **HOLD** | `status:hold` | Carl | Hold |
| **RESOLVED** | *closed* | — | Done |

**Ball-in-court assignment** (the inbox spine): when a state's ball is **Carl's**, assign him; when it's the **author's** (needs-info), assign the author. **Religiously un-assign the moment the ball leaves the court** — that's what makes `assignee:@me` and the "Needs you" column self-clear. The board's `Go` column has no resting state — it's a command (below).

## Board sync (every tick)

Each sweep, after reading config, the parent reconciles the board (the sub-agent applies changes):

1. **Adopt:** any open issue not yet a card → `addProjectV2ItemById(projectId, contentId)`.
2. **Consume command columns first** (Carl's inputs — these are read *before* state logic): for every card whose **Stage** is a command value, treat it as that command and act, then move the card to the resulting real-state column:
   - **`Go`** → approve/advance, routed by the card's label: `awaiting-design-approval`/`awaiting-fix-approval` → build; `awaiting-validation` → close (validation pass → Done); `awaiting-merge` → merge **iff merge mode**, else leave approved + report "approved, awaiting a merge pass". A `needs-info` card in `Go` is a no-op (comment to answer it, not Go).
   - **`Hold`** → add `status:hold` → Hold column.
   - **`Done`** → close the issue (`/close` equivalent) → Done.
3. **Mirror:** for every other card, set its Stage to match its label-state per the table above. (A known GitHub quirk: the board-view grouping index can lag a field-value change; the data is correct.)

Commands are honoured the same way whether issued by **moving a card** or by a **reserved comment** ([Control commands](#control-commands)).

## Bot identity & idempotency

The token is Carl's own account (`carlheinmostert`), so bot comments and Carl's comments share an author. Every bot comment opens with `> _Automated triage. A human reviews before anything merges._` and ends with a hidden marker:

- **Action comments** (grills, specs, fix proposals, PR links): `<!-- managed-issue-bot -->`.
- **Dry-run proposals**: `<!-- managed-issue-bot:dry-run -->` (transient scaffolding — see [Dry run](#dry-run)).

**"The logger replied"** = the newest comment that is **not** a bot comment (carries *neither* marker) is newer than the last bot *action* comment. **Dry-run comments are ignored** in this check, so a proposal sitting at the bottom never masks a real reply.

## Control commands (`/go`, `/close`, `/hold`)

Reserved commands let Carl steer without the bot guessing. **Commands are exact-match; prose is interpreted content.** Honoured only in the **newest non-bot comment**, authored by **`$OWNER`**, at the **start of a line** (case-insensitive). These are the comment twins of the board command columns:

| Command | = board move | Effect |
|---|---|---|
| `/go` | → `Go` | Approve/advance — routed by label (trailing notes fold into the build) |
| `/close` | → `Done` | Resolve the issue |
| `/hold` | → `Hold` | Park (hands off) |

Prose with no command at an approval gate = **changes requested** → iterate, don't advance.

## Delegation — the parent orchestrates, sub-agents act

Carl's rule: **every change to an issue or the board is delegated to a sub-agent.** The parent reads state and decides; one isolated sub-agent per issue executes the whole step — comment, labels, assignment, board move, and (for a build) the code/branch/PR.

- **Parent direct calls are read-only:** `gh issue list/view`, `gh pr view`, `gh project item-list`, `git fetch/diff/log`, GraphQL queries. After the sub-agent reports done, the parent re-reads and confirms the mutations landed (`gotcha_gh_pr_merge_silent_success`).
- **Verification stays with the parent.** Missing/partial/bogus changes → re-delegate or escalate (`help wanted` + assign Carl) and fail loud. Never hand-patch.

## The sweep

```bash
gh issue list --repo "$REPO" --state open --limit 100 --json number,title,labels,assignees,author > /tmp/issues.json
```

Compute **queue depth** = open issues in `status:awaiting-merge` (for the throttle). Do [Board sync](#board-sync-every-tick) (including command-column consumption). Then for each issue, decide ONE next step (first match wins). The parent decides; a sub-agent executes.

1. **`status:hold` / `wontfix` / `duplicate` / `invalid`** → skip.
2. **`help wanted`** → Carl left an instruction (newest non-bot comment)? No → skip. Yes → remove `help wanted`, fold it in, re-evaluate from triage.
3. **`status:awaiting-validation`** → did Carl confirm (a `Go`/`/go` consumed in board sync closes it as pass; a `/close` closes it)? Did he report a failure in prose? → re-open as a fresh defect (re-diagnose → new fix/PR). No new input → skip. *(Surface-specific "is it testable yet" — web URL / phone cursor — is wired in stage 4; for now the card just sits in Needs you with the test note.)*
4. **`status:awaiting-merge`** → read the PR's review state: Carl requested changes → re-delegate a fix on the **same branch** → `status:building`. Carl approved + merge consumed (merge mode) → merge → `status:awaiting-validation`. Otherwise skip (his gate).
5. **`status:awaiting-pr`** → branch is pushed; verify a real diff, delegate the **closeout** (open PR → `status:awaiting-merge`). Branch missing/bogus → escalate.
6. **`status:building`** → PR now links it → `status:awaiting-merge`. Branch pushed, no PR → treat as `status:awaiting-pr`. Stale, no branch → escalate (`help wanted`).
7. **`status:awaiting-fix-approval`** → `/go`/`Go` (± notes) + queue room → build. Prose → revise the proposal, stay. No input → skip.
8. **`status:awaiting-design-approval`** → `/go`/`Go` (± notes) + queue room → build. Prose → revise the spec ("rev N"), stay. No input → skip.
9. **`status:needs-info`** → logger replied? No → skip. Yes → remove `status:needs-info`, re-evaluate from triage.
10. **No `status:` label (TRIAGE / CLASSIFIED)**:
    - **Classify** — apply `bug`/`enhancement` (own step). Can't classify → grill, `status:needs-info`, assign **author**.
    - **Bug**: too little detail → grill, `status:needs-info`, assign author. Enough + clears [checklist](#auto-build-checklist) + queue room → build. Clears checklist, queue full → defer (stay). Fails checklist → post the **fix proposal**, `status:awaiting-fix-approval`, assign **Carl**.
    - **Enhancement**: enough detail → post the **design spec**, `status:awaiting-design-approval`, assign **Carl**. Too little → grill, `status:needs-info`, assign author.

## Grilling the logger (light, doc-referenced)

One consolidated comment per sweep asking only the highest-value missing things; reference docs; ask for screenshots/recordings on visual reports. **Assign the issue author** alongside `status:needs-info` (ball-in-court). Checklists — **Bug:** repro · expected vs actual · surface · screenshot. **Feature:** the job-to-be-done · who · success · constraints. Read image attachments via `gh api <asset-url> > /tmp/shot.png` then Read; if unfetchable, say so and ask for a text description.

## Auto-build checklist

A bug auto-builds **only if all five hold** (the concrete stand-in for "high confidence"; `feedback_no_silent_fallbacks`):

1. **Root cause identified, not guessed** — exact line(s).
2. **Contained to one unit** — single file/function, no cross-surface ripple.
3. **Mechanical, not a judgment call** — wrong constant, missing `await`/null-check, off-by-one, typo. Not new logic/refactor/UX choice.
4. **Outside the review-before-merge zones** (`feedback_sensitive_code_review_before_merge`).
5. **Doesn't touch the player** — R-10 makes a player fix a mobile+web change, so not contained.

Any failure → `status:awaiting-fix-approval` (diagnosis + proposed fix, assigned to Carl).

## Build (auto-buildable bug or approved feature/fix)

Only on an **understood repo**. Every mutation below is performed by a sub-agent.

1. **Read conventions** (`CLAUDE.md`/`AGENTS.md`): integration branch (TrainMe = `staging`, else default), branch prefixes (`fix/`/`feat/`), test/lint, review-before-merge zones. (Read-only.)
2. **Delegate coding** to a worktree-isolated sub-agent (repo-relative paths only). First act: set `status:building`, remove other `status:` labels. Branch from the integration branch (`feedback_branch_sub_agent_from_staging`); code, test, commit, push; flip `status:building` → `status:awaiting-pr`; **do not open the PR yet**.
3. **Parent verify (read-only):** real diff, conflict-marker scan (`gotcha_test_scripts_index_cascade` — must be 0), migration sanity. Worktree Dart builds emit false-positive URI/analyzer errors (no `flutter pub get`) — environment noise, not a regression. Empty/bogus → re-delegate or escalate.
4. **Delegate closeout:** open a PR targeting the integration branch with **`Refs #N`** (not `Fixes #N` — merge must not auto-close; validation closes). Add `ios-impact` if it touched Dart/Swift/`pubspec`. Flag any review-before-merge zone in the PR body. Then assign **Carl**, set `status:awaiting-merge`, remove `status:awaiting-pr`, post the **single** consolidated comment with the PR link. Never merge.
5. **Parent verify (read-only):** PR open against the integration branch, labels right, issue `status:awaiting-merge` + assigned to Carl, comment carries the marker.

Build can't complete → remove `status:building`, `help wanted`, assign Carl, comment what blocked it.

**Re-build on PR feedback:** a "changes requested" review re-delegates a fix on the **same branch** (step 2 on) → `status:awaiting-pr` → closeout updates the existing PR.

## Validation

A merged PR does **not** close its issue (it used `Refs #N`). On detecting the merge, the sweep moves the issue to `status:awaiting-validation` (Needs you) and posts a **test note** scoped to the surface. **Only Carl's validation closes it:** `Go`/`/go`/`/close` at this state → close (Done); a prose failure → re-open as a fresh defect (new fix/PR — a merged PR can't be reopened).

**Which surface** (from the PR's labels/files):
- **`ios-impact`** (Dart/Swift/`pubspec`) → **mobile** → the phone-cursor path.
- otherwise → **web** (portal/player) → the Vercel-deploy path.
- both → post both notes; fully validated only when both are confirmed.

**Web validation (automatic):** the sweep confirms the merge commit's Vercel deployment succeeded (`gh api repos/$REPO/deployments?sha=<mergeSha>` → its `statuses_url` shows `success` + the target URL; or the commit's check/status for the Vercel deploy) and writes the **live staging URL** + what to check into the test note. Carl tests in a browser; pass → `/go`/`/close`.

**Mobile validation (build cursor):** the sweep reads the phone cursor at `phoneCursorPath` (default `docs/phone-build.json`): `{ "sha", "build", "branch", "installedAt" }` — the SHA + build number of the last build Carl installed, stamped by `homefit-ship-to-phone`.
- If the merged fix's commit is **an ancestor of the cursor SHA** (`git merge-base --is-ancestor <fixSha> <cursorSha>`; `fixSha` = the PR's merge commit) → it's **on the phone** → the note reads "**test now — build {build}**".
- Otherwise → "**awaiting build** — run `homefit-ship-to-phone` to put this on your phone, then validate." The sweep **never** builds or installs.
- The ship step does the reconcile (see that skill): after install it stamps the new cursor and flips every in-build mobile `awaiting-validation` issue's note to "test now", linking the build's numbered test list — which *is* the validation worklist.

**Optional (either surface):** the sweep may smoke-test on the iOS simulator first and annotate "passed on sim — needs your eyes on device for X", thinning the manual list.

## Merge mode

Default sweeps never merge. **Two keys:** (1) Carl approves a specific PR — `/go`/`Go` on its `awaiting-merge` card, or a GitHub PR approval; (2) the run is invoked as `/manage-issues merge`. Only with **both** does the bot merge, and only PRs that are **approved + CI-green + cleanly mergeable + targeting the integration branch** — never `main`, never force. A merged PR flows to `status:awaiting-validation`. Approved-but-not-merged (no merge mode) stays put, reported as "approved, awaiting a merge pass".

### Cascade (merge train)

`/manage-issues merge cascade` runs merge mode as a **fixpoint loop** — because merging one PR can make the next mergeable, it keeps going until nothing moves:

```
repeat:
  ready = your-approved + CI-green + cleanly-mergeable + integration-branch PRs
  if ready is empty → break
  merge each (in dependency order — honour declared chains in the issue comments)
  for any approved PR that is behind staging but NOT conflicting:
    clean branch-update it (gh pr update-branch — merges staging in, NO force-push;
    succeeds only if conflict-free) → CI re-runs → it becomes mergeable on a later pass
  re-fetch PR states (a merge may unblock — or newly conflict — others)
until a full pass merges nothing (fixpoint)
```

**Clean-only, never force.** A *true* rebase needs a force-push (forbidden), so "rebase if clean" is done as a **branch-update that only applies when conflict-free** (a merge commit on the PR branch — harmless on the integration branch). A PR whose update would conflict is **flagged "blocked on you — needs manual rebase"** and skipped: that's a Carl-input blockage, exactly where the train is meant to stop.

**Stops at** the fixpoint (a whole pass merges nothing) — typically when every remaining PR is blocked on you (un-approved, conflicting, failing CI, or awaiting a decision). A hard max-iteration cap backstops runaway loops. Each merge still flows to `status:awaiting-validation`. The end report lists every un-merged PR with the single reason it's stuck on you.

### Email brief (merge runs)

At the end of any `merge` / `merge cascade` run that **did something** (merged ≥1 PR, or left items waiting on you), email a brief to **`notifyEmail`** from the config. A pure no-op run stays silent. Delegate the send like any mutation; use the available email channel — locally the Gmail/IMAP MCP, in the cloud Routine an account-integration email connector or the Resend SMTP. If **no** email channel is reachable, **fail loud** in the end report ("couldn't send the brief — no email channel"), don't silently skip.

Subject: `manage-issues — {repo}: {N} merged, {M} waiting on you`. Body (plain text, scannable):
- **Merged this run** — each `#PR — title` + link, and the issue it advanced.
- **Clean-updated** — PRs brought current (CI re-running; merge next pass).
- **Now waiting for you to test** — issues moved to validation, with where to test (web URL / "build to phone — build N").
- **Blocked on you** — each remaining PR + the one reason it's stuck (`/go` / conflict / failing CI / decision).
- The board link.

## Dry run

`dry-run` mode runs the entire read + decide pass — config, board-sync *plan*, command detection, per-issue decisions, throttle — but performs **no state changes**: no labels, no board moves, no branches, no PRs, no merges, no closes. Its *only* write is a proposal comment per issue.

Per issue, each dry run:

1. **Delete** the bot's previous dry-run comment, if any (the bot owns it).
2. **Re-read the whole thread** — so it incorporates any feedback Carl added since the last dry run.
3. **Post a fresh proposal as the newest comment**, marked `<!-- managed-issue-bot:dry-run -->`, stating the decided next step and how to approve it ("reply `/go`, or drag the card to **Go**"; `/hold` to park, `/close` to close).

So there is never more than one dry-run comment per issue; it always sits at the **bottom** (its position is the proof it accounted for everything above it); and it is never stale. Dry-run comments are disposable scaffolding — the permanent record is the real action comments + human replies.

A **live** sweep deletes any lingering dry-run comment on an issue when it acts on that issue (the proposal has been consumed). Dry-run is safe to run as often as Carl likes; the hourly Routine may even be run **dry by default**, flipping a run to live only when Carl is comfortable.

## Throttle

Triage/grill/spec/fix-proposals are uncapped; only autonomous code is throttled, from config:

- **Queue ceiling (`queueCeiling`, default 15):** don't start new builds while ≥ ceiling issues are in `status:awaiting-merge`. Bounds Carl's review queue.
- **Per-sweep circuit breaker (`maxNewPrsPerSweep`, default 5):** hard cap on builds started in one run.

## End-of-run report

Plain-English (`feedback_explanation_level`): a table (issue · action · new state/column); PRs opened (awaiting merge); issues now in Needs you wanting your `Go`/test; anything escalated (`help wanted`); queue depth vs ceiling; anything that failed and why.

## Common mistakes

- **Posting a comment without the marker** → next sweep mistakes it for a logger reply. Always append `<!-- managed-issue-bot -->`.
- **Running on an un-init'd repo** → fail loud ("run init first"); never self-bootstrap or guess the board.
- **Auto-building a bug that isn't a slam dunk** → must clear all five checklist points, else `awaiting-fix-approval`.
- **Merging in a default sweep** → only in `merge` mode, only Carl-approved + green + mergeable + integration branch.
- **Auto-resolving a conflict in `cascade`** → never. Only **conflict-free** branch-updates are allowed (no force-push, no true rebase); a conflicting PR is flagged "blocked on you" and skipped — that's where the train stops.
- **Using `Fixes #N`** → use `Refs #N`; validation closes, not merge.
- **Forgetting to un-assign on exit** → the inbox/Needs you column won't self-clear. Remove Carl/author the moment the ball leaves their court.
- **Reading `/go` + notes as "changes requested"** → `/go`/`Go` always advances; fold notes in.
- **Honouring a command from a non-owner** → only `$OWNER`'s commands count.
- **Parent applying a mutation itself** → delegate; parent `gh`/`git` is read-only.
- **Briefing a sub-agent with absolute paths / branching from `main`** → repo-relative paths; branch from the integration branch.

## Encodes

- `feedback_delegate_coding` · `feedback_agent_worktree_isolation` · `feedback_branch_sub_agent_from_staging` · `feedback_branch_naming_discipline`
- `feedback_ask_before_mobile_deployment` · `feedback_no_silent_fallbacks` · `feedback_explanation_level`
- `feedback_sensitive_code_review_before_merge` · `gotcha_test_scripts_index_cascade`
- `gotcha_gh_pr_merge_silent_success` (verify PR/issue/board state after each mutating call)
