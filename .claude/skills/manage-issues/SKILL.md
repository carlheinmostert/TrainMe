---
name: manage-issues
description: Use when asked to triage, drive, or work through GitHub issues on a repository toward resolution, sweep an issue backlog, or run an unattended issue-management routine over a repo's open issues. Triggers include "/manage-issues", "manage the issue queue", "sweep the issues", "work the backlog".
---

# manage-issues

Autonomously drive every open issue in a GitHub repo one step closer to resolution, then stop. Designed to run **unattended** (e.g. as a scheduled desktop routine), so it never asks interactive questions mid-run — the issue thread itself is the only conversation.

**Core principle:** the issue's labels + comment thread are the entire memory. Each run re-reads where every issue is and takes the single next sensible step. The end state for every issue is `status:awaiting-merge` (a PR waiting for Carl to merge). Carl's merge is the only human gate that ships code; Carl's design approval is the gate for features.

## Inputs

- `$REPO` — `owner/repo` passed as the argument. Defaults to the current repo (`gh repo view --json nameWithOwner -q .nameWithOwner`).
- Everything else is read live from the issues.

## Non-negotiable safety rules

These hold on every repo, every run. Violating the letter is violating the spirit.

- **Never merge** a PR. Never push to `main` or `staging` (or any default/integration branch) directly. Never force-push. Never delete branches.
- **Never deploy or install to a device** (respects `feedback_ask_before_mobile_deployment`). Opening a PR is the ceiling.
- **Never touch** CI/CD configs, workflows, secrets, or `.env` files.
- **Code path only on understood repos** — see the guard below. Otherwise: triage, grill, spec, then hand the fix to Carl.
- **The parent never mutates directly** (`feedback_delegate_coding`). The orchestrator decides each issue's next step but delegates the *execution* of every GitHub mutation — comments, labels, assignment, branches, PRs — to a sub-agent. The parent's own `gh`/`git` calls stay read-only (list, view, verify). See *Delegation* below.
- **No interactive prompts.** No `AskUserQuestion`. If you'd need to ask Carl something, post it as an issue comment or escalate via `help wanted` + assignment, and move on.
- **Fail loud, never silently degrade** (`feedback_no_silent_fallbacks`). If a step can't be done, say so in the comment and the end report — don't fake success.
- **One consolidated comment per issue per sweep.** Never spam an issue with multiple comments in a single run.
- **Skip issues a human has parked:** any issue labelled `wontfix`, `duplicate`, `invalid`, or `status:hold`. Skip pull requests entirely (`gh issue list` already excludes them).

## State model (labels)

Type uses the native labels `bug` / `enhancement`. Status uses `status:*` labels the skill creates if missing.

**Assignment follows whose court the ball is in** (native GitHub, independent of labels):

- Replying to / grilling the **submitter** (a `status:needs-info` grill) → assign the issue to the **issue author** (`--add-assignee <author>`). The ball is in their court; the assignment surfaces it for them.
- Escalating to / waiting on the **developer** (`status:awaiting-design-approval`, `status:awaiting-merge`, `help wanted`) → assign **Carl** (`--add-assignee carlheinmostert`).

In repos where Carl logs his own issues these resolve to the same person; the rule matters where loggers are other people.

| State | Meaning | Set by |
|-------|---------|--------|
| *(no `status:` label)* | Needs triage / classification | — |
| `status:needs-info` | Bot asked the logger something; waiting on their reply | bot |
| `status:awaiting-design-approval` | Feature spec drafted in a comment; Carl's gate | bot |
| `status:building` | A code sub-agent is implementing this (in-run guard) | bot |
| `status:awaiting-merge` | PR open + assigned to Carl; Carl's merge gate | bot |
| `status:hold` | "Bot, hands off" — manual override | Carl |
| `help wanted` (native) | Bot can't auto-fix (repo not understood, or stuck build); assigned to Carl | bot |

Ensure labels exist once per run, before the sweep:

```bash
for L in "status:needs-info|fbca04|Bot is waiting on the issue author for more detail" \
         "status:awaiting-design-approval|5319e7|Feature spec drafted; awaiting Carl's approval" \
         "status:building|0e8a16|Bot is implementing a fix/feature (in-run guard)" \
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

## Delegation — the parent orchestrates, sub-agents act

Carl's rule: **any change applied to an issue is delegated to a sub-agent.** The parent (the sweep itself) reads state and decides the single next step per issue — then hands the *execution* of that step to one isolated sub-agent. The parent does not post comments, flip labels, assign, branch, or open PRs with its own hands.

- **One sub-agent per issue per sweep.** It carries out the whole step end-to-end: the consolidated comment (with marker + signature), the label adds/removes, the assignment (per the ball-in-court rule), and — for a build — the code, branch, and PR. Brief it with the exact comment body, the exact label changes, and who to assign.
- **The parent's only direct calls are read-only:** `gh issue list`, `gh issue view`, `gh pr view`, `git fetch`/`git diff`/`git log` to verify. After the sub-agent reports done, the parent re-reads the issue/PR and confirms the intended mutations actually landed (`gotcha_gh_pr_merge_silent_success`).
- **The verification gate stays with the parent.** Because the parent no longer applies the mutations, verifying them is its main safety contribution — do it rigorously. If a sub-agent's changes are missing, partial, or bogus (e.g. a PR with no real diff), the parent does NOT hand-patch — it re-delegates with a corrected brief, or escalates (`help wanted` + assign Carl) and fails loud in the report.
- The label-definition bootstrap loop (creating the `status:*` label *definitions*) is repo setup, not an issue mutation — the parent may run it directly.

## The sweep

```bash
gh issue list --repo "$REPO" --state open --limit 100 \
  --json number,title,labels,assignees,author > /tmp/issues.json
