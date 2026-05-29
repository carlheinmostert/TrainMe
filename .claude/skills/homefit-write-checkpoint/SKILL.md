---
name: homefit-write-checkpoint
description: Author the daily or wave-close docs/CHECKPOINT_YYYY-MM-DD.md, commit it direct-to-main via an ephemeral worktree, then pull main back into Carl's current worktree so the file appears in his files panel. Use when Carl says "write checkpoint", "save a checkpoint", "where are we — checkpoint", or at the end of a multi-PR wave.
---

# homefit-write-checkpoint

Generate the canonical checkpoint document for today (or the wave just closed), ship it directly to `main` per the specs-direct-to-main rule, then pull main back into Carl's working worktree so he can see it in his files panel.

## Inputs

- Today's date (already in context).
- The "last checkpoint" — the most recent file matching `docs/CHECKPOINT_*.md` by filename sort.
- The set of PRs merged since that checkpoint.

## Workflow

### 1. Gather material

In parallel:

- `ls docs/CHECKPOINT_*.md | sort | tail -1` — locate the most recent checkpoint.
- `gh pr list --state merged --search "merged:>=<lastCheckpointDate>" --json number,title,headRefName,mergedAt,url` — every PR merged since.
- `git log --since="<lastCheckpointDate>" --pretty=format:"%h %s" origin/main` — direct commits to main (specs, docs, runbooks).
- `git -C <repo> log -1 --format=%h%x09%s origin/main` and `git -C <repo> log -1 --format=%h%x09%s origin/staging` — current tips.
- Read the previous checkpoint to mirror its tone, section order, and depth.

### 2. Draft the checkpoint

Path: `docs/CHECKPOINT_<today>.md`. Required sections (canonical TOC per `feedback_markdown_toc.md`):

```
# Checkpoint — YYYY-MM-DD — <one-line theme>

<one-paragraph opening — what the day was about, what changed, plain English>

## Table of Contents

- [Status at session end](#status-at-session-end)
- [The day's big decisions](#the-days-big-decisions)
- [PR sequence](#pr-sequence)
- [Memory rules added today](#memory-rules-added-today)
- [Open follow-ups for next session](#open-follow-ups-for-next-session)
- [Lessons / gotchas](#lessons--gotchas)
- [Fresh-session handoff](#fresh-session-handoff)

## Status at session end
- Where main is: <short SHA> · <PR link>
- Where staging is: <short SHA> · <PR link>
- Where Carl's iPhone is: <build SHA + wave>
- Blocked on Carl: <bulleted list, unchanged-from-prior if applicable>

## The day's big decisions
<plain-English narrative of the decisions made; skip file paths>

## PR sequence
| # | SHA / PR | Title | Why |
| ... |

## Memory rules added today
- [name](relative/path/to/memory.md) — one-line summary

## Open follow-ups for next session

## Lessons / gotchas

## Fresh-session handoff
<the "READ FIRST" pointer paragraph — what a fresh session needs to know>
```

Style rules:

- Narrative leads, table follows. Carl reads top-down.
- Plain English for the lede and "big decisions" sections (per `feedback_explanation_level.md`). Save file paths and code refs for the PR table.
- Anchor every TOC entry to a real heading slug.
- No emojis. Use `&check;` / `&times;` / em-dashes (`—`) directly.

### 3. Update the "READ FIRST" pointer in `CLAUDE.md`

Open `CLAUDE.md`, find the section that points to the most-recent checkpoint (usually under "Current Phase" or "Key Documents"), and update the pointer to the new file. Keep the prior 2-3 checkpoints listed for historical reference; drop anything older than ~30 days from the active mention.

### 4. Commit direct-to-main via ephemeral worktree

Per `feedback_specs_direct_to_main.md`, never PR a checkpoint:

```
git worktree add /tmp/checkpoint-<today> main
cp docs/CHECKPOINT_<today>.md /tmp/checkpoint-<today>/docs/
cp CLAUDE.md /tmp/checkpoint-<today>/  # if the pointer was updated
cd /tmp/checkpoint-<today>
git add docs/CHECKPOINT_<today>.md CLAUDE.md
git commit -m "docs(checkpoint): <today> — <one-line summary>"
git push origin main
cd -
git worktree remove /tmp/checkpoint-<today>
```

Confirm with Carl before pushing. Never auto-push.

### 5. Pull main back into Carl's current worktree

Per `feedback_pull_main_after_direct_commit.md`, Carl needs the file in his files panel:

```
git fetch origin main
git pull --ff-only origin main
```

If `--ff-only` fails (worktree branch ahead of main), fall back to a surgical drop-in:

```
git fetch origin main
git checkout origin/main -- docs/CHECKPOINT_<today>.md CLAUDE.md
```

Then tell Carl explicitly that the worktree branch has diverged, the file is staged as a pending change, and how to clear it (`git restore --source=HEAD --staged --worktree <file>` once he is done viewing). Don't try `git stash` games or merge commits.

### 6. Report

Hand Carl:

- The local repo-relative path link `[docs/CHECKPOINT_<today>.md](docs/CHECKPOINT_<today>.md)` if the pull succeeded.
- The GitHub commit URL if only the surgical-drop fallback worked.
- The commit SHA.
- A 2-3 sentence plain-English summary of what's in the checkpoint.

## Don'ts

- Don't open a PR for the checkpoint.
- Don't leave the file in Carl's worktree branch — it must hit main today.
- Don't write the checkpoint into the working worktree's `docs/` and then PR it. That risks the worktree-cleanup loss that triggered the rule.
- Don't auto-push without Carl confirming.
- Don't fall through to `git merge origin/main` or `git rebase` when `--ff-only` fails. Surgical checkout only.

## Encodes

- `feedback_specs_direct_to_main`
- `feedback_pull_main_after_direct_commit`
- `feedback_markdown_toc`
- `feedback_explanation_level`
