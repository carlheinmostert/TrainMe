---
name: manage-issues
description: Use when asked to triage, drive, or work through GitHub issues on a repository toward resolution, sweep an issue backlog, or run an unattended issue-management routine over a repo's open issues. Triggers include "/manage-issues", "manage the issue queue", "sweep the issues", "work the backlog".
---

# manage-issues

Autonomously drive every open issue in a GitHub repo one step closer to resolution, then stop. Designed to run **unattended** (e.g. a scheduled hourly Routine), so it never asks interactive questions mid-run — the issue thread itself is the only conversation.

This skill is a **state machine**. The issue's label *is* its state; the sweep is the clock; each sweep reads the state, evaluates the guards against the thread, and takes one transition. The full machine is drawn in [`STATE_MACHINE.md`](STATE_MACHINE.md) (mermaid diagram + state/transition tables) — keep it in sync with this file.

**Core principle:** the issue's labels + comment thread are the entire memory. Each run re-reads where every issue is and takes the single next sensible step. Built code always ends at `status:awaiting-merge` (Carl's merge gate). The two approval gates — `status:awaiting-design-approval` (features) and `status:awaiting-fix-approval` (risky bugs) — are Carl's go/no-go. `status:needs-info` parks the ball in the logger's court. Carl's merge is the only thing that ships code.

## Inputs

- `$REPO` — `owner/repo` passed as the argument. Defaults to the current repo (`gh repo view --json nameWithOwner -q .nameWithOwner`).
- `$OWNER` — the human whose commands the bot obeys and who holds the developer gates. Defaults to `carlheinmostert`.
- Everything else is read live from the issues.

## Modes

The first argument selects the mode (default is the sweep):

- **sweep** (default) — `/manage-issues [owner/repo]` runs the unattended state machine below over the repo's open issues.
- **init** — `/manage-issues init [owner/repo]` reconciles a repo to the desired state: labels · Projects board ("Stage" field columns) · the CLAUDE.md intake memory rule · `.github/managed-issues.json` config. Idempotent and safe to re-run after a skill update. Full runbook: [`init.md`](init.md). Run once per repo before sweeping.

## Non-negotiable safety rules

These hold on every repo, every run. Violating the letter is violating the spirit.

