---
name: homefit:cleanup-worktrees
description: Prune merged, stale, or orphaned agent worktrees under .claude/worktrees/agent-*. Report count freed and disk reclaimed. Use when Carl says "clean up worktrees", "prune agents", "worktree cleanup", "kill orphan agents", or notices the agent-* directory bloat (currently 120+ worktrees alive).
---

# homefit:cleanup-worktrees

Prune dead agent worktrees from `.claude/worktrees/agent-*`. Carl runs many parallel agents in isolation:worktree mode; orphaned worktrees pile up and fragment the repo. This skill enumerates candidates, classifies them, shows the list, and waits for explicit confirmation before any destructive op.

## Inputs

- No required inputs. Optional: a max-age override in days (default: 14 for "stale" classification, 7 for "active" guard).
- The repo root is `/Users/chm/dev/TrainMe`. Worktrees live at `.claude/worktrees/agent-*` (repo-relative).

## Workflow

### 1. Enumerate

Run from the repo root:

- `git worktree list --porcelain` — full active worktree set with branch + HEAD.
- `ls -la .claude/worktrees/` — file-system view, including orphaned dirs that git no longer tracks.
- Build the candidate set: every `.claude/worktrees/agent-*` path. Skip non-agent prefixes (`priceless-ishizaka-*`, `thirsty-shaw-*`, etc. — those are the user's worktrees, not agent isolations).

### 2. Classify each candidate

For each agent worktree, produce a classification tag:

- **Active** — has uncommitted changes OR mtime within last 7 days OR the branch has commits not on `origin/main` AND not on `origin/staging`. SKIP these.
- **Orphan** — the parent session ID (per `.claude/hooks/rewrite-agent-prompts.py` naming convention) is no longer in active sessions. Candidate for removal.
- **Merged** — the worktree's branch is reachable from `origin/main` OR `origin/staging`. Check via:
  - `git merge-base --is-ancestor <branch> origin/main` (exit 0 == merged)
  - PLUS `gh pr list --state merged --head <branch> --limit 1` — squash-merged PRs do NOT show via `is-ancestor`, so the gh check is load-bearing.
- **Stale** — mtime > 14 days AND not in active sessions AND no uncommitted changes AND no unpushed commits. Candidate for removal.

Per-worktree data to surface for the user:

- Path (repo-relative)
- Branch name
- Classification
- mtime (days ago)
- Disk size (use `du -sh <path>` per worktree)
- One-line reason (e.g. "PR #287 merged", "session abc123 no longer active", "stale 23d")

### 3. Show the candidate list

Total active worktrees, total agent-* count, and the candidate list. Chunk into groups of 20 if the list is long. Present as a table:

```
#   path                                     branch                  class    mtime  size   reason
1   .claude/worktrees/agent-a1518cef...      claude/feat-foo         merged   18d    420M   PR #284 merged
2   .claude/worktrees/agent-a4d0b7fd...      claude/fix-bar          orphan   12d    310M   session not active
...
```

Sum the candidate disk usage and report: "N candidates totalling X GB."

### 4. Wait for explicit confirmation

NEVER auto-delete. Ask Carl:

> "Remove all N? Or a subset? (e.g. 'all', '1-5,8,12', 'merged only', 'skip 7')"

He may also ask to inspect a specific worktree before pruning — surface `git -C <path> status` + `git -C <path> log --oneline -5` on demand.

### 5. Remove

After confirmation, for each approved candidate:

1. `git worktree remove --force <path>` — `--force` because we already filtered out worktrees with uncommitted changes.
2. `git branch -D <branch>` — clean up the branch reference. Tolerate "branch not found" (some agent worktrees never created a branch).
3. Track success / failure per item.

If a removal fails (e.g. git is using the worktree elsewhere), surface the error inline and skip; don't bail the whole run.

### 6. Report

End the reply with:

- Total worktrees removed.
- Total disk reclaimed (sum of pre-deletion `du -sh` values).
- Remaining active worktree count.
- Any failures with their error messages.

## Critical safety rules

- NEVER remove the main worktree (the one at `/Users/chm/dev/TrainMe` proper).
- NEVER remove a worktree on `main`, `staging`, or `prod` branches.
- NEVER remove the current shell's working-directory worktree (the one this skill is running in). Detect via `pwd` and exclude.
- NEVER remove a worktree with uncommitted changes — `git -C <path> status --porcelain` must return empty before classifying as removable. Carl may have in-flight work the agent left unstaged.
- NEVER auto-delete without Carl's explicit list-or-subset confirmation. Skill describes; user approves.
- If unsure about a worktree's status, classify as Active and SKIP. Better to leak one than delete real work.

## Don'ts

- Don't use `rm -rf` on the worktree dir directly — always go through `git worktree remove` so git's metadata stays consistent.
- Don't delete the parent `.claude/worktrees/` directory itself.
- Don't touch non-agent worktrees (`priceless-*`, `thirsty-*`, dictionary-word prefixes — those are Carl's primary working dirs).
- Don't run `git gc` or `git prune` after — that's a separate operation; ask Carl if he wants it as a follow-up.
- Don't notify Carl via WhatsApp / iMessage; this is a local-only chore.

## Encodes

- The agent-worktree-isolation pattern (`feedback_agent_worktree_isolation` + `.claude/hooks/rewrite-agent-prompts.py`).
- The "investigate before deleting" rule from the system prompt's git safety protocol.
- Carl's "ask permission then execute" preference (`feedback_use_apis_not_dashboards` extended to local file-system destructive ops).