```

For each issue, fetch the full thread (read-only) and decide ONE next step. The parent decides; a delegated sub-agent executes it (see *Delegation*):

```bash
gh issue view "$N" --repo "$REPO" \
  --json number,title,body,labels,assignees,author,comments,url
```

Decide by current state (read top-to-bottom; first match wins):

1. **`status:hold` / `wontfix` / `duplicate` / `invalid`** → skip.
2. **`status:awaiting-merge`** → skip (Carl's gate). If its linked PR was merged the issue auto-closes via `Fixes #N`, so it won't appear in the open set.
3. **`status:building`** →
   - A PR now links this issue → flip to `status:awaiting-merge`, assign Carl, remove `status:building`. (See *Closing out a build* below.)
   - No PR and the marker shows the build was attempted a prior run (stale) → the build failed/died. Post a "couldn't complete the fix automatically" comment, add `help wanted`, assign Carl, remove `status:building`.
4. **`status:needs-info`** → did the logger reply (marker rule)?
   - No → skip (still waiting).
   - Yes → remove `status:needs-info` and re-evaluate this issue from the top of the *triage* logic with the new detail.
5. **`status:awaiting-design-approval`** → read Carl's newest non-bot comment(s) as an **ongoing chat**:
   - Clear go-ahead (even bundled with extra instructions) → fold the instructions into the plan and run the **build** (below). Reply confirming what you're building.
   - Asked for design changes → revise the spec, post it as a new "Design spec (rev N)" comment, stay in `status:awaiting-design-approval`, reply acknowledging the change.
   - No new Carl comment → skip (waiting on Carl).
6. **No `status:` label (triage)** → read the whole thread, then:
   - Classify and apply `bug` or `enhancement` (if not already labelled).
   - **Bug, enough detail to diagnose/repro** → run the **build**.
   - **Bug, not enough detail** → post a grill comment, add `status:needs-info`, assign the **issue author** (ball-in-court).
   - **Enhancement, enough detail to spec** → post the **design spec** comment, add `status:awaiting-design-approval`, assign **Carl**.
   - **Enhancement, not enough detail** → grill comment, add `status:needs-info`, assign the **issue author**.
   - **Can't even classify** → grill comment asking the logger to clarify, add `status:needs-info`, assign the **issue author**.

"Enough detail" is your judgment against the checklists below.

## Grilling the logger (light, doc-referenced)

The feedback channel is an abbreviated GitHub comment thread, so grill *lightly*: one consolidated comment per sweep asking only the highest-value missing things. Be friendly and concise; reference docs where it sharpens the question (link the relevant README/CLAUDE.md/spec section). Ask for **screenshots or a screen recording** when the report is visual or UI-related. Never post a wall of questions.

**Assign the submitter.** A needs-info grill puts the ball in the issue author's court, so the executing sub-agent assigns the issue to the author (`--add-assignee <author>`) at the same time it adds `status:needs-info`.

Checklists for "enough detail":
- **Bug:** repro steps · expected vs. actual · environment/surface (which app/page/build) · a screenshot or recording if visual.
- **Feature:** the problem/job-to-be-done · who it's for · what success looks like · any hard constraints.

**Reading attachments:** issue image attachments appear as markdown URLs in the body/comments. For private repos, fetch with `gh api <asset-url> > /tmp/shot.png` then Read it; if it can't be fetched, say so and ask the logger to describe it in text.

## Build (bug fix or approved feature)

Only on an **understood repo** — one with a `CLAUDE.md`/`AGENTS.md`, or a clear `README` + recognizable stack. If the repo isn't understood: post your diagnosis/approach as a comment, add `help wanted`, assign Carl, and stop (no code).

Otherwise (every mutation below is performed by the sub-agent, not the parent — see *Delegation*):

1. **Read repo conventions** (`CLAUDE.md`/`AGENTS.md`): integration branch (TrainMe = `staging`, else the default branch), branch-name prefixes (`fix/` / `feat/`), test/lint commands, and any "review before merge" zones. (Read-only — the parent does this to brief the agent. Respect the per-run PR cap — see Throttle.)
2. **Delegate the coding to a worktree-isolated sub-agent** (`feedback_delegate_coding`, `feedback_agent_worktree_isolation`). Brief it with **repo-relative paths only**. The agent's first act is to set `status:building` and remove other `status:` labels (the in-run double-build guard); then it branches from the integration branch (`feedback_branch_sub_agent_from_staging`):
   ```
   git fetch origin <integration-branch>
   git checkout -b fix/issue-<N>-<slug> origin/<integration-branch>
   ```
   The brief must: state the issue + acceptance criteria, require the repo's tests/lint to pass, forbid touching unrelated files, and produce the fix only — commit + push the branch, but **do not open the PR yet** (no merge, no deploy).