- **Never merge** a PR. Never push to `main` or `staging` (or any default/integration branch) directly. Never force-push. Never delete branches.
- **Never deploy or install to a device** (respects `feedback_ask_before_mobile_deployment`). Opening a PR is the ceiling.
- **Never touch** CI/CD configs, workflows, secrets, or `.env` files.
- **Code path only on understood repos** — see the guard below. Otherwise: triage, grill, spec, then hand the fix to Carl.
- **The parent never mutates directly** (`feedback_delegate_coding`). The orchestrator decides each issue's next step but delegates the *execution* of every GitHub mutation — comments, labels, assignment, branches, PRs, closes — to a sub-agent. The parent's own `gh`/`git` calls stay read-only (list, view, verify). See *Delegation* below.
- **Auto-build is gated by risk, not just count** — a bug only auto-builds if it clears the [auto-build checklist](#auto-build-checklist). Everything else goes to a human approval gate. Never auto-build a broad, judgment-heavy, or sensitive-zone change.
- **No interactive prompts.** No `AskUserQuestion`. If you'd need to ask Carl something, post it as an issue comment or escalate via `help wanted` + assignment, and move on.
- **Fail loud, never silently degrade** (`feedback_no_silent_fallbacks`). If a step can't be done, say so in the comment and the end report — don't fake success. Don't dress a guess up as a confidence number.
- **One consolidated comment per issue per sweep.** Never spam an issue with multiple comments in a single run.
- **Skip issues a human has parked:** any issue labelled `wontfix`, `duplicate`, `invalid`, or `status:hold`. Skip pull requests entirely (`gh issue list` already excludes them).

## State model (labels)

Type uses the native labels `bug` / `enhancement`. Status uses `status:*` labels the skill creates if missing.

**Assignment follows whose court the ball is in** (native GitHub, independent of labels):

- Replying to / grilling the **submitter** (a `status:needs-info` grill) → assign the issue to the **issue author** (`--add-assignee <author>`). The ball is in their court.
- Escalating to / waiting on the **developer** (`status:awaiting-design-approval`, `status:awaiting-fix-approval`, `status:awaiting-merge`, `help wanted`) → assign **Carl** (`--add-assignee carlheinmostert`).

In repos where Carl logs his own issues these resolve to the same person; the rule matters where loggers are other people.

| State | Encoded as | Ball in court | Meaning |
|---|---|---|---|
| **TRIAGE** | *no labels* | bot | New issue, not yet classified |
| **CLASSIFIED** | `bug`/`enhancement`, no `status:` | bot | Classified; assessing detail or waiting for build budget |
| `status:needs-info` | label | issue author | Bot asked the logger something; waiting on their reply |
| `status:awaiting-design-approval` | label | Carl | Feature spec drafted; Carl's gate |
| `status:awaiting-fix-approval` | label | Carl | Bug diagnosed but not auto-buildable; proposed fix awaits Carl's go |
| `status:building` | label | bot (sub-agent) | Coding sub-agent producing the branch (no PR yet) |
| `status:awaiting-pr` | label | bot (sub-agent) | Branch pushed + verified; PR-open pending (resume point) |
| `status:awaiting-merge` | label | Carl | PR open + assigned; Carl's merge gate |
| `help wanted` (native) | label | Carl | Bot stuck; **skip until Carl leaves an instruction** |
| `status:hold` | label | Carl | "Bot, hands off" — manual override |
| *(closed)* | — | — | RESOLVED: merged PR (`Fixes #N`) or Carl-instructed `/close` |

Ensure labels exist once per run, before the sweep:

```bash
for L in "status:needs-info|fbca04|Bot is waiting on the issue author for more detail" \
         "status:awaiting-design-approval|5319e7|Feature spec drafted; awaiting Carl's approval" \
         "status:awaiting-fix-approval|8a2be2|Bug diagnosed; proposed fix awaiting Carl's go-ahead" \
         "status:building|0e8a16|Coding sub-agent producing the branch (in-run guard)" \
         "status:awaiting-pr|0052cc|Branch pushed + verified; PR-open pending (resume point)" \
         "status:awaiting-merge|1d76db|PR open and assigned; awaiting Carl's merge" \
         "status:hold|e4e669|Bot: hands off this issue"; do
  IFS='|' read -r name color desc <<< "$L"
  gh label create "$name" --color "$color" --description "$desc" --repo "$REPO" 2>/dev/null \
    || gh label edit "$name" --color "$color" --description "$desc" --repo "$REPO" 2>/dev/null || true
done
```

## Bot identity & idempotency

The token is Carl's own account (`carlheinmostert`), so bot comments and Carl's comments share an author. **The hidden marker is how runs stay idempotent and detect replies.** Every comment the bot posts MUST:

1. End with the hidden marker `<!-- managed-issue-bot -->`.
2. Open with a one-line signature so humans know it's automated:
   `> _Automated triage. A human reviews before anything merges._`

**"The logger replied"** = the most recent comment on the issue does **not** contain the marker AND is newer than the last comment that does. If the newest comment carries the marker, the bot is still waiting — skip.

## Control commands (`/go`, `/close`, `/hold`)

Carl steers the machine with reserved commands so the bot never has to *guess* his intent. **Commands are exact-match directives; plain prose is interpreted content.** A reserved command only ever moves an issue forward or parks it — to send something *back* (request changes), Carl just writes prose.

Recognition rules — a command is honoured only when **all** hold:
- It appears in the **newest non-bot-marked** comment (the current reply).
- The comment author is **`$OWNER`** (Carl). A command from any other logger is ignored — a random submitter can't `/go` a build into existence.
- The command is the **start of a line**, slash-prefixed, case-insensitive after trimming (e.g. `/go`, `/Go`, `  /go `). This avoids matching prose like "let's go ahead and…".

| Command | Effect | Notes |
|---|---|---|
| `/go` | Take the **forward / approve** edge from the current waiting state | `awaiting-design-approval` → build · `awaiting-fix-approval` → build · `help wanted` → proceed with the proposed approach. Honours the [queue ceiling](#throttle). |
| `/close` | Resolve the issue (bot runs `gh issue close`) → RESOLVED | The decision-4 path for work that never became a PR. Optional trailing reason. |
| `/hold` | Add `status:hold` → HOLD | Hands off; useful when Carl would rather take a fix himself. |

`/go` may carry trailing instructions (`/go but rename that variable first`) — the bot **advances and folds the note into the build** (consistent with "approved, but change X"). Prose with no command at an approval gate = **changes requested** → iterate, don't advance.

## Delegation — the parent orchestrates, sub-agents act

Carl's rule: **any change applied to an issue is delegated to a sub-agent.** The parent (the sweep itself) reads state and decides the single next step per issue — then hands the *execution* of that step to one isolated sub-agent. The parent does not post comments, flip labels, assign, branch, open PRs, or close issues with its own hands.

- **One sub-agent per issue per sweep.** It carries out the whole step end-to-end: the consolidated comment (with marker + signature), the label adds/removes, the assignment (per the ball-in-court rule), and — for a build — the code, branch, and PR. Brief it with the exact comment body, the exact label changes, and who to assign.
- **The parent's only direct calls are read-only:** `gh issue list`, `gh issue view`, `gh pr view`, `git fetch`/`git diff`/`git log` to verify. After the sub-agent reports done, the parent re-reads the issue/PR and confirms the intended mutations actually landed (`gotcha_gh_pr_merge_silent_success`).
- **The verification gate stays with the parent.** Because the parent no longer applies the mutations, verifying them is its main safety contribution — do it rigorously. If a sub-agent's changes are missing, partial, or bogus (e.g. a PR with no real diff), the parent does NOT hand-patch — it re-delegates with a corrected brief, or escalates (`help wanted` + assign Carl) and fails loud in the report.
- The label-definition bootstrap loop (creating the `status:*` label *definitions*) is repo setup, not an issue mutation — the parent may run it directly.

## The sweep

```bash
gh issue list --repo "$REPO" --state open --limit 100 \
  --json number,title,labels,assignees,author > /tmp/issues.json
```

Compute the **queue depth** once per sweep: the number of open issues already in `status:awaiting-merge`. This feeds the [throttle](#throttle).

For each issue, fetch the full thread (read-only) and decide ONE next step. The parent decides; a delegated sub-agent executes it (see *Delegation*):

```bash
gh issue view "$N" --repo "$REPO" \
  --json number,title,body,labels,assignees,author,comments,url
```

Decide top-to-bottom; **first match wins**:

0. **Global commands** (from `$OWNER`, newest non-bot comment — see *Control commands*):
   - `/close` → delegate: close the issue → RESOLVED.
   - `/hold` → delegate: add `status:hold` → HOLD.
   (`/go` is state-specific and handled in the waiting states below.)
1. **`status:hold` / `wontfix` / `duplicate` / `invalid`** → skip.
2. **`help wanted`** → did Carl leave a new instruction (newest non-bot comment)?
   - No → **skip** (waiting on Carl).
   - Yes (`/go` or prose direction) → remove `help wanted`, fold his instruction in, and re-evaluate from the top of *triage* (or build directly on `/go`).
3. **`status:awaiting-merge`** → read the PR's review state:
   - Carl requested changes (changes-requested review, or a new Carl review comment since the bot's last push) → delegate a fix on the **same branch** → `status:building`.
   - Otherwise → skip (Carl's merge gate). A merged PR auto-closes the issue via `Fixes #N`, so it leaves the open set.
4. **`status:awaiting-pr`** → the branch should already be pushed. Verify it exists with a real diff, then delegate the **closeout** (open PR → `status:awaiting-merge`). If the branch is missing/bogus → escalate (`help wanted` + assign Carl).
5. **`status:building`** →
   - A PR now links this issue → flip to `status:awaiting-merge`, assign Carl.
   - A branch was pushed but no PR (agent died after push) → treat as `status:awaiting-pr` (verify + closeout).
   - No branch and the marker shows the build was attempted a prior run (stale) → the build died → escalate (`help wanted` + assign Carl), remove `status:building`.
6. **`status:awaiting-fix-approval`** → read Carl's newest non-bot comment:
   - `/go` (± notes) → if [queue has room](#throttle), delegate the build → `status:building`; else defer (stay, note it).
   - Prose requesting a different approach → revise the diagnosis/proposed fix, re-post, stay.
   - No new Carl comment → skip.
7. **`status:awaiting-design-approval`** → read Carl's newest non-bot comment:
   - `/go` (± notes) → if queue has room, fold notes in and delegate the build → `status:building`; else defer.
   - Prose requesting changes → revise the spec, post "Design spec (rev N)", stay.
   - No new Carl comment → skip.
8. **`status:needs-info`** → did the logger reply (marker rule)?
   - No → skip (still waiting).
   - Yes → remove `status:needs-info` and re-evaluate from the top of *triage* with the new detail.
9. **No `status:` label (TRIAGE / CLASSIFIED)** → read the whole thread, then:
   - **Classify** (its own step): apply `bug` or `enhancement` if not already present. If it can't be classified at all → grill, add `status:needs-info`, assign the **issue author**.
   - **Bug:**
     - Not enough detail to diagnose/repro → grill, add `status:needs-info`, assign the **issue author**.
     - Enough detail + clears the [auto-build checklist](#auto-build-checklist) + queue has room → run the **build**.
     - Enough detail + clears the checklist but queue is full → defer (leave at CLASSIFIED; next sweep retries).
     - Enough detail but **fails** the checklist (broad / judgment-heavy / sensitive zone / touches the player) → post the **fix proposal** (root-cause diagnosis + proposed fix + why it didn't auto-qualify), add `status:awaiting-fix-approval`, assign **Carl**.
   - **Enhancement:**
     - Enough detail to spec → post the **design spec**, add `status:awaiting-design-approval`, assign **Carl**.
     - Not enough detail → grill, add `status:needs-info`, assign the **issue author**.

"Enough detail" is your judgment against the checklists below.

## Grilling the logger (light, doc-referenced)

The feedback channel is an abbreviated GitHub comment thread, so grill *lightly*: one consolidated comment per sweep asking only the highest-value missing things. Be friendly and concise; reference docs where it sharpens the question (link the relevant README/CLAUDE.md/spec section). Ask for **screenshots or a screen recording** when the report is visual or UI-related. Never post a wall of questions.

**Assign the submitter.** A needs-info grill puts the ball in the issue author's court, so the executing sub-agent assigns the issue to the author (`--add-assignee <author>`) at the same time it adds `status:needs-info`.

Checklists for "enough detail":
- **Bug:** repro steps · expected vs. actual · environment/surface (which app/page/build) · a screenshot or recording if visual.
- **Feature:** the problem/job-to-be-done · who it's for · what success looks like · any hard constraints.

**Reading attachments:** issue image attachments appear as markdown URLs in the body/comments. For private repos, fetch with `gh api <asset-url> > /tmp/shot.png` then Read it; if it can't be fetched, say so and ask the logger to describe it in text.

## Auto-build checklist

A bug auto-builds **only if all five hold** — this is the concrete stand-in for "high confidence", because the bot cannot produce a calibrated probability (`feedback_no_silent_fallbacks`):

1. **Root cause identified, not guessed** — the bot can point to the exact line(s), not "probably somewhere in the publish path".
2. **Contained to one unit** — a single file/function, no cross-module or cross-surface ripple.
3. **The fix is mechanical, not a judgment call** — wrong constant, missing `await`/null-check, off-by-one, typo, wrong field. *Not* new logic, a refactor, or anything with a UX/behaviour choice baked in.
4. **Outside the review-before-merge zones** (`feedback_sensitive_code_review_before_merge`) — publish flow, conversion listener, SyncService pull, any `CREATE OR REPLACE FUNCTION` on a client RPC.
5. **Doesn't touch the player** — R-10 makes a player fix a mobile *and* web change, so by definition it isn't contained.

If any one fails → it does **not** auto-build → route to `status:awaiting-fix-approval` with a written diagnosis + proposed fix, assigned to Carl. He approves with `/go` (then it builds) or takes it himself (`/hold`).

## Build (auto-buildable bug or approved feature/fix)

Only on an **understood repo** — one with a `CLAUDE.md`/`AGENTS.md`, or a clear `README` + recognizable stack. If the repo isn't understood: post your diagnosis/approach as a comment, add `help wanted`, assign Carl, and stop (no code).

Otherwise (every mutation below is performed by a sub-agent, not the parent — see *Delegation*):

1. **Read repo conventions** (`CLAUDE.md`/`AGENTS.md`): integration branch (TrainMe = `staging`, else the default branch), branch-name prefixes (`fix/` / `feat/`), test/lint commands, and any "review before merge" zones. (Read-only — the parent does this to brief the agent. Respect the [throttle](#throttle).)
2. **Delegate the coding to a worktree-isolated sub-agent** (`feedback_delegate_coding`, `feedback_agent_worktree_isolation`). Brief it with **repo-relative paths only**. The agent's first act is to set `status:building` and remove other `status:` labels (the in-run double-build guard); then it branches from the integration branch (`feedback_branch_sub_agent_from_staging`):
   ```
   git fetch origin <integration-branch>
   git checkout -b fix/issue-<N>-<slug> origin/<integration-branch>
   ```
   The brief must: state the issue + acceptance criteria, require the repo's tests/lint to pass, forbid touching unrelated files, and produce the fix only — commit + push the branch, then flip `status:building` → `status:awaiting-pr`, but **do not open the PR yet** (no merge, no deploy).
3. **Parent verify (read-only).** When the sub-agent reports done, the parent confirms the branch exists with a real diff, scans the changed files for conflict markers (`gotcha_test_scripts_index_cascade` — must be 0), and sanity-checks any migration structure. Note: a worktree-isolated Dart build emits false-positive URI/analyzer errors because the worktree has no `flutter pub get` — that is environment noise, not a regression. If the diff is empty or bogus, do NOT hand-patch — re-delegate or escalate (`help wanted` + assign Carl) and fail loud.
4. **Delegate the closeout.** Resume the build sub-agent (it still holds the branch + change context for a good PR body) or spawn a closeout sub-agent to open a PR **targeting the integration branch**:
   ```bash
   gh pr create --repo "$REPO" --base <integration-branch> --head fix/issue-<N>-<slug> \
     --title "<type>(scope): <summary> (#<N>)" \
     --body "Fixes #<N>"$'\n\n'"<what changed + how it was verified>"$'\n\n'"<!-- managed-issue-bot -->"
   ```
   Use `Fixes #N` for bugs, `Implements #N` for features. Add `ios-impact` to the PR if it touched Dart/Swift/`pubspec` (TrainMe convention). **If the change touched a review-before-merge zone** (`feedback_sensitive_code_review_before_merge`), call it out explicitly in the PR body so Carl knows what to scrutinise. The same agent then closes out: assign the issue to **Carl** (developer gate), set `status:awaiting-merge`, remove `status:awaiting-pr`/`status:building`, and post the **single** consolidated comment linking the PR — build confirmation + PR link in ONE comment, never a separate "starting" and "done" comment. Never merge.
5. **Parent verify (read-only).** Confirm the PR is open against the integration branch, labels are right, the issue is `status:awaiting-merge` + assigned to Carl, and the closing comment carries the marker (`gotcha_gh_pr_merge_silent_success`).

If the build genuinely can't be completed (tests won't pass, ambiguity discovered): remove `status:building`, add `help wanted`, assign Carl, and comment what blocked it. Fail loud.

**Re-build on PR feedback:** when an `status:awaiting-merge` issue gets a "changes requested" review from Carl, the build is re-delegated on the **same branch** (step 2 onward, reusing the existing branch) — set `status:building`, address the feedback, push, back to `status:awaiting-pr` → closeout updates the existing PR → `status:awaiting-merge`.

## Throttle

Triage, grill, spec, and fix-proposals are **uncapped** — only autonomous *code* is throttled, gated two ways:

- **Queue ceiling (primary): `QUEUE_CEILING = 15`.** Before delegating any build, check the sweep's queue depth (open issues in `status:awaiting-merge`). If it's already ≥ 15, do **not** start new builds this sweep — leave build-ready issues at CLASSIFIED / the approval gate so the next sweep retries. This bounds *Carl's review queue* directly, regardless of how often the Routine ticks (hourly).
- **Per-sweep circuit breaker: `MAX_NEW_PRS_PER_SWEEP = 5`.** A hard cap on builds started in a single run, purely to bound the blast radius of one runaway sweep. Once hit, defer the rest.

The [auto-build checklist](#auto-build-checklist) is the real volume control — most bugs route to an approval gate, so few builds fire unprompted.

## End-of-run report

Print a plain-English summary (Carl reads this; `feedback_explanation_level`):

- A table: issue # · title · action taken · new state.
- PRs opened (with links) — awaiting your merge.
- Issues now `status:awaiting-design-approval` or `status:awaiting-fix-approval` — these want your `/go`.
- Anything escalated via `help wanted` — these want an instruction from you.
- The queue depth vs the ceiling (e.g. "9/15 awaiting merge") and whether the throttle deferred any builds.
- Anything that failed and why.

## Common mistakes

- **Posting a comment without the hidden marker** → next sweep mistakes the bot's own comment for a logger reply (or re-asks). Always append `<!-- managed-issue-bot -->`.
- **Writing code on a repo you don't understand** → violates the guard. Diagnose + hand to Carl instead.
- **Auto-building a bug that isn't a slam dunk** → it must clear all five checklist points; broad, judgment-heavy, sensitive-zone, or player changes route to `status:awaiting-fix-approval`, not a PR.
- **Reading `/go` + extra notes as "changes requested"** → `/go` always advances; fold the notes into the build. Only prose *without* a command means iterate.
- **Honouring a command from a non-owner** → only `$OWNER`'s commands count. A logger's `/go` is ignored.
- **Re-triaging a `help wanted` issue** → it's a skip-until-Carl state now; only a new instruction from Carl moves it.
- **Starting builds past the queue ceiling** → always check the `status:awaiting-merge` count (< 15) before delegating a build.
- **Briefing the sub-agent with absolute paths** → it leaks into Carl's main worktree. Repo-relative paths only.
- **Branching from `main`** on TrainMe → produces a conflict cascade. Branch from the integration branch the conventions name.
- **Multiple comments in one sweep** → noise. Consolidate into one.
- **The parent applying a mutation itself** → violates delegation. The orchestrator decides; a sub-agent posts/labels/assigns/branches/PRs/closes. The parent's own `gh`/`git` calls stay read-only.
- **Assigning Carl when the ball is the submitter's** → a `needs-info` grill assigns the issue author, not Carl. Reserve Carl for the approval gates, awaiting-merge, and `help wanted`.

## Encodes

- `feedback_delegate_coding` · `feedback_agent_worktree_isolation` · `feedback_branch_sub_agent_from_staging` · `feedback_branch_naming_discipline`
- `feedback_ask_before_mobile_deployment` · `feedback_no_silent_fallbacks` · `feedback_explanation_level`
- `feedback_sensitive_code_review_before_merge` · `gotcha_test_scripts_index_cascade` (parent verify gate: scan for conflict markers + flag review-before-merge zones in the PR body)
- `gotcha_gh_pr_merge_silent_success` (verify PR/issue state after each mutating gh call)
