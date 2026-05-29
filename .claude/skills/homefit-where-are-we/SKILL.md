---
name: homefit-where-are-we
description: Fresh-session context briefing — read the latest checkpoint, list open PRs, show iPhone build SHA, surface what's blocked on Carl, and report any active failures. Use when Carl says "where were we", "catch me up", "what's the latest", "where are we", "status", or starts a fresh session and needs to be brought up to speed.
---

# homefit-where-are-we

Bring Carl up to speed at the start of a session. Read the latest checkpoint, summarise the current state of main / staging / iPhone, surface what's open, and report in plain English. The output is for Carl; pitch it at his level (no file paths, no function names) unless he asks for depth.

## Workflow

### 1. Locate the most recent checkpoint

```
ls /Users/chm/dev/TrainMe/docs/CHECKPOINT_*.md | sort | tail -1
```

Read its "Status at session end", "Open follow-ups for next session", and "Blocked on Carl" sections (or whichever sections that checkpoint uses — sections drifted a bit over time).

Extract the `<lastCheckpointDate>` from the filename for downstream queries.

### 2. Gather live state in parallel

Run these in a single Bash block:

- `gh pr list --state open --json number,title,headRefName,baseRefName,updatedAt,url --limit 20` — what's open.
- `git -C /Users/chm/dev/TrainMe log --since="<lastCheckpointDate>" --pretty=format:"%h %s" origin/main` — what's landed on main since.
- `git -C /Users/chm/dev/TrainMe log --since="<lastCheckpointDate>" --pretty=format:"%h %s" origin/staging` — what's landed on staging since.
- `git -C /Users/chm/dev/TrainMe log -1 --format=%h%x09%s origin/main` and same for `origin/staging` — current tips.
- `git -C /Users/chm/dev/TrainMe tag --list "v2026-*" --sort=-creatordate | head -5` — recent release tags.
- `git -C /Users/chm/dev/TrainMe tag --list "mobile-v*" --sort=-creatordate | head -3` — most recent mobile uploads (TestFlight anchor).

### 3. iPhone build SHA

Check `app/.last_dart_define_fingerprint` if it exists, otherwise infer from the most recent `mobile-v*` tag. If a more recent staging-install ran (look in `git log` for `./install-device.sh` references or the test-scripts wave most recently created in `docs/test-scripts/`), surface that SHA instead.

### 4. Vercel spend snapshot (conditional)

If any merge to `main` since the last checkpoint touched `web-portal/` or `web-player/` paths, pull MTD spend (per `feedback_vercel_spend_monitor.md`). Either:

- `vercel billing` if the CLI exposes it, or
- direct Carl to `https://vercel.com/carlheinmosterts-projects/settings/billing` and ask him to peek.

Skip this step if nothing web-deploy-triggering has landed since the last checkpoint.

### 5. Surface failures

Quick scan for:

- Open PRs with `failure` checks: `gh pr list --state open --json number,title,statusCheckRollup --limit 10` then filter for failures.
- Any `docs/test-scripts/*.results.json` updated since last checkpoint that contain `"status":"fail"`.
- Any `conversion_error.log`-related discussion in recent commit messages.

### 6. Compose the briefing

Plain-English structure (per `feedback_explanation_level.md`):

1. **Where main is.** One sentence — "Main is at <short SHA>, last merge was <PR title>."
2. **Where staging is.** Diverged from main or in sync, and what's pending promotion.
3. **Where Carl's iPhone is.** Build SHA + the wave it represents. Note if it's old vs current main.
4. **What's open.** Bullet list of open PRs with one-line context each. Flag any that target `main` instead of `staging` (against the new release-train discipline).
5. **Blocked on Carl.** Carry forward from the latest checkpoint's "Blocked on Carl" section, updated for anything resolved since.
6. **Anything actively broken?** Failed PR checks, failed test-script items, conversion errors flagged in commits — one or two lines if found, otherwise "nothing on fire".
7. **Vercel spend.** Only if §4 ran.

Skip file paths, function names, line numbers. If Carl asks "what file is that in", go deeper.

### 7. Suggest next moves

End with 1-2 sentences proposing the obvious next move ("Two stale PRs (#NNN, #MMM) are waiting on you to rebase onto staging"; "iPhone is two waves behind main — want me to ship to phone?"). Carl can take it or redirect.

## Don'ts

- Don't dump every PR title and every commit. Summarise.
- Don't lead with technical detail. Plain English first.
- Don't run `git pull` or other state-modifying commands during a briefing.
- Don't read older checkpoints beyond the latest unless Carl explicitly asks for the longer arc.
- Don't recap what's in `CLAUDE.md` — Carl already knows the project.

## Encodes

- `feedback_explanation_level`
- `feedback_vercel_spend_monitor`