3. **Parent verify (read-only).** When the sub-agent reports done, the parent confirms the branch exists with a real diff, scans the changed files for conflict markers (`gotcha_test_scripts_index_cascade` — must be 0), and sanity-checks any migration structure. Note: a worktree-isolated Dart build emits false-positive URI/analyzer errors because the worktree has no `flutter pub get` — that is environment noise, not a regression. If the diff is empty or bogus, do NOT hand-patch — re-delegate or escalate (`help wanted` + assign Carl) and fail loud.
4. **Delegate the closeout.** Resume the build sub-agent (it still holds the branch + change context for a good PR body) or spawn a closeout sub-agent to open a PR **targeting the integration branch**:
   ```bash
   gh pr create --repo "$REPO" --base <integration-branch> --head fix/issue-<N>-<slug> \
     --title "<type>(scope): <summary> (#<N>)" \
     --body "Fixes #<N>"$'\n\n'"<what changed + how it was verified>"$'\n\n'"<!-- managed-issue-bot -->"
   ```
   Use `Fixes #N` for bugs, `Implements #N` for features. Add `ios-impact` to the PR if it touched Dart/Swift/`pubspec` (TrainMe convention). **If the change touched a review-before-merge zone** (`feedback_sensitive_code_review_before_merge` — publish flow, conversion listener, SyncService pull, any `CREATE OR REPLACE FUNCTION` on a client RPC), call it out explicitly in the PR body so Carl knows what to scrutinise. The same agent then closes out: assign the issue to **Carl** (developer gate), set `status:awaiting-merge`, remove `status:building`, and post the **single** consolidated comment linking the PR — build confirmation + PR link in ONE comment, never a separate "starting" and "done" comment. Never merge.
5. **Parent verify (read-only).** Confirm the PR is open against the integration branch, labels are right, the issue is `status:awaiting-merge` + assigned to Carl, and the closing comment carries the marker (`gotcha_gh_pr_merge_silent_success`).

If the build genuinely can't be completed (tests won't pass, ambiguity discovered): remove `status:building`, add `help wanted`, assign Carl, and comment what blocked it. Fail loud.

## Throttle

Triage, grill, and spec **every** eligible issue. But cap **autonomous code PRs at 3 per sweep** (`MAX_PRS=3`). Once the cap is hit, leave remaining build-ready issues untouched (no `status:building`) so the next sweep picks them up. This bounds blast radius on any single unattended run.

## End-of-run report

Print a plain-English summary (Carl reads this; `feedback_explanation_level`):

- A table: issue # · title · action taken · new state.
- PRs opened (with links) — these are the ones awaiting your merge.
- Issues now `status:awaiting-design-approval` — these want your approval comment.
- Anything escalated via `help wanted`.
- Anything that failed and why.

## Common mistakes

- **Posting a comment without the hidden marker** → next sweep mistakes the bot's own comment for a logger reply (or re-asks). Always append `<!-- managed-issue-bot -->`.
- **Writing code on a repo you don't understand** → violates the guard. Diagnose + hand to Carl instead.
- **Setting `status:building` then exceeding the PR cap** → leaves a false "in progress" state. Only set `status:building` when you're actually about to build within the cap.
- **Briefing the sub-agent with absolute paths** → it leaks into Carl's main worktree. Repo-relative paths only.
- **Branching from `main`** on TrainMe → produces a conflict cascade. Branch from the integration branch the conventions name.
- **Multiple comments in one sweep** → noise. Consolidate into one.
- **Treating "approved, but change X" as plain approval** → read the whole comment; fold the instructions in or revise the spec.
- **The parent applying a mutation itself** → violates delegation. The orchestrator decides; a sub-agent posts the comment, edits labels, assigns, branches, and opens the PR. The parent's own `gh`/`git` calls stay read-only (list, view, verify).
- **Assigning Carl when the ball is the submitter's** → a `needs-info` grill puts the next move on the issue author, so assign the **author**, not Carl. Reserve Carl for design approval, awaiting-merge, and `help wanted`.

## Encodes

- `feedback_delegate_coding` · `feedback_agent_worktree_isolation` · `feedback_branch_sub_agent_from_staging` · `feedback_branch_naming_discipline`
- `feedback_ask_before_mobile_deployment` · `feedback_no_silent_fallbacks` · `feedback_explanation_level`
- `gotcha_gh_pr_merge_silent_success` (verify PR/issue state after each mutating gh call)
- `feedback_sensitive_code_review_before_merge` · `gotcha_test_scripts_index_cascade` (parent verify gate: scan for conflict markers + flag review-before-merge zones in the PR body)
